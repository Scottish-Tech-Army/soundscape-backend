#!/usr/bin/env python3
"""Fetch Cloudflare Worker and R2 bucket metrics for pmtiles and extracts.

Stage 1 validation tool — uses the same query logic as the function app.

Note: HTTP response status codes (e.g. 503 "data not available yet") are NOT
available via the Cloudflare analytics API for workers.dev workers on this
account plan.  Distinguishing 503s from 200s will require instrumenting the
worker via the Workers Analytics Engine — deferred to a later phase.

Required environment variables:
    CF_API_TOKEN        Cloudflare API token (needs Analytics:Read permission)
    CF_ACCOUNT_ID       Cloudflare account tag (hex ID)
    CF_PMTILES_SCRIPT   Name of the pmtiles worker script (also the bucket name)
    CF_EXTRACTS_SCRIPT  Name of the extracts worker script (also the bucket name)

Usage:
    CF_API_TOKEN=xxx CF_ACCOUNT_ID=yyy ... python getmetrics.py
    python getmetrics.py --hours 24
    python getmetrics.py --raw     # dump raw GraphQL responses for inspection
"""

import argparse
import json
import os
import sys

import requests

from cloudflare import (
    fetch_r2_storage,
    fetch_worker_metrics,
    run_query,
    time_window,
    WORKER_ANALYTICS_QUERY,
    R2_STORAGE_QUERY,
)


def fmt_bytes(b):
    if b < 1024:
        return f"{b} B"
    if b < 1024 ** 2:
        return f"{b / 1024:.1f} KB"
    if b < 1024 ** 3:
        return f"{b / 1024 ** 2:.1f} MB"
    return f"{b / 1024 ** 3:.1f} GB"


def fmt_ms(us):
    return f"{us / 1000:.1f} ms"


def fetch_and_print(token, account_id, script, start, end, raw):
    print(f"\n{'=' * 56}")
    print(f"  Worker / bucket: {script}")
    print(f"  Period: {start}  →  {end}")
    print(f"{'=' * 56}")

    print("\nWorker metrics:")
    try:
        if raw:
            result = run_query(token, WORKER_ANALYTICS_QUERY, {
                "accountId": account_id, "scriptName": script,
                "start": start, "end": end,
            })
            print(json.dumps(result, indent=2))
        else:
            m = fetch_worker_metrics(token, account_id, script, start, end)
            print(f"  Requests:          {m['total_requests']}")
            print(f"  Script errors:     {m['total_errors']}  (uncaught exceptions)")
            print(f"  Response bytes:    {fmt_bytes(m['total_bytes'])}")
            print(f"  Total wall time:   {fmt_ms(m['total_wall_us'])}")
            print(f"  Total CPU time:    {fmt_ms(m['total_cpu_us'])}")
            if m['total_requests']:
                print(f"  Avg wall time:     {fmt_ms(m['total_wall_us'] / m['total_requests'])} / request")
            print(f"\n  Execution status:")
            for status, count in sorted(m['requests_by_status'].items()):
                print(f"    {status:<30} {count:>10} requests")
    except (RuntimeError, requests.HTTPError) as e:
        print(f"  Error: {e}")

    print("\nR2 bucket storage:")
    try:
        if raw:
            result = run_query(token, R2_STORAGE_QUERY, {
                "accountId": account_id, "bucketName": script,
                "start": start, "end": end,
            })
            print(json.dumps(result, indent=2))
        else:
            r2 = fetch_r2_storage(token, account_id, script, start, end)
            if r2["object_count"] == 0 and r2["payload_size"] == 0:
                print("  No data for this period.")
            else:
                print(f"  Objects:           {r2['object_count']:,}")
                print(f"  Payload size:      {fmt_bytes(r2['payload_size'])}")
    except (RuntimeError, requests.HTTPError) as e:
        print(f"  Error: {e}")


def main():
    parser = argparse.ArgumentParser(
        description="Fetch Cloudflare Worker and R2 bucket metrics for pmtiles and extracts"
    )
    parser.add_argument(
        "--hours", type=int, default=1,
        help="Hours of history to fetch (default: 1)"
    )
    parser.add_argument(
        "--raw", action="store_true",
        help="Print raw GraphQL responses for inspection"
    )
    args = parser.parse_args()

    token           = os.environ.get("CF_API_TOKEN")
    account_id      = os.environ.get("CF_ACCOUNT_ID")
    pmtiles_script  = os.environ.get("CF_PMTILES_SCRIPT")
    extracts_script = os.environ.get("CF_EXTRACTS_SCRIPT")

    missing = [
        name for val, name in [
            (token,           "CF_API_TOKEN"),
            (account_id,      "CF_ACCOUNT_ID"),
            (pmtiles_script,  "CF_PMTILES_SCRIPT"),
            (extracts_script, "CF_EXTRACTS_SCRIPT"),
        ]
        if not val
    ]
    if missing:
        print(f"Error: missing environment variables: {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)

    start, end = time_window(args.hours)
    for script in [pmtiles_script, extracts_script]:
        fetch_and_print(token, account_id, script, start, end, args.raw)

    print()


if __name__ == "__main__":
    main()
