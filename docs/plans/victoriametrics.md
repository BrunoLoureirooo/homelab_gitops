# Research: should the homelab replace its observability stack with VictoriaMetrics?

Written 2026-11-24. Convention followed: `docs/plans/` is where this repo keeps its plan and research notes (there is no `docs/research/`), so this lives at `docs/plans/victoriametrics.md`.
Unlike the other files in that directory it is a research note, not a hand-off plan: nothing here is to be executed without the operator's decision.

Source rules: primary sources only (VictoriaMetrics docs and repos, prometheus.io, grafana.com docs and the Grafana repo). Docs versions: VictoriaMetrics **v1.157.0** (released 2026-11-23, [release](https://github.com/VictoriaMetrics/VictoriaMetrics/releases/tag/v1.157.0)); VictoriaLogs v1.54.0 (2026-11-13); VictoriaTraces v0.13.0 (2026-11-05); Helm chart `victoria-metrics-single` 0.52.0 (appVersion v1.157.0). The docs text was read from the repository files at those tags, which is what docs.victoriametrics.com renders.
Marks: `[vendor claim]` = a number the vendor publishes about its own product. `[repo]` = read in this repository. `[live]` = read-only query of the running cluster on 2026-11-24. `[not verified]` = I could not confirm it; the text says why.

## 1. TL;DR

- **The "replaces Grafana with a tenth of the resources" claim is wrong as stated.** VictoriaMetrics (VM) is a time-series database and scraper with a Prometheus-compatible query API. Its own docs describe it as "a drop-in replacement for Prometheus in Grafana", that is, Grafana stays and VM takes Prometheus's place as the datasource ([README](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/v1.157.0/docs/victoriametrics/README.md), "Prominent features"). No VM page I read claims to replace Grafana. The closest product is vmui, a query/troubleshooting UI, which is not a dashboard engine (section 5).
- **The only "x times less" figures in the VM docs are against Prometheus, Thanos, Cortex, InfluxDB, TimescaleDB and Graphite, never against Grafana.** The largest Prometheus figure is "up to 7x less RAM" and "up to 7x less storage", [vendor claim], measured "when dealing with millions of unique time series" ([README](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/v1.157.0/docs/victoriametrics/README.md), "Prominent features"). "A tenth" appears for InfluxDB RAM ("10x less RAM than InfluxDB"), not for Prometheus. The speaker most likely mixed these up.
- **What VM would replace here: Prometheus only** (storage, scraping, query API) plus Prometheus's rule evaluation, which moves to a separate `vmalert` process. **What it would not replace: Alertmanager** (vmalert sends to it via `-notifier.url`), **Grafana**, node-exporter, kube-state-metrics.
- **Savings at this scale are small in absolute terms.** The stack has ~55.5k active series and ingests ~917 samples/s [live]. The vendor's numbers are for millions of series. Prometheus is using ~300 to 376 MiB; even if the vendor's best-case 7x applied (it will not at this size), the ceiling is about 320 MiB freed. Grafana, the actual pain point, uses about twice what Prometheus does and VM does not touch it.
- **Recommendation: do not migrate for resource reasons.** Fix Grafana's memory first (limit, `GOMEMLIMIT`, section 5). If the operator still wants VM for other reasons, run it side by side as a trial (section 6). Details in section 8.

## 2. Baseline: what the current stack actually uses

Manifests: `talos/manifests/monitoring/` [repo]: plain manifests, no operator, deployed by a manual-sync Argo CD Application. Prometheus `quay.io/prometheus/prometheus:v3.15.1`, `--storage.tsdb.retention.time=30d`, `--storage.tsdb.retention.size=7GB`, 10Gi `topolvm-fast` PVC, limit 768Mi. Alertmanager v0.34.1 (Watchdog routed to healthchecks.io). Grafana 13.2.4, five provisioned dashboards (node-exporter-full, kube-state-metrics-v2, argocd, cloudnativepg, cluster-overview), limit 768Mi in the manifest. kube-state-metrics, node-exporter DaemonSet. Everything is pinned to node mini03 with `nodeSelector` and a `tier=mobile` toleration. One hand-written `prometheus.yml` (global `scrape_interval: 60s`, 14 jobs, `kubernetes_sd_configs` for roles `node`, `pod`, `endpoints`) and `rules-core.yml` (49 alerts).

Measured read-only on 2026-11-24 [live] (`kubectl top pod -n monitoring`, and queries against Prometheus's own API through `kubectl exec`):

| Component | CPU | Memory (working set) | Notes |
|---|---|---|---|
| Prometheus | 13m | 300Mi (process RSS 376 MB) | 30 targets up; `GOMEMLIMIT` auto-set to ~691 MiB |
| Grafana | 17m | 600Mi (process RSS 751 MB, 2-day max RSS 933 MB, Go heap in use 475 MB) | 222 restarts, last termination reason `OOMKilled` at 10:44 UTC today; live limit still 768Mi |
| Alertmanager | 1m | 15Mi | |
| kube-state-metrics | 1m | 14Mi | |
| node-exporter x3 | 1-2m each | 10-19Mi each | |
| **Total** | ~36m | ~970Mi | |

TSDB [live]: head series 55,529; ingestion `rate(prometheus_tsdb_head_samples_appended_total[5m])` = 917 samples/s; persistent blocks 652 MB, WAL 142 MB, `/prometheus` 789 MB on disk; oldest sample about 5.5 days old, so the 30d retention is not yet reached. Derived: 652 MB over about 467,000 s at 917 samples/s is about 1.5 bytes per sample (assumes a constant rate; approximate). This matches the Prometheus docs: "Prometheus stores an average of only 1-2 bytes per sample" ([prometheus.io storage](https://prometheus.io/docs/prometheus/latest/storage/)). At 30 days the data would be about 4.3 GB, under the 7 GB cap.

**Takeaway: Grafana, not Prometheus, is the biggest consumer on mini03, and it is the one that is being OOM-killed.**

## 3. Components and how each maps to this repo

Single-node VM is one binary that stores data, scrapes, and serves the query API. The cluster version splits it into vminsert, vmselect and vmstorage. The FAQ says "it is recommended to use single-node VictoriaMetrics in the majority of cases" and "Don't choose VictoriaMetrics cluster unless you have to" ([FAQ](https://docs.victoriametrics.com/victoriametrics/faq/#which-victoriametrics-type-is-recommended-for-use-in-production---single-node-or-cluster)); only the cluster version has multitenancy ([FAQ](https://docs.victoriametrics.com/victoriametrics/faq/#what-is-the-difference-between-single-node-and-cluster-versions-of-victoriametrics)). For one 8 GiB node and a single operator, cluster mode is pointless.

| VM component | What it does (source) | Today's equivalent | Needed here? |
|---|---|---|---|
| `victoria-metrics` (single-node) | TSDB + `/api/v1/*` Prometheus query API + optional scraping via `-promscrape.config` ([README](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#how-to-scrape-prometheus-exporters-such-as-node-exporter)) | Prometheus | Yes, this is the replacement |
| `vmagent` | "a tiny agent that helps you collect metrics ... relabel and filter" and forward by remote_write; no query API ([vmagent](https://docs.victoriametrics.com/victoriametrics/vmagent/)) | Prometheus scraping / agent mode | No. Single-node VM can scrape by itself. Useful only with remote storage or multiple clusters |
| `vmalert` | "executes a list of the given alerting or recording rules against configured `-datasource.url`" ([vmalert](https://docs.victoriametrics.com/victoriametrics/vmalert/#features)) | Prometheus rule evaluation (`rule_files`) | Yes, a second Deployment |
| `vmui` | Built-in UI at `/vmui` on port 8428 ([README vmui](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#vmui)) | Prometheus's own web UI | Comes with VM, nothing to deploy |
| `vmauth` | HTTP proxy that can authorize, route and load-balance requests ([vmauth](https://docs.victoriametrics.com/victoriametrics/vmauth/)) | Nothing today (access is through the Tailscale ingress) | No |
| `vmbackup` / `vmrestore` | Backup to GCS, S3, Azure or local filesystem, incremental ([vmbackup](https://docs.victoriametrics.com/victoriametrics/vmbackup/)); works from a snapshot ([snapshots](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#how-to-work-with-snapshots)) | Nothing; Prometheus data is covered only by whatever backs up the PVC | Optional. Metrics are a low-value restore target here |
| Alertmanager | Not a VM component. vmalert relies on it for notifications: "For sending alerting notifications vmalert relies on Alertmanager configured via `-notifier.url`" ([vmalert](https://docs.victoriametrics.com/victoriametrics/vmalert/#features)) | Alertmanager v0.34.1 | Stays unchanged |
| Grafana | Not a VM component | Grafana 13.2.4 | Stays unchanged |

## 4. Compatibility

**Scrape config.** "VictoriaMetrics can be used as drop-in replacement for Prometheus for scraping targets configured in `prometheus.yml` ... Just set `-promscrape.config` command-line flag to the path to `prometheus.yml`" ([README](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/v1.157.0/docs/victoriametrics/README.md), "How to scrape Prometheus exporters"). `kubernetes_sd_configs` is supported with all six roles: node, service, pod, endpoints, endpointslice, ingress ([sd_configs](https://docs.victoriametrics.com/victoriametrics/sd_configs/#kubernetes_sd_configs)). So the answer to "does single-node VM accept `-promscrape.config` with `kubernetes_sd_configs`" is yes. Unsupported sections are `remote_write`, `remote_read`, `rule_files` and `alerting` ([vmagent](https://docs.victoriametrics.com/victoriametrics/vmagent/#unsupported-prometheus-config-sections)); by default VM errors on unsupported fields and `-promscrape.config.strictParse=false` skips them ([flags](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#list-of-command-line-flags)). `refresh_interval` is not supported on the k8s SD (use `-promscrape.kubernetesSDCheckInterval`). This repo's `prometheus.yml` has an `alerting:` and a `rule_files:` block that would have to be removed. The `-promscrape.config.dryRun` flag exists to validate a file ([flags](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#list-of-command-line-flags)); **I did not run it against this repo's file** (the sandbox denied running the container), so full parse compatibility of the 14 jobs, in particular `metric_relabel_configs` and `authorization.credentials_file`, is `[not verified]`.

**Alert rules.** vmalert is "heavily inspired by Prometheus implementation and aims to be compatible with its syntax" and uses the same YAML `groups:` structure ([vmalert](https://docs.victoriametrics.com/victoriametrics/vmalert/#features)). It adds optional fields (`keep_firing_for`, `eval_offset`, `limit`, `type`) and different templating variables ([vmalert groups](https://docs.victoriametrics.com/victoriametrics/vmalert/#groups)). `rules-core.yml` should load as-is in structure. Two caveats from the repo: (a) rules like `PrometheusAlertmanagerUnreachable`, `PrometheusRuleFailures`, `PrometheusNotificationsFailing` and `PrometheusTSDBNearCap` use `prometheus_*` metrics that VM does not emit; they would need rewriting to `vmalert_*` / `vm_*` metrics. (b) With no Prometheus, the Watchdog (an always-firing alert) would need to come from vmalert instead, and still goes to Alertmanager and healthchecks.io unchanged; that works by the general mechanism above, but the docs have no Watchdog-specific page `[not verified]`.

**Query language.** MetricsQL "is backwards-compatible with PromQL" but has intentional differences ([MetricsQL](https://docs.victoriametrics.com/victoriametrics/metricsql/)): `rate`/`increase` "take into account the last raw sample before the lookbehind window" and "don't extrapolate" results; a step smaller than the sample interval still returns data; NaN values are removed from the output; the lookbehind window can be omitted (`rate(x)`); metric names are dropped after functions unless `keep_metric_names` is used. So `increase()` results on the five dashboards and 49 alerts may differ by small amounts (non-extrapolated, integer values). Threshold alerts such as `increase(...) > 0` are not affected in practice; a side-by-side run (section 6) is the way to confirm.

**Alertmanager still needed?** Yes. vmalert has no notification layer of its own; grouping, inhibition, routing and silencing are Alertmanager's job ([Alertmanager overview](https://prometheus.io/docs/alerting/latest/alertmanager/)), and the current `alertmanager.yml` (Discord, healthchecks.io, inhibit rules) is unchanged. `-notifier.url` "is optional and is needed only if you have alerting rules" ([vmalert](https://docs.victoriametrics.com/victoriametrics/vmalert/#topology-examples)); this repo has alerting rules.

**Grafana datasource.** Two options ([VM Grafana docs](https://docs.victoriametrics.com/victoriametrics/integrations/grafana/)):
1. **Prometheus datasource type**, pointing at `http://<vm>:8428`; the docs say to set the Prometheus type to "Prometheus" and version "at least 2.24.x" in the "Performance" section. Nothing to install, provisioned dashboards stay as they are. `grafana-datasources.yml` would only change its `url` (and keep `uid: prometheus`, so dashboards need no edits).
2. **VictoriaMetrics datasource plugin** (`victoriametrics-metrics-datasource`, v1.0.2 released 2026-11-19, [releases](https://github.com/VictoriaMetrics/victoriametrics-datasource/releases)). Adds MetricsQL functions, query tracing, WITH expressions, a label-name validation fix and vmui integration ([plugin README](https://github.com/VictoriaMetrics/victoriametrics-datasource/blob/main/README.md)). Its `plugin.json` declares `grafanaDependency` `>=11.6.11 <12 || ... || >=12.2.5`, so Grafana 13.x is accepted ([plugin.json](https://github.com/VictoriaMetrics/victoriametrics-datasource/blob/main/src/plugin.json)). Installed with `GF_INSTALL_PLUGINS`, but this repo sets `GF_PLUGINS_PREINSTALL_DISABLED=true` and the plugin would add memory to the process that is already OOM-ing. Dashboards need each panel's datasource re-pointed ([plugin README, "How to convert dashboard"](https://github.com/VictoriaMetrics/victoriametrics-datasource/blob/main/README.md)). Not needed unless MetricsQL is wanted.

   Recommendation: option 1.

## 5. Resource claims and Grafana's memory

All numbers in this section are **vendor claims** from the VM docs. They link to articles on the vendor founder's Medium blog; I could not retrieve those articles (HTTP 403), so **the methodology (hardware, series counts, versions, duration) is not verified by me**. No independent benchmark with published methodology was used.

| Claim (VM README, "Prominent features", v1.157.0) | Against | Stated condition |
|---|---|---|
| "up to 7x less RAM than Prometheus, Thanos or Cortex" | Prometheus | "when dealing with millions of unique time series" |
| "up to 7x less storage space is required compared to Prometheus, Thanos or Cortex" | Prometheus | source: a node-exporter benchmark |
| "uses 10x less RAM than InfluxDB" | InfluxDB | an `inch` insert benchmark |
| "up to 70x more data points may be stored into limited storage compared with TimescaleDB" | TimescaleDB | "when size matters" benchmark |
| "reducing infrastructure costs by more than 10x comparing to Graphite" | Graphite | one customer case study |
| "vmagent usually requires less CPU, RAM and disk IO compared to Prometheus" | Prometheus | no figures ([FAQ](https://docs.victoriametrics.com/victoriametrics/faq/#what-is-the-difference-between-vmagent-and-prometheus)) |

Source for the table: [README](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/v1.157.0/docs/victoriametrics/README.md) lines on "Prominent features"; the vendor's reference scale is "50+ million active time series, 1.5+ million samples per second" ([capacity planning](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#capacity-planning)). I found **no CPU multiplier against Prometheus** in the README or FAQ. Ratio at this repo: 55.5k series is about 0.1% of the vendor's reference scale and 917 samples/s is about 0.06% of its ingest rate, so extrapolating "7x" is not justified. Process baselines do not shrink proportionally with scale.

**Is there anything about Grafana's own memory? No.** None of the VM docs I read compare against Grafana or claim to reduce Grafana's memory; the "tenth" figure is for InfluxDB RAM (see TL;DR). Grafana is the UI process; swapping the datasource behind it does not change its footprint, except marginally if queries return less data.

**Grafana knobs that can reduce or cap memory.** The Grafana configuration reference ([Grafana repo, `configure-grafana`](https://github.com/grafana/grafana/blob/main/docs/sources/setup-grafana/configure-grafana/_index.md), 13.x) has no memory-tuning section, so the list is short:
- Already done in this repo [repo]: `GF_UNIFIED_ALERTING_ENABLED=false`, `GF_PLUGINS_PREINSTALL_DISABLED=true`, analytics and update checks off.
- `[dashboards] min_refresh_interval` (default 5s) stops users setting very fast auto-refresh; `[query] concurrent_query_limit` (default: number of CPUs) caps concurrent queries in mixed panels; `[live] max_connections` (default 100) caps WebSocket connections. All are documented in the reference above. They bound load, not baseline memory, and I did not test their effect.
- Go runtime: Grafana is a Go program, so the standard `GOMEMLIMIT` soft limit applies ([runtime docs](https://pkg.go.dev/runtime)). Setting it to about 85% of the container limit makes the garbage collector work harder before the kernel OOM-kills it. Prometheus already shows this (its `GOMEMLIMIT` was auto-set to ~691 MiB against its 768Mi limit [live]). This is the cheapest change to try, but I did not test it on Grafana.
- Limit: Grafana's 2-day maximum RSS was 933 MB [live], so the planned 1Gi is barely above the observed peak. Ask for at least 1.25 to 1.5Gi on a node that has 8 GiB, or find the cause (which dashboard load drives the peak, whether `node-exporter-full` is the trigger). I did not diagnose the cause.

**Could vmui replace Grafana for the kiosk? No.** vmui has Query, Raw Query, Explore (metrics and cardinality explorers, top and active queries), Tools, a `Dashboards` tab and an `Alerting` tab ([README vmui](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#vmui)). The `Dashboards` tab shows only "predefined dashboards" in vmui's own JSON schema (rows of panels with `expr`, `alias`, `title`, `unit`, `showLegend`, `width`), loaded from files via `--vmui.customDashboardsPath` or compiled into the binary ([vmui README](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/v1.157.0/app/vmui/README.md#predefined-dashboards)). I found no statement that it imports Grafana dashboard JSON, so the five provisioned dashboards (and variables, table/stat panels, kiosk playlists) would have to be rewritten by hand and would not render the same. The `Alerting` tab needs `-vmalert.proxyURL`.

## 6. Related products (logs and traces)

Out of scope today: the monitoring plan lists "Logs (Loki) and traces" as non-goals [repo: `docs/plans/monitoring.md`, section 0].
- **VictoriaLogs** v1.54.0: a log database, single-node or cluster, Apache 2.0. Vendor claim: "up to 30x less RAM and up to 15x less disk space than other solutions such as Elasticsearch and Grafana Loki", pointing at its own benchmarks ([README](https://github.com/VictoriaMetrics/VictoriaLogs/blob/v1.54.0/docs/victorialogs/README.md), "Features"); also a built-in web UI, a Grafana plugin, LogsQL, alerting through vmalert, and a size-based retention flag `-retention.maxDiskSpaceUsageBytes`.
- **VictoriaTraces** v0.13.0: a trace database accepting OTLP and serving the Jaeger Query JSON API. Vendor claim: "up to 3.7x less RAM and up to 2.6x less CPU" than Grafana Tempo ([README](https://github.com/VictoriaMetrics/VictoriaTraces/blob/v0.13.0/docs/victoriatraces/README.md), "Prominent features"), with a vendor blog as source (not read). A 0.x version number.
- Neither replaces anything in this repo, and neither would reduce Grafana's memory. If logs are ever wanted, VictoriaLogs is a reasonable candidate then; not now.

## 7. Migration path for this repo (if the operator chooses it)

Principle: keep Alertmanager, Grafana and the dashboards; replace only the Prometheus Deployment; run both in parallel first.

1. **Add VM next to Prometheus** (no change to Prometheus). New `victoria-metrics.yaml` in `talos/manifests/monitoring/`: image `docker.io/victoriametrics/victoria-metrics:v1.157.0` (also `quay.io/victoriametrics/victoria-metrics`; tag confirmed on [Quay](https://quay.io/repository/victoriametrics/victoria-metrics?tab=tags) and Docker Hub; pin a digest like the other images). Same pod pinning as `prometheus.yaml` (nodeSelector mini03, `tier=mobile` toleration, `Recreate`, own 10Gi PVC). Args: `-storageDataPath=/storage`, `-retentionPeriod=30d`, `-promscrape.config=/etc/vm/prometheus.yml` (a copy with `alerting:` and `rule_files:` removed), `-promscrape.config.strictParse=false` if needed, `-httpListenAddr=:8428`, `-storage.minFreeDiskSpaceBytes=...`. Alternatively the official chart `victoria-metrics-single` 0.52.0 ([values](https://github.com/VictoriaMetrics/helm-charts/blob/master/charts/victoria-metrics-single/values.yaml)); this repo uses plain manifests with no Helm, so plain manifests fit better.
2. **Where data lives:** `-storageDataPath` (default `victoria-metrics-data` in the working directory, so set it explicitly to the PVC mount) ([README](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#how-to-start-victoriametrics)).
3. **Retention behaves differently.** `-retentionPeriod` accepts `h/d/w/M/y`, default 1 month; data is in monthly partitions "deleted on the first day of the new month", and "the maximum disk space usage ... is going to be (`-retentionPeriod` + 1) months" ([retention](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#retention)). **I found no size-based retention flag for single-node VM in the v1.157.0 flag list** (only VictoriaLogs has one), so the Prometheus `retention.size=7GB` safety cap has no direct equivalent; the closest guard is `-storage.minFreeDiskSpaceBytes`, which makes storage stop accepting data when free space runs out. Keep 20% free disk ([capacity planning](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#capacity-planning)). At about 4.3 GB per 30 days, the 10Gi PVC is fine.
4. **vmalert** Deployment: `docker.io/victoriametrics/vmalert:v1.157.0`, args `-rule=/etc/rules/*.yml -datasource.url=http://victoria-metrics:8428 -notifier.url=http://alertmanager.monitoring.svc.cluster.local:9093 -remoteWrite.url=http://victoria-metrics:8428` (the last only if recording rules are used; `-remoteRead.url` restores alert state across restarts) ([vmalert quickstart](https://docs.victoriametrics.com/victoriametrics/vmalert/#quickstart)). Rewrite the four `prometheus_*` self-monitoring alerts. VM exposes its own metrics at `/metrics`; add a scrape job for VM and vmalert.
5. **Grafana:** add a second provisioned datasource (Prometheus type, VM URL, a different uid) and compare the five dashboards and the alert expressions side by side for a week; then switch the default and `uid: prometheus` to VM. `/api/v1/query` is served by VM, so no dashboard JSON edits are expected for option 1; confirm.
6. **Cutover:** repoint Alertmanager's only inputs (vmalert instead of Prometheus), scale Prometheus to 0, keep its PVC for the retention window.
7. **Rollback:** scale Prometheus back to 1 and revert the datasource URL. Prometheus's PVC and manifests stay in git until the operator deletes them; no data conversion is involved, because VM was fed by scraping in parallel. Migrating the old Prometheus history (about 5.5 days today) is possible with VM's migration tooling ([FAQ](https://docs.victoriametrics.com/victoriametrics/faq/#how-to-migrate-data-from-prometheus-to-victoriametrics)) but not worth doing.
8. **Repo guards:** this is a public repo; keep tailnet names and IPs out of the new files (the Prometheus external URL comes from a SealedSecret; do the same for any VM URL). The Argo Application is manual-sync, so the new objects need no other registration beyond `kustomization.yaml`.

**Risks.**
- **Node pinning on mini03** is unchanged by VM; this is the same single point of failure as today. A node rebuild loses VM's PVC the same way it loses Prometheus's. VM is not more highly available than Prometheus on a single replica; running both during the trial adds a second TSDB on the same 8 GiB VM (VM's own memory at this scale is `[not verified]`; its docs recommend keeping 50% of RAM free for it, which does not fit a shared 768Mi-class budget, and it caches in memory via `-memory.allowedPercent`).
- **Two new moving parts** (VM and vmalert) replace one (Prometheus), with a different retention model and different self-metrics.
- **Query semantics differ** in small ways (section 4); alert thresholds tuned on Prometheus numbers need a re-check.
- **Operational familiarity:** Prometheus v3.15.1 and Alertmanager v0.34.1 are the references used in the existing plan, runbooks and dashboards.

## 8. Recommendation

1. **Do not replace the stack with VictoriaMetrics to solve the Grafana memory problem.** It cannot: Grafana is a separate process that stays, and VM docs make no claim about Grafana.
2. **Fix Grafana first:** raise the limit (the observed 2-day RSS peak is 933 MB, so choose above 1Gi), set `GOMEMLIMIT` to about 85% of the limit, find which dashboard or query drives the peak, and re-measure. This costs a few manifest lines and is reversible.
3. **VM for Prometheus is optional and only a modest win here.** Reasons to do it: lower memory at higher scale, lower disk use, a nicer vmui for ad-hoc queries, MetricsQL, a single scraper with Prometheus config compatibility. Reasons not to: only about 300 to 376 MiB of Prometheus memory and about 0.8 GB of disk are at stake, the savings are bounded and unmeasured on this workload, there is no size-based retention cap, alerts must be partly rewritten, and the operational cost of changing a working stack goes up while the pain point (Grafana) stays.
4. **If the operator wants to try it, use the side-by-side trial in section 7 steps 1 to 5,** measure VM's real RSS and CPU at 55k series and 917 samples/s, and decide with numbers. That measurement is the one thing this note cannot supply.
5. The "replaces Grafana with a tenth of the resources" claim should not be a factor in the decision.

## 9. Sources

VictoriaMetrics (docs version v1.157.0 unless noted):
- Single-node docs / README: https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/ and https://github.com/VictoriaMetrics/VictoriaMetrics/blob/v1.157.0/docs/victoriametrics/README.md
- FAQ: https://docs.victoriametrics.com/victoriametrics/faq/
- vmalert: https://docs.victoriametrics.com/victoriametrics/vmalert/
- vmagent: https://docs.victoriametrics.com/victoriametrics/vmagent/
- Supported service discovery: https://docs.victoriametrics.com/victoriametrics/sd_configs/
- MetricsQL: https://docs.victoriametrics.com/victoriametrics/metricsql/
- Grafana integration: https://docs.victoriametrics.com/victoriametrics/integrations/grafana/
- vmui README: https://github.com/VictoriaMetrics/VictoriaMetrics/blob/v1.157.0/app/vmui/README.md
- vmauth: https://docs.victoriametrics.com/victoriametrics/vmauth/ ; vmbackup: https://docs.victoriametrics.com/victoriametrics/vmbackup/
- Flags: https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#list-of-command-line-flags
- Releases: https://github.com/VictoriaMetrics/VictoriaMetrics/releases/tag/v1.157.0
- Helm charts (victoria-metrics-single 0.52.0): https://github.com/VictoriaMetrics/helm-charts/tree/master/charts/victoria-metrics-single
- Datasource plugin: https://github.com/VictoriaMetrics/victoriametrics-datasource
- VictoriaLogs v1.54.0: https://github.com/VictoriaMetrics/VictoriaLogs/blob/v1.54.0/docs/victorialogs/README.md
- VictoriaTraces v0.13.0: https://github.com/VictoriaMetrics/VictoriaTraces/blob/v0.13.0/docs/victoriatraces/README.md
- Images: https://hub.docker.com/r/victoriametrics/victoria-metrics , https://quay.io/repository/victoriametrics/victoria-metrics

Comparison side:
- Prometheus storage: https://prometheus.io/docs/prometheus/latest/storage/
- Alertmanager: https://prometheus.io/docs/alerting/latest/alertmanager/
- Grafana configuration reference: https://github.com/grafana/grafana/blob/main/docs/sources/setup-grafana/configure-grafana/_index.md
- Go runtime (`GOMEMLIMIT`): https://pkg.go.dev/runtime

Not retrieved: the vendor's Medium benchmark articles (HTTP 403), so their methodology is unverified; no benchmark of this repo's workload was run on VM.
