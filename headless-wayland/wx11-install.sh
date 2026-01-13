cat > ~/.local/bin/run-electron-wayland <<'EOF'
#!/bin/sh
set -e
APP_DIR="${APP_DIR:-$HOME/dev/electrontest}"
ELECTRON="$APP_DIR/node_modules/.bin/electron"

# Ensure electron is installed
if [ ! -x "$ELECTRON" ]; then
  cd "$APP_DIR"
  npm ci || npm i
fi

LAUNCH_CMD='"$ELECTRON" "$APP_DIR" --kiosk --start-fullscreen --ozone-platform=wayland --no-sandbox'

# Prefer software rendering in VMs; then try hardware
if env WLR_RENDERER=pixman dbus-run-session -- cage -- bash -lc "$LAUNCH_CMD"; then
  exit 0
fi

echo "Wayland (software) failed; trying hardware..." >&2
exec dbus-run-session -- cage -- bash -lc "$LAUNCH_CMD"
EOF
chmod +x ~/.local/bin/run-electron-wayland
cat > ~/.local/bin/run-electron-x11 <<'EOF'
#!/bin/sh
set -e
APP_DIR="${APP_DIR:-$HOME/dev/electrontest}"
ELECTRON="$APP_DIR/node_modules/.bin/electron"

# Ensure electron is installed
if [ ! -x "$ELECTRON" ]; then
  cd "$APP_DIR"
  npm ci || npm i
fi

CLIENT='
xset -dpms s off s noblank
openbox &
exec bash -lc "\"'"$ELECTRON"'" \"'"$APP_DIR"'\" --kiosk --start-fullscreen --no-sandbox"
'

exec dbus-run-session -- xinit /bin/sh -c "$CLIENT" -- :1 -nolisten tcp
EOF
chmod +x ~/.local/bin/run-electron-x11
cat > ~/.local/bin/run-electron-kiosk <<'EOF'
#!/bin/sh
set -e
if ~/.local/bin/run-electron-wayland; then
  exit 0
fi
echo "Falling back to X11..." >&2
exec ~/.local/bin/run-electron-x11
EOF
chmod +x ~/.local/bin/run-electron-kiosk

export XVFB_MAYBE_DISABLE=1

sudo apt-get update
sudo apt-get install -y xserver-xorg-legacy
echo 'allowed_users=anybody' | sudo tee /etc/Xorg.wrap >/dev/null

sudo chown root:root "$HOME/dev/electrontest/node_modules/electron/dist/chrome-sandbox"
sudo chmod 4755 "$HOME/dev/electrontest/node_modules/electron/dist/chrome-sandbox"
echo "Setup complete. You can run 'run-electron-kiosk' to start the app in kiosk mode."