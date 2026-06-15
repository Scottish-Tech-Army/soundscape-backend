#!/usr/bin/env python3
"""Validate the usage-metrics Log Analytics queries locally (Stage-1 tool).

Mirrors src/cfmetrics/getmetrics.py: runs the *same* query/transform code as the
function app and prints the resulting long rows, so per-metric totals can be compared
against the equivalent saved Log Analytics queries, and session counts checked for
stability as the window widens. With --write it also upserts (for exercising the DB path).

Auth: DefaultAzureCredential (your `az login`). For Log Analytics you need reader access
on the workspace; for --write your principal must be a mapped Postgres role with write
access (set PG_USER to your own role/UPN locally).

Required environment:
    LAW_CUSTOMER_ID    Log Analytics workspace GUID to query
    METRICS_SOURCE     frontdoor | cloudflare   (overridable with --source)
    SOURCE_RG          RG name written into the source_rg label (default '(local)')
    PG_HOST/PG_DATABASE/PG_USER   only needed with --write

Usage:
    LAW_CUSTOMER_ID=... METRICS_SOURCE=frontdoor python getmetrics.py --days 1
    python getmetrics.py --source cloudflare --days 7
    python getmetrics.py --days 2 --write          # also upsert to Postgres
"""

import argparse
import os
import sys
from collections import defaultdict

from azure.identity import DefaultAzureCredential

from usagemetrics import collect_rows, connect_pg, logs_client, upsert_rows, window_days


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--days", type=float, default=1.0,
                        help="Days of history to query (default: 1; fractional allowed)")
    parser.add_argument("--source", choices=["frontdoor", "cloudflare"],
                        default=os.environ.get("METRICS_SOURCE"),
                        help="Metrics source (default: $METRICS_SOURCE)")
    parser.add_argument("--timeout", type=int,
                        default=int(os.environ.get("SESSION_TIMEOUT_MINUTES", "30")),
                        help="Session inactivity timeout in minutes (default: 30)")
    parser.add_argument("--detail", action="store_true",
                        help="Print every row, not just per-metric totals")
    parser.add_argument("--write", action="store_true",
                        help="Also upsert the rows into Postgres (needs PG_* + write access)")
    args = parser.parse_args()

    workspace_id = os.environ.get("LAW_CUSTOMER_ID")
    source_rg = os.environ.get("SOURCE_RG", "(local)")
    missing = [n for v, n in [(workspace_id, "LAW_CUSTOMER_ID"), (args.source, "METRICS_SOURCE/--source")] if not v]
    if missing:
        print(f"Error: missing required value(s): {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)

    credential = DefaultAzureCredential()
    start, end = window_days(args.days)
    print(f"Querying {args.source} over {start} → {end} (source_rg={source_rg})\n")

    rows = collect_rows(args.source, logs_client(credential), workspace_id,
                        source_rg, start, end, args.timeout)

    # Per-metric totals — the figures to compare against the saved Log Analytics queries.
    totals = defaultdict(int)
    counts = defaultdict(int)
    for r in rows:
        totals[r.metric_name] += r.value
        counts[r.metric_name] += 1
    print(f"{'metric_name':<34}{'sum(value)':>14}{'rows':>8}")
    print("-" * 56)
    for name in sorted(totals):
        print(f"{name:<34}{totals[name]:>14,}{counts[name]:>8}")
    print(f"\n{len(rows)} rows total.")

    if args.detail:
        print()
        for r in sorted(rows, key=lambda r: (r.metric_name, r.metric_ts, r.country or "")):
            print(f"  {r.metric_ts:%Y-%m-%d %H:%M}  {r.metric_name:<34}"
                  f"{(r.country or '-'):<22}{r.value:>10,}")

    if args.write:
        print("\nUpserting to Postgres...")
        with connect_pg(credential) as conn:
            written = upsert_rows(conn, rows)
        print(f"Upserted {written} rows.")


if __name__ == "__main__":
    main()
