# AI agent telemetry: Claude Code, Claude Cowork, Ollama

Two different mechanisms for two different kinds of sources, both feeding Graylog. Claude
Code/Cowork use their native OpenTelemetry export; Ollama gets a logging/enforcement proxy since
it has no equivalent built in.

## Claude Code / Claude Cowork -> OTel Collector -> Graylog

### 1. One-time: create the Graylog OTLP input

The `otel-collector` container is already running as part of `--role=core` (see
`docker/graylog-compose.yml`), listening on port 4317. It forwards to Graylog's own OTLP input,
which -- like the MISP lookup table -- is a short manual step rather than something auto-imported,
since Graylog's input schema is more version-sensitive than worth guessing at:

**Graylog UI -> System -> Inputs -> select "OpenTelemetry (gRPC)" -> Launch new input**
- Bind address: `0.0.0.0`
- Port: `4318` (deliberately different from the collector's own `4317` -- see
  `docker/otel-collector-config.yaml` for why)

That's it -- the collector is already configured to export to `graylog:4318` on the Docker network.

### 2. Claude Code CLI

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=http://<core-vm-ip>:4317
# Optional, real privacy tradeoff -- off by default for a reason:
export OTEL_LOG_USER_PROMPTS=1     # includes actual prompt text
export OTEL_LOG_TOOL_DETAILS=1     # includes tool params (e.g. bash_command) -- sensitive
```

Or persist it in `~/.claude/settings.json`:

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "http://<core-vm-ip>:4317"
  }
}
```

### 3. Claude Code VS Code extension

Same mechanism, same `~/.claude/settings.json` -- but there's a known bug
([anthropics/claude-code#35105](https://github.com/anthropics/claude-code/issues/35105)) where
OTel doesn't always initialize from that file alone inside the extension's process. Set it
**redundantly** in VS Code's own `settings.json` too:

```json
{
  "claudeCode.environmentVariables": [
    { "name": "CLAUDE_CODE_ENABLE_TELEMETRY", "value": "1" },
    { "name": "OTEL_LOGS_EXPORTER", "value": "otlp" },
    { "name": "OTEL_EXPORTER_OTLP_PROTOCOL", "value": "grpc" },
    { "name": "OTEL_EXPORTER_OTLP_ENDPOINT", "value": "http://<core-vm-ip>:4317" }
  ]
}
```

### 4. Claude Code VS Code extension over Remote-SSH

The extension runs **on the remote host**, not your local machine (VS Code puts workspace
extensions like this one on the SSH host by design). This means:

- `~/.claude/settings.json` needs to exist **on the remote host**, not your laptop.
- The `claudeCode.environmentVariables` VS Code setting needs to go in the **Remote [SSH:
  hostname]** settings scope (there's a separate Local/Remote tab in Settings when connected via
  Remote-SSH) -- setting it Locally won't reach the remote extension host.
- `OTEL_EXPORTER_OTLP_ENDPOINT` should point at wherever the OTel Collector is reachable **from
  the remote host's network** -- if that remote host is itself a homelab VM, this is genuinely
  simpler than the local-laptop case: the traffic never leaves the homelab.

**Sanity check before assuming this all works**: there's a separate, unrelated bug
([anthropics/claude-code#20226](https://github.com/anthropics/claude-code/issues/20226)) where
certain OS combinations (Windows-local -> Linux-remote in particular) cause the extension to not
fully switch into remote mode -- it keeps trying to use local paths and can't find the remote
`claude` binary. If that's happening, telemetry won't fire either, since the extension isn't
actually running on the remote side. Open the VS Code integrated terminal while connected and run
`claude --version` -- if it resolves cleanly to the remote binary, the OTel config above will work.

### What lands in Graylog

Events (`user_prompt`, `tool_result`, `api_request`) carry a shared `prompt.id` correlating
everything from one interaction. Resource attributes land as `otel_resource_attributes_*` fields.

**Recommended approach for detection**: rather than depending on `atr convert elastic` output
matching this exact field schema (uncertain without testing against your specific Graylog
version), write detection logic as native Graylog pipeline rules against the
`otel_resource_attributes_*`/prompt-content fields directly -- using ATR's rule *content* as
reference material for what patterns matter, not as literal drop-in queries. Same reasoning as
using SigmaHQ conversions: verify the field mapping before trusting it blindly.

---

## Ollama (and n8n)

No native OTel equivalent, so this repo ships an actual proxy: `docker/ollama-atr-proxy/`. It
sits in front of Ollama's API, forwards everything transparently, and evaluates any request that
looks like a prompt (`/api/generate`'s `prompt` field, `/api/chat`'s `messages` array) through a
real embedded ATR engine.

### Install

```bash
export OLLAMA_UPSTREAM="http://127.0.0.1:11434"   # wherever Ollama actually listens
export OLLAMA_ATR_PROXY_PORT="11500"              # what n8n will call instead
export OLLAMA_ATR_MODE="alert"                    # or "enforce" to block high/critical matches
sudo bash -s -- --role=agent --graylog=<core-vm-ip> --agents=ollama-atr-proxy --yes
```

### Point n8n at the proxy instead of Ollama directly

In any n8n workflow's Ollama/HTTP Request node, change the base URL from
`http://<ollama-host>:11434` to `http://<ollama-host>:11500` (or whatever `OLLAMA_ATR_PROXY_PORT`
you set). Nothing else about the workflow changes -- responses (including streaming) pass through
unmodified unless a request is actually blocked in `enforce` mode.

### Modes

- **`alert`** (default): every match gets logged to `/opt/threadline-ollama-atr-findings.ndjson`
  (tagged `source_tool: atr`, ships to Graylog via Vector like everything else), request still
  forwards to Ollama normally.
- **`enforce`**: matches with `severity: high` or `severity: critical` get an HTTP 403 instead of
  reaching Ollama at all. Lower-severity matches still log but pass through. Start in `alert` mode
  until you've tuned for false positives on your own workflows, then switch.

### What this does and doesn't cover

Only the **request** (prompt/message content) is scanned right now -- not Ollama's response. This
was a deliberate v1 scope choice to keep the proxy simple; extending `server.js` to also run
`engine.evaluate()` on the response body (buffering instead of piping it straight through) is a
natural next step if you want output-side detection (e.g. data exfiltration patterns in model
responses) as well.
