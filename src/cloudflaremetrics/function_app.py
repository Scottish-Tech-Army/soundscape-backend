import logging
import os

import azure.functions as func

from cloudflare import fetch_r2_storage, fetch_worker_metrics, time_window

app = func.FunctionApp()

# Pull the CRON expression from the environment
TRIGGER_SCHEDULE = os.environ.get("TRIGGER_SCHEDULE", "0 * * * *")  # every hour by default


@app.timer_trigger(schedule=TRIGGER_SCHEDULE, arg_name="timer")
def cfmetrics(timer: func.TimerRequest):
    token           = os.environ["CF_API_TOKEN"]
    account_id      = os.environ["CF_ACCOUNT_ID"]
    pmtiles_script  = os.environ["CF_PMTILES_SCRIPT"]
    extracts_script = os.environ["CF_EXTRACTS_SCRIPT"]

    start, end = time_window(1)  # metrics for the last hour

    for script in [pmtiles_script, extracts_script]:
        try:
            m = fetch_worker_metrics(token, account_id, script, start, end)
            logging.info("CLOUDFLARE: %s worker requests: %d", script, m["total_requests"])
            for status, count in sorted(m["requests_by_status"].items()):
                logging.info("CLOUDFLARE: %s worker requests %s: %d", script, status, count)
            logging.info("CLOUDFLARE: %s worker responseBodySize: %d", script, m["total_bytes"])
            logging.info("CLOUDFLARE: %s worker wallTimeMs: %d",        script, m["total_wall_us"] // 1000)
            logging.info("CLOUDFLARE: %s worker cpuTimeMs: %d",         script, m["total_cpu_us"] // 1000)
        except Exception as e:
            logging.error("Error fetching worker metrics for %s: %s", script, str(e))

        try:
            r2 = fetch_r2_storage(token, account_id, script, start, end)
            logging.info("CLOUDFLARE: %s r2 objectCount: %d",      script, r2["object_count"])
            logging.info("CLOUDFLARE: %s r2 payloadSizeBytes: %d", script, r2["payload_size"])
        except Exception as e:
            logging.error("Error fetching R2 storage for %s: %s", script, str(e))
