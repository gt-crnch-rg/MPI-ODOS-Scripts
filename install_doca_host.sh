#!/bin/bash
# This script details how to install DOCA on a host VM or machine. Docker installation expects a valid DOCA installation either in the container or bind-mounted from the host.

if dpkg -s doca-host > /dev/null 2>&1; then
    echo "DOCA is already installed ($(dpkg -s doca-host | grep ^Version | awk '{print $2}')), skipping."
    exit 0
fi

DEB=doca-host_3.3.0-088000-26.01-ubuntu2204_amd64.deb
if [ ! -f "$DEB" ]; then
    wget https://www.mellanox.com/downloads/DOCA/DOCA_v3.3.0/host/"$DEB"
fi
sudo dpkg -i "$DEB"
sudo apt-get update
sudo apt-get -y install doca-all