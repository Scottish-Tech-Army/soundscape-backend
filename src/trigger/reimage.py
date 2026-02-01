import base64
import logging
import os
from azure.identity import ManagedIdentityCredential
from azure.mgmt.compute import ComputeManagementClient
from datetime import datetime, timezone

def reimage_instances():
    client_id = os.environ["UAMI_CLIENT_ID"]
    subscription_id = os.environ["AZURE_SUBSCRIPTION_ID"]
    rg = os.environ["VMSS_RESOURCE_GROUP"]
    vmss_name = os.environ["VMSS_NAME"]

    logging.info("About to modify custom data in %s", vmss_name)

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

    extensions = vmss.virtual_machine_profile.extension_profile.extensions

    noop_ext = None
    for ext in extensions:
        logging.info("Checking extension: %s", ext.name)
        if ext.name == "noop-reimage-trigger":
            noop_ext = ext

    if noop_ext is None:
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