#!/bin/bash
# Clean out all the code cruft
set -euo pipefail

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."
echo "Cleaning out all python cache and build artefacts"
find . -type d -name ".pytest_cache" -exec rm -rf {} +
find . -type d -name "__pycache__" -exec rm -rf {} +
find . -type d -name ".venv" -exec rm -rf {} +
find . -type d -name "venv" -exec rm -rf {} +

echo "  Removing built zip files"
rm -f build/*

echo "Done"
