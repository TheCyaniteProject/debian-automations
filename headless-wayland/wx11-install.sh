sudo apt-get update
sudo apt-get install -y xserver-xorg-legacy
echo 'allowed_users=anybody' | sudo tee /etc/Xorg.wrap >/dev/null
ls -l /usr/lib/xorg/Xorg.wrap
# Expect: -rwsr-sr-x root root ... Xorg.wrap  (setuid bit 's' present)

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

# Try software-rendered Wayland (best for VMs)
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
exec "'"$ELECTRON"'" "'"$APP_DIR"'" --kiosk --start-fullscreen --no-sandbox
'

# Use the setuid wrapper and the active VT (XDG_VTNR is set on real TTY logins)
SERVER=/usr/lib/xorg/Xorg.wrap
VT_OPT=
[ -n "$XDG_VTNR" ] && VT_OPT="vt$XDG_VTNR"

exec dbus-run-session -- xinit /bin/sh -c "$CLIENT" -- "$SERVER" :1 -nolisten tcp $VT_OPT
EOF
chmod +x ~/.local/bin/run-electron-x11

