import azure.functions as func
import os
from scale import scale_vmss_to_one
import logging

app = func.FunctionApp()

# Pull the CRON expression from the environment
TRIGGER_SCHEDULE = os.environ.get("TRIGGER_SCHEDULE", "0 0 9 * * 1")  # default if not set

@app.timer_trigger(schedule=TRIGGER_SCHEDULE, arg_name="timer")
def ingest_timer(timer: func.TimerRequest):
    logging.info("Scaling on timer")
    scale_vmss_to_one()
