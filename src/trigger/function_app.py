import azure.functions as func
import os
from scale import scale_vmss_to_one
import logging

app = func.FunctionApp()

@app.function_name(name="ingest_manual")
@app.route(route="ingest_manual", methods=["POST"], auth_level=func.AuthLevel.ADMIN)
def ingest_manual(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("Scaling manually")
    scale_vmss_to_one()
    return func.HttpResponse("VMSS scaled to 1", status_code=200)

# Pull the CRON expression from the environment
TRIGGER_SCHEDULE = os.environ.get("TRIGGER_SCHEDULE", "0 0 9 * * 1")  # default if not set

@app.timer_trigger(schedule=TRIGGER_SCHEDULE, arg_name="timer")
def ingest_timer(timer: func.TimerRequest):
    logging.info("Scaling on timer")
    scale_vmss_to_one()
