#!/usr/bin/env bash
set -euo pipefail

# Debian script to install pip3 and gdown
# Saves to /E:/Projects/automations/gdown-install.sh

# require apt-get
if ! command -v apt-get >/dev/null 2>&1; then
    echo "This script requires apt-get (Debian/Ubuntu)." >&2
    exit 1
fi

# determine privilege wrapper
SUDO=""
if [ "$EUID" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        echo "Please run as root or install sudo." >&2
        exit 1
    fi
fi

$SUDO apt-get update
$SUDO apt-get install -y python3 python3-pip

# upgrade pip and install gdown
$SUDO pip3 install --upgrade pip
$SUDO pip3 install --upgrade gdown

# verify
if command -v gdown >/dev/null 2>&1; then
    echo "gdown installed at: $(command -v gdown)"
else
    echo "gdown installation failed." >&2
    exit 2
fi