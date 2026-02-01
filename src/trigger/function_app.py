import azure.functions as func
import os
from scale import scale_vmss_to_one
from reimage import reimage_instances
import logging

SCALE="SCALE"
REIMAGE="REIMAGE"

app = func.FunctionApp()

# Pull the CRON expression from the environment
TRIGGER_SCHEDULE = os.environ.get("TRIGGER_SCHEDULE", "0 0 9 * * 1")  # default if not set
TRIGGER_TYPE = os.environ.get("TRIGGER_TYPE", SCALE)

@app.timer_trigger(schedule=TRIGGER_SCHEDULE, arg_name="timer")
def trigger_timer(timer: func.TimerRequest):
    if TRIGGER_TYPE == SCALE:
        logging.info("Scaling on timer")
        scale_vmss_to_one()
    elif TRIGGER_TYPE == REIMAGE:
        logging.info("Reimage instances to force rolling upgrade")
        reimage_instances()
    else:
        logging.error("Trigger type not implemented: %s", TRIGGER_TYPE)
