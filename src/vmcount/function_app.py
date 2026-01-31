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

    try:
        instances = list(client.virtual_machine_scale_set_vms.list(rg, vmss_name))
        instance_count = len(instances)

        running_count = 0
        healthy_count = 0
        report_health = False

        for vm in instances:
            iview = client.virtual_machine_scale_set_vms.get_instance_view(rg, vmss_name, vm.instance_id)
            if iview.statuses and any(s.code == 'PowerState/running' for s in iview.statuses):
                running_count += 1

            if iview.vm_health and iview.vm_health.status:
                report_health = True
                if iview.vm_health.status.code == "HealthState/healthy":
                    healthy_count += 1

        logging.info("METRIC: Total instance count: %d", instance_count)
        logging.info("METRIC: Live instance count: %d", running_count)
        if report_health:
            logging.info("METRIC: Healthy instance count: %d", healthy_count)
    except Exception as e:
        logging.error("Error fetching VM instances: %s", str(e))
        return
