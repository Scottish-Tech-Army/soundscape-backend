#!/bin/bash
# Clean out all the code cruft
set -euo pipefail

nuke() {
    # Nukes all directories with the specified name.
    # Arguments:
    # - the name
    local DIRNAME="$1"
    echo "  Nuking ${DIRNAME}"
    find . -type d -name "${DIRNAME}" -exec rm -rf {} +
}

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."
echo "Cleaning out all python cache and build artefacts"
nuke ".pytest_cache"
nuke "__pycache__"
nuke ".venv"
nuke "venv"

echo "Removing node build artefacts"
nuke "node_modules"
nuke "dist"

echo "Removing build directory"
nuke "build"

echo "Done"
