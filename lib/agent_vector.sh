#!/usr/bin/env bash
# threadline :: lib/agent_vector.sh
# Installs Vector and lays down a base config.
#
# Convention used across all agent_*.sh scripts: every Vector source/transform
# component ID is prefixed "shipped_" (e.g. shipped_rustinel, shipped_falco).
# The single sink at the bottom uses Vector's wildcard input matching
# (inputs = ["shipped_*"]) so each agent script can drop its own .toml
# fragment into /etc/vector/conf.d/ independently, with zero coordination
# and no need to rewrite the sink's input list each time.

VECTOR_CONF_DIR="/etc/vector"
VECTOR_FRAGMENTS_DIR="/etc/vector/conf.d"

install_vector() {
  local root_dir="$1" graylog_host="$2"

  if ! has_cmd vector; then
    log "Installing Vector..."
    # Old domain (repositories.timber.io) is dead -- Vector moved under Datadog
    # and now serves its APT repo bootstrap from setup.vector.dev.
    bash -c "$(curl -fsSL https://setup.vector.dev)"
    apt-get install -y vector
  else
    log "Vector already installed, skipping package install."
  fi

  mkdir -p "$VECTOR_FRAGMENTS_DIR"

  # Base fragment: always-on journald source + the one sink every fragment ships to.
  cat > "$VECTOR_FRAGMENTS_DIR/00-base.toml" <<EOF
[sources.shipped_journald]
type = "journald"

[sinks.graylog]
type = "gelf"
inputs = ["shipped_*"]
endpoint = "udp://${graylog_host}:12201"
EOF

  # Point the systemd unit at the whole conf.d directory instead of a single file.
  mkdir -p /etc/systemd/system/vector.service.d
  cat > /etc/systemd/system/vector.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/vector --config-dir ${VECTOR_FRAGMENTS_DIR}
EOF

  systemctl daemon-reload
  systemctl enable --now vector
  log "Vector base config written, shipping journald -> ${graylog_host}:12201 (config-dir: ${VECTOR_FRAGMENTS_DIR})"
}
