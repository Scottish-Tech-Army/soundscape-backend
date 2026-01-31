import azure.functions as func
import os
from scale import scale_vmss_to_one
import logging

SCALE="SCALE"
REIMAGE="REIMAGE"

app = func.FunctionApp()

# Pull the CRON expression from the environment
TRIGGER_SCHEDULE = os.environ.get("TRIGGER_SCHEDULE", "0 0 9 * * 1")  # default if not set
TRIGGER_TYPE = os.environ.get("TYPE", SCALE)

@app.timer_trigger(schedule=TRIGGER_SCHEDULE, arg_name="timer")
def ingest_timer(timer: func.TimerRequest):
    if TRIGGER_TYPE == SCALE:
        logging.info("Scaling on timer")
        scale_vmss_to_one()
    elif TRIGGER_TYPE == REIMAGE:
        # FIXME xxx implement reimage logic
        logging.warning("REIMAGE NOT YET IMPLEMENTED")
    else:
        logging.error("Trigger type not implemented: %s", TRIGGER_TYPE)
