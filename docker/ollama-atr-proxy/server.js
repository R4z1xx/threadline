#!/usr/bin/env node
// threadline :: docker/ollama-atr-proxy/server.js
// ESM module -- agent-threat-rules ships ESM-only (no CJS "require" export).
//
// Transparent reverse proxy in front of Ollama's API. Every request body is
// inspected: if it looks like a prompt (Ollama's /api/generate `prompt`
// field, or /api/chat `messages` array), it's run through the ATR engine
// before being forwarded upstream. Findings are appended as NDJSON to
// ATR_FINDINGS_LOG for Vector to tail -- same shape as the Rustinel/Falco/
// ATR-scan pipeline already in this project.
//
// Point n8n's Ollama/HTTP node at this proxy's port instead of Ollama's
// native port. Everything else about the request/response is passed
// through unmodified (including streaming responses).
//
// Env vars:
//   OLLAMA_UPSTREAM   default http://127.0.0.1:11434
//   PROXY_PORT        default 11500
//   ATR_FINDINGS_LOG  default /opt/threadline-ollama-atr-findings.ndjson
//   ATR_MODE          "alert" (default, log only) or "enforce" (block
//                      high/critical matches with an HTTP 403 instead of
//                      forwarding them)

import http from 'node:http';
import fs from 'node:fs';
import { ATREngine } from 'agent-threat-rules';

const UPSTREAM = process.env.OLLAMA_UPSTREAM || 'http://127.0.0.1:11434';
const LISTEN_PORT = parseInt(process.env.PROXY_PORT || '11500', 10);
const FINDINGS_LOG = process.env.ATR_FINDINGS_LOG || '/opt/threadline-ollama-atr-findings.ndjson';
const MODE = process.env.ATR_MODE || 'alert';

const upstreamUrl = new URL(UPSTREAM);
const engine = new ATREngine();
if (typeof engine.loadRules === 'function') {
  await engine.loadRules();
}

function extractPromptContent(bodyText) {
  try {
    const parsed = JSON.parse(bodyText);
    if (typeof parsed.prompt === 'string') return parsed.prompt;
    if (Array.isArray(parsed.messages)) {
      return parsed.messages.map((m) => m.content || '').join('\n');
    }
  } catch (_e) {
    // Not JSON (or not a shape we recognize) -- nothing to scan.
  }
  return '';
}

function logFinding(req, matches) {
  const line = JSON.stringify({
    timestamp: new Date().toISOString(),
    source_tool: 'atr',
    proxy: 'ollama',
    path: req.url,
    matches: matches.map((m) => ({
      rule_id: m.rule && m.rule.id,
      severity: m.rule && m.rule.severity,
      category: m.rule && m.rule.category,
    })),
  }) + '\n';
  fs.appendFile(FINDINGS_LOG, line, (err) => {
    if (err) console.error('Failed to write findings log:', err.message);
  });
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const bodyRaw = Buffer.concat(chunks);
    const promptContent = extractPromptContent(bodyRaw.toString('utf8'));

    let matches = [];
    if (promptContent) {
      try {
        matches = engine.evaluate({
          type: 'llm_input',
          content: promptContent,
          timestamp: new Date().toISOString(),
        }) || [];
      } catch (err) {
        console.error('ATR evaluate() failed:', err.message);
      }
    }

    if (matches.length > 0) {
      logFinding(req, matches);
      const blocking = matches.some(
        (m) => m.rule && (m.rule.severity === 'critical' || m.rule.severity === 'high')
      );
      if (MODE === 'enforce' && blocking) {
        res.writeHead(403, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          error: 'Blocked by threadline ollama-atr-proxy',
          rule_ids: matches.map((m) => m.rule && m.rule.id),
        }));
        return;
      }
    }

    const upstreamReq = http.request(
      {
        hostname: upstreamUrl.hostname,
        port: upstreamUrl.port || 80,
        path: req.url,
        method: req.method,
        headers: req.headers,
      },
      (upstreamRes) => {
        res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
        upstreamRes.pipe(res);
      }
    );
    upstreamReq.on('error', (err) => {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Upstream Ollama unreachable', detail: err.message }));
    });
    upstreamReq.write(bodyRaw);
    upstreamReq.end();
  });
});

server.listen(LISTEN_PORT, () => {
  console.log(
    `threadline ollama-atr-proxy listening on :${LISTEN_PORT} -> ${UPSTREAM} ` +
    `(mode=${MODE}, findings=${FINDINGS_LOG})`
  );
});
