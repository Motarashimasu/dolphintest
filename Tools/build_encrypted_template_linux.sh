#!/usr/bin/env bash
# Builds the Linux Godot export template with your .pck encryption key compiled in, on your own
# PC (WSL's Ubuntu 22.04 on Windows, or any Ubuntu 22.04), so the key never leaves it: not on
# GitHub, not in any upload. The Linux twin of Tools/build_encrypted_template.ps1.
# Docs: Docs/LINUX.md > "The launcher: Godot export".
#
#   bash Tools/build_encrypted_template_linux.sh [key file] [Godot tag]
#
# Defaults: the key the Windows script made, C:\SparkingKeys\godot_pck_key.txt (seen from WSL as
# /mnt/c/SparkingKeys/godot_pck_key.txt), and Godot 4.7.2-stable (your editor's exact version:
# Help > About). Ubuntu 22.04 on purpose: a template built there runs on older Linux systems too
# (glibc 2.35, as the Dolphin build). 20-60 minutes the first time.
#
# The result is copied next to the key: C:\SparkingKeys\godot.linuxbsd.template_release.x86_64
set -euo pipefail

KEY_FILE="${1:-/mnt/c/SparkingKeys/godot_pck_key.txt}"
TAG="${2:-4.7.2-stable}"
SRC="$HOME/godot-src-$TAG"

[ -f "$KEY_FILE" ] || { echo "No key at $KEY_FILE (run Tools\\build_encrypted_template.ps1 on Windows first, or pass the key file)."; exit 1; }
KEY="$(tr -d ' \r\n' < "$KEY_FILE")"
[[ "$KEY" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "$KEY_FILE must hold 64 hex characters."; exit 1; }

. /etc/os-release
if [ "${VERSION_ID:-}" != "22.04" ]; then
  echo "Note: this is ${PRETTY_NAME:-unknown}, not Ubuntu 22.04: the template will need a newer Linux than the Dolphin build."
fi

echo "Installing the build tools (asks for your WSL password)..."
sudo apt-get update -q
sudo apt-get install -y -q --no-install-recommends build-essential git python3 python3-pip pkg-config \
  libx11-dev libxcursor-dev libxinerama-dev libgl1-mesa-dev libglu1-mesa-dev libasound2-dev \
  libpulse-dev libudev-dev libxi-dev libxrandr-dev
python3 -m SCons --version >/dev/null 2>&1 || python3 -m pip install --user -q scons

if [ ! -d "$SRC/.git" ]; then
  echo "Downloading Godot $TAG source..."
  git clone -q --depth 1 --branch "$TAG" https://github.com/godotengine/godot.git "$SRC"
fi
HAVE="$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)"
[ "$HAVE" = "$TAG" ] || { echo "$SRC holds Godot '$HAVE', not $TAG: delete it and run again."; exit 1; }

echo "Building the export template (this takes a while)..."
cd "$SRC"
# X11 only (XWayland covers Wayland desktops); no screen-reader driver, as on Windows.
# The key goes in through the environment only for this command, never into a file or the log.
SCRIPT_AES256_ENCRYPTION_KEY="$KEY" python3 -m SCons platform=linuxbsd target=template_release \
  arch=x86_64 production=yes accesskit=no wayland=no -j "$(nproc)"
unset KEY

OUT="$SRC/bin/godot.linuxbsd.template_release.x86_64"
[ -f "$OUT" ] || { echo "The build finished but $OUT isn't there."; exit 1; }
DEST="$(dirname "$KEY_FILE")/godot.linuxbsd.template_release.x86_64"
cp "$OUT" "$DEST"
echo
echo "Done: $DEST"
echo "Next, in the Godot editor: Project > Export > Linux:"
echo "  Options > Custom Template > Release: that file (C:\\SparkingKeys\\godot.linuxbsd.template_release.x86_64)"
echo "  Encryption: the same as Windows (Encrypt Exported PCK, Encrypt Index, filters *, the same key)"
