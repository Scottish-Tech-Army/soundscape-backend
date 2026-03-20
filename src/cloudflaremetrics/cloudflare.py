"""Cloudflare GraphQL API queries for worker invocation and R2 bucket metrics.

Shared between the CLI tool (getmetrics.py) and the Azure function app
(function_app.py).
"""

import logging
from datetime import datetime, timedelta, timezone

import requests

GRAPHQL_URL = "https://api.cloudflare.com/client/v4/graphql"

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
# orderBy datetimeHour_DESC gives us the most recent hourly snapshot.
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
    result = response.json()
    if result.get("errors"):
        raise RuntimeError(f"GraphQL errors: {result['errors']}")
    return result


def fetch_worker_metrics(token, account_id, script, start, end):
    """Fetch worker invocation metrics for the given script and time window.

    Returns a dict with:
        requests_by_status  dict of status string → request count
        total_requests      int
        total_errors        int  (uncaught script exceptions)
        total_bytes         int  (response body bytes)
        total_wall_us       int  (wall time in microseconds)
        total_cpu_us        int  (CPU time in microseconds)
    """
    result = run_query(token, WORKER_ANALYTICS_QUERY, {
        "accountId": account_id,
        "scriptName": script,
        "start": start,
        "end": end,
    })
    groups = result["data"]["viewer"]["accounts"][0]["workersInvocationsAdaptive"]
    requests_by_status = {
        (g["dimensions"]["status"] or "(none)"): g["sum"]["requests"]
        for g in groups
    }
    return {
        "requests_by_status": requests_by_status,
        "total_requests": sum(g["sum"]["requests"]      for g in groups),
        "total_errors":   sum(g["sum"]["errors"]        for g in groups),
        "total_bytes":    sum(g["sum"]["responseBodySize"] for g in groups),
        "total_wall_us":  sum(g["sum"]["wallTime"]      for g in groups),
        "total_cpu_us":   sum(g["sum"]["cpuTimeUs"]     for g in groups),
    }


def fetch_r2_storage(token, account_id, bucket, start, end):
    """Fetch R2 bucket storage snapshot for the given bucket and time window.

    Returns a dict with:
        object_count    int
        payload_size    int  (bytes)
    """
    result = run_query(token, R2_STORAGE_QUERY, {
        "accountId": account_id,
        "bucketName": bucket,
        "start": start,
        "end": end,
    })
    groups = result["data"]["viewer"]["accounts"][0]["r2StorageAdaptiveGroups"]
    if not groups:
        raise RuntimeError(
            f"R2 storage query for bucket '{bucket}' returned no data "
            f"for window {start}–{end} (Cloudflare analytics lag?)"
        )
    logging.debug("R2 storage for '%s': snapshot at %s", bucket, groups[0]["dimensions"]["datetimeHour"])
    return {
        "object_count": groups[0]["max"]["objectCount"],
        "payload_size": groups[0]["max"]["payloadSize"],
    }


def time_window(hours):
    """Return (start_str, end_str) covering the last N complete clock hours.

    The window is aligned to the clock hour (e.g. 14:00–15:00) rather than
    ending at the current second, so successive hourly runs produce
    non-overlapping, gap-free windows regardless of cold-start latency.
    """
    now = datetime.now(timezone.utc)
    end = now.replace(minute=0, second=0, microsecond=0)
    start = end - timedelta(hours=hours)
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    return start.strftime(fmt), end.strftime(fmt)
