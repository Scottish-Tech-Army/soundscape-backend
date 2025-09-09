import os
from azure.identity import ManagedIdentityCredential
from azure.mgmt.compute import ComputeManagementClient
import azure.functions as func
import logging

app = func.FunctionApp()

# Pull the CRON expression from the environment
TRIGGER_SCHEDULE = os.environ.get("TRIGGER_SCHEDULE", "*/5 * * * *")  # every 5 minutes by default

@app.timer_trigger(schedule=TRIGGER_SCHEDULE, arg_name="timer")
def vmcount(timer: func.TimerRequest):
    client_id = os.environ["UAMI_CLIENT_ID"]
    subscription_id = os.environ["AZURE_SUBSCRIPTION_ID"]
    rg = os.environ["VMSS_RESOURCE_GROUP"]
    vmss_name = os.environ["VMSS_NAME"]

    client = ComputeManagementClient(
        credential=ManagedIdentityCredential(client_id=client_id),
        subscription_id=subscription_id
    )

    vmss = client.virtual_machine_scale_sets.get(rg, vmss_name)
    instance_count = vmss.sku.capacity
    logging.info("METRIC: Current VMSS capacity: %d", instance_count)

    instances = list(client.virtual_machine_scale_set_vms.list(rg, vmss_name))
    running_instances = [vm for vm in instances if vm.instance_view.statuses and any(
        s.code == 'PowerState/running' for s in vm.instance_view.statuses)]
    logging.info("METRIC: Live instance count: %d", len(running_instances))
    logging.info("METRIC: Total instance count: %d", len(instances))
