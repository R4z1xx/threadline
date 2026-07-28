#!/usr/bin/env bash
# threadline :: lib/agent_falco.sh
# Installs Falco, enables JSON file output, drops in curated custom rules,
# and wires the alert file into Vector.

install_falco() {
  local root_dir="$1"

  if has_cmd falco; then
    log "Falco already installed, skipping package install (rules/output config will still be refreshed)."
  else
    log "Installing Falco..."
    curl -fsSL https://falco.org/repo/falcosecurity-packages.asc | \
      gpg --dearmor -o /usr/share/keyrings/falco-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/falco-archive-keyring.gpg] https://download.falco.org/packages/deb stable main" \
      > /etc/apt/sources.list.d/falcosecurity.list
    apt-get update -y
    FALCO_FRONTEND=noninteractive apt-get install -y falco
  fi

  # Enable JSON output to a file Vector can tail. Falco ships modern eBPF as
  # the default driver on recent kernels (Ubuntu 22.04/24.04), no DKMS needed.
  if ! grep -q '^json_output: true' /etc/falco/falco.yaml 2>/dev/null; then
    cat >> /etc/falco/falco.yaml <<'EOF'

# --- added by threadline ---
json_output: true
file_output:
  enabled: true
  keep_alive: false
  filename: /var/log/falco_events.json
EOF
  fi

  mkdir -p /etc/falco/rules.d
  if [ -d "$root_dir/rules/falco" ]; then
    cp -f "$root_dir"/rules/falco/*.yaml /etc/falco/rules.d/ 2>/dev/null
  fi

  touch /var/log/falco_events.json
  systemctl enable --now falco || systemctl enable --now falco-modern-bpf

  cat > /etc/vector/conf.d/11-falco.toml <<'EOF'
[sources.falco_raw]
type = "file"
include = ["/var/log/falco_events.json"]

[transforms.shipped_falco]
type = "remap"
inputs = ["falco_raw"]
source = '''
. = parse_json!(.message)
.source_tool = "falco"
'''
EOF

  systemctl restart vector 2>/dev/null || true
  log "Falco installed and shipping alerts via Vector."
}
