"""Core usage-metrics ingestion: query Log Analytics, shape into long rows, upsert.

Shared between the CLI tool (getmetrics.py) and the Azure function app (function_app.py),
mirroring the structure of src/cfmetrics/.

Source-parametrised via METRICS_SOURCE: the *same* code is deployed twice —
  - a 'frontdoor' reader (iOS + photon, reading shared-law), and
  - a 'cloudflare' reader (pmtiles + offline maps, reading the Android App Insights) —
each running only its own queries and writing only its own metric names into the one
shared Postgres table (usage_metrics).

Writes are upserts on the natural key (metric_ts, metric_name, source_rg, country); the
unique index is NULLS NOT DISTINCT, so the Cloudflare (NULL-country) rows dedupe to one
row per hour and ON CONFLICT needs no NULL-aware predicate. Rows are never deleted, so
data that has aged out of the 30-day Log Analytics window survives in Postgres.

KQL note: queries do their own hourly binning (bin(..., 1h)); the time window is applied
via the query timespan rather than an explicit `where TimeGenerated` filter, mirroring
the saved Log Analytics queries in templates/. Output columns are named after the metric:
every column except `metric_ts` and (optional) `country` is treated as a measure.
"""

import os
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Optional

import psycopg
from azure.monitor.query import LogsQueryClient, LogsQueryStatus

# Entra-token scope for Azure Database for PostgreSQL.
PG_TOKEN_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"


@dataclass
class MetricRow:
    """One hourly measurement destined for usage_metrics."""
    metric_ts: datetime         # start of the hour, UTC (tz-aware)
    metric_name: str
    source_rg: str
    country: Optional[str]      # None where the source has no country dimension
    value: int


# --- Front Door queries (iOS + photon) -------------------------------------------------
#
# Per-country hourly request counts, extending templates/iosrequestquery.txt and
# templates/photonrequestquery.txt with a clientCountry_s dimension. The three measures
# mirror the saved query: total successes, origin (cache-MISS) successes, and errors.

_IOS_REQUESTS_KQL = """
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where requestUri_s startswith "https://prd2." or requestUri_s startswith "https://tst."
| where requestUri_s contains "/tiles/"
| extend isSuccess = toint(httpStatusCode_s) == 200
| extend isMiss = tostring(cacheStatus_s) == "MISS"
| summarize
    ios_requests = countif(isSuccess),
    ios_requests_origin = countif(isSuccess and isMiss),
    ios_requests_error = countif(not(isSuccess)),
    ios_requests_http2 = countif(isSuccess and httpVersion_s == "2.0.0.0")
    by metric_ts = bin(TimeGenerated, 1h), country = tostring(clientCountry_s)
"""

_PHOTON_REQUESTS_KQL = """
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where requestUri_s startswith "https://photon." or requestUri_s startswith "https://photontest."
| where requestUri_s contains "/photon/"
| extend isSuccess = toint(httpStatusCode_s) == 200
| extend isMiss = tostring(cacheStatus_s) == "MISS"
| summarize
    photon_requests = countif(isSuccess),
    photon_requests_origin = countif(isSuccess and isMiss),
    photon_requests_error = countif(not(isSuccess))
    by metric_ts = bin(TimeGenerated, 1h), country = tostring(clientCountry_s)
"""

# Session-start counts. A session is an IP:port with an inactivity timeout: a gap longer
# than {timeout} minutes from the same client starts a new session (KQL
# row_window_session, restarting whenever the client changes after the sort). Each
# session is counted once, in the hour it *started*, which keeps sessions additive across
# time and bounds them so they do not reappear as the 30-day window slides. The first
# bound (1d) just caps a single session's total length; the second ({timeout}m) is the
# inactivity gap that actually defines the session boundary.
_IOS_SESSIONS_KQL = """
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where requestUri_s startswith "https://prd2." or requestUri_s startswith "https://tst."
| where requestUri_s contains "/tiles/"
| project TimeGenerated,
          client = strcat(tostring(clientIp_s), ":", tostring(clientPort_s)),
          country = tostring(clientCountry_s),
          httpVersion_s
| order by client asc, TimeGenerated asc
| extend session_start = row_window_session(TimeGenerated, 1d, {timeout}m, client != prev(client))
| summarize country = take_any(country),
            v2_only = countif(httpVersion_s != "2.0.0.0") == 0
            by client, session_start
| summarize ios_sessions = count(),
            ios_sessions_http2 = countif(v2_only)
            by metric_ts = bin(session_start, 1h), country
"""

_PHOTON_SESSIONS_KQL = """
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where requestUri_s startswith "https://photon." or requestUri_s startswith "https://photontest."
| where requestUri_s contains "/photon/"
| project TimeGenerated,
          client = strcat(tostring(clientIp_s), ":", tostring(clientPort_s)),
          country = tostring(clientCountry_s)
| order by client asc, TimeGenerated asc
| extend session_start = row_window_session(TimeGenerated, 1d, {timeout}m, client != prev(client))
| summarize country = take_any(country) by client, session_start
| summarize photon_sessions = count() by metric_ts = bin(session_start, 1h), country
"""


# --- Cloudflare queries (pmtiles + offline maps) ---------------------------------------
#
# The Android instance's App Insights holds the cfmetrics traces (see
# templates/cf-pmtiles-requests-query.txt). These rows carry no country dimension.
# pmtiles_requests is the worker's total request count; offline_maps_downloads_success is
# the extracts worker's `success` count. max() per hour collapses any duplicate emissions.

_PMTILES_KQL = """
AppTraces
| where OperationName == "cfmetrics"
| where Message matches regex @"^METRIC: pmtiles worker requests: \\d"
| extend Count = tolong(extract(@"worker requests: (\\d+)", 1, Message))
| summarize pmtiles_requests = max(Count) by metric_ts = bin(TimeGenerated, 1h)
"""

_OFFLINE_MAPS_KQL = """
AppTraces
| where OperationName == "cfmetrics"
| where Message matches regex @"^METRIC: extracts worker requests success: \\d"
| extend Count = tolong(extract(@"requests success: (\\d+)", 1, Message))
| summarize offline_maps_downloads_success = max(Count) by metric_ts = bin(TimeGenerated, 1h)
"""

_CLOUDFLARE_QUERIES = [_PMTILES_KQL, _OFFLINE_MAPS_KQL]


def _frontdoor_queries(timeout_minutes):
    """Front Door queries with the session timeout substituted in."""
    return [
        _IOS_REQUESTS_KQL,
        _PHOTON_REQUESTS_KQL,
        _IOS_SESSIONS_KQL.format(timeout=timeout_minutes),
        _PHOTON_SESSIONS_KQL.format(timeout=timeout_minutes),
    ]


def queries_for(source, timeout_minutes):
    """Return the list of KQL queries for the given METRICS_SOURCE."""
    if source == "frontdoor":
        return _frontdoor_queries(timeout_minutes)
    if source == "cloudflare":
        return _CLOUDFLARE_QUERIES
    raise ValueError(f"unknown METRICS_SOURCE '{source}' (expected 'frontdoor' or 'cloudflare')")


# --- Log Analytics querying + reshaping -------------------------------------------------

def logs_client(credential):
    return LogsQueryClient(credential)


def run_kql(client, workspace_id, kql, start, end):
    """Run one KQL query over [start, end) and return its first result table."""
    response = client.query_workspace(workspace_id, query=kql, timespan=(start, end))
    if response.status == LogsQueryStatus.SUCCESS:
        return response.tables[0]
    if response.status == LogsQueryStatus.PARTIAL:
        # Surface the partial error rather than silently undercounting.
        raise RuntimeError(f"Log Analytics query returned partial data: {response.partial_error}")
    raise RuntimeError(f"Log Analytics query failed: {response}")


def melt_table(table, source_rg):
    """Turn a wide result table (metric_ts, [country], <measure columns>) into MetricRows.

    Every column other than metric_ts and country is a measure; each becomes one row.
    A blank country is normalised to NULL; a NULL measure value is skipped.
    """
    columns = list(table.columns)
    ts_idx = columns.index("metric_ts")
    country_idx = columns.index("country") if "country" in columns else None
    measures = [(i, name) for i, name in enumerate(columns)
                if name not in ("metric_ts", "country")]

    rows = []
    for r in table.rows:
        ts = r[ts_idx]
        country = r[country_idx] if country_idx is not None else None
        if not country:                      # "" or None → genuine NULL
            country = None
        for i, name in measures:
            value = r[i]
            if value is None:
                continue
            rows.append(MetricRow(ts, name, source_rg, country, int(value)))
    return rows


def collect_rows(source, client, workspace_id, source_rg, start, end, timeout_minutes):
    """Run every query for `source` and return the combined list of MetricRows."""
    rows = []
    for kql in queries_for(source, timeout_minutes):
        rows.extend(melt_table(run_kql(client, workspace_id, kql, start, end), source_rg))
    return rows


# --- Postgres upsert --------------------------------------------------------------------

_UPSERT_SQL = """
INSERT INTO usage_metrics (metric_ts, metric_name, source_rg, country, value)
VALUES (%s, %s, %s, %s, %s)
ON CONFLICT (metric_ts, metric_name, source_rg, country)
DO UPDATE SET value = EXCLUDED.value
"""


def pg_token(credential):
    return credential.get_token(PG_TOKEN_SCOPE).token


def connect_pg(credential):
    """Connect to the metrics DB using an Entra access token as the password.

    Host/db/user come from the PG_* app settings; the user is the Entra role name
    (PG_USER), which the credential's principal must be mapped to.
    """
    return psycopg.connect(
        host=os.environ["PG_HOST"],
        dbname=os.environ["PG_DATABASE"],
        user=os.environ["PG_USER"],
        password=pg_token(credential),
        sslmode=os.environ.get("PG_SSLMODE", "require"),
    )


def upsert_rows(conn, rows):
    """Upsert MetricRows; returns the number of rows written. Never deletes."""
    if not rows:
        return 0
    with conn.cursor() as cur:
        cur.executemany(_UPSERT_SQL, [
            (r.metric_ts, r.metric_name, r.source_rg, r.country, r.value) for r in rows
        ])
    conn.commit()
    return len(rows)


# --- Time windows -----------------------------------------------------------------------

def window_days(days):
    """Return (start, end) covering the last `days` days, ending at the last clock hour.

    Aligning the end to the clock hour keeps successive runs' windows consistent and the
    hourly bins stable. `days` may be fractional.
    """
    end = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    start = end - timedelta(days=days)
    return start, end
