#!/bin/bash
# Install everything we might need. This script runs as root.
set -euo pipefail
# Remove any old distro-provided Node.js
apt-get remove -y nodejs npm

# Update package index
apt-get update -y

# Add NodeSource repo for Node.js 20
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -

# Install Node.js 20 (includes npm)
apt-get install -y nodejs

# Install wrangler
npm install -g wrangler

# Download pmtiles bin tool
pushd /tmp
wget https://github.com/protomaps/go-pmtiles/releases/download/v1.28.1/go-pmtiles_1.28.1_Linux_x86_64.tar.gz
tar -xzf go-pmtiles_1.28.1_Linux_x86_64.tar.gz
mv pmtiles /usr/local/bin/
popd
