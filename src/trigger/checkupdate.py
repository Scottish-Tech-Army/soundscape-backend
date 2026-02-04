import logging
import os
from azure.identity import ManagedIdentityCredential
from azure.mgmt.compute import ComputeManagementClient

def check_and_complete():
    # Check if the VMSS has 2 instances, both healthy, and if so delete one and scale down to 1.
    client_id = os.environ["UAMI_CLIENT_ID"]
    subscription_id = os.environ["AZURE_SUBSCRIPTION_ID"]
    rg = os.environ["VMSS_RESOURCE_GROUP"]
    vmss_name = os.environ["VMSS_NAME"]

    logging.info("About to check for whether we can delete a VM from %s", vmss_name)

    credential=ManagedIdentityCredential(client_id=client_id)

    client = ComputeManagementClient(
        credential=credential,
        subscription_id=subscription_id
    )

    instances = list(client.virtual_machine_scale_set_vms.list(rg, vmss_name))
    instance_count = len(instances)

    if instance_count != 2:
        logging.info("VMSS has %d capacity, do nothing", instance_count)
        return

    logging.info("VMSS has 2 capacity, checking health")
    healthy_count = 0

    for vm in instances:
        iview = client.virtual_machine_scale_set_vms.get_instance_view(rg, vmss_name, vm.instance_id)
        if iview.vm_health and iview.vm_health.status and iview.vm_health.status.code == "HealthState/healthy":
            healthy_count += 1

    if healthy_count != 2:
        logging.info("Only %d instances healthy, do nothing", healthy_count)
        return

    instances_sorted = sorted(instances, key=lambda vm: int(vm.instance_id))
    lowest = instances_sorted[0]
    logging.info("Both healthy - nuke VM numbered %s, named %s", lowest.instance_id, lowest.name)
    client.virtual_machine_scale_set_vms.begin_delete( rg, vmss_name, lowest.instance_id ).result()

    logging.info("Scale down VMSS")
    parameters = { "sku": {"capacity": 1 } }

    client.virtual_machine_scale_sets.begin_update(
        resource_group_name=rg,
        vm_scale_set_name=vmss_name,
        parameters=parameters
    ).result()

    logging.info("Modification completed")