#!/usr/bin/env bash
# threadline :: lib/agent_rustinel.sh
# Installs Rustinel (https://github.com/Karib0u/rustinel) and wires up three
# rule sources, kept in clearly separated folders so provenance stays obvious:
#
#   rules/sigma/custom/           <- this repo's own hand-written rules
#   rules/sigma/vendor/sigmahq/   <- SigmaHQ/sigma default repo, filtered to
#                                    Linux-relevant categories (homelab fleet
#                                    is Linux, no point pulling 3000+ Windows
#                                    rules). Add other Sigma sources here
#                                    manually later if you want them.
#   rules/yara/custom/            <- this repo's own hand-written rules
#   rules/yara/vendor/yara-collection/ <- your R4z1xx/yara-collection repo,
#                                    cloned as-is (already curated by you)
#
# Falco keeps the stock falcosecurity default rules only (see agent_falco.sh
# -- unchanged). Sysmon-Linux keeps the MSTIC-Sysmon config (see
# agent_sysmon.sh -- unchanged).

RUSTINEL_DIR="/opt/rustinel"

# Pinned-by-default, override by exporting before running the installer if
# you want a fork or a different commit, e.g.:
#   export YARA_COLLECTION_REPO="https://github.com/you/your-fork.git"
SIGMAHQ_REPO="${SIGMAHQ_REPO:-https://github.com/SigmaHQ/sigma.git}"
SIGMAHQ_CATEGORIES="${SIGMAHQ_CATEGORIES:-linux cloud network web}"
YARA_COLLECTION_REPO="${YARA_COLLECTION_REPO:-https://github.com/R4z1xx/yara-collection.git}"

install_rustinel_binary() {
  if [ -x "$RUSTINEL_DIR/rustinel" ]; then
    log "Rustinel binary already installed at $RUSTINEL_DIR, skipping."
    return
  fi

  log "Installing Rustinel..."
  mkdir -p "$RUSTINEL_DIR"
  local arch version url
  arch="$(uname -m)"
  version="$(curl -fsSL https://api.github.com/repos/Karib0u/rustinel/releases/latest | grep '"tag_name"' | cut -d'"' -f4)" || true
  [ -n "$version" ] || die "Could not determine latest Rustinel release version."
  url="https://github.com/Karib0u/rustinel/releases/download/${version}/rustinel-${version#v}-${arch}-unknown-linux-musl.tar.gz"

  curl -fsSL "$url" -o /tmp/rustinel.tar.gz || die "Failed to download Rustinel from $url"
  tar -xzf /tmp/rustinel.tar.gz -C "$RUSTINEL_DIR" --strip-components=1
  rm -f /tmp/rustinel.tar.gz
  chmod +x "$RUSTINEL_DIR/rustinel"

  cat > /etc/systemd/system/rustinel.service <<EOF
[Unit]
Description=Rustinel eBPF Sentinel
Documentation=https://github.com/Karib0u/rustinel
After=network.target

[Service]
ExecStart=${RUSTINEL_DIR}/rustinel run
WorkingDirectory=${RUSTINEL_DIR}
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_BPF CAP_NET_ADMIN CAP_SYS_RESOURCE
CapabilityBoundingSet=CAP_BPF CAP_NET_ADMIN CAP_SYS_RESOURCE
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

write_rustinel_config() {
  # Explicit config.toml instead of relying on undocumented default
  # discovery -- keeps this script correct even if Rustinel's zero-config
  # defaults change in a future release. Run `rustinel doctor` after first
  # start to confirm paths resolved as expected.
  [ -f "$RUSTINEL_DIR/config.toml" ] && return   # don't clobber hand-edits
  cat > "$RUSTINEL_DIR/config.toml" <<EOF
[scanner]
sigma_rules_path = "rules/sigma"
yara_rules_path  = "rules/yara"

[ioc]
hashes_path  = "rules/ioc/hashes.txt"
ips_path     = "rules/ioc/ips.txt"
domains_path = "rules/ioc/domains.txt"

[reload]
enabled = true
debounce_ms = 2000
EOF
}

sync_sigmahq() {
  local dest="$RUSTINEL_DIR/rules/sigma/vendor/sigmahq"
  local checkout="/opt/threadline-cache/sigmahq"

  log "Syncing SigmaHQ default repo (categories: ${SIGMAHQ_CATEGORIES})..."
  mkdir -p /opt/threadline-cache

  if [ ! -d "$checkout/.git" ]; then
    git clone --filter=blob:none --sparse --depth 1 "$SIGMAHQ_REPO" "$checkout"
  fi
  ( cd "$checkout" && git sparse-checkout set $(printf 'rules/%s ' $SIGMAHQ_CATEGORIES) && git pull --ff-only )

  mkdir -p "$dest"
  rm -rf "${dest:?}"/*
  for cat in $SIGMAHQ_CATEGORIES; do
    [ -d "$checkout/rules/$cat" ] && cp -r "$checkout/rules/$cat" "$dest/"
  done
  log "SigmaHQ sync done: $(find "$dest" -name '*.yml' | wc -l) rules in $dest"
}

sync_yara_collection() {
  local dest="$RUSTINEL_DIR/rules/yara/vendor/yara-collection"
  local checkout="/opt/threadline-cache/yara-collection"

  log "Syncing your YARA collection ($YARA_COLLECTION_REPO)..."
  mkdir -p /opt/threadline-cache

  if [ ! -d "$checkout/.git" ]; then
    git clone --depth 1 "$YARA_COLLECTION_REPO" "$checkout"
  else
    ( cd "$checkout" && git pull --ff-only )
  fi

  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest"
  cp -r "$checkout" "$dest"
  rm -rf "$dest/.git"
  log "YARA collection sync done: $(find "$dest" -name '*.yar' | wc -l) rules in $dest"
}

sync_custom_rules() {
  local root_dir="$1"
  mkdir -p "$RUSTINEL_DIR/rules/sigma/custom" "$RUSTINEL_DIR/rules/yara/custom" "$RUSTINEL_DIR/rules/ioc" "$RUSTINEL_DIR/logs"

  if [ -d "$root_dir/rules/sigma" ]; then
    find "$root_dir/rules/sigma" -maxdepth 1 -name '*.yml' -exec cp -f {} "$RUSTINEL_DIR/rules/sigma/custom/" \;
  fi
  if [ -d "$root_dir/rules/yara" ]; then
    find "$root_dir/rules/yara" -maxdepth 1 -name '*.yar' -exec cp -f {} "$RUSTINEL_DIR/rules/yara/custom/" \;
  fi
}

install_rustinel() {
  local root_dir="$1"

  has_cmd git || { apt-get update -y && apt-get install -y git; }

  install_rustinel_binary
  write_rustinel_config
  sync_custom_rules "$root_dir"
  sync_sigmahq
  sync_yara_collection

  cat > /etc/vector/conf.d/10-rustinel.toml <<EOF
[sources.rustinel_raw]
type = "file"
include = ["${RUSTINEL_DIR}/logs/alerts.json.*"]
line_delimiter = "\n"

[transforms.shipped_rustinel]
type = "remap"
inputs = ["rustinel_raw"]
source = '''
. = parse_json!(.message)
.source_tool = "rustinel"
'''
EOF

  systemctl daemon-reload
  systemctl enable --now rustinel
  systemctl restart vector 2>/dev/null || true

  log "Rustinel installed. Rule counts: $(find "$RUSTINEL_DIR/rules/sigma" -name '*.yml' | wc -l) Sigma, $(find "$RUSTINEL_DIR/rules/yara" -name '*.yar' | wc -l) YARA."
  log "Run '${RUSTINEL_DIR}/rustinel doctor' to confirm paths and rule counts resolved correctly."
}

# Standalone re-sync, for cron/manual updates without touching the binary or
# systemd unit -- rules hot-reload, so this alone is enough to pick up
# upstream changes:
#   source lib/agent_rustinel.sh && sync_sigmahq && sync_yara_collection
