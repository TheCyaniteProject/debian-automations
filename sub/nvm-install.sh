#!/usr/bin/env bash
set -euo pipefail

# Simple installer for the latest nvm on Debian-based systems.

# Require apt-get
if ! command -v apt-get >/dev/null 2>&1; then
    echo "Error: apt-get not found. This script targets Debian/Ubuntu." >&2
    exit 1
fi

# Use sudo for package installs if not root
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        echo "Error: run as root or install sudo." >&2
        exit 1
    fi
fi

# Install prerequisites
$SUDO apt-get update -y
$SUDO apt-get install -y curl git ca-certificates build-essential libssl-dev

# Avoid re-installing if nvm already present
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

# Flag to control whether to run the installer
SKIP_INSTALL=0

# If nvm already exists, ask whether to remove and reinstall
if [ -d "$NVM_DIR" ]; then
    echo "nvm appears to be already installed at $NVM_DIR"

    # If running interactively, prompt the user. Otherwise, honor REINSTALL_NVM env (y/N)
    if [ -t 0 ]; then
        read -r -p "Would you like to remove it and install again? [y/N]: " REPLY
    else
        REPLY="${REINSTALL_NVM:-}"
    fi

    case "${REPLY}" in
        y|Y|yes|YES)
            echo "Removing existing nvm directory: $NVM_DIR"
            rm -rf "$NVM_DIR"
            ;;
        *)
            echo "Keeping existing nvm installation."
            SKIP_INSTALL=1
            ;;
    esac
fi

# Run the official installer (latest from repo) if not skipping
if [ "${SKIP_INSTALL}" -eq 0 ]; then
    # Only install if the directory doesn't exist (e.g., after removal)
    if [ ! -d "$NVM_DIR" ]; then
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
    else
        echo "Installer skipped: $NVM_DIR still present."
    fi
fi

# Load nvm into this shell (if installed)
if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck source=/dev/null
    . "$NVM_DIR/nvm.sh"
    echo "nvm version: $(nvm --version 2>/dev/null || true)"

    # Install the latest LTS Node.js release
    nvm install --lts
else
    echo "nvm install script completed but $NVM_DIR/nvm.sh not found." >&2
    exit 1
fi