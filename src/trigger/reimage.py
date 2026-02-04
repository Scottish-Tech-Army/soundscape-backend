

import base64
import logging
import os
from azure.identity import ManagedIdentityCredential
from azure.mgmt.compute import ComputeManagementClient
from datetime import datetime, timezone

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
        logging.info("VMSS has capacity %d, do nothing", instance_count)
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

def update_and_scale():
    client_id = os.environ["UAMI_CLIENT_ID"]
    subscription_id = os.environ["AZURE_SUBSCRIPTION_ID"]
    rg = os.environ["VMSS_RESOURCE_GROUP"]
    vmss_name = os.environ["VMSS_NAME"]

    # The reason we modify an extension is that this ensures that the VMSS is fully reimaged
    # the latest image, rather than using whatever ubuntu version was last used. This gets
    # us security patches etc. when we upgrade.
    logging.info("About to modify extension and scale out %s", vmss_name)
    credential=ManagedIdentityCredential(
        client_id=client_id,
        scopes=["https://management.azure.com/.default"])

    client = ComputeManagementClient(
        credential=credential,
        subscription_id=subscription_id
    )

    vmss = client.virtual_machine_scale_sets.get(
        resource_group_name=rg,
        vm_scale_set_name=vmss_name
    )

    if vmss.sku.capacity != 1:
        logging.error("VMSS capacity is not 1, cannot proceed")
        raise RuntimeError("VMSS capacity is not 1, cannot proceed")
    vmss.sku.capacity = 2

    extensions = vmss.virtual_machine_profile.extension_profile.extensions

    noop_ext = None
    for ext in extensions:
        logging.info("Checking extension: %s", ext.name)
        if ext.name == "noop-reimage-trigger":
            noop_ext = ext

    if noop_ext is None:
        logging.error("Noop extension not found in VMSS")
        raise RuntimeError("Noop extension not found in VMSS")

    logging.info("Noop extension content: %s", str(noop_ext))
    noop_ext.force_update_tag = datetime.now(timezone.utc).isoformat()

    logging.info("Issuing change to VMSS %s", vmss_name)
    try:
        client.virtual_machine_scale_sets.begin_create_or_update(
            resource_group_name=rg,
            vm_scale_set_name=vmss_name,
            parameters=vmss).result()
    except Exception as e:
        logging.error("Azure request failed: %s", str(e))
        if getattr(e, "response", None) is not None:
            logging.error("Status: %s", e.response.status_code)
            try:
                logging.error("Response body: %s", e.response.text())
            except Exception:
                pass
        raise

    logging.info("Modification completed")