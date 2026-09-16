#!/usr/bin/env bash
#
# Remote Pi Cockpit — cockpit-server installer for Linux hosts (VPS)
# ==================================================================
#
#   curl -fsSL https://remote-pi.jacobmoura.work/cockpit-server.sh | bash
#   curl -fsSL https://remote-pi.jacobmoura.work/cockpit-server.sh | bash -s -- --service
#   COCKPIT_VERSION=1.28.33 curl -fsSL ... | bash
#
# Canonical file: cockpit/install-server.sh in the repo; the site URL above
# redirects to the GitHub raw of this file:
#   https://raw.githubusercontent.com/jacobaraujo7/remote_pi/main/cockpit/install-server.sh
#
# What it does (user-space, NO sudo, idempotent):
#   1. Detects the architecture (x86_64 or arm64; Linux only).
#   2. Resolves the version: $COCKPIT_VERSION, else the latest
#      `cockpit-server-v*` GitHub release.
#   3. Downloads cockpit-server-<version>-linux-<arch>.zip + SHA256SUMS from
#      that release and verifies the checksum.
#   4. Unzips to a temp dir and runs the install.sh shipped inside the zip,
#      which installs to ~/.cockpit/server (same layout the desktop app uses).
#   --service: also registers a systemd --user unit so the server starts at
#      boot (`cockpit-server service install`; may print one sudo command for
#      `loginctl enable-linger`). Without it the app starts the server on
#      demand over SSH, which is enough for most hosts.
#
# The server version must match the Cockpit app you connect from.
# Trust: plain readable script, no privileges. Read it before piping to bash.
set -euo pipefail

REPO="${COCKPIT_REPO:-jacobaraujo7/remote_pi}"
GH_API="https://api.github.com/repos/$REPO"
GH_DL="https://github.com/$REPO/releases/download"
INSTALL_ARGS=()
for a in "$@"; do
  case "$a" in
    --service) INSTALL_ARGS+=("--service") ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; RST=$'\033[0m'
else
  BOLD=""; RED=""; GRN=""; RST=""
fi
step() { printf '%s\n' "${BOLD}==> $*${RST}"; }
ok()   { printf '%s\n' "    ${GRN}ok${RST} $*"; }
die()  { printf '%s\n' "${RED}${BOLD}error:${RST} $*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || die "cockpit-server runs on Linux hosts only (macOS hosts are set up by the app over SSH)"
case "$(uname -m)" in
  x86_64|amd64)  ARCH=x86_64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported architecture: $(uname -m) (x86_64 and arm64 only)" ;;
esac
for tool in curl unzip sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required (apt install $tool)"
done

step "Resolving version"
if [ -n "${COCKPIT_VERSION:-}" ]; then
  VERSION="${COCKPIT_VERSION#v}"
else
  # Latest cockpit-server-v* tag (the repo has other release families).
  VERSION="$(curl -fsSL "$GH_API/releases?per_page=30" \
    | grep -o '"tag_name": *"cockpit-server-v[^"]*"' \
    | head -1 | sed 's/.*cockpit-server-v//; s/"//')"
  [ -n "$VERSION" ] || die "could not find a cockpit-server release on GitHub; set COCKPIT_VERSION=x.y.z"
fi
TAG="cockpit-server-v$VERSION"
ZIP="cockpit-server-$VERSION-linux-$ARCH.zip"
ok "cockpit-server $VERSION ($ARCH)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
step "Downloading $ZIP"
curl -fsSL --retry 3 -o "$TMP/$ZIP" "$GH_DL/$TAG/$ZIP" \
  || die "download failed: $GH_DL/$TAG/$ZIP"
curl -fsSL --retry 3 -o "$TMP/SHA256SUMS" "$GH_DL/$TAG/SHA256SUMS" \
  || die "download failed: SHA256SUMS"
( cd "$TMP" && grep " $ZIP\$" SHA256SUMS | sha256sum -c --quiet ) \
  || die "checksum mismatch for $ZIP"
ok "checksum verified"

step "Installing"
( cd "$TMP" && unzip -q "$ZIP" )
"$TMP/cockpit-server/install.sh" "${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"}"
