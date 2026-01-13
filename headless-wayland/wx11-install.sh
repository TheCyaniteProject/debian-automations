#!/usr/bin/env bash
# setup-electron-kiosk.sh
# Universal Ubuntu Server setup for running an Electron app in a temporary GUI.
# - Installs required packages
# - Creates runners:
#     ~/.local/bin/run-electron-wayland
#     ~/.local/bin/run-electron-x11
#     ~/.local/bin/run-electron-kiosk  (tries Wayland, falls back to X11)
# - No auto-start on boot is configured.
# - If --vbox is passed, applies VirtualBox-specific tweaks (packages + Wayland prefers software rendering first).
#
# Usage:
#   bash setup-electron-kiosk.sh [--app-dir PATH] [--vbox]
#
# Notes:
# - Run this as your normal user (it will sudo for package installs). If you run with sudo, files are written to the original user's home.
# - Your Electron app directory defaults to the current working directory (override with APP_DIR).
# - After setup, switch to a TTY (Ctrl+Alt+F3), log in, and run: run-electron-kiosk
# - Closing the app will tear down the temporary GUI and return you to the TTY.

set -euo pipefail

# -------- Parse args --------
APP_DIR_DEFAULT="dev/electrontest"
VBOX=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app-dir)
      shift
      [ $# -gt 0 ] || { echo "Missing value for --app-dir"; exit 1; }
      APP_DIR_DEFAULT="$1"
      shift
      ;;
    --vbox)
      VBOX=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--app-dir PATH] [--vbox]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--app-dir PATH] [--vbox]"
      exit 1
      ;;
  esac
done

# -------- Determine target user/home --------
if [ "${SUDO_USER-}" ]; then
  TARGET_USER="$SUDO_USER"
  HOME_DIR="$(eval echo "~$SUDO_USER")"
else
  TARGET_USER="$USER"
  HOME_DIR="$HOME"
fi

APP_DIR_RELATIVE="$APP_DIR_DEFAULT"
APP_DIR_EXPANDED="$HOME_DIR/${APP_DIR_RELATIVE#/}"  # expanded for messages only

echo "Setting up Electron kiosk runners for user: $TARGET_USER"
echo "App directory (expected): $APP_DIR_EXPANDED"
[ "$VBOX" = 1 ] && echo "VirtualBox mode: ON"

# -------- Check apt availability --------
if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script requires apt-get (Ubuntu/Debian)."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# -------- Install packages --------
echo "Updating apt and installing packages..."
sudo apt-get update -y

# Wayland single-app compositor + portals + GL/EGL/GBM + D-Bus user session
sudo apt-get install -y \
  cage xdg-desktop-portal xdg-desktop-portal-wlr \
  libgl1-mesa-dri libegl1 libgbm1 mesa-utils \
  dbus-user-session

# X11 fallback stack (minimal)
sudo apt-get install -y --no-install-recommends \
  xserver-xorg xinit openbox x11-xserver-utils

# VirtualBox extras (optional)
if [ "$VBOX" = 1 ]; then
  echo "Installing VirtualBox guest extras (utils/x11)..."
  sudo apt-get install -y virtualbox-guest-utils virtualbox-guest-x11 || true
fi

# -------- Add user to render/video groups --------
RELOGIN_REQUIRED=0
for grp in render video; do
  if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$grp"; then
    :
  else
    echo "Adding $TARGET_USER to group: $grp"
    sudo usermod -aG "$grp" "$TARGET_USER"
    RELOGIN_REQUIRED=1
  fi
done

# -------- Create ~/.local/bin and runners --------
BIN_DIR="$HOME_DIR/.local/bin"
echo "Creating runner scripts in $BIN_DIR ..."
sudo -u "$TARGET_USER" mkdir -p "$BIN_DIR"

# run-electron-wayland
WAYLAND_RUNNER="$BIN_DIR/run-electron-wayland"
if [ "$VBOX" = 1 ]; then
  # Prefer software rendering first in VirtualBox, then try hardware
  sudo tee "$WAYLAND_RUNNER" >/dev/null <<'EOF'
#!/bin/sh
set -e
APP_DIR="${APP_DIR:-$PWD}"
CMD='cd "$APP_DIR" && ELECTRON_OZONE_PLATFORM_HINT=wayland npm start -- --kiosk --start-fullscreen --ozone-platform=wayland --no-sandbox/'

# Try software rendering (pixman) first for better reliability in VirtualBox
if WLR_RENDERER=pixman dbus-run-session -- cage -- bash -lc "$CMD"; then
  exit 0
fi

echo "Wayland (software) failed; trying hardware rendering..." >&2
exec dbus-run-session -- cage -- bash -lc "$CMD"
EOF
else
  # Try hardware first, then software fallback
  sudo tee "$WAYLAND_RUNNER" >/dev/null <<'EOF'
#!/bin/sh
set -e
APP_DIR="${APP_DIR:-$PWD}"
CMD='cd "$APP_DIR" && ELECTRON_OZONE_PLATFORM_HINT=wayland npm start -- --kiosk --start-fullscreen --ozone-platform=wayland --no-sandbox/'

# Try hardware rendering first
if dbus-run-session -- cage -- bash -lc "$CMD"; then
  exit 0
fi

# Fallback: software rendering (pixman)
echo "Wayland (hardware) failed; retrying with software renderer..." >&2
exec WLR_RENDERER=pixman dbus-run-session -- cage -- bash -lc "$CMD"
EOF
fi
sudo chown "$TARGET_USER":"$TARGET_USER" "$WAYLAND_RUNNER"
sudo chmod +x "$WAYLAND_RUNNER"

# run-electron-x11
X11_RUNNER="$BIN_DIR/run-electron-x11"
sudo tee "$X11_RUNNER" >/dev/null <<'EOF'
#!/bin/sh
set -e
APP_DIR="${APP_DIR:-$PWD}"

# xinit client script: disable power saving, start tiny WM, then start app.
CLIENT='xset -dpms s off s noblank; openbox & exec bash -lc "cd \"$APP_DIR\" && ELECTRON_OZONE_PLATFORM_HINT=x11 npm start -- --kiosk --start-fullscreen"'

# Use a separate display (:1) and disable TCP
exec dbus-run-session -- xinit /bin/sh -c "$CLIENT" -- :1 -nolisten tcp
EOF
sudo chown "$TARGET_USER":"$TARGET_USER" "$X11_RUNNER"
sudo chmod +x "$X11_RUNNER"

# run-electron-kiosk
KIOSK_RUNNER="$BIN_DIR/run-electron-kiosk"
sudo tee "$KIOSK_RUNNER" >/dev/null <<'EOF'
#!/bin/sh
set -e
if ~/.local/bin/run-electron-wayland; then
  exit 0
fi
echo "Falling back to X11..." >&2
exec ~/.local/bin/run-electron-x11
EOF
sudo chown "$TARGET_USER":"$TARGET_USER" "$KIOSK_RUNNER"
sudo chmod +x "$KIOSK_RUNNER"

# -------- Final messages --------
echo
echo "Setup complete."
echo
echo "Runners installed:"
echo "  $WAYLAND_RUNNER"
echo "  $X11_RUNNER"
echo "  $KIOSK_RUNNER"
echo
echo "Default app directory used by runners: the current working directory at runtime."
echo "Override by setting APP_DIR when launching, e.g.: APP_DIR=/path/to/app run-electron-kiosk"
echo
echo "Usage (from a TTY, e.g., Ctrl+Alt+F3):"
echo "  run-electron-kiosk"
echo "  # or explicitly:"
echo "  run-electron-wayland"
echo "  run-electron-x11"
echo
if [ "$RELOGIN_REQUIRED" -eq 1 ]; then
  echo "NOTE: You were added to 'render' and/or 'video' groups. Log out and back in (or reboot) for this to take effect."
  echo
fi
echo "If X11 refuses to start with 'Only console users are allowed to run the X server', either run from a real TTY as your user or:"
echo "  sudo apt-get install -y xserver-xorg-legacy && sudo dpkg-reconfigure xserver-xorg-legacy"
echo
echo "If npm isn't found when launching, ensure your shell profile sets PATH for non-interactive shells, or edit the runners to call the Electron binary directly:"
echo "  \$APP_DIR/node_modules/.bin/electron \$APP_DIR --kiosk --start-fullscreen"
echo
[ "$VBOX" = 1 ] && {
  echo "VirtualBox notes:"
  echo "- Wayland runner prefers software rendering (pixman) first for reliability."
  echo "- For best results, configure the VM (on the host) to use: Adapter=VMSVGA, Enable 3D Acceleration, 64–128MB VRAM."
  echo "- If Wayland still fails, use the X11 runner which is generally robust in VirtualBox."
  echo
}

sed -i 's/--ozone-platform=wayland/--ozone-platform=wayland --no-sandbox/' ~/.local/bin/run-electron-wayland
sed -i 's/--start-fullscreen"/--start-fullscreen --no-sandbox"/' ~/.local/bin/run-electron-x11