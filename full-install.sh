#!/usr/bin/env bash
set -euo pipefail

# Fetch and execute installer scripts from:
#   https://github.com/TheCyaniteProject/debian-automations/tree/main/sub
#
# Behavior:
# - Downloads known sub scripts to a temp directory and runs them in order.
# - Special handling for gdown-install.sh:
#     * If gdown is already installed, it is skipped.
#     * If not installed, prompt to install (interactive only). With -y, skip without prompting.
# - Runs gpt-install.sh last.
#
# Usage:
#   ./full-install.sh [-y] [--] [gpt-installer-args...]
#     -y  Skip gdown installation (non-interactive skip)
#     gpt-installer-args are forwarded to gpt-install.sh

RAW_BASE="https://raw.githubusercontent.com/TheCyaniteProject/debian-automations/main/sub"

SKIP_GDOWN=0
FORWARD_ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
		-y)
			SKIP_GDOWN=1
			shift
			;;
		--)
			shift
			FORWARD_ARGS+=("$@")
			break
			;;
		*)
			FORWARD_ARGS+=("$1")
			shift
			;;
	esac
done

have() { command -v "$1" >/dev/null 2>&1; }

ensure_fetch_tool() {
	if have curl || have wget; then
		return 0
	fi
	if have apt-get; then
		local SUDO=""
		if [ "$(id -u)" -ne 0 ] && have sudo; then SUDO="sudo"; fi
		echo "Installing curl (no curl/wget found)..."
		$SUDO apt-get update -y
		$SUDO apt-get install -y curl ca-certificates || true
	fi
	if ! have curl && ! have wget; then
		echo "Error: need curl or wget to download scripts." >&2
		exit 1
	fi
}

fetch_to() {
	# fetch_to URL DEST
	local url="$1" dest="$2"
	if have curl; then
		curl -fsSL "$url" -o "$dest"
	else
		wget -qO "$dest" "$url"
	fi
}

run_script() {
	local path="$1"; shift || true
	chmod +x "$path" 2>/dev/null || true
	echo "==> Running $(basename "$path")"
	bash "$path" "$@"
}

ensure_fetch_tool

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Known scripts and desired order (gpt-install.sh last)
SCRIPTS_ORDER=(
	nvm-install.sh
	gdown-install.sh
	gpt-install.sh
)

declare -A DL
for s in "${SCRIPTS_ORDER[@]}"; do
	url="$RAW_BASE/$s"
	dest="$TMP_DIR/$s"
	if fetch_to "$url" "$dest"; then
		DL[$s]="$dest"
	else
		# Non-fatal for non-essential scripts except gpt-install.sh
		if [ "$s" = "gpt-install.sh" ]; then
			echo "Error: failed to download $s from $url" >&2
			exit 1
		else
			echo "Warning: could not download $s (skipping)"
		fi
	fi
done

# 1) nvm-install.sh (if present)
if [ -n "${DL[nvm-install.sh]:-}" ]; then
	run_script "${DL[nvm-install.sh]}"
fi

# 2) gdown-install.sh (if present) with special handling
if [ -n "${DL[gdown-install.sh]:-}" ]; then
	if have gdown; then
		echo "gdown already installed: $(command -v gdown)"
	elif [ "$SKIP_GDOWN" = "1" ]; then
		echo "Skipping gdown installation (-y)"
	else
		if [ -t 0 ]; then
			read -r -p "gdown not found. Install it now (not required)? [y/N]: " REPLY
			case "$REPLY" in
				y|Y|yes|YES)
					run_script "${DL[gdown-install.sh]}"
					;;
				*)
					echo "Skipping gdown installation."
					;;
			esac
		else
			echo "gdown not found and no TTY; skipping installation. Use -y to skip explicitly."
		fi
	fi
fi

# 3) gpt-install.sh (must exist)
run_script "${DL[gpt-install.sh]}" "${FORWARD_ARGS[@]}"

echo "All tasks complete."
