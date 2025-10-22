#!/bin/bash
# Set up secrets as environment variables, loading them from key vault.
# env.sh must have been sourced so as to ensure that BASE and other variables are set.
# We do not do the set -euo pipefail here as either this is being sourced from a shell or from a script that already has that set.

getsecret() {
  local secret_name=$1
  az keyvault secret show \
    --vault-name ${KEY_VAULT_NAME} \
    --name ${secret_name} \
    --query value \
    -o tsv
}

az login --identity

export CLOUDFLARE_API_TOKEN=$(getsecret cloudflare-api-token)
export CLOUDFLARE_ACCOUNT_ID=$(getsecret cloudflare-account-id)
export R2_ACCESS_KEY=$(getsecret r2-access-key)
export R2_SECRET=$(getsecret r2-secret)

# Set up the rclone config file with this data.
mkdir -p ${HOME}/.config/rclone
cat > ${HOME}/.config/rclone/rclone.conf <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY}
secret_access_key = ${R2_SECRET}
endpoint = https://${CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com
no_check_bucket = true

[blob]
type = azureblob

# Storage account name (the one you created in Bicep)
account = ${EXTRACTS_STORAGE_ACCOUNT}

# Tell rclone to use Managed Identity instead of a key
use_msi = true

# Explicitly bind to your User‑Assigned Managed Identity
# (replace with the actual client ID of your UAMI)
msi_client_id = ${CLIENT_ID}
EOF
