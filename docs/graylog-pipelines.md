# Graylog pipelines, Sigma alerts & MISP enrichment

The MISP enrichment section below (data adapter, cache, lookup table, pipeline rule) is created
automatically by `sudo ./run.sh --role=core --link-misp` once `MISP_API_KEY` is set -- see
`lib/core_bootstrap.sh` (`create_misp_data_adapter`, `create_misp_cache`, `create_misp_lookup_table`,
`create_misp_pipeline`). What follows is the manual, click-through equivalent: useful if one of
those automated steps warns and needs finishing by hand, or if you just want to understand what
the automation is doing under the hood.

## MISP enrichment pipeline rule

If doing this by hand: once you've created the `misp_ioc_lookup` lookup table, add this under
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

## Backing up your pipeline/dashboard setup

If you've customized pipelines/dashboards beyond what's automated here, Graylog can still export
them as a content pack (**System → Content Packs → Export content pack**) for your own backup/
reference purposes -- useful if you ever need to rebuild this Graylog instance from scratch. This
repo's installer doesn't consume or auto-import that export, though: content packs turned out to
be persistently version-fragile in practice (missing required fields, "already found" duplicate
errors, a broken details-viewer page across different Graylog versions), so both the GELF input
and the MISP enrichment chain are created via Graylog's plain REST API directly instead -- see the
comment above `create_gelf_input()` in `lib/core_bootstrap.sh` for the full history.