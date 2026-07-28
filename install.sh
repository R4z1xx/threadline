#!/usr/bin/env bash
#
# threadline :: install.sh
#
# This is the ONLY file you ever need to fetch by hand. It clones/updates
# the full project into /opt/threadline and hands off to run.sh, which does
# the real work with access to lib/, docker/, content-packs/ and rules/.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<you>/threadline/main/install.sh | sudo bash -s -- --role=core
#   curl -fsSL https://raw.githubusercontent.com/<you>/threadline/main/install.sh | sudo bash -s -- --role=agent --graylog=192.168.1.50
#
set -euo pipefail

REPO_URL="${THREADLINE_REPO:-https://github.com/R4z1xx/threadline.git}"
REPO_TARBALL="${THREADLINE_TARBALL:-https://github.com/R4z1xx/threadline/archive/refs/heads/main.tar.gz}"
INSTALL_DIR="/opt/threadline"

log()  { echo -e "\033[1;34m[threadline]\033[0m $*"; }
die()  { echo -e "\033[1;31m[threadline][FATAL]\033[0m $*" >&2; exit 1; }

print_banner() {
  cat <<'BANNER'
 _____ _                        _   __ _
/__   \ |__  _ __ ___  __ _  __| | / /(_)_ __   ___
  / /\/ '_ \| '__/ _ \/ _` |/ _` |/ / | | '_ \ / _ \
 / /  | | | | | |  __/ (_| | (_| / /__| | | | |  __/
 \/   |_| |_|_|  \___|\__,_|\__,_\____/_|_| |_|\___|

BANNER
}
print_banner

[ "$(id -u)" -eq 0 ] || die "Run this with sudo/root (needed for docker, apt, systemd units)."

fetch_repo() {
  if [ -d "$INSTALL_DIR/.git" ]; then
    log "Existing checkout found at $INSTALL_DIR, updating..."
    git -C "$INSTALL_DIR" pull --ff-only || die "git pull failed. Resolve manually in $INSTALL_DIR or remove it and re-run."
    return
  fi

  if [ -d "$INSTALL_DIR" ]; then
    log "Non-git directory already exists at $INSTALL_DIR, leaving it as-is."
    return
  fi

  if command -v git >/dev/null 2>&1; then
    log "Cloning $REPO_URL into $INSTALL_DIR ..."
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
  else
    log "git not found, falling back to tarball download..."
    mkdir -p "$INSTALL_DIR"
    tmp_tar="$(mktemp)"
    curl -fsSL "$REPO_TARBALL" -o "$tmp_tar" || die "Could not download $REPO_TARBALL"
    tar -xzf "$tmp_tar" --strip-components=1 -C "$INSTALL_DIR"
    rm -f "$tmp_tar"
  fi
}

fetch_repo

chmod +x "$INSTALL_DIR/run.sh"
exec "$INSTALL_DIR/run.sh" "$@"
