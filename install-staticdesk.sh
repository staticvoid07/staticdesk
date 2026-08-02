#!/usr/bin/env bash
#
# Install a locally built StaticDesk onto this machine, as a system service so
# the desktop is reachable without anyone being logged in.
#
#   sudo ./install-staticdesk.sh
#
# Build first (see BUILD_HINT below) - this script only installs what is
# already in flutter/build/linux/x64/release/bundle.
#
# Everything it touches:
#   /usr/share/staticdesk               the bundle
#   /usr/bin/staticdesk                 symlink into it
#   /usr/share/icons/hicolor/...        tray and launcher icons
#   /usr/share/applications/staticdesk*.desktop
#   /etc/pam.d/staticdesk               login-screen / unattended access
#   /etc/systemd/system/staticdesk.service
#
set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$SRC/flutter/build/linux/x64/release/bundle"
PREFIX=/usr/share/staticdesk

read -r -d '' BUILD_HINT <<'EOF' || true
Build it with:

  cargo build --locked --lib --release \
      --features flutter,hwcodec,unix-file-copy-paste
  (cd flutter && flutter build linux --release)

`hwcodec` is NOT a default feature. Without it the build can only encode
VP8/VP9/AV1 in software, H264/H265 can never be negotiated, and every client
falls back to software decoding.

That feature needs ffmpeg from vcpkg. hwcodec's build.rs reads
$VCPKG_ROOT/installed/<triplet> directly and ignores VCPKG_INSTALLED_ROOT, so
if your ffmpeg lives in a manifest-mode tree (./vcpkg_installed), point
VCPKG_ROOT at a directory whose `installed` entry is a symlink to it.

On GCC 15 libwebm also needs CXXFLAGS="-include cstdint".
EOF

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^#\s\?//'
  exit 0
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root: sudo $0" >&2
  exit 1
fi

if [ ! -x "$BUNDLE/staticdesk" ]; then
  echo "No build found at:" >&2
  echo "  $BUNDLE" >&2
  echo >&2
  echo "$BUILD_HINT" >&2
  exit 1
fi

missing=()
for tool in rsvg-convert systemctl; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "Missing required tool(s): ${missing[*]}" >&2
  echo "rsvg-convert comes from librsvg2-bin on Debian/Ubuntu." >&2
  exit 1
fi

# A build without hwcodec installs and runs fine, it is just silently limited to
# software encoding - which is easy to do by accident and hard to notice later,
# so say so plainly rather than failing.
if ! strings -a "$BUNDLE/lib/librustdesk.so" 2>/dev/null \
    | grep -q 'scrap/src/common/hwcodec.rs'; then
  echo "WARNING: this build has no hwcodec support." >&2
  echo "         Hardware H264/H265 encoding will be unavailable and peers" >&2
  echo "         will software-decode VP9/AV1. Rebuild with --features hwcodec." >&2
  echo >&2
fi

echo "== Installing bundle to $PREFIX =="
rm -rf "$PREFIX"
cp -r "$BUNDLE" "$PREFIX"
chown -R root:root "$PREFIX"

echo "== Symlinking /usr/bin/staticdesk =="
ln -sfn "$PREFIX/staticdesk" /usr/bin/staticdesk

echo "== Installing icons =="
mkdir -p /usr/share/icons/hicolor/256x256/apps /usr/share/icons/hicolor/scalable/apps
rsvg-convert -w 256 -h 256 "$SRC/res/icon-tray.svg" \
  -o /usr/share/icons/hicolor/256x256/apps/staticdesk.png
cp "$SRC/res/scalable.svg" /usr/share/icons/hicolor/scalable/apps/staticdesk.svg
gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true

echo "== Installing .desktop entries =="
cp "$SRC/res/staticdesk.desktop" /usr/share/applications/staticdesk.desktop
cp "$SRC/res/staticdesk-link.desktop" /usr/share/applications/staticdesk-link.desktop
update-desktop-database /usr/share/applications || true

echo "== Installing PAM service (login-screen / unattended session access) =="
cp "$SRC/res/pam.d/staticdesk.debian" /etc/pam.d/staticdesk

echo "== Installing systemd service =="
cp "$SRC/res/staticdesk.service" /etc/systemd/system/staticdesk.service
systemctl daemon-reload
systemctl enable staticdesk.service
# `enable --now` is a no-op when the unit is already running, which would leave
# the previous binary running from memory after an upgrade (the replaced file
# shows up as "(deleted)" in /proc/PID/exe). Restart explicitly so a reinstall
# always picks up the new build.
systemctl restart staticdesk.service

echo
echo "== Done. Status: =="
systemctl status staticdesk.service --no-pager || true
