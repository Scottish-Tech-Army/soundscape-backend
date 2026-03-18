#!/usr/bin/env python3
"""Fetch Cloudflare Worker and R2 bucket metrics for pmtiles and extracts.

Workers run on workers.dev (no custom zone), so all queries are account-scoped.

Worker metrics (workersInvocationsAdaptive):
  request counts by execution status, response bytes, wall time, CPU time.

R2 bucket metrics (r2StorageAdaptiveGroups):
  object count and payload size. Bucket names match worker script names.

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
from datetime import datetime, timedelta, timezone

import requests

GRAPHQL_URL = "https://api.cloudflare.com/client/v4/graphql"

# Grouped by execution status so we see the breakdown of outcomes:
#   success, scriptThrewException, clientDisconnected, etc.
WORKER_ANALYTICS_QUERY = """
query WorkerMetrics(
    $accountId: String!,
    $scriptName: String!,
    $start: Time!,
    $end: Time!
) {
  viewer {
    accounts(filter: {accountTag: $accountId}) {
      workersInvocationsAdaptive(
        limit: 10000,
        filter: {
          scriptName: $scriptName,
          datetime_geq: $start,
          datetime_leq: $end
        },
        orderBy: [sum_requests_DESC]
      ) {
        sum {
          requests
          errors
          responseBodySize
          wallTime
          cpuTimeUs
        }
        dimensions {
          status
        }
      }
    }
  }
}
"""

# Storage is a gauge so we use max rather than sum. limit: 1 with
# orderBy datetime_DESC gives us the most recent snapshot in the window.
R2_STORAGE_QUERY = """
query R2Storage(
    $accountId: String!,
    $bucketName: String!,
    $start: Time!,
    $end: Time!
) {
  viewer {
    accounts(filter: {accountTag: $accountId}) {
      r2StorageAdaptiveGroups(
        limit: 1,
        filter: {
          bucketName: $bucketName,
          datetime_geq: $start,
          datetime_leq: $end
        },
        orderBy: [datetimeHour_DESC]
      ) {
        max {
          objectCount
          payloadSize
        }
        dimensions {
          datetimeHour
        }
      }
    }
  }
}
"""


def run_query(token, query, variables):
    response = requests.post(
        GRAPHQL_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        json={"query": query, "variables": variables},
        timeout=30,
    )
    response.raise_for_status()
    return response.json()


def fmt_bytes(b):
    if b < 1024:
        return f"{b} B"
    if b < 1024 ** 2:
        return f"{b / 1024:.1f} KB"
    if b < 1024 ** 3:
        return f"{b / 1024 ** 2:.1f} MB"
    return f"{b / 1024 ** 3:.1f} GB"


def fmt_ms(us):
    """Format microseconds as milliseconds."""
    return f"{us / 1000:.1f} ms"


def print_worker_analytics(result, raw):
    if raw:
        print(json.dumps(result, indent=2))
        return

    if result.get("errors"):
        print(f"  GraphQL errors: {result['errors']}")
        return

    groups = result["data"]["viewer"]["accounts"][0]["workersInvocationsAdaptive"]
    if not groups:
        print("  No data for this period.")
        return

    total_requests = sum(g["sum"]["requests"] for g in groups)
    total_errors   = sum(g["sum"]["errors"] for g in groups)
    total_bytes    = sum(g["sum"]["responseBodySize"] for g in groups)
    total_wall     = sum(g["sum"]["wallTime"] for g in groups)
    total_cpu      = sum(g["sum"]["cpuTimeUs"] for g in groups)

    print(f"  Requests:          {total_requests}")
    print(f"  Script errors:     {total_errors}  (uncaught exceptions)")
    print(f"  Response bytes:    {fmt_bytes(total_bytes)}")
    print(f"  Total wall time:   {fmt_ms(total_wall)}")
    print(f"  Total CPU time:    {fmt_ms(total_cpu)}")
    if total_requests:
        print(f"  Avg wall time:     {fmt_ms(total_wall / total_requests)} / request")

    print(f"\n  Execution status:")
    for g in groups:
        status = g["dimensions"]["status"]
        reqs   = g["sum"]["requests"]
        print(f"    {status or '(none)':<30} {reqs:>10} requests")


def print_r2_storage(result, raw):
    if raw:
        print(json.dumps(result, indent=2))
        return

    if result.get("errors"):
        print(f"  GraphQL errors: {result['errors']}")
        return

    groups = result["data"]["viewer"]["accounts"][0]["r2StorageAdaptiveGroups"]
    if not groups:
        print("  No data for this period.")
        return

    obj_count    = groups[0]["max"]["objectCount"]
    payload_size = groups[0]["max"]["payloadSize"]
    print(f"  Objects:           {obj_count:,}")
    print(f"  Payload size:      {fmt_bytes(payload_size)}")


def fetch_for_script(token, account_id, script, start, end, raw):
    print(f"\n{'=' * 56}")
    print(f"  Worker / bucket: {script}")
    print(f"  Period: {start}  →  {end}")
    print(f"{'=' * 56}")

    print("\nWorker metrics:")
    try:
        result = run_query(token, WORKER_ANALYTICS_QUERY, {
            "accountId": account_id,
            "scriptName": script,
            "start": start,
            "end": end,
        })
        print_worker_analytics(result, raw)
    except requests.HTTPError as e:
        print(f"  HTTP error: {e}")

    print("\nR2 bucket storage:")
    try:
        result = run_query(token, R2_STORAGE_QUERY, {
            "accountId": account_id,
            "bucketName": script,
            "start": start,
            "end": end,
        })
        print_r2_storage(result, raw)
    except requests.HTTPError as e:
        print(f"  HTTP error: {e}")


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

    now   = datetime.now(timezone.utc)
    start = now - timedelta(hours=args.hours)
    start_str = start.strftime("%Y-%m-%dT%H:%M:%SZ")
    end_str   = now.strftime("%Y-%m-%dT%H:%M:%SZ")

    for script in [pmtiles_script, extracts_script]:
        try:
            fetch_for_script(token, account_id, script, start_str, end_str, args.raw)
        except KeyError as e:
            print(f"\nUnexpected response structure for {script}: missing key {e}", file=sys.stderr)
            print("Re-run with --raw to inspect the full response.", file=sys.stderr)

    print()


if __name__ == "__main__":
    main()
