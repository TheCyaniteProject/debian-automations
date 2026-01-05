#!/usr/bin/env bash
set -euo pipefail

# Fetch TheCyaniteProject/node-gpt-cli-debian and run its installer.
# Usage:
#   ./gpt-install.sh [installer args...]
#   ENV:
#     DEST_DIR         Target folder (default: current directory ".")
#     GIT_REF          Branch/tag/commit to checkout (default: repo default; tarball fallback uses 'main')
#     REINSTALL=1      Remove DEST_DIR and re-download

REPO_URL="https://github.com/TheCyaniteProject/node-gpt-cli-debian"
DEFAULT_DIR="."
DEST_DIR="${DEST_DIR:-$DEFAULT_DIR}"
GIT_REF="${GIT_REF:-}"
REINSTALL="${REINSTALL:-0}"

have() { command -v "$1" >/dev/null 2>&1; }

# Determine sudo if available
SUDO=""
if [ "$(id -u)" -ne 0 ] && have sudo; then
	SUDO="sudo"
fi

ensure_packages() {
	# Install packages via apt-get if available
	if have apt-get; then
		$SUDO apt-get update -y
		$SUDO apt-get install -y "$@"
	else
		return 1
	fi
}

# Ensure we have at least one download method and tar for extraction
if ! have git && ! have curl && ! have wget; then
	echo "No git/curl/wget found; attempting to install curl (Debian/Ubuntu)..." >&2
	ensure_packages curl ca-certificates || {
		echo "Cannot install curl automatically. Please install git, curl, or wget and re-run." >&2
		exit 1
	}
fi

if ! have tar; then
	ensure_packages tar || true
fi

# Always fetch into a temporary directory, then copy into DEST_DIR
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

SRC_DIR=""

if have git; then
	echo "Cloning $REPO_URL -> temporary directory"
	if [ -n "$GIT_REF" ]; then
		if git clone --depth 1 --branch "$GIT_REF" "$REPO_URL" "$TMP_ROOT/repo" 2>/dev/null; then
			SRC_DIR="$TMP_ROOT/repo"
		else
			echo "Shallow clone failed; attempting full clone then checkout..."
			git clone "$REPO_URL" "$TMP_ROOT/repo"
			(
				cd "$TMP_ROOT/repo"
				git checkout "$GIT_REF"
			)
			SRC_DIR="$TMP_ROOT/repo"
		fi
	else
		git clone --depth 1 "$REPO_URL" "$TMP_ROOT/repo"
		SRC_DIR="$TMP_ROOT/repo"
	fi
else
	# Tarball fallback via curl/wget
	ref="${GIT_REF:-main}"
	echo "Downloading tarball for ref: $ref"
	TARBALL_URL_HEADS="$REPO_URL/archive/refs/heads/$ref.tar.gz"
	TARBALL_URL_TAGS="$REPO_URL/archive/refs/tags/$ref.tar.gz"
	if have curl; then
		curl -fsSL "$TARBALL_URL_HEADS" -o "$TMP_ROOT/repo.tar.gz" || curl -fsSL "$TARBALL_URL_TAGS" -o "$TMP_ROOT/repo.tar.gz"
	else
		wget -qO "$TMP_ROOT/repo.tar.gz" "$TARBALL_URL_HEADS" || wget -qO "$TMP_ROOT/repo.tar.gz" "$TARBALL_URL_TAGS"
	fi
	tar -C "$TMP_ROOT" -xzf "$TMP_ROOT/repo.tar.gz"
	extracted=$(tar -tzf "$TMP_ROOT/repo.tar.gz" | head -1 | cut -f1 -d"/")
	SRC_DIR="$TMP_ROOT/$extracted"
fi

if [ -z "$SRC_DIR" ] || [ ! -d "$SRC_DIR" ]; then
	echo "Download failed: no source directory prepared." >&2
	exit 1
fi

# If REINSTALL=1 and DEST_DIR is NOT current directory, remove it first
if [ "$REINSTALL" = "1" ] && [ "$DEST_DIR" != "." ]; then
	echo "Removing existing directory: $DEST_DIR"
	rm -rf "$DEST_DIR"
fi

mkdir -p "$DEST_DIR"

# Copy repository contents into DEST_DIR (including dotfiles) and overwrite existing files
rm -rf "$SRC_DIR/.git" "$SRC_DIR/.github" 2>/dev/null || true
echo "Copying files into $DEST_DIR (overwriting existing files)..."
if have rsync; then
	rsnyc_opts=( -a )
	# Exclude any stray VCS directories just in case
	rsync "${rsnyc_opts[@]}" --exclude='.git' --exclude='.github' "$SRC_DIR"/ "$DEST_DIR"/
else
	# Force overwrite and remove destination before writing to handle type changes
	\cp -a --force --remove-destination "$SRC_DIR"/. "$DEST_DIR"/
fi

cd "$DEST_DIR"

if [ ! -f installer/install.sh ]; then
	echo "Error: installer/install.sh not found in $(pwd)." >&2
	exit 1
fi

chmod +x installer/install.sh || true
echo "Running installer/install.sh..."
bash installer/install.sh "$@"

echo "Install complete."
