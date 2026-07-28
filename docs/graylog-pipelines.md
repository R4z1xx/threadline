# Graylog pipelines, Sigma alerts & MISP enrichment

Copy-paste reference for the manual step in `README.md#post-install-graylog-setup`.

## MISP enrichment pipeline rule

Once you've created the `misp_ioc_lookup` lookup table (README §2), add this under
**System → Pipelines → Rules → Create rule**:

```
rule "enrich src_ip with MISP"
when
  has_field("src_ip")
then
  let result = lookup("misp_ioc_lookup", to_string($message.src_ip));
  set_field("misp_match", result["value"]);
  set_field("misp_event_id", result["event_id"]);
  set_field("misp_tags", result["tags"]);
end
```

Attach it to a pipeline (**System → Pipelines → Create pipeline**), stage 0, connected to whichever
stream(s) carry your raw logs (or the default "All messages" stream to start).

## Sigma → Graylog alert workflow

Graylog doesn't speak Sigma YAML natively. Convert with [`sigma-cli`](https://github.com/SigmaHQ/sigma-cli):

```bash
pip install sigma-cli pysigma-backend-opensearch --break-system-packages
sigma convert -t opensearch -p ecs_windows rules/sigma/whoami_execution.yml
```

Pick the pysigma pipeline (`-p`) that matches how your fields are named once ingested — `ecs_windows`
is a reasonable default if you're also enriching Sysmon-Linux fields, but check `sigma-cli list pipelines`
for the current options.

Take the resulting query string and either:

1. **Saved search + Event Definition** (simplest): paste the query into a Graylog search, save it,
   then **Alerts → Event Definitions → Create event definition → Filter & Aggregation**, using that
   query as the filter condition. Attach a notification (see below).
2. **Pipeline rule** — if the rule needs pre-processing/enrichment before matching, wrap the
   converted query inside a pipeline stage instead.

## Wiring alerts to n8n

**Alerts → Notifications → Create notification → HTTP notification**, pointing at your n8n Webhook
node URL. Attach it to each Event Definition. The payload includes the full enriched message
(including `misp_match`/`misp_tags` from the pipeline rule above), so n8n can branch on severity or
CTI match without a second lookup.

## Keeping this in sync with the repo

Once you've built pipelines/dashboards/lookup tables you're happy with, export them:
**System → Content Packs → Export content pack**, save the JSON, and replace
`content-packs/graylog-threadline.json` in your fork — future `--role=core` installs (yours or
anyone else's) will then get your full setup automatically instead of just the bare GELF input.
