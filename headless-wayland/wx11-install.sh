#!/usr/bin/env bash
# installer.sh
# Universal Ubuntu Server setup to run an Electron app in a temporary GUI.
# - Installs Wayland (cage) and X11 (Xorg + openbox) stacks
# - Creates runners in ~/.local/bin:
#     run-electron-wayland  (temporary Wayland compositor)
#     run-electron-x11      (temporary Xorg + openbox)
#     run-electron-kiosk    (try Wayland, then X11)
# - Configures Xorg legacy wrapper so non-root users can start X from a TTY
# - Adds the user to render/video groups
# - No auto-start on boot is configured
#
# Usage:
#   bash installer.sh [--app-dir PATH] [--vbox]
#     --app-dir PATH  Path to your Electron app directory (default: ~/dev/electrontest)
#     --vbox          Apply VirtualBox-friendly defaults (install guest utils, and make Wayland prefer software renderer first)
#
# Notes:
# - Run this as your normal user; the script will sudo as needed.
# - The runners call the local Electron binary directly (avoids npm start/xvfb-maybe).
# - Electron is launched with --no-sandbox by default. For stricter security,
#   you can later set the setuid sandbox helper on chrome-sandbox and remove that flag.

set -euo pipefail

# -------------------- Parse arguments --------------------
APP_DIR_REL_DEFAULT="dev/electrontest"
VBOX=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app-dir)
      shift
      [ $# -gt 0 ] || { echo "Missing value for --app-dir"; exit 1; }
      APP_DIR_REL_DEFAULT="$1"
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
      echo "Unknown argument: $1"; exit 1;;
  esac
done

# -------------------- Determine target user/home --------------------
if [ "${SUDO_USER-}" ]; then
  TARGET_USER="$SUDO_USER"
  TARGET_HOME="$(eval echo "~$SUDO_USER")"
else
  TARGET_USER="$USER"
  TARGET_HOME="$HOME"
fi

APP_DIR="$TARGET_HOME/${APP_DIR_REL_DEFAULT#/}"

echo "Target user: $TARGET_USER"
echo "App directory: $APP_DIR"
[ "$VBOX" = 1 ] && echo "VirtualBox mode: ON"

# -------------------- Sanity checks --------------------
if ! command -v apt-get >/dev/null 2>&1; then
  echo "This installer requires apt-get (Ubuntu/Debian)."; exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# -------------------- Install packages --------------------
echo "Updating apt and installing packages..."
sudo apt-get update -y

# Wayland compositor + portals + GL/EGL/GBM + dbus user session
sudo apt-get install -y \
  cage xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk \
  libgl1-mesa-dri libegl1 libgbm1 mesa-utils \
  dbus-user-session

# X11 stack
sudo apt-get install -y --no-install-recommends \
  xserver-xorg xinit openbox x11-xserver-utils

# Xorg legacy wrapper to allow starting X on TTY
sudo apt-get install -y xserver-xorg-legacy
echo 'allowed_users=anybody' | sudo tee /etc/Xorg.wrap >/dev/null || true

# VirtualBox extras (only if requested)
if [ "$VBOX" = 1 ]; then
  echo "Installing VirtualBox guest utilities (optional)..."
  sudo apt-get install -y virtualbox-guest-utils virtualbox-guest-x11 || true
fi

# -------------------- Group membership (render, video) --------------------
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

# -------------------- Create runners --------------------
BIN_DIR="$TARGET_HOME/.local/bin"
sudo -u "$TARGET_USER" mkdir -p "$BIN_DIR"

# Helper: generate Wayland runner with different preference order for VBox
WAYLAND_RUNNER="$BIN_DIR/run-electron-wayland"
if [ "$VBOX" = 1 ]; then
  # Prefer software (pixman) first in VMs
  sudo tee "$WAYLAND_RUNNER" >/dev/null <<'EOF'
#!/bin/sh
set -e
APP_DIR="${APP_DIR:-$HOME/dev/electrontest}"
ELECTRON="$APP_DIR/node_modules/.bin/electron"

# Ensure Electron binary exists (installs dependencies if needed)
if [ ! -x "$ELECTRON" ]; then
  cd "$APP_DIR"
  npm ci || npm i
fi

# Try software-rendered Wayland (pixman)
if env WLR_RENDERER=pixman ELECTRON_OZONE_PLATFORM_HINT=wayland dbus-run-session -- \
  cage -- \
  "$ELECTRON" "$APP_DIR" \
  --kiosk --start-fullscreen --ozone-platform=wayland --no-sandbox
then
  exit 0
fi

echo "Wayland (software) failed; trying hardware..." >&2

# Try hardware-rendered Wayland
exec ELECTRON_OZONE_PLATFORM_HINT=wayland dbus-run-session -- \
  cage -- \
  "$ELECTRON" "$APP_DIR" \
  --kiosk --start-fullscreen --ozone-platform=wayland --no-sandbox
EOF
else
  # Prefer hardware first on bare metal
  sudo tee "$WAYLAND_RUNNER" >/dev/null <<'EOF'
#!/bin/sh
set -e
APP_DIR="${APP_DIR:-$HOME/dev/electrontest}"
ELECTRON="$APP_DIR/node_modules/.bin/electron"

# Ensure Electron binary exists (installs dependencies if needed)
if [ ! -x "$ELECTRON" ]; then
  cd "$APP_DIR"
  npm ci || npm i
fi

# Try hardware-rendered Wayland first
if ELECTRON_OZONE_PLATFORM_HINT=wayland dbus-run-session -- \
  cage -- \
  "$ELECTRON" "$APP_DIR" \
  --kiosk --start-fullscreen --ozone-platform=wayland --no-sandbox
then
  exit 0
fi

echo "Wayland (hardware) failed; retrying with software renderer..." >&2

# Fallback: software-rendered Wayland (pixman)
exec env WLR_RENDERER=pixman ELECTRON_OZONE_PLATFORM_HINT=wayland dbus-run-session -- \
  cage -- \
  "$ELECTRON" "$APP_DIR" \
  --kiosk --start-fullscreen --ozone-platform=wayland --no-sandbox
EOF
fi
sudo chown "$TARGET_USER":"$TARGET_USER" "$WAYLAND_RUNNER"
sudo chmod +x "$WAYLAND_RUNNER"

# X11 runner: use Xorg.wrap and the active VT (XDG_VTNR)
X11_RUNNER="$BIN_DIR/run-electron-x11"
sudo tee "$X11_RUNNER" >/dev/null <<'EOF'
#!/bin/sh
set -e
APP_DIR="${APP_DIR:-$HOME/dev/electrontest}"
ELECTRON="$APP_DIR/node_modules/.bin/electron"

# Ensure Electron binary exists (installs dependencies if needed)
if [ ! -x "$ELECTRON" ]; then
  cd "$APP_DIR"
  npm ci || npm i
fi

SERVER=/usr/lib/xorg/Xorg.wrap
VT_OPT=
[ -n "$XDG_VTNR" ] && VT_OPT="vt$XDG_VTNR"

# Disable power saving, start a tiny WM, then launch Electron
CMD='xset -dpms s off s noblank; openbox & exec "'"$ELECTRON"'" "'"$APP_DIR"'" --kiosk --start-fullscreen --no-sandbox'

exec dbus-run-session -- xinit /bin/sh -c "$CMD" -- "$SERVER" :1 -nolisten tcp $VT_OPT
EOF
sudo chown "$TARGET_USER":"$TARGET_USER" "$X11_RUNNER"
sudo chmod +x "$X11_RUNNER"

# Wrapper that prefers Wayland then X11
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

# -------------------- Final messages --------------------
echo
echo "Installation complete."
echo "Runners installed to: $BIN_DIR"
echo "  - run-electron-wayland"
echo "  - run-electron-x11"
echo "  - run-electron-kiosk"
echo
echo "Your app directory is expected at:"
echo "  $APP_DIR"
echo "Override at runtime with: APP_DIR=/path/to/app run-electron-kiosk"
echo
echo "Usage: switch to a real TTY on the machine/VM (Ctrl+Alt+F3), log in as $TARGET_USER, then run:"
echo "  run-electron-kiosk"
echo
if [ "$RELOGIN_REQUIRED" -eq 1 ]; then
  echo "NOTE: You were added to render/video groups. Log out and back in (or reboot) for changes to take effect."
  echo
fi
echo "If you prefer to keep Chromium's sandbox instead of --no-sandbox, set the setuid helper and remove --no-sandbox from the runners:"
echo "  sudo chown root:root \"$APP_DIR/node_modules/electron/dist/chrome-sandbox\" && sudo chmod 4755 \"$APP_DIR/node_modules/electron/dist/chrome-sandbox\""
echo
[ "$VBOX" = 1 ] && {
  echo "VirtualBox tips: Enable VMSVGA + 3D Acceleration and 64–128MB VRAM for best results. Software-rendered Wayland is used by default in this mode."
  echo
}