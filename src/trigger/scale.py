import logging
import os
from azure.identity import ManagedIdentityCredential
from azure.mgmt.compute import ComputeManagementClient

def scale_vmss(capacity):
    client_id = os.environ["UAMI_CLIENT_ID"]
    subscription_id = os.environ["AZURE_SUBSCRIPTION_ID"]
    rg = os.environ["VMSS_RESOURCE_GROUP"]
    vmss = os.environ["VMSS_NAME"]

    client = ComputeManagementClient(
        credential=ManagedIdentityCredential(client_id=client_id),
        subscription_id=subscription_id
    )

    parameters = { "sku": {"capacity": capacity } }

    logging.info("Scaling VMSS %s in resource group %s to %d instances", vmss, rg, capacity)
    client.virtual_machine_scale_sets.begin_update(
        resource_group_name=rg,
        vm_scale_set_name=vmss,
        parameters=parameters
    ).result()
