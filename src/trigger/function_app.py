import azure.functions as func
import os
from scale import scale_vmss
from reimage import update_and_scale, check_and_complete
import logging

SCALE="SCALE"      # Scale up to 1 instance; will shut itself down
REIMAGE="REIMAGE"  # Scale up to 2 instances; will check and shut down one if both healthy

app = func.FunctionApp()

# Pull the CRON expression from the environment
SCALEUP_SCHEDULE = os.environ.get("TRIGGER_SCHEDULE", "0 0 9 * 1 *")  # default if not set; 09:00 on 1st of month
CHECK_SCHEDULE = "*/5 * * * *" # Every 5 minutes
TRIGGER_TYPE = os.environ.get("TRIGGER_TYPE", SCALE)

@app.timer_trigger(schedule=SCALEUP_SCHEDULE, arg_name="timer")
def scaleup_trigger(timer: func.TimerRequest):
    if TRIGGER_TYPE == SCALE:
        # In this model, the VMSS is scaled up to 1 instance (from 0), then we rely on the
        # VM instance scaling itself away when completed.
        logging.info("Scale up to 1 instance")
        scale_vmss(1)
    elif TRIGGER_TYPE == REIMAGE:
        # In this model, we need to reimage the VM instances. We scale up to 2 instances,
        # then the check trigger will check health and scale down when the new instance is healthy.
        logging.info("Scale up to 2 instances")
        update_and_scale()
    else:
        logging.error("scaleup_trigger: trigger type not implemented: %s", TRIGGER_TYPE)

@app.timer_trigger(schedule=CHECK_SCHEDULE, arg_name="timer")
def check_status(timer: func.TimerRequest):
    if TRIGGER_TYPE == SCALE:
        # Nothing to do
        pass
    elif TRIGGER_TYPE == REIMAGE:
        logging.info("Checking status")
        check_and_complete()
    else:
        logging.error("check_trigger: trigger type not implemented: %s", TRIGGER_TYPE)

