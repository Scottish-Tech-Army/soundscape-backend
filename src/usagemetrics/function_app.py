import logging
import os

import azure.functions as func
from azure.identity import ManagedIdentityCredential

from usagemetrics import collect_rows, connect_pg, logs_client, upsert_rows, window_days

app = func.FunctionApp()

# Source parametrisation + behaviour, all from app settings (see metricsdb.bicep).
SOURCE              = os.environ["METRICS_SOURCE"]            # 'frontdoor' | 'cloudflare'
SOURCE_RG           = os.environ["SOURCE_RG"]                 # RG name written into the source_rg label
WORKSPACE_ID        = os.environ["LAW_CUSTOMER_ID"]           # Log Analytics workspace GUID
UAMI_CLIENT_ID      = os.environ["UAMI_CLIENT_ID"]            # identity for LA read + PG write
SESSION_TIMEOUT     = int(os.environ.get("SESSION_TIMEOUT_MINUTES", "30"))
NIGHTLY_WINDOW_DAYS = float(os.environ.get("NIGHTLY_WINDOW_DAYS", "2"))
BACKFILL_WINDOW_DAYS = float(os.environ.get("BACKFILL_WINDOW_DAYS", "30"))
TRIGGER_SCHEDULE    = os.environ.get("TRIGGER_SCHEDULE", "0 3 * * *")


def _ingest(days):
    """Query the trailing `days`-day window and upsert. Returns (start, end, row_count)."""
    credential = ManagedIdentityCredential(client_id=UAMI_CLIENT_ID)
    start, end = window_days(days)
    rows = collect_rows(SOURCE, logs_client(credential), WORKSPACE_ID,
                        SOURCE_RG, start, end, SESSION_TIMEOUT)
    with connect_pg(credential) as conn:
        written = upsert_rows(conn, rows)
    return start, end, written


@app.timer_trigger(schedule=TRIGGER_SCHEDULE, arg_name="timer")
def usagemetrics_timer(timer: func.TimerRequest):
    """Nightly: re-query a trailing window (comfortably wider than the session timeout and
    any late-log arrival) and upsert. The most recent hours are re-covered and corrected
    on each run, which the upsert handles."""
    start, end, written = _ingest(NIGHTLY_WINDOW_DAYS)
    logging.info("usagemetrics(%s): upserted %d rows for %s–%s", SOURCE, written, start, end)


@app.route(route="backfill", auth_level=func.AuthLevel.FUNCTION)
def usagemetrics_backfill(req: func.HttpRequest) -> func.HttpResponse:
    """On-demand backfill over a wider window (default BACKFILL_WINDOW_DAYS, ~LA retention).
    Same upsert path as the timer; used on first deploy to populate history.
    Optional ?days=N overrides the window."""
    try:
        days = float(req.params.get("days", BACKFILL_WINDOW_DAYS))
    except ValueError:
        return func.HttpResponse("invalid 'days' parameter\n", status_code=400)
    start, end, written = _ingest(days)
    logging.info("usagemetrics(%s) backfill: upserted %d rows for %s–%s", SOURCE, written, start, end)
    return func.HttpResponse(
        f"usagemetrics({SOURCE}): upserted {written} rows for {start}–{end}\n"
    )
