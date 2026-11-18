# Plan: monitoring and alerting for the whole homelab (hand-off)

Audience: a local language model working on this repository for the operator. Follow it literally, one work
package (WP) at a time. Where it says STOP, stop and report to the operator; do not decide for him.

Written 2026-10-25. Service list: `docs/BACKLOG.md` (row "Monitoring", status Planned).
Marks: `[verified <url>]` = read in the project's official docs or release feed on 2026-10-25.
`[UNVERIFIED]` = not confirmed; the text next to it says how you confirm it. `[ASSUMED]` = interface of
another plan that you cannot read. `[repo]` = read in this repository or read-only from the live cluster.

## 0. Purpose, scope, non-goals, and the definition of done

**Purpose.** Today nothing tells the operator that something broke. Evidence from the live cluster (read-only, 2026-10-25):
the monthly `zfs-scrub` Job pod has been `Pending` for 5 h 25 min because the CronJob has no toleration for the
cordon taint of `mini02` (event: `1 node(s) were unschedulable`), and nobody noticed. This plan adds a light
metrics + alerting stack that watches the nodes, the cluster, the backups, the ZFS pool, the services the operator uses,
and itself, and sends a message to the operator's phone when something needs him.

**Scope (what this plan builds).**

1. Namespace `monitoring` with Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter (DaemonSet),
   blackbox-exporter; optional smartctl-exporter (DaemonSet).
2. Scrape jobs for: nodes, kubelet/cAdvisor, API server, CoreDNS, kube-state-metrics, ZFS pool (node-exporter),
   Velero, CloudNativePG (immich-pg), MinIO, Argo CD, cert-manager, probes of Jellyfin/Immich/Vaultwarden/AdGuard/
   cp-reserva-bot/Samba/MinIO, Tailscale proxies (through kube-state-metrics), Intel GPU (device availability),
   PVC fullness and the ZFS quotas.
3. A concrete alert rule set (section 7, WP4 and WP6) with PromQL, thresholds and severities.
4. Alert delivery to the operator's phone (decision D1) and a dead-man's switch so he notices when monitoring itself is down.
5. Grafana on the tailnet, with data source and dashboards provisioned from git.

**Non-goals.** Logs (Loki) and traces. Long-term metrics storage. Prometheus Operator and its CRDs. High availability.
Exposing Prometheus or Alertmanager on the tailnet. Changing Velero's schedules. Fixing the `zfs-scrub` toleration (reported
to the operator, section 12; it is a different file and a different PR). GPU utilisation graphs (needs a privileged
exporter; recorded as an optional follow-up).

**Definition of done** (all must be true):

- [ ] `monitoring` namespace exists with the `privileged` Pod Security label, and every monitoring pod is `Running`.
- [ ] Prometheus shows every target `UP` on `/targets` except the ones section 11 lists as expected-down.
- [ ] A deliberately created test alert (WP8, performed by the operator) arrives on the operator's phone, and its "resolved" message arrives too.
- [ ] The `Watchdog` heartbeat reaches the external dead-man's-switch service (or the operator has recorded decision D4 = "none").
- [ ] Grafana opens on the tailnet at `https://grafana.<tailnet-name>.ts.net`, logs in with the sealed admin password (anonymous visitors get read-only Viewer), shows 4 provisioned dashboards with data.
- [ ] The alert "last Velero backup older than 36 h" and "ZFS pool not ONLINE" exist and evaluate (state `inactive`, not `error`).
- [ ] `bash .github/scripts/run-all-guards.sh` prints 20 `OK` on every PR branch.
- [ ] Total added memory requests stay under 1 GiB and limits under 2 GiB (section 4 has the table).

## 1. Rules for the executor

1. You change files in the repository and open **draft** pull requests. **Nothing else.** the operator merges and syncs
   Argo CD apps in the Argo web UI.
2. Cluster access is **read-only** and always with `--context admin@<cluster>`: `get`, `describe`, `logs`, `top`.
   Forbidden: `apply`, `create`, `delete`, `patch`, `edit`, `scale`, `rollout`, `replace`, `label`, `annotate`, `drain`,
   `cordon`, `taint`, `exec` into pods, `port-forward`, any `talosctl` write command, any `argocd app sync`. Never suggest a live fix
   with `kubectl patch/apply`: every change goes through a PR and an Argo sync.
3. **No secrets in the repo, in chat, in logs or in a PR description.** Never run `get secret -o yaml/json/jsonpath`; `describe secret`
   (key names only) is allowed. Secrets are sealed by the operator (section 6, WP3). If a command prints a secret, STOP and tell the operator.
4. **No host details** in any file: no IPv4 addresses or CIDRs, MAC addresses, disk serial numbers, `/dev/disk/by-id` names, and no
   host name ending in `.ts.net`. Use `<node-ip>`, `<tailnet-name>`. Use in-cluster DNS names (`service.namespace.svc.cluster.local`)
   for every target; never an IP. The guard `check-no-host-details.sh` rejects violations.
5. One concern per PR, branch from current main: `git fetch origin && git switch -c <branch> origin/main`. Branch names are given per WP.
   Never push to `main`, never force-push, never merge, never delete a branch.
6. Before every commit run `bash .github/scripts/run-all-guards.sh`; all 20 lines must start with `OK`. Never edit a guard to make it pass.
7. After changing `talos/apps-src/*.yaml` run `talos/render-apps.sh --force` and commit `talos/apps/` too. Every Application needs a line in
   `talos/test/empty-cluster-expectations.txt`.
8. Commit messages end with the line `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; PR descriptions end with
   `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
9. Images: always `repo/name:<version>@sha256:<digest>`. Never `latest`. Resolve the digest read-only (section 3, "Resolving digests"). If you cannot, STOP and put it on the operator's list.
10. Every container sets `resources.requests` and `resources.limits` (cpu and memory). Every PVC sets `storageClassName: topolvm-fast`.
11. **STOP conditions**: a decision in section 5 is unanswered and the WP depends on it; a guard fails and the fix is not obvious; a read-only
    check in a WP gives a different result than "expected"; a command would print a secret; you need a value you do not have.
    On STOP write the report (section 11) and wait.
12. **You never decide a the operator decision (section 5).** If the operator has not answered, do the independent WPs and report the rest as `needs decision`.
13. Trust the repo and the live cluster over this document where they differ; write the difference in the report ("Differences from the plan").
14. All Argo apps here are manual-sync. Do not add `syncPolicy.automated` to the monitoring app.

## 2. Prerequisites and dependencies

| Needed | Read-only proof | If it fails |
|---|---|---|
| Cluster reachable | `kubectl --context admin@<cluster> get nodes` shows `mini01` and `mini02` `Ready` | STOP |
| StorageClass `topolvm-fast` exists | `kubectl --context admin@<cluster> get sc` lists `topolvm-fast` (no `(default)`) | STOP |
| Tailscale operator works | `kubectl --context admin@<cluster> -n tailscale get pods` shows `operator-...` `Running` | WP5 (Grafana ingress) blocked; rest continues |
| Sealed Secrets controller | `kubectl --context admin@<cluster> -n kube-system get pods` shows `sealed-secrets-...` `Running`; file `argocd/sealed-secrets/pub-cert.pem` exists | WP3 blocked |
| Velero exposes metrics | `kubectl --context admin@<cluster> -n velero get deploy velero -o jsonpath='{.spec.template.metadata.annotations}'` contains `prometheus.io/scrape` `true` and port `8085` [repo, seen 2026-10-25] | Alerts on Velero would have no data: STOP WP6 part |
| CNPG pods export metrics | `kubectl --context admin@<cluster> -n homeserver get pod immich-pg-1 -o jsonpath='{.spec.containers[*].ports}'` contains `"name":"metrics"` `9187` [repo] | skip CNPG job, report |
| `kubeseal`, `jq`, `skopeo` or `crane`, `kustomize`, `curl` on the operator's/the executor's machine | `command -v kubeseal jq kustomize curl` | Ask the operator to install; digests: The operator step |
| `mini03` (planned, draft PRs 49, 52, 71) | `gh pr list --state all` | Not needed. When mini03 exists see WP10 (node-exporter DaemonSet already covers it, because it tolerates everything) |
| Authentik `[ASSUMED]` namespace `authentik`, public tailnet URL | only for WP9 | WP9 stays out |

**What depends on this plan.** Nothing blocks on it, but every later service (arr, paperless, torrent, actual-budget, homepage, authentik) can add a
probe or an annotation to be seen. Homepage may show Grafana/Alertmanager status `[ASSUMED]`. Authentik can become Grafana's login (WP9).
**No other plan has to wait for monitoring.**

**Existing facts the plan relies on** (all `[repo]`, 2026-10-25):

- Talos v1.14.2, Kubernetes v1.36.4 (`talos/versions.env`). Talos enforces Pod Security `baseline` cluster-wide; namespaces that need hostPath,
  hostPID or privileged pods carry `pod-security.kubernetes.io/enforce: privileged` (`talos/manifests/namespaces/namespaces.yaml`).
- No Prometheus Operator CRDs exist in the cluster (`kubectl get crd` shows none from `monitoring.coreos.com`). The plan therefore uses plain
  manifests and `kubernetes_sd` discovery, and `immich-pg` has `enablePodMonitor: false`.
- PriorityClasses `hs-critical` ("Vault and alerting. Evict last."), `hs-interactive`, `hs-batch` exist (`talos/manifests/cluster-baseline/priority-classes.yaml`).
- `mini02` is cordoned; pods that must run there carry the toleration `node.kubernetes.io/unschedulable` `Exists` `NoSchedule` (as `talos/manifests/samba-nas/deployment.yaml`).
- Velero schedules (live): `velero-homeserver-nightly` (daily 10:00 UTC), `velero-cp-reserva-bot-nightly` (03:30 UTC). The Velero `schedule` label of the
  metrics equals these names. The CNPG `ScheduledBackup` `immich-pg-daily` runs to MinIO bucket `immich-pg`, retention 14 d.
- Argo CD in this cluster has **no** `argocd-metrics` / `argocd-server-metrics` Services (only `argocd-server`, `argocd-repo-server`, `argocd-redis`, `argocd-applicationset-controller`), so Argo pods are scraped directly by container port.
- GPU: node `mini01` reports allocatable `gpu.intel.com/i915: 2`.

## 3. Facts about this service (verified-marked)

### 3.1 Components and versions (latest releases seen on 2026-10-25; re-check with the same URL when you start and pick the newest tag that is at least 14 days old, else the previous patch)

| Component | Image (registry path) | Version seen | Source |
|---|---|---|---|
| Prometheus | `quay.io/prometheus/prometheus` | v3.15.1 (published 2026-10-21; if younger than 14 days at execution, use the previous release) | [verified https://api.github.com/repos/prometheus/prometheus/releases/latest] |
| Alertmanager | `quay.io/prometheus/alertmanager` | v0.34.1 (2026-09-17) | [verified https://api.github.com/repos/prometheus/alertmanager/releases/latest] |
| node-exporter | `quay.io/prometheus/node-exporter` | v1.12.1 (2026-07-14) | [verified https://api.github.com/repos/prometheus/node_exporter/releases/latest] |
| blackbox-exporter | `quay.io/prometheus/blackbox-exporter` | v0.29.1 (2026-10-21; same 14-day rule) | [verified https://api.github.com/repos/prometheus/blackbox_exporter/releases/latest] |
| kube-state-metrics | `registry.k8s.io/kube-state-metrics/kube-state-metrics` | v2.20.0 (2026-08-18) | [verified https://api.github.com/repos/kubernetes/kube-state-metrics/releases/latest] |
| Grafana | `docker.io/grafana/grafana` (tags have no `v`: `13.2.4`) | 13.2.4 (2026-10-13) | [verified https://api.github.com/repos/grafana/grafana/releases/latest] |
| smartctl-exporter (optional, WP7) | `docker.io/prometheuscommunity/smartctl-exporter` (the name used in the README; see below) | v0.15.0 (2026-10-07) | [verified https://api.github.com/repos/prometheus-community/smartctl_exporter/releases/latest] |

**Image names.** The registry paths above follow each project's published images. The README of smartctl_exporter names the image
`prometheuscommunity/smartctl-exporter` [verified https://github.com/prometheus-community/smartctl_exporter/blob/master/README.md], so in WP7 use
`docker.io/prometheuscommunity/smartctl-exporter` unless `quay.io/prometheuscommunity/smartctl-exporter` resolves too; the other images: confirm each tag exists with the digest
command below before writing it. [UNVERIFIED registry paths for the quay.io images: confirmed only by the digest command, which fails if the name or tag is wrong; if it fails, STOP and ask the operator.]

**Resolving digests (read-only, no cluster).** Run on your machine, for each image:
`skopeo inspect --format '{{.Digest}}' docker://quay.io/prometheus/prometheus:v3.15.1` (or `crane digest quay.io/prometheus/prometheus:v3.15.1`). Expected output: one line
`sha256:` plus 64 hex characters. `talos/`'s template script only resolves ghcr.io, so none of these can use it. If neither `skopeo` nor `crane` is installed, put "digest needed" on the operator's list and STOP that WP.
Write the result as `image: quay.io/prometheus/prometheus:v3.15.1@sha256:<64 hex>`.

### 3.2 Ports, paths, flags

| Component | Port | Endpoints / key flags |
|---|---|---|
| Prometheus | 9090 | `/-/healthy`, `/-/ready`, `/targets`, `/rules`, `/alerts`; flags `--config.file`, `--storage.tsdb.path`, `--storage.tsdb.retention.time`, `--storage.tsdb.retention.size`, `--web.enable-lifecycle` (not used: config changes roll the pod via hashed ConfigMaps) |
| Alertmanager | 9093 (web), 9094 (cluster, disabled with `--cluster.listen-address=`) | `/-/healthy`, `/-/ready` |
| Grafana | 3000 | `/api/health`, `/metrics`; data `/var/lib/grafana`; provisioning `/etc/grafana/provisioning`; any setting can be overridden with `GF_<SECTION>_<KEY>` [verified https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/]; `admin_user`/`admin_password` default `admin`/`admin`, and the admin password is set only on first run [verified same URL] |
| node-exporter | 9100 | `--path.procfs`, `--path.sysfs`, `--path.rootfs` for container use, host PID namespace recommended; the `zfs` collector is enabled by default on Linux; the `textfile` collector needs `--collector.textfile.directory` [verified https://raw.githubusercontent.com/prometheus/node_exporter/master/README.md] |
| kube-state-metrics | 8080 (metrics), 8081 (self) | `/healthz`, `/metrics` |
| blackbox-exporter | 9115 | `/probe?target=..&module=..`, `/-/healthy` |
| smartctl-exporter | 9633 default; needs smartmontools >= 7.0 inside the image; example runs `privileged: true`, `user: root`; scans devices if no `--smartctl.device` is given [verified README URL above] | |
| Velero | 8085 `/metrics`, pod annotations already set [repo] | `velero_backup_last_successful_timestamp{schedule}` (unix seconds, set on success), `velero_backup_last_status{schedule}` (1 success, 0 failure), `velero_backup_failure_total{schedule}`, `velero_backup_attempt_total{schedule}`, `velero_backup_location_status_gauge{backup_location_name}`, `velero_schedule_expected_interval_seconds{schedule}` [verified https://raw.githubusercontent.com/vmware-tanzu/velero/main/pkg/metrics/metrics.go] |
| CNPG instance | 9187, port name `metrics`, HTTP unless `.spec.monitoring.tls.enabled` is true (off by default; `immich-pg` has no TLS setting); operator itself 8080 [verified https://cloudnative-pg.io/docs/1.29/monitoring]. Metrics: `cnpg_collector_up`, `cnpg_collector_last_available_backup_timestamp` and `..._last_failed_backup_timestamp` (documented as deprecated from 1.26; the live operator is 1.25.0 per `talos/apps-src/cnpg-operator.yaml`, so they exist), `cnpg_collector_pg_wal_archive_status` | |
| Argo CD | controller 8082, server 8083, repo-server 8084; metric `argocd_app_info` with labels `sync_status`, `health_status` [verified https://argo-cd.readthedocs.io/en/stable/operator-manual/metrics/] | |
| cert-manager | 9402 (Services exist in the cluster [repo]); `certmanager_certificate_expiration_timestamp_seconds`, `certmanager_certificate_ready_status` | [UNVERIFIED names: confirm after WP4 with `curl` on the target, step 4.14] |
| MinIO | 9000, `/minio/v2/metrics/cluster`; anonymous scraping needs env `MINIO_PROMETHEUS_AUTH_TYPE=public` on the server | [UNVERIFIED: the MinIO doc moved to https://docs.min.io/enterprise/aistor-object-store/operations/monitoring/metrics-and-alerts/ and was not read. Confirm path and env name there in WP6 step 6.2. The image is Chainguard `minio`, a community build; if `/minio/v2/metrics/cluster` returns 404, fall back to the blackbox probe only and report] |

### 3.3 What works on Talos (verified vs not)

- **node-exporter on Talos**: Talos has no shell, but node-exporter is a container. It needs: `hostPID: true`; hostPath mounts of `/proc`, `/sys` and `/`
  (read-only, `mountPropagation: HostToContainer` for `/`); a namespace with Pod Security `privileged` (baseline forbids hostPath and hostPID). It does not need `privileged: true` containers.
  That the Talos root filesystem can be mounted this way and that all collectors read correctly is [UNVERIFIED]: the check is "node_filesystem_size_bytes exists for the `/var` mounts of both nodes" (WP4 step 4.13). If filesystem metrics are missing with `runAsUser: 65534`, set `runAsUser: 0` (keep `allowPrivilegeEscalation: false`, drop ALL capabilities, read-only root filesystem).
- **Talos itself**: I did not find an official Talos Prometheus endpoint for apid/machined [UNVERIFIED: the Talos docs page paths I tried returned 404 or a redirect to the docs front page, https://docs.siderolabs.com/talos]. Node health is therefore covered by node-exporter + kubelet + kube-state-metrics, and Talos state is checked by the operator with `talosctl` (outside this plan). Do not invent a Talos scrape target. In WP1 repeat the search on https://docs.siderolabs.com and, if an official metrics endpoint exists, put it on the operator's list instead of building it.
- **kube-controller-manager and kube-scheduler metrics**: they run on `mini01` as static pods (`kube-controller-manager-mini01`, `kube-scheduler-mini01` [repo]). Third-party guides disagree on whether they listen on all interfaces or only on localhost, and need `bind-address` set in the Talos machine config if localhost [UNVERIFIED; no official page was read]. v1 does NOT scrape them (a Talos machine-config change is a separate, riskier decision; see open question Q3). The API server is scraped through its Service.
- **etcd**: not scraped in v1 (single control plane, same reason).
- **ZFS pool health on mini02**: node-exporter's `zfs` collector exposes pool state as `node_zfs_zpool_state{zpool,state}` on Linux (reads `/proc/spl/kstat/zfs`) [UNVERIFIED: the README says only "ZFS performance statistics" and does not name the files or metrics]. The ZFS kernel module is loaded by the Talos `siderolabs/zfs` extension (`talos/schematics/mini02.yaml`, `talos/patches/volumes-mini02.yaml` [repo]), so `/proc/spl` should exist on the host. Confirm in WP4 step 4.13 with a `curl` on the mini02 node-exporter pod looking for `node_zfs_zpool_state`. **Fallback if absent**: the scrub CronJob already fails when the pool is unhealthy and `kube_job_status_failed` alerts on it; plus the filesystem metrics for `/var/mnt/tank/...`; and report to the operator that pool state needs a textfile-collector Job (a separate PR).
- **Disk SMART on Talos**: the Talos extension list has no smartmontools extension [verified https://raw.githubusercontent.com/siderolabs/extensions/main/README.md]. Feasible alternative: a privileged smartctl-exporter pod that ships its own `smartctl` (README example is `privileged: true`, root). Works only if the disks are reachable as block devices; USB-bridged disks or some RAID controllers need a device type. Whether it works on the operator's disks is [UNVERIFIED] and is why SMART is an optional, last WP (WP7) with a STOP if `smartctl_device_smart_status` is absent.
- **Kubelet / cAdvisor**: kubelet serving certificates are self-signed (metrics-server runs with `--kubelet-insecure-tls`, `talos/apps-src/metrics-server.yaml` [repo]). Prometheus therefore scrapes kubelet and cAdvisor through the API server proxy (`/api/v1/nodes/<node>/proxy/metrics[/cadvisor]`), which needs RBAC `nodes/proxy`, not kubelet certificates.
- **Intel GPU**: the plugin exposes the device as node allocatable `gpu.intel.com/i915` [repo]. v1 alerts on that resource disappearing (kube-state-metrics label form is `gpu_intel_com_i915`; confirm in WP4 step 4.13 with the query `kube_node_status_allocatable{node="mini01"}` listing a `resource` value that contains `i915`, and write the exact value in the rule). Utilisation needs an extra privileged exporter: out of scope.
- **PVC fullness**: the kubelet metric `kubelet_volume_stats_used_bytes` is reported for PVC-backed volumes, but for local-path (hostPath) volumes it may be missing [UNVERIFIED]. Check in step 4.13 (`count(kubelet_volume_stats_capacity_bytes)` by `persistentvolumeclaim`). Fallback for every node-local PVC: the node filesystem rule on the mount that holds `/var/mnt/data/local-path` (`nodePathMap` of the local-path provisioner [repo]).
- **ZFS quotas (128 GiB `tank/immich`, 256 GiB `tank/nas`, 128 GiB `tank/backups`)**: a quota-limited dataset reports the quota as its size in `statfs`, so `node_filesystem_size_bytes{mountpoint=~"/var/mnt/tank.*"}` is the quota [UNVERIFIED but standard ZFS behaviour; confirm in step 4.13 that sizes match the quotas]. The quota alert uses these filesystem metrics.

### 3.4 Comparison of stacks (numbers: the first two are live measurements, the rest are estimates and marked)

Live (kubectl top, 2026-10-25): `mini01` 740m CPU (18%), 5077 Mi memory (45% of 11.5 GiB); `mini02` 125m CPU (3%), 1193 Mi memory (16% of 7.6 GiB).
Current top pods: kube-apiserver 812 Mi, immich-server 910 Mi, jellyfin 407 Mi, argocd controller 279 Mi, MinIO 254 Mi. About 55 pods, 2 nodes.
Estimated series: node-exporter 2 nodes x ~1 000 = 2 000; kube-state-metrics ~8 000; kubelet+cAdvisor ~15 000 after dropping heavy families; apps ~3 000: **about 30 000 active series** [estimate; WP4 step 4.13 measures it with `prometheus_tsdb_head_series`]. At a 60 s scrape interval that is about 500 samples/s.

| Option | Pieces | Memory (est.) | CRDs / operator | Fit |
|---|---|---|---|---|
| kube-prometheus-stack | operator, Prometheus, Alertmanager, Grafana + sidecars, KSM, node-exporter, ~100 default rules, ~10 CRDs | about 1.2 to 1.8 GiB total [estimate, no verified source] | yes (large CRDs, server-side apply, upgrade pain) | Too heavy for a 12 GiB node already 45% used; the rule set and CRDs are mostly unused here |
| **Prometheus + Alertmanager + Grafana (plain manifests, chosen)** | the same components without the operator | about 0.75 GiB requested, 1.5 GiB limits | none | Same PromQL everyone documents; dashboards and alert examples work as is; each piece is a small file a weak model can edit |
| VictoriaMetrics single node + vmagent + vmalert + Alertmanager + Grafana | 5 to 6 processes; scraping through `-promscrape.config` [verified https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/]; image `victoriametrics/victoria-metrics` [verified same]; latest v1.154.1 [verified https://api.github.com/repos/VictoriaMetrics/VictoriaMetrics/releases/latest] | lower than Prometheus per series (vendor claim not verified here) | none | Real saving only above ~100 000 series; at 30 000 it saves ~100 MiB and adds vmalert as one more component. The docs advise keeping ~50% spare CPU/RAM and 20% free disk [verified same URL]. Not chosen; revisit if series pass ~150 000 |
| Grafana Alloy (v1.21.2 seen [verified https://api.github.com/repos/grafana/alloy/releases/latest]) | collector only | n/a | none | Alloy does not store metrics or evaluate alerts; it would still need a backend. Not an alternative on its own |

**Recommendation: plain Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics + blackbox-exporter, in namespace `monitoring`.**

## 4. Architecture and placement

**Nodes.**

- **Prometheus and Alertmanager on `mini02`** (tolerate the cordon taint, `nodeSelector kubernetes.io/hostname: mini02`). Reasons: mini02 has 16% memory use against 45% on mini01;
  monitoring survives a `mini01` outage and can tell the operator that `mini01` is down (the node that runs almost everything); mini02 already hosts the pods that the operator cares about for backups (Velero, MinIO) so cluster-to-cluster traffic is not new. Cost: the TSDB sits on mini02's OS disk (a spinning disk, `/var/mnt/data/local-path`, 100 GiB EPHEMERAL); 500 samples/s is a negligible write load.
  If mini02 is down, Prometheus is down: the dead-man's-switch (WP8) covers that. Decision D5 lets the operator move it to mini01.
- **Grafana, kube-state-metrics, blackbox-exporter on `mini01`** (no toleration needed): Grafana is next to the Tailscale proxy pods; Grafana's own SQLite is small.
- **node-exporter (and optional smartctl-exporter) DaemonSets** on every node: tolerate `operator: Exists` so they also run on cordoned `mini02` and later on `mini03`.

**Namespace** `monitoring` with Pod Security `privileged` (node-exporter needs hostPath and hostPID). Every container still drops all capabilities and, where possible, uses a read-only root filesystem.

**Storage** (all `storageClassName: topolvm-fast`, `ReadWriteOnce`, `WaitForFirstConsumer`; the local-path provisioner does **not enforce** the size, so the Prometheus size is capped by a flag, not by the PVC):

| PVC | Size | Node | Used for |
|---|---|---|---|
| `prometheus-data` | 10Gi | mini02 | TSDB. `--storage.tsdb.retention.time=30d` and `--storage.tsdb.retention.size=7GB`. Estimate: 500 samples/s x 86 400 s x 30 d x ~1.5 byte/sample = ~2 GB [estimate]; the 7 GB cap is a safety net |
| `grafana-data` | 1Gi | mini01 | `/var/lib/grafana` SQLite (users, preferences). Dashboards and data sources come from git |
| `alertmanager-data` | 1Gi | mini02 | silences and notification log |

**Resources** (explicit on every container; there is no LimitRange in `monitoring`):

| Container | Node | requests cpu / mem | limits cpu / mem | Reasoning |
|---|---|---|---|---|
| prometheus | mini02 | 150m / 384Mi | 1000m / 768Mi | 30 000 series x ~4 KB head = ~120 MiB, plus WAL, compaction and queries; 768 Mi limit gives 2x headroom. A series explosion OOM-kills only Prometheus |
| alertmanager | mini02 | 10m / 32Mi | 100m / 64Mi | tiny |
| grafana | mini01 | 50m / 160Mi | 500m / 384Mi | typical Grafana idle 100-200 MiB [estimate] |
| kube-state-metrics | mini01 | 20m / 64Mi | 200m / 160Mi | ~70 pods, a few hundred objects |
| blackbox-exporter | mini01 | 10m / 24Mi | 100m / 64Mi | |
| node-exporter (x2, x3 later) | each | 20m / 24Mi | 200m / 64Mi | |
| smartctl-exporter (x2, optional) | each | 10m / 24Mi | 100m / 64Mi | |

Totals (requests): CPU ~330m, memory ~700 Mi. Limits: CPU ~3.0 cores, memory ~1.8 GiB. mini01 gets ~290 Mi of requests (~2.5% of 11.5 GiB), mini02 ~480 Mi (~6% of 7.6 GiB). Both stay far below pressure; the limits only matter in a fault, and the stack is `hs-critical`/`hs-interactive` so it is evicted last (priority classes exist [repo]).
Re-check in WP1 with `kubectl top nodes` and `kubectl top pods -A`; if mini01 memory is above 75% STOP and tell the operator (decision D5).

**Diagram.**

```
                 tailnet (Tailscale operator Ingress `grafana`)
                               |
        mini01                 v                       mini02 (cordoned, tolerated)
 +-----------------------------------+      +--------------------------------------+
 | grafana (SQLite PVC 1Gi)          |----->| prometheus (PVC 10Gi, 30d)           |
 | kube-state-metrics                |<-----|  scrapes: node-exporter x2,           |
 | blackbox-exporter  --probes-----> |      |  kubelet+cAdvisor (via API proxy),    |
 |   jellyfin immich vaultwarden     |      |  KSM, apiserver, coredns, velero,     |
 |   adguard cp-reserva-bot samba    |      |  cnpg, minio, argocd, cert-manager,   |
 |   minio                           |      |  blackbox, grafana, itself            |
 | node-exporter (hostPID)           |      |        | rules                        |
 | [smartctl-exporter]               |      |        v                              |
 +-----------------------------------+      | alertmanager (PVC 1Gi)                |
                                            |   | telegram (or ntfy)  | Watchdog    |
 node-exporter + [smartctl] also here       +---|---------------------|--------------+
                                                v                     v
                                       the operator's phone        external heartbeat service
                                                            (alerts if it stops hearing us)
```

**How it connects.** Everything is in-cluster HTTP over the pod network. Grafana reaches Prometheus at `http://prometheus.monitoring.svc.cluster.local:9090`.
Prometheus reaches Alertmanager at `alertmanager.monitoring.svc.cluster.local:9093`. Only Grafana is exposed (tailnet Ingress, `tls.hosts: [grafana]`). Prometheus and Alertmanager UIs are used by the operator through `kubectl port-forward` in his own terminal (read-only) or not at all.

### 4.x Current placement: everything on mini03 (supersedes the mini01/mini02 text above)

Decided by the operator on 2026-11-18: Prometheus, Alertmanager, Grafana, kube-state-metrics and the two tailnet proxy
pods (`ts-grafana-*`, `ts-prometheus-*`) run on `mini03`. metrics-server and the node-exporter DaemonSet are unchanged.
mini03 is tainted `node-role.homeserver/tier=mobile:NoSchedule`, so each Deployment selects
`kubernetes.io/hostname: mini03` and tolerates that taint (same style as `talos/manifests/backup-replica/minio.yaml`).
The proxies are pinned by the ProxyClass `observability` (`talos/manifests/tailscale-proxyclasses/observability.yaml`),
set with the label `tailscale.com/proxy-class: observability` on the two Ingresses.

**Fresh start, no data migration.** The three claims were renamed (`prometheus-data-mini03`, `grafana-data-mini03`,
`alertmanager-data-mini03`) so the new Pods get new volumes on mini03 (local-path, `/var/mnt/data/local-path`, the
provisioner's default for every node not listed). The old claims are no longer in git. The monitoring app does not
prune (no `automated` block, and Prune is an opt-in checkbox of a manual sync), so the old claims and their `Retain`
volumes on mini01 stay as orphans. Prometheus history, Alertmanager silences and Grafana's database (users, preferences,
UI-created dashboards) are not carried over. The one UI-created dashboard that mattered, `adclgtz` ("Cluster Overview",
shown by the mini04 kiosk), is provisioned from git (`dashboards/cluster-overview.json`).

Provisioned dashboards cannot be saved from the UI (`allowUiUpdates: false`, `disableDeletion: true`): to change one,
edit its JSON in git. All provisioned dashboards land in the General folder (`foldersFromFilesStructure: false`).

**Orphan cleanup** (run by the operator after the new stack is verified and the old data is no longer wanted; every
step is destructive and irreversible, `Retain` PVs keep the data on mini01 until the PV object is deleted AND its
directory under `/var/mnt/data/local-path` on mini01 is removed):

```
kubectl -n monitoring delete pvc prometheus-data grafana-data alertmanager-data
kubectl delete pv pvc-881668f9-5c70-4f51-b837-fefc778e7003 \
                  pvc-01c6c478-3d75-4940-a4f3-a84917cc3676 \
                  pvc-02d23d1f-8abb-4589-ac8c-69ad83508574 \
                  pvc-2358a25e-9e71-4f64-88de-2d4d5272bd45   # stale Released grafana-data from an earlier sync
```

Deleting a `Retain` PV does not delete the directory; remove the four `pvc-*_monitoring_*` directories on mini01 by hand.

## 5. Decisions for the operator

The executor STOPs at any WP that depends on an unanswered decision.

| Id | Question | Options and trade-offs | Recommended default | If decided otherwise |
|---|---|---|---|---|
| D1 | Where do alerts go? | **Telegram**: Alertmanager has a native receiver with `bot_token_file`; needs a free Telegram account and a bot made with @BotFather; phone push works; credentials: bot token (secret) and chat id (not secret). **ntfy.sh (public server)**: no account; anyone who learns the topic name can read and post, so the topic must be a long random string, and the topic URL is the secret; Alertmanager has no native ntfy receiver, so use a `webhook_config` with `?template=alertmanager`, supported by ntfy [verified https://docs.ntfy.sh/publish/]; messages pass through a third party. **ntfy self-hosted**: one more pod (~30 MiB), must be reachable from the phone (tailnet only: the phone needs the Tailscale app and no iOS-background-push guarantee, because iOS push relays through ntfy.sh anyway); access tokens/auth are [UNVERIFIED, the docs section was not read]. **Email (SMTP)**: Alertmanager native; needs an SMTP account (a Gmail app password = a long-lived secret), slow, easy to ignore. **Pushover**: native (`user_key_file`, `token_file`) [verified https://prometheus.io/docs/alerting/latest/configuration/], one-time paid app, very reliable | **Telegram** (native, no extra pod, secrets by file) | ntfy: replace the receiver block in WP4 step 4.9 with the ntfy webhook block given there; email/Pushover: ask the operator for the exact SMTP/Pushover fields. Only the receiver block and the Secret keys change |
| D2 | Retention | 30 days (default), 15 days, 90 days | 30 days, 7 GB cap | change `--storage.tsdb.retention.time` and PVC; 90 d needs ~3x disk (still fine at ~6 GB) |
| D3 | Grafana login | local admin password only (default), or also Authentik OIDC later (WP9) | local admin password now; OIDC later | WP9 |
| D4 | Dead-man's switch service | **healthchecks.io** (free tier; ping URL is the secret; they notify the operator if pings stop); **Better Stack / UptimeRobot heartbeat**; **none** (monitoring may be silently dead) | healthchecks.io, with its own notification to the same phone | `none`: delete the `deadman` receiver and route in 4.9, keep `Watchdog` rule, record the risk in section 12 |
| D5 | Where Prometheus runs | mini02 (default; survives mini01 loss, HDD, cordoned), mini01 (SSD? unknown, but dies with mini01), mini03 later (VM on victus, 8 GiB, depends on victus being up) | mini02 | change `nodeSelector` and remove the toleration in the Prometheus/Alertmanager Deployments |
| D6 | Scrape interval | 60 s (default), 30 s (smoother graphs, 2x data) | 60 s | edit `global.scrape_interval` |
| D7 | Back up the Grafana database with Velero? | no (default: nothing irreplaceable), or add namespace `monitoring` to the Velero schedule (a separate PR on `talos/values/velero.yaml`) | no | add `includedNamespaces` and the opt-in annotation `backup.velero.io/backup-volumes: data` to the Grafana pod; restore test in section 8 |
| D8 | Probe mini01 services from a cluster-internal blackbox only (default) or also a probe through the tailnet name | internal only; tailnet name would need the full `.ts.net` name (guard) and the Tailscale device as a prober | internal only | would need a sealed value; not planned |
| D9 | Alert noise policy | `warning` messages 1 per 12 h, `critical` per 4 h (default), or immediate repeats | default | edit `repeat_interval` in 4.9 |

Decided (PR #128): **D1 = a Discord channel webhook** (one channel, no separate critical channel; Alertmanager `discord_configs` with `webhook_url_file`). **D4 = the `Watchdog` alert (always firing) routed to a healthchecks.io ping URL** (`webhook_configs` with `url_file`); healthchecks.io itself notifies Discord when the pings stop. Both URLs live in the sealed Secret `monitoring/alertmanager-notifiers` (keys `discord-webhook-url`, `healthchecks-ping-url`), replacing the Telegram `alertmanager-secrets` / `deadman-url` names used in sections 6 and 4.9 below.

## 6. Credentials and secret handling

Inventory (every credential this service has or needs):

| # | Credential | Who creates it, how | Secret (ns/name) and key | Sealed file | How the app receives it | First-login / discovery | The operator retrieves later (clipboard only) | If lost | Rotate / reset |
|---|---|---|---|---|---|---|---|---|---|
| C1 | Grafana admin password | The operator: `openssl rand -base64 24 \| pbcopy`, save in Vaultwarden BEFORE sealing | `monitoring/grafana-secrets` key `GF_SECURITY_ADMIN_PASSWORD` | `talos/sealed-secrets/grafana-secrets.yaml` | env var `GF_SECURITY_ADMIN_PASSWORD` via `secretKeyRef` (Grafana maps `GF_<SECTION>_<KEY>` [verified Grafana config doc above]); the user name is the fixed env `GF_SECURITY_ADMIN_USER=admin` in the Deployment | User `admin`, password = the value the operator saved. The password is applied only when the Grafana database is created (first start) [verified]. UI: `https://grafana.<tailnet-name>.ts.net/login` | `kubectl --context admin@<cluster> -n monitoring get secret grafana-secrets -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' \| base64 -d \| pbcopy` | see "Lost admin password" below | see below |
| C2 | Grafana external URL (contains the full tailnet name; not a secret but a host detail the guard rejects) | The operator types it at sealing time: `https://grafana.<tailnet-name>.ts.net` | `monitoring/grafana-secrets` key `GF_SERVER_ROOT_URL` | same file | env var `GF_SERVER_ROOT_URL` (`[server] root_url`; needed for correct links and OIDC callbacks [verified same doc]) | n/a | same command with `.data.GF_SERVER_ROOT_URL` | Grafana still works but builds wrong absolute links; re-seal | re-seal the file and sync |
| C3 | Telegram bot token (if D1 = Telegram) | The operator: Telegram, chat with @BotFather, `/newbot`; copy the token | `monitoring/alertmanager-secrets` key `telegram-bot-token` | `talos/sealed-secrets/alertmanager-secrets.yaml` | mounted as file `/etc/alertmanager/secrets/telegram-bot-token`, config field `bot_token_file` [verified Alertmanager config doc] | n/a | `... get secret alertmanager-secrets -o jsonpath='{.data.telegram-bot-token}' \| base64 -d \| pbcopy` | no alerts reach the phone; Alertmanager logs `Notify attempt failed` | in BotFather `/revoke`, seal the new token, sync |
| C4 | Telegram chat id | The operator: message the bot once, then WP3 step 3.2 shows how to read it (it is an integer, not a secret) | not a secret: written in `alertmanager.yml` as `chat_id` by the operator at WP4 | n/a | config field `chat_id` | n/a | n/a | n/a | edit the PR |
| C5 | Dead-man's-switch ping URL (D4) | The operator: create a check at the heartbeat service, copy the ping URL | `monitoring/alertmanager-secrets` key `deadman-url` | same sealed file | file `/etc/alertmanager/secrets/deadman-url`, config `webhook_config.url_file` [verified same doc] | n/a | `... jsonpath='{.data.deadman-url}'` | no heartbeat: the service will page the operator falsely; he knows why | create a new check, re-seal |
| C6 | ntfy topic URL / token (only if D1 = ntfy) | The operator: `openssl rand -hex 16 \| pbcopy` to make a topic; for self-hosted a token created by the operator | same Secret, key `ntfy-url` (full URL incl. topic, `?template=alertmanager`) | same file | `url_file` | n/a | as above | alerts stop | new topic, re-seal, change phone subscription |
| C7 | Prometheus/Alertmanager/KSM/blackbox | no credentials: in-cluster, no auth, not exposed | n/a | n/a | n/a | n/a | n/a | n/a | n/a |
| C8 | Prometheus ServiceAccount token | automatic (Kubernetes) | n/a | n/a | projected token, RBAC read-only | n/a | n/a | n/a | n/a |
| C9 | MinIO metrics access (WP6) | no new credential: `MINIO_PROMETHEUS_AUTH_TYPE=public` is a setting, not a secret; limited to the in-cluster Service | n/a | n/a | env in `backup-target` | n/a | n/a | n/a | n/a |
| C10 | Authentik OIDC client id/secret (WP9 only) | created in the Authentik UI by the operator | `monitoring/grafana-oidc` keys `GF_AUTH_GENERIC_OAUTH_CLIENT_ID`, `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET`, and the full Authentik URLs | `talos/sealed-secrets/grafana-oidc.yaml` | env vars | n/a | same pattern | OIDC login breaks; the local admin still works | rotate in Authentik, re-seal |

**Sealing rule for a Secret outside `homeserver`.** `docs/templates/ghcr-app/seal-secret.sh` writes namespace `homeserver` only, so WP3 uses a `jq` + `kubeseal`
recipe (same as the helper, namespace changed). A sealed Secret can only be decrypted in its own namespace and with its own name: the names above are exact.

**"Lost admin password" recovery (Grafana).** The sealed password only matters when the database is created. If the operator changed it in the UI or the Secret and the login no longer works:

1. The operator runs, in his own terminal (this is the only `exec` in the plan and it is his, not the executor's):
   `kubectl --context admin@<cluster> -n monitoring exec -it deploy/grafana -- grafana cli admin reset-admin-password --password-from-stdin`
   then types the new password and presses Enter and Ctrl-D. If the flag is unknown, run
   `... -- grafana cli admin reset-admin-password --help` and use the form it shows (the older form takes the password as the last argument; that puts it on the command line, so prefer stdin). `[UNVERIFIED flag; confirm with --help]`. If `grafana` is not on the PATH, try `grafana-cli`.
2. Save the new password in Vaultwarden and update the sealed Secret in a PR so git and the live state agree (the sealed value is then only used if the PVC is ever recreated).
3. If even `exec` is impossible (pod not running): delete nothing; ask the operator. Last resort (his decision): delete the PVC `grafana-data` through a PR that removes it, then sync; Grafana recreates the database and applies the sealed password. Dashboards come back from git. Only users and preferences are lost.

**"Lost secret" for the notification path**: Alertmanager keeps running; messages fail. The operator notices because the dead-man's switch (C5) still pings from the `Watchdog` route.

## 7. Work packages

Order: WP1 audit; WP2 namespace; WP3 secrets (the operator); WP4 core stack and alerts; WP5 Grafana; WP6 probes, MinIO, remaining alerts; WP7 SMART (optional); WP8 test alerts and dead-man's switch check; WP9 OIDC (optional, later); WP10 when mini03 exists.
Standard PR text ending: the description ends with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

### WP1. Read-only audit (no PR; report only)

Goal: confirm the facts of sections 2 to 4 still hold. Branch: none.

1. `kubectl --context admin@<cluster> top nodes` and `kubectl --context admin@<cluster> top pods -A --sort-by=memory`. Expected (2026-10-25): mini01 about 740m / 5077Mi, mini02 about 125m / 1193Mi. If mini01 memory% is above 75 or mini02 above 70: STOP.
2. `kubectl --context admin@<cluster> get ns monitoring` -> expected `NotFound`. If it exists, STOP and ask.
3. `kubectl --context admin@<cluster> get crd | grep -c monitoring.coreos.com` -> expected `0`. If not 0, STOP (an operator exists; the plan changes).
4. `kubectl --context admin@<cluster> get sc` -> `topolvm-fast`, no `(default)`.
5. `kubectl --context admin@<cluster> -n argocd get svc` -> no `argocd-metrics`; `kubectl --context admin@<cluster> -n argocd get pods --show-labels` -> pods named `argocd-application-controller-0`, `argocd-server-...`, `argocd-repo-server-...` with label `app.kubernetes.io/name=<same name>`. If labels differ, adapt the three Argo scrape rules in 4.8 and report.
6. `kubectl --context admin@<cluster> -n velero get schedules` -> `velero-homeserver-nightly`, `velero-cp-reserva-bot-nightly`. Write the real names into the report; rules in 4.10 use them.
7. `kubectl --context admin@<cluster> -n homeserver get scheduledbackup,cluster` -> `immich-pg-daily`, cluster `immich-pg`.
8. `kubectl --context admin@<cluster> get pods -A | grep -v -E 'Running|Completed'` -> record anything abnormal. Expected one line: `zfs-scrub-<id>` `Pending` in `kube-system`. Report it as a finding: the CronJob in `talos/storage/zfs-scrub/zfs-scrub-cronjob.yaml` lacks the toleration `node.kubernetes.io/unschedulable`, so its pod can never start on cordoned mini02. **Do not fix it in this plan**; tell the operator (the monitoring alert `ZfsScrubNotRun`/`PodStuckPending` will keep firing until he does).
9. `kubectl --context admin@<cluster> describe node mini01 | grep -i gpu` -> `gpu.intel.com/i915`.
10. `kubectl --context admin@<cluster> get ingress -A` -> note that existing ingresses use `tls.hosts` with a short name; read `talos/manifests/jellyfin/ingress.yaml`.
11. Read `talos/render-apps.sh`, `talos/apps-src/zfs-scrub.yaml`, `talos/apps-src/cnpg-operator.yaml`, `talos/sealed-secrets/kustomization.yaml`, `talos/manifests/namespaces/namespaces.yaml`, `.github/scripts/check-no-host-details.sh`.
12. Check whether an official Talos metrics endpoint exists (section 3.3) at https://docs.siderolabs.com/talos; record the answer with the URL.
13. Report in the section 11 format. STOP point: wait for the operator's answers to D1, D4 and D5 before WP3 and WP4.

### WP2. Namespace `monitoring`

Goal: the namespace exists with the right Pod Security label. Branch `feat/monitoring-namespace`. Preconditions: WP1 done.

1. Edit `talos/manifests/namespaces/namespaces.yaml`: append exactly this document (keep `---` separators as in the file):
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  labels:
    pod-security.kubernetes.io/enforce: privileged # node-exporter needs hostPath + hostPID; smartctl-exporter needs a privileged container
```
   Why: Talos enforces `baseline` otherwise and node-exporter pods would be rejected.
2. `bash .github/scripts/run-all-guards.sh` -> 20 `OK`.
3. Commit `feat: add namespace monitoring`, push, open a **draft** PR titled `feat: namespace monitoring (privileged for node-exporter)`.
   Description: what, why, "no workloads yet", "After merge the operator syncs the Argo app `namespaces` in the UI; then `kubectl --context admin@<cluster> get ns monitoring --show-labels` shows `pod-security.kubernetes.io/enforce=privileged`." + the Claude Code line.
4. Rollback: revert the PR (empty namespace; safe).
5. STOP: wait for merge and sync (the operator).

### WP3. Sealed secrets (The operator does the sealing; executor prepares)

Goal: `grafana-secrets` and `alertmanager-secrets` sealed in git. Branch `feat/monitoring-sealed-secrets`. Preconditions: WP2 synced (the namespace must exist before the auto-sync app delivers the SealedSecrets; `kubectl --context admin@<cluster> get ns monitoring` works), D1 and D4 answered.

The executor cannot do this: it needs the operator's values. The executor's job is to hand the operator the copy-paste list and, after the operator commits the two files, to edit `talos/sealed-secrets/kustomization.yaml`.

**Copy-paste list for the operator** (run in the repo root of his machine; values never echo):

```bash
# 3.1 Grafana: password + external URL
openssl rand -base64 24 | pbcopy        # paste it into Vaultwarden NOW, then continue
read -rsp 'Grafana admin password (paste, hidden): ' GP; echo
read -rp  'Grafana external URL, e.g. https://grafana.<tailnet-name>.ts.net : ' GU
export GP GU
jq -n '{apiVersion:"v1",kind:"Secret",metadata:{name:"grafana-secrets",namespace:"monitoring"},type:"Opaque",
  data:{GF_SECURITY_ADMIN_PASSWORD:(env.GP|@base64),GF_SERVER_ROOT_URL:(env.GU|@base64)}}' \
 | KUBECONFIG=/dev/null kubeseal --cert argocd/sealed-secrets/pub-cert.pem --format yaml \
 > talos/sealed-secrets/grafana-secrets.yaml
unset GP GU
grep -c 'kind: SealedSecret' talos/sealed-secrets/grafana-secrets.yaml   # expect 1
```
```bash
# 3.2 Telegram (D1 = Telegram). Create the bot in Telegram with @BotFather (/newbot), send the new bot any message first.
read -rsp 'Telegram bot token (hidden): ' TT; echo
# chat id (an integer, not a secret): read it from the bot's updates; the token is only in a shell variable
curl -s "https://api.telegram.org/bot${TT}/getUpdates" | jq '.result[].message.chat.id' | sort -u   # note the number for WP4 step 4.9
# 3.3 Dead-man's switch (D4): create a check at the service, copy its ping URL
read -rsp 'Dead-man ping URL (hidden; press Enter for none): ' DU; echo
export TT DU
jq -n '{apiVersion:"v1",kind:"Secret",metadata:{name:"alertmanager-secrets",namespace:"monitoring"},type:"Opaque",
  data:({"telegram-bot-token":(env.TT|@base64)} + (if (env.DU|length)>0 then {"deadman-url":(env.DU|@base64)} else {} end))}' \
 | KUBECONFIG=/dev/null kubeseal --cert argocd/sealed-secrets/pub-cert.pem --format yaml \
 > talos/sealed-secrets/alertmanager-secrets.yaml
unset TT DU
```
For D1 = ntfy replace the Telegram key by `ntfy-url` (the whole topic URL ending `?template=alertmanager`). If D4 = none the file has only the bot key and WP4 must omit the deadman receiver.

Executor steps after the operator commits (or tells the executor the files exist on his branch):

1. Edit `talos/sealed-secrets/kustomization.yaml`: add under `resources:` the lines `  - grafana-secrets.yaml` and `  - alertmanager-secrets.yaml`, and add two comment lines in the header table in the same style (`grafana-secrets.yaml  monitoring/grafana-secrets  GF_SECURITY_ADMIN_PASSWORD, GF_SERVER_ROOT_URL` and `alertmanager-secrets.yaml  monitoring/alertmanager-secrets  telegram-bot-token, deadman-url`).
2. Guards -> 20 `OK`. In particular check that the two files contain only `kind: SealedSecret` (the repo guard enforces it).
3. Draft PR `feat: sealed secrets for monitoring`. Description lists the keys (names only), and: "After merge the auto-sync app `talos-sealed-secrets` delivers them; the operator checks `kubectl --context admin@<cluster> -n monitoring describe secret grafana-secrets alertmanager-secrets` shows the key names (no values)."
4. Rollback: revert; Secrets in prune-OFF app stay in the cluster (harmless).
5. STOP.

### WP4. Core stack: Prometheus, Alertmanager, kube-state-metrics, node-exporter, rules

Goal: metrics flowing, core alerts evaluating, notifications configured. Branch `feat/monitoring-core`. Preconditions: WP2 and WP3 synced; digests resolved (section 3.1) for prometheus, alertmanager, node-exporter, kube-state-metrics; D1, D4, D5 answered; chat id from WP3 known.

Files created (all under `talos/manifests/monitoring/` unless noted):
`kustomization.yaml`, `rbac.yaml`, `prometheus.yaml`, `prometheus.yml` (config), `rules-core.yml`, `alertmanager.yaml`, `alertmanager.yml`, `kube-state-metrics.yaml`, `node-exporter.yaml`; and `talos/apps-src/monitoring.yaml` (+ generated `talos/apps/monitoring.yaml`) and a line in `talos/test/empty-cluster-expectations.txt`.

**4.1 `kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: monitoring
resources:
  - rbac.yaml
  - prometheus.yaml
  - alertmanager.yaml
  - kube-state-metrics.yaml
  - node-exporter.yaml
configMapGenerator:
  # a content hash is appended to each name, so a config change rolls the pods (no reload sidecar needed)
  - name: prometheus-config
    files: [prometheus.yml]
  - name: prometheus-rules
    files: [rules-core.yml]
  - name: alertmanager-config
    files: [alertmanager.yml]
```
Why: the Deployment references `prometheus-config` etc.; kustomize rewrites the references to the hashed names. Verify in 4.12.

**4.2 `rbac.yaml`**
```yaml
apiVersion: v1
kind: ServiceAccount
metadata: {name: prometheus, namespace: monitoring}
automountServiceAccountToken: true
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: kube-state-metrics, namespace: monitoring}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: prometheus-monitoring}
rules:
  - apiGroups: [""]
    resources: [nodes, nodes/metrics, nodes/proxy, services, endpoints, pods]
    verbs: [get, list, watch]
  - nonResourceURLs: [/metrics, /metrics/cadvisor]
    verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: prometheus-monitoring}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: prometheus-monitoring}
subjects:
  - {kind: ServiceAccount, name: prometheus, namespace: monitoring}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: kube-state-metrics-monitoring}
rules:
  - apiGroups: [""]
    resources: [nodes, pods, persistentvolumeclaims, persistentvolumes]
    verbs: [list, watch]
  - apiGroups: [apps]
    resources: [deployments, statefulsets, daemonsets]
    verbs: [list, watch]
  - apiGroups: [batch]
    resources: [jobs, cronjobs]
    verbs: [list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: kube-state-metrics-monitoring}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: kube-state-metrics-monitoring}
subjects:
  - {kind: ServiceAccount, name: kube-state-metrics, namespace: monitoring}
```
Least privilege: read-only, no secrets, no write verbs.

**4.3 `prometheus.yaml`** (Service, PVC, Deployment)
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: prometheus-data, namespace: monitoring}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: topolvm-fast
  resources: {requests: {storage: 10Gi}}
---
apiVersion: v1
kind: Service
metadata: {name: prometheus, namespace: monitoring, labels: {app.kubernetes.io/name: prometheus}}
spec:
  selector: {app.kubernetes.io/name: prometheus}
  ports: [{name: http, port: 9090, targetPort: http}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: prometheus, namespace: monitoring, labels: {app.kubernetes.io/name: prometheus}}
spec:
  replicas: 1
  strategy: {type: Recreate}          # RWO volume: never two pods at once
  selector: {matchLabels: {app.kubernetes.io/name: prometheus}}
  template:
    metadata: {labels: {app.kubernetes.io/name: prometheus}}
    spec:
      serviceAccountName: prometheus
      priorityClassName: hs-critical
      nodeSelector: {kubernetes.io/hostname: mini02}          # D5
      tolerations:
        - {key: node.kubernetes.io/unschedulable, operator: Exists, effect: NoSchedule}
      securityContext: {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, fsGroup: 65534, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: prometheus
          image: quay.io/prometheus/prometheus:v3.15.1@sha256:<DIGEST-resolved-in-3.1>
          args:
            - --config.file=/etc/prometheus/prometheus.yml
            - --storage.tsdb.path=/prometheus
            - --storage.tsdb.retention.time=30d       # D2
            - --storage.tsdb.retention.size=7GB
            - --web.listen-address=:9090
          ports: [{name: http, containerPort: 9090}]
          readinessProbe: {httpGet: {path: /-/ready, port: http}, periodSeconds: 10}
          livenessProbe: {httpGet: {path: /-/healthy, port: http}, initialDelaySeconds: 30, periodSeconds: 20}
          startupProbe: {httpGet: {path: /-/ready, port: http}, periodSeconds: 10, failureThreshold: 60}   # WAL replay can take minutes
          resources: {requests: {cpu: 150m, memory: 384Mi}, limits: {cpu: "1", memory: 768Mi}}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          volumeMounts:
            - {name: config, mountPath: /etc/prometheus/prometheus.yml, subPath: prometheus.yml}
            - {name: rules, mountPath: /etc/prometheus/rules}
            - {name: data, mountPath: /prometheus}
      volumes:
        - {name: config, configMap: {name: prometheus-config}}
        - {name: rules, configMap: {name: prometheus-rules}}
        - {name: data, persistentVolumeClaim: {claimName: prometheus-data}}
```
Notes: `subPath` ConfigMap mounts do not update live, which is why the hashed names roll the pod. The `Recreate` strategy is required because the PVC is RWO and node-local.

**4.4 `prometheus.yml`** (the whole scrape config; interval per D6)
```yaml
global:
  scrape_interval: 60s
  scrape_timeout: 15s
  evaluation_interval: 60s
alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager.monitoring.svc.cluster.local:9093"]
rule_files:
  - /etc/prometheus/rules/*.yml
scrape_configs:
  - job_name: prometheus
    static_configs: [{targets: ["localhost:9090"]}]
  - job_name: alertmanager
    static_configs: [{targets: ["alertmanager.monitoring.svc.cluster.local:9093"]}]
  - job_name: grafana
    static_configs: [{targets: ["grafana.monitoring.svc.cluster.local:3000"]}]   # down until WP5: expected
  - job_name: kube-state-metrics
    honor_labels: true
    static_configs: [{targets: ["kube-state-metrics.monitoring.svc.cluster.local:8080"]}]
  - job_name: node
    kubernetes_sd_configs: [{role: pod, namespaces: {names: [monitoring]}}]
    relabel_configs:
      - {source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name], regex: node-exporter, action: keep}
      - {source_labels: [__meta_kubernetes_pod_node_name], target_label: instance}
      - {source_labels: [__meta_kubernetes_pod_node_name], target_label: node}
  - job_name: apiserver
    scheme: https
    tls_config: {ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt}
    authorization: {credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token}
    kubernetes_sd_configs: [{role: endpoints, namespaces: {names: [default]}}]
    relabel_configs:
      - {source_labels: [__meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name], regex: kubernetes;https, action: keep}
    metric_relabel_configs:
      - {source_labels: [__name__], regex: "apiserver_request_duration_seconds_bucket|apiserver_request_slo_duration_seconds_bucket|apiserver_response_sizes_bucket|etcd_request_duration_seconds_bucket", action: drop}
  - job_name: kubelet
    scheme: https
    tls_config: {ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt}
    authorization: {credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token}
    kubernetes_sd_configs: [{role: node}]
    relabel_configs:
      - {target_label: __address__, replacement: kubernetes.default.svc.cluster.local:443}
      - {source_labels: [__meta_kubernetes_node_name], regex: (.+), target_label: __metrics_path__, replacement: /api/v1/nodes/$1/proxy/metrics}
      - {source_labels: [__meta_kubernetes_node_name], target_label: node}
  - job_name: cadvisor
    scheme: https
    tls_config: {ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt}
    authorization: {credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token}
    kubernetes_sd_configs: [{role: node}]
    relabel_configs:
      - {target_label: __address__, replacement: kubernetes.default.svc.cluster.local:443}
      - {source_labels: [__meta_kubernetes_node_name], regex: (.+), target_label: __metrics_path__, replacement: /api/v1/nodes/$1/proxy/metrics/cadvisor}
      - {source_labels: [__meta_kubernetes_node_name], target_label: node}
    metric_relabel_configs:   # keep the series count near 15 000
      - {source_labels: [__name__], regex: "container_(tasks_state|network_tcp_usage_total|network_udp_usage_total|memory_failures_total|blkio_device_usage_total|fs_(reads|writes)_bytes_total|cpu_load_average_10s|file_descriptors|sockets|threads_max|threads|spec_.*|ulimits_soft)|container_(start_time_seconds|last_seen)", action: drop}
      - {source_labels: [container], regex: "", action: drop}      # drop pod-level cgroup duplicates
  - job_name: coredns
    static_configs: [{targets: ["kube-dns.kube-system.svc.cluster.local:9153"]}]
  - job_name: annotated-pods            # Velero (annotations prometheus.io/scrape, /port, /path are already set)
    kubernetes_sd_configs: [{role: pod}]
    relabel_configs:
      - {source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape], regex: "true", action: keep}
      - {source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path], regex: (.+), target_label: __metrics_path__}
      - {source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port], regex: ([^:]+)(?::\d+)?;(\d+), replacement: $1:$2, target_label: __address__}
      - {source_labels: [__meta_kubernetes_namespace], target_label: namespace}
      - {source_labels: [__meta_kubernetes_pod_name], target_label: pod}
      - {source_labels: [__meta_kubernetes_namespace], regex: monitoring, action: drop}
  - job_name: argocd                    # no metrics Services exist: select pods by container port (WP1 step 5)
    kubernetes_sd_configs: [{role: pod, namespaces: {names: [argocd]}}]
    relabel_configs:
      - {source_labels: [__meta_kubernetes_pod_container_port_number], regex: "8082|8083|8084", action: keep}
      - {source_labels: [__meta_kubernetes_pod_name], target_label: pod}
  - job_name: cnpg-instances            # immich-pg: port name `metrics` (9187), plain HTTP
    kubernetes_sd_configs: [{role: pod}]
    relabel_configs:
      - {source_labels: [__meta_kubernetes_pod_label_cnpg_io_podRole], regex: instance, action: keep}
      - {source_labels: [__meta_kubernetes_pod_container_port_name], regex: metrics, action: keep}
      - {source_labels: [__meta_kubernetes_namespace], target_label: namespace}
      - {source_labels: [__meta_kubernetes_pod_label_cnpg_io_cluster], target_label: cluster}
  - job_name: cnpg-operator
    kubernetes_sd_configs: [{role: pod, namespaces: {names: [cnpg-system]}}]
    relabel_configs:
      - {source_labels: [__meta_kubernetes_pod_container_port_number], regex: "8080", action: keep}
  - job_name: cert-manager
    kubernetes_sd_configs: [{role: pod, namespaces: {names: [cert-manager]}}]
    relabel_configs:
      - {source_labels: [__meta_kubernetes_pod_container_port_number], regex: "9402", action: keep}
```
(Probes, MinIO and the optional jobs are added in WP6/WP7.) `[UNVERIFIED]` pieces to confirm in 4.13: that the pod label `cnpg.io/podRole=instance` yields `__meta_kubernetes_pod_label_cnpg_io_podRole` (Prometheus sanitises the label name; the live pod has the label `cnpg.io/podRole: instance` [repo]) and that the `argocd` pods expose those container ports in their spec (if the ports are not declared in the pod spec, `container_port_number` is empty and the target is missing: then use `role: endpoints` is not possible; STOP and report, do not add Services in this PR).

**4.5 `kube-state-metrics.yaml`**
```yaml
apiVersion: v1
kind: Service
metadata: {name: kube-state-metrics, namespace: monitoring, labels: {app.kubernetes.io/name: kube-state-metrics}}
spec:
  selector: {app.kubernetes.io/name: kube-state-metrics}
  ports: [{name: http, port: 8080, targetPort: http}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: kube-state-metrics, namespace: monitoring, labels: {app.kubernetes.io/name: kube-state-metrics}}
spec:
  replicas: 1
  selector: {matchLabels: {app.kubernetes.io/name: kube-state-metrics}}
  template:
    metadata: {labels: {app.kubernetes.io/name: kube-state-metrics}}
    spec:
      serviceAccountName: kube-state-metrics
      priorityClassName: hs-interactive
      nodeSelector: {kubernetes.io/hostname: mini01}
      securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: kube-state-metrics
          image: registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0@sha256:<DIGEST>
          args:
            - --port=8080
            - --resources=nodes,pods,deployments,statefulsets,daemonsets,jobs,cronjobs,persistentvolumeclaims,persistentvolumes
          ports: [{name: http, containerPort: 8080}]
          readinessProbe: {httpGet: {path: /healthz, port: http}, periodSeconds: 10}
          livenessProbe: {httpGet: {path: /healthz, port: http}, initialDelaySeconds: 10, periodSeconds: 20}
          resources: {requests: {cpu: 20m, memory: 64Mi}, limits: {cpu: 200m, memory: 160Mi}}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
```
The `--resources` list matches the ClusterRole in 4.2 exactly; a resource without RBAC makes KSM log errors.

**4.6 `node-exporter.yaml`**
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: node-exporter, namespace: monitoring, labels: {app.kubernetes.io/name: node-exporter}}
spec:
  selector: {matchLabels: {app.kubernetes.io/name: node-exporter}}
  updateStrategy: {type: RollingUpdate, rollingUpdate: {maxUnavailable: 1}}
  template:
    metadata: {labels: {app.kubernetes.io/name: node-exporter}}
    spec:
      hostPID: true
      priorityClassName: hs-critical
      tolerations: [{operator: Exists}]          # run on cordoned mini02 and on mini03 later
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: node-exporter
          image: quay.io/prometheus/node-exporter:v1.12.1@sha256:<DIGEST>
          args:
            - --path.procfs=/host/proc
            - --path.sysfs=/host/sys
            - --path.rootfs=/host/root
            - --web.listen-address=:9100
            - --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run|var/lib/kubelet/pods|var/lib/containerd|var/run|etc/cni|etc/kubernetes|usr/libexec)($|/)
            - --collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs|tmpfs)$
            - --no-collector.wifi
            - --no-collector.infiniband
            - --no-collector.nfs
            - --no-collector.nfsd
            - --no-collector.fibrechannel
            - --no-collector.bcache
            - --no-collector.thermal_zone
          ports: [{name: metrics, containerPort: 9100}]
          readinessProbe: {httpGet: {path: /, port: metrics}, periodSeconds: 15}
          resources: {requests: {cpu: 20m, memory: 24Mi}, limits: {cpu: 200m, memory: 64Mi}}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          volumeMounts:
            - {name: proc, mountPath: /host/proc, readOnly: true}
            - {name: sys, mountPath: /host/sys, readOnly: true}
            - {name: root, mountPath: /host/root, readOnly: true, mountPropagation: HostToContainer}
      volumes:
        - {name: proc, hostPath: {path: /proc}}
        - {name: sys, hostPath: {path: /sys}}
        - {name: root, hostPath: {path: /}}
```
Notes: no `hostNetwork` (so the port is not exposed on the node's LAN/tailnet addresses; the cost is that `node_network_*` shows the pod's interface, [UNVERIFIED] but irrelevant to the alerts; see Q2). `--no-collector.thermal_zone` may be unknown in v1.12.1: if the pod crash-loops with `unknown long flag`, remove that single flag (check `kubectl logs`, read-only) and report. The `zfs` collector is on by default: nothing to add. The mount-point exclusion deliberately does not hide `/var/mnt/*`.

**4.7 `alertmanager.yaml`**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: alertmanager-data, namespace: monitoring}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: topolvm-fast
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Service
metadata: {name: alertmanager, namespace: monitoring, labels: {app.kubernetes.io/name: alertmanager}}
spec:
  selector: {app.kubernetes.io/name: alertmanager}
  ports: [{name: http, port: 9093, targetPort: http}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: alertmanager, namespace: monitoring, labels: {app.kubernetes.io/name: alertmanager}}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app.kubernetes.io/name: alertmanager}}
  template:
    metadata: {labels: {app.kubernetes.io/name: alertmanager}}
    spec:
      priorityClassName: hs-critical
      automountServiceAccountToken: false
      nodeSelector: {kubernetes.io/hostname: mini02}
      tolerations: [{key: node.kubernetes.io/unschedulable, operator: Exists, effect: NoSchedule}]
      securityContext: {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, fsGroup: 65534, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: alertmanager
          image: quay.io/prometheus/alertmanager:v0.34.1@sha256:<DIGEST>
          args:
            - --config.file=/etc/alertmanager/alertmanager.yml
            - --storage.path=/alertmanager
            - --cluster.listen-address=
          ports: [{name: http, containerPort: 9093}]
          readinessProbe: {httpGet: {path: /-/ready, port: http}, periodSeconds: 10}
          livenessProbe: {httpGet: {path: /-/healthy, port: http}, initialDelaySeconds: 15, periodSeconds: 20}
          resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: 100m, memory: 64Mi}}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          volumeMounts:
            - {name: config, mountPath: /etc/alertmanager/alertmanager.yml, subPath: alertmanager.yml}
            - {name: secrets, mountPath: /etc/alertmanager/secrets, readOnly: true}
            - {name: data, mountPath: /alertmanager}
      volumes:
        - {name: config, configMap: {name: alertmanager-config}}
        - {name: secrets, secret: {secretName: alertmanager-secrets}}
        - {name: data, persistentVolumeClaim: {claimName: alertmanager-data}}
```

**4.8** (no extra files; Argo scrape rules are in 4.4.)

**4.9 `alertmanager.yml`** (D1 = Telegram; D4 = healthchecks-type URL). Replace `<CHAT_ID>` with the integer the operator gives you in WP3 (an ordinary number, not a secret; if the operator has not given it, STOP).
```yaml
global:
  resolve_timeout: 5m
route:
  receiver: phone
  group_by: [alertname, instance]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h            # D9 (warnings)
  routes:
    - matchers: [alertname = "Watchdog"]
      receiver: deadman
      group_wait: 0s
      group_interval: 1m
      repeat_interval: 5m          # a heartbeat every 5 minutes
    - matchers: [severity = "critical"]
      receiver: phone
      repeat_interval: 4h
    - matchers: [severity = "info"]
      receiver: "null"
receivers:
  - name: phone
    telegram_configs:
      - bot_token_file: /etc/alertmanager/secrets/telegram-bot-token
        chat_id: <CHAT_ID>
        send_resolved: true
        parse_mode: ""             # plain text; avoids Markdown escaping errors
        message: |-
          [{{ .Status | toUpper }}] {{ .CommonLabels.alertname }} ({{ .CommonLabels.severity }})
          {{ range .Alerts }}{{ .Annotations.summary }}
          {{ end }}
  - name: deadman
    webhook_configs:
      - url_file: /etc/alertmanager/secrets/deadman-url
        send_resolved: false
  - name: "null"
inhibit_rules:
  - source_matchers: [severity = "critical"]
    target_matchers: [severity = "warning"]
    equal: [alertname, instance]
  - source_matchers: [alertname = "NodeDown"]
    target_matchers: [alertname =~ "TargetDown|ProbeFailed|PodStuckPending"]
    equal: [node]
```
For D1 = ntfy: replace the `phone` receiver by
```yaml
  - name: phone
    webhook_configs:
      - url_file: /etc/alertmanager/secrets/ntfy-url      # full URL incl. topic and ?template=alertmanager
        send_resolved: true
```
[template support verified https://docs.ntfy.sh/publish/]. If D4 = none, delete the `deadman` receiver and the Watchdog route.
Syntax check before commit (no cluster): `docker run --rm -v "$PWD/talos/manifests/monitoring:/c:ro" --entrypoint amtool quay.io/prometheus/alertmanager:v0.34.1 check-config /c/alertmanager.yml` (needs the secret files to exist; if it complains about missing files, that is expected here; any other error is a real error). If Docker is unavailable say so in the report.

**4.10 `rules-core.yml`** (Prometheus rule file; `for` makes alerts quiet during blips; `severity` drives routing)
```yaml
groups:
  - name: meta
    rules:
      - alert: Watchdog
        expr: vector(1)
        labels: {severity: info}
        annotations: {summary: "Always firing: the monitoring heartbeat"}
      - alert: PrometheusAlertmanagerUnreachable
        expr: prometheus_notifications_alertmanagers_discovered < 1
        for: 10m
        labels: {severity: critical}
        annotations: {summary: "Prometheus sees no Alertmanager: alerts cannot be delivered"}
      - alert: PrometheusRuleFailures
        expr: increase(prometheus_rule_evaluation_failures_total[10m]) > 0
        for: 10m
        labels: {severity: warning}
        annotations: {summary: "Prometheus rule evaluation is failing"}
      - alert: PrometheusNotificationsFailing
        expr: increase(prometheus_notifications_errors_total[15m]) > 0
        for: 15m
        labels: {severity: warning}
        annotations: {summary: "Prometheus cannot send notifications to Alertmanager"}
      - alert: TargetDown
        expr: up{job!="grafana"} == 0   # in WP5 change this to: up == 0 (the grafana job exists from then on)
        for: 10m
        labels: {severity: warning}
        annotations: {summary: "Scrape target {{ $labels.job }} {{ $labels.instance }} is down"}
      - alert: PrometheusTSDBNearCap
        expr: prometheus_tsdb_storage_blocks_bytes > 6.3e9
        for: 30m
        labels: {severity: warning}
        annotations: {summary: "Prometheus TSDB is above 90% of its 7 GB size cap; old data is being dropped early"}

  - name: nodes
    rules:
      - alert: NodeDown
        expr: up{job="node"} == 0
        for: 5m
        labels: {severity: critical}
        annotations: {summary: "Node {{ $labels.node }} is not reporting metrics"}
      - alert: NodeNotReady
        expr: kube_node_status_condition{condition="Ready",status="true"} == 0
        for: 5m
        labels: {severity: critical}
        annotations: {summary: "Node {{ $labels.node }} is NotReady"}
      - alert: NodePressure
        expr: kube_node_status_condition{condition=~"MemoryPressure|DiskPressure|PIDPressure",status="true"} == 1
        for: 5m
        labels: {severity: critical}
        annotations: {summary: "Node {{ $labels.node }} reports {{ $labels.condition }}"}
      - alert: NodeMemoryHigh
        expr: 1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.90
        for: 15m
        labels: {severity: warning}
        annotations: {summary: "Memory use above 90% on {{ $labels.node }} for 15 min"}
      - alert: NodeMemoryCritical
        expr: 1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.95
        for: 5m
        labels: {severity: critical}
        annotations: {summary: "Memory use above 95% on {{ $labels.node }}: OOM kills are likely"}
      - alert: NodeCPUHigh
        expr: 1 - avg by (node) (rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.90
        for: 30m
        labels: {severity: warning}
        annotations: {summary: "CPU above 90% on {{ $labels.node }} for 30 min"}
      - alert: NodeFilesystemLow
        expr: |
          node_filesystem_avail_bytes{mountpoint!~"/var/mnt/tank.*"} / node_filesystem_size_bytes{mountpoint!~"/var/mnt/tank.*"} < 0.15
        for: 15m
        labels: {severity: warning}
        annotations: {summary: "{{ $labels.node }} {{ $labels.mountpoint }} has less than 15% free"}
      - alert: NodeFilesystemCritical
        expr: |
          node_filesystem_avail_bytes{mountpoint!~"/var/mnt/tank.*"} / node_filesystem_size_bytes{mountpoint!~"/var/mnt/tank.*"} < 0.05
        for: 5m
        labels: {severity: critical}
        annotations: {summary: "{{ $labels.node }} {{ $labels.mountpoint }} has less than 5% free"}
      - alert: NodeFilesystemFillingFast
        expr: predict_linear(node_filesystem_avail_bytes{mountpoint!~"/var/mnt/tank.*"}[6h], 24 * 3600) < 0 and node_filesystem_size_bytes{mountpoint!~"/var/mnt/tank.*"} > 5e9
        for: 1h
        labels: {severity: warning}
        annotations: {summary: "{{ $labels.node }} {{ $labels.mountpoint }} will be full within 24 h at the current rate"}

  - name: storage
    rules:
      - alert: ZfsPoolNotOnline
        expr: node_zfs_zpool_state{state!="online"} == 1
        for: 5m
        labels: {severity: critical}
        annotations: {summary: "ZFS pool {{ $labels.zpool }} on {{ $labels.node }} is {{ $labels.state }} (degraded/faulted)"}
      - alert: ZfsPoolMetricMissing
        expr: absent(node_zfs_zpool_state{zpool="tank"})
        for: 30m
        labels: {severity: warning}
        annotations: {summary: "No ZFS pool metrics for tank: the exporter cannot see the pool (check node-exporter on mini02)"}
      - alert: NasQuotaLow
        expr: node_filesystem_avail_bytes{mountpoint=~"/var/mnt/tank.+"} / node_filesystem_size_bytes{mountpoint=~"/var/mnt/tank.+"} < 0.20
        for: 30m
        labels: {severity: warning}
        annotations: {summary: "ZFS dataset {{ $labels.mountpoint }} has less than 20% of its quota free"}
      - alert: NasQuotaCritical
        expr: node_filesystem_avail_bytes{mountpoint=~"/var/mnt/tank.+"} / node_filesystem_size_bytes{mountpoint=~"/var/mnt/tank.+"} < 0.08
        for: 10m
        labels: {severity: critical}
        annotations: {summary: "ZFS dataset {{ $labels.mountpoint }} has less than 8% of its quota free: writes will fail soon"}
      - alert: PvcFilling
        expr: kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.85
        for: 15m
        labels: {severity: warning}
        annotations: {summary: "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} is over 85% full"}
      - alert: PvcFull
        expr: kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.95
        for: 5m
        labels: {severity: critical}
        annotations: {summary: "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} is over 95% full"}
      - alert: PvcNotBound
        expr: kube_persistentvolumeclaim_status_phase{phase=~"Pending|Lost"} == 1
        for: 30m      # a WaitForFirstConsumer claim with no pod yet is Pending: warn only after 30 min
        labels: {severity: warning}
        annotations: {summary: "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} is {{ $labels.phase }}"}

  - name: workloads
    rules:
      - alert: PodCrashLooping
        expr: max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m]) >= 1
        for: 15m
        labels: {severity: warning}
        annotations: {summary: "{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) is crash-looping"}
      - alert: PodOOMKilled
        expr: increase(kube_pod_container_status_restarts_total[10m]) > 0 and on (namespace, pod, container) kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
        labels: {severity: warning}
        annotations: {summary: "{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) was OOM-killed: raise its memory limit"}
      - alert: PodStuckPending
        expr: kube_pod_status_phase{phase=~"Pending|Unknown"} == 1
        for: 30m
        labels: {severity: warning}
        annotations: {summary: "{{ $labels.namespace }}/{{ $labels.pod }} has been {{ $labels.phase }} for 30 min (scheduling problem?)"}
      - alert: DeploymentUnavailable
        expr: kube_deployment_status_replicas_available < kube_deployment_spec_replicas
        for: 15m
        labels: {severity: warning}
        annotations: {summary: "Deployment {{ $labels.namespace }}/{{ $labels.deployment }} has fewer ready pods than wanted"}
      - alert: StatefulSetNotReady
        expr: kube_statefulset_status_replicas_ready < kube_statefulset_replicas
        for: 10m
        labels: {severity: warning}
        annotations: {summary: "StatefulSet {{ $labels.namespace }}/{{ $labels.statefulset }} is not ready (for namespace tailscale: a tailnet proxy is down)"}
      - alert: TailscaleProxyDown
        expr: kube_statefulset_status_replicas_ready{namespace="tailscale"} < 1
        for: 5m
        labels: {severity: critical}
        annotations: {summary: "Tailscale proxy {{ $labels.statefulset }} has no ready pod: that app is unreachable on the tailnet"}
      - alert: DaemonSetNotScheduled
        expr: kube_daemonset_status_number_unavailable > 0
        for: 15m
        labels: {severity: warning}
        annotations: {summary: "DaemonSet {{ $labels.namespace }}/{{ $labels.daemonset }} has pods missing"}
      - alert: JobFailed
        expr: kube_job_status_failed > 0
        labels: {severity: warning}
        annotations: {summary: "Job {{ $labels.namespace }}/{{ $labels.job_name }} failed (the last 3 failed Jobs stay visible)"}
      - alert: ZfsScrubFailed
        expr: kube_job_status_failed{namespace="kube-system", job_name=~"zfs-scrub-.*"} > 0
        labels: {severity: critical}
        annotations: {summary: "The monthly ZFS scrub failed or the pool was not healthy afterwards"}
      - alert: ZfsScrubNotRun
        expr: time() - kube_cronjob_status_last_successful_time{namespace="kube-system", cronjob="zfs-scrub"} > 40 * 86400
        labels: {severity: warning}
        annotations: {summary: "No successful ZFS scrub in 40 days (the CronJob runs on the 1st of each month)"}
      - alert: IntelGpuUnavailable
        expr: kube_node_status_allocatable{node="mini01", resource="gpu_intel_com_i915"} < 1
        for: 10m
        labels: {severity: warning}
        annotations: {summary: "mini01 no longer offers the Intel GPU to pods: Jellyfin hardware transcoding falls back to CPU"}

  - name: backups
    rules:
      - alert: VeleroBackupFailed
        expr: velero_backup_last_status == 0
        for: 10m
        labels: {severity: critical}
        annotations: {summary: "The last Velero backup of schedule {{ $labels.schedule }} failed"}
      - alert: VeleroBackupTooOld
        expr: time() - velero_backup_last_successful_timestamp{schedule=~"velero-homeserver-nightly|velero-cp-reserva-bot-nightly"} > 36 * 3600
        labels: {severity: critical}
        annotations: {summary: "No successful Velero backup of {{ $labels.schedule }} for more than 36 h"}
      - alert: VeleroBackupMetricMissing
        expr: absent(velero_backup_last_successful_timestamp{schedule="velero-homeserver-nightly"})
        for: 36h
        labels: {severity: warning}
        annotations: {summary: "Velero reports no successful homeserver backup at all (the gauge is empty after a Velero restart until the next success)"}
      - alert: VeleroStorageLocationUnavailable
        expr: velero_backup_location_status_gauge == 0
        for: 15m
        labels: {severity: critical}
        annotations: {summary: "Velero cannot reach its backup location {{ $labels.backup_location_name }} (MinIO on mini02?)"}
      - alert: CnpgDown
        expr: cnpg_collector_up == 0
        for: 5m
        labels: {severity: critical}
        annotations: {summary: "PostgreSQL {{ $labels.cluster }} ({{ $labels.pod }}) is down: Immich has no database"}
      - alert: CnpgBackupTooOld
        expr: time() - cnpg_collector_last_available_backup_timestamp > 36 * 3600
        labels: {severity: warning}
        annotations: {summary: "No successful CNPG base backup of {{ $labels.cluster }} for more than 36 h (ScheduledBackup immich-pg-daily)"}
      - alert: CnpgBackupFailed
        expr: cnpg_collector_last_failed_backup_timestamp > cnpg_collector_last_available_backup_timestamp
        for: 5m
        labels: {severity: warning}
        annotations: {summary: "The last CNPG backup of {{ $labels.cluster }} failed"}
      - alert: CnpgWalArchiveBacklog
        expr: cnpg_collector_pg_wal_archive_status{value="ready"} > 50
        for: 30m
        labels: {severity: warning}
        annotations: {summary: "{{ $labels.cluster }} has more than 50 WAL files waiting for archive: backup target unreachable?"}

  - name: gitops-and-certs
    rules:
      - alert: ArgoAppDegraded
        expr: argocd_app_info{health_status=~"Degraded|Missing"} == 1
        for: 15m
        labels: {severity: warning}
        annotations: {summary: "Argo CD app {{ $labels.name }} is {{ $labels.health_status }}"}
      - alert: ArgoAppOutOfSync
        expr: argocd_app_info{sync_status="OutOfSync"} == 1
        for: 24h        # apps are manual-sync: a merged PR waits for the operator; alert only after a day
        labels: {severity: info}
        annotations: {summary: "Argo CD app {{ $labels.name }} has been OutOfSync for 24 h (merged but not synced?)"}
      - alert: CertificateExpiringSoon
        expr: certmanager_certificate_expiration_timestamp_seconds - time() < 14 * 86400
        for: 1h
        labels: {severity: warning}
        annotations: {summary: "Certificate {{ $labels.namespace }}/{{ $labels.name }} expires in under 14 days"}
      - alert: CertificateNotReady
        expr: certmanager_certificate_ready_status{condition="False"} == 1
        for: 1h
        labels: {severity: warning}
        annotations: {summary: "Certificate {{ $labels.namespace }}/{{ $labels.name }} is not Ready"}
```
Notes the executor must keep in the PR description: (1) There are no cert-manager `Certificate` objects today (`kubectl get certificate -A` -> none [repo]), so the two certificate rules have no data and stay `inactive`; this is correct. The tailnet HTTPS certificates are issued and renewed by Tailscale, not cert-manager; they cannot be seen by this stack (Q4). (2) `ZfsScrubFailed`, `PodStuckPending` and `JobFailed` use KSM label `job_name`; `job` is Prometheus' own label. (3) The `PodOOMKilled` rule has no `for` on purpose. (4) `ArgoAppOutOfSync` is `info` and goes to the `null` receiver; it is visible in the Alertmanager UI and Grafana only.

**Expected immediately after sync (so the operator is not alarmed):** `PodStuckPending` fires for the stuck `zfs-scrub-<id>` pod (a true finding). `TargetDown` does not fire for the not-yet-deployed `grafana` job because the expression excludes it until WP5.

**4.11 Argo app `talos/apps-src/monitoring.yaml`**
```yaml
# Monitoring stack (plan docs/plans/monitoring.md). Manual sync: The operator syncs it in the Argo CD UI.
# ServerSideApply: the hashed ConfigMaps and the dashboards can exceed the 256 KiB annotation limit of client-side apply.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/BrunoLoureirooo/homelab_gitops
    targetRevision: main
    path: talos/manifests/monitoring
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    syncOptions:
      - CreateNamespace=false
      - ServerSideApply=true
    # Manual sync, no automated block.
```
Then `talos/render-apps.sh --force`; commit `talos/apps/monitoring.yaml`. Add to `talos/test/empty-cluster-expectations.txt` (same column format as the existing lines):
`monitoring              *       *       # needs the monitoring namespace, the sealed grafana-secrets/alertmanager-secrets and a node that tolerates the cordon taint`

**4.12 Validate before commit (no cluster)**
1. `kustomize build talos/manifests/monitoring > /tmp/monitoring.yaml` -> exit 0. Then `grep -E 'name: (prometheus|alertmanager)-(config|rules)-' /tmp/monitoring.yaml` -> hashed names appear both as ConfigMaps and in Deployment `volumes`. If a Deployment still references the unhashed name, STOP.
2. `grep -c 'sha256:<' /tmp/monitoring.yaml` -> `0` (no unresolved digest placeholders).
3. Config syntax: `docker run --rm -v "$PWD/talos/manifests/monitoring:/c:ro" --entrypoint promtool quay.io/prometheus/prometheus:v3.15.1 check config /c/prometheus.yml` (it will complain that `/etc/prometheus/rules/*.yml` matches nothing: acceptable) and `... promtool check rules /c/rules-core.yml` -> `SUCCESS: N rules found`. If Docker is unavailable say so; the operator then runs these two commands.
4. Guards: 20 `OK`.

**4.13 After the operator merges and syncs `monitoring` (The operator syncs in the Argo UI; the executor verifies read-only)**

Order for the operator: sync `namespaces` (already, WP2), confirm sealed secrets delivered, sync `monitoring`. Watch: all pods `Running`. Expected in about 3 minutes:
```
kubectl --context admin@<cluster> -n monitoring get pods -o wide
  prometheus-...            1/1 Running  mini02
  alertmanager-...          1/1 Running  mini02
  kube-state-metrics-...    1/1 Running  mini01
  node-exporter-xxxxx       1/1 Running  mini01
  node-exporter-yyyyy       1/1 Running  mini02
```
Executor checks (read-only; `kubectl logs` is allowed):
- `kubectl --context admin@<cluster> -n monitoring logs deploy/prometheus --tail=30` -> contains `Server is ready to receive web requests`; no `permission denied`.
- `kubectl --context admin@<cluster> get pvc -n monitoring` -> `Bound`.
- Targets and metrics (the operator, in his own terminal): `kubectl --context admin@<cluster> -n monitoring port-forward svc/prometheus 9090:9090` then open `http://localhost:9090/targets`: every job `UP` except `grafana` (until WP5) and `blackbox`/`minio` (not added yet). Then in Graph run each query and note the result in the report:
  - `count(up == 1)` -> at least 12.
  - `prometheus_tsdb_head_series` -> about 30 000 (anything under 80 000 is fine; above 80 000 STOP and tighten `metric_relabel_configs`).
  - `node_filesystem_size_bytes{node="mini02"}` -> series for `/var` and `/var/mnt/tank/...` mounts; sizes of the tank datasets should equal the quotas (256 GiB, 128 GiB, 128 GiB) (section 3.3).
  - `node_zfs_zpool_state{zpool="tank"}` -> a series with `state="online"` value 1. If empty: see the fallback in section 3.3 and report; the rule `ZfsPoolMetricMissing` will fire after 30 min, which is the intended behaviour.
  - `count by (persistentvolumeclaim) (kubelet_volume_stats_capacity_bytes)` -> note which PVCs appear. If the local-path PVCs are missing, report; `PvcFilling` then covers only the PVCs that appear, and the filesystem rules cover the rest (Q5).
  - `velero_backup_last_successful_timestamp` -> two series (schedules above). `cnpg_collector_up` -> 1. `argocd_app_info` -> about 24 series. `certmanager_certificate_expiration_timestamp_seconds` -> probably empty (no Certificates).
  - `kube_node_status_allocatable{node="mini01"}` -> read the exact `resource` label that contains `i915` and, if it differs from `gpu_intel_com_i915`, fix the rule in a follow-up commit.
- Rules: `http://localhost:9090/rules` -> no rule in state `error`; `http://localhost:9090/alerts` -> `Watchdog` firing, `PodStuckPending` firing for the zfs-scrub pod (expected).
- Alertmanager: `kubectl --context admin@<cluster> -n monitoring logs deploy/alertmanager --tail=30` -> no `unsupported`/`yaml:` errors.

**4.14 Rollback.** the operator deletes the Argo app `monitoring` in the UI (prune removes the workloads; the PVCs are `Retain` through the StorageClass, so data remains until deleted by hand) and reverts the PR. No other service depends on it.

**4.15 PR.** Branch `feat/monitoring-core`. Title `feat: monitoring core (Prometheus, Alertmanager, kube-state-metrics, node-exporter)`. Description: what the stack is, node placement (D5), resources table from section 4, "no secrets in this PR", list of new files, the 4.12 results, the expected `PodStuckPending` finding for `zfs-scrub`, and "the operator after merge: 1) confirm `kubectl -n monitoring describe secret alertmanager-secrets` lists `telegram-bot-token`; 2) sync Argo app `monitoring`; 3) watch pods; 4) port-forward and check `/targets` as listed in plan 4.13." Draft. Claude Code line.
STOP: wait for the operator's confirmation of 4.13 before WP5 and WP6.

### WP5. Grafana (provisioned from git) with tailnet ingress

Goal: Grafana on the tailnet, Prometheus data source and 4 dashboards. Branch `feat/monitoring-grafana`. Preconditions: WP4 verified; digest for `docker.io/grafana/grafana:13.2.4` (confirm the tag exists with the digest command first; tag form without `v`).

Files: `talos/manifests/monitoring/grafana.yaml`, `grafana-datasources.yaml` (as a kustomize-generated file), `grafana-dashboards.yml` (provider file), `dashboards/*.json`, ingress inside `grafana.yaml`; edit `kustomization.yaml` (append resources and generators).

**5.1 `grafana.yaml`**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: grafana-data, namespace: monitoring}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: topolvm-fast
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Service
metadata: {name: grafana, namespace: monitoring, labels: {app.kubernetes.io/name: grafana}}
spec:
  selector: {app.kubernetes.io/name: grafana}
  ports: [{name: http, port: 3000, targetPort: http}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: grafana, namespace: monitoring, labels: {app.kubernetes.io/name: grafana}}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app.kubernetes.io/name: grafana}}
  template:
    metadata: {labels: {app.kubernetes.io/name: grafana}}
    spec:
      priorityClassName: hs-interactive
      automountServiceAccountToken: false
      nodeSelector: {kubernetes.io/hostname: mini01}
      securityContext: {runAsNonRoot: true, runAsUser: 472, runAsGroup: 472, fsGroup: 472, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: grafana
          image: docker.io/grafana/grafana:13.2.4@sha256:<DIGEST>
          env:
            - {name: GF_SECURITY_ADMIN_USER, value: admin}
            - name: GF_SECURITY_ADMIN_PASSWORD
              valueFrom: {secretKeyRef: {name: grafana-secrets, key: GF_SECURITY_ADMIN_PASSWORD}}
            - name: GF_SERVER_ROOT_URL              # full tailnet URL: sealed, never in git in clear
              valueFrom: {secretKeyRef: {name: grafana-secrets, key: GF_SERVER_ROOT_URL}}
            - {name: GF_USERS_ALLOW_SIGN_UP, value: "false"}
            - {name: GF_AUTH_ANONYMOUS_ENABLED, value: "false"}
            - {name: GF_ANALYTICS_REPORTING_ENABLED, value: "false"}
            - {name: GF_ANALYTICS_CHECK_FOR_UPDATES, value: "false"}
            - {name: GF_UNIFIED_ALERTING_ENABLED, value: "false"}   # alerts live in Prometheus/Alertmanager only
            - {name: GF_ALERTING_ENABLED, value: "false"}
          ports: [{name: http, containerPort: 3000}]
          readinessProbe: {httpGet: {path: /api/health, port: http}, periodSeconds: 10}
          livenessProbe: {httpGet: {path: /api/health, port: http}, initialDelaySeconds: 30, periodSeconds: 20}
          resources: {requests: {cpu: 50m, memory: 160Mi}, limits: {cpu: 500m, memory: 384Mi}}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          volumeMounts:
            - {name: data, mountPath: /var/lib/grafana}
            - {name: tmp, mountPath: /tmp}
            - {name: datasources, mountPath: /etc/grafana/provisioning/datasources}
            - {name: dashboard-provider, mountPath: /etc/grafana/provisioning/dashboards}
            - {name: dashboards, mountPath: /var/lib/grafana-dashboards, readOnly: true}
      volumes:
        - {name: data, persistentVolumeClaim: {claimName: grafana-data}}
        - {name: tmp, emptyDir: {sizeLimit: 100Mi}}
        - {name: datasources, configMap: {name: grafana-datasources}}
        - {name: dashboard-provider, configMap: {name: grafana-dashboard-provider}}
        - name: dashboards
          projected:
            sources:
              - configMap: {name: grafana-dash-node-exporter}
              - configMap: {name: grafana-dash-kube-state}
              - configMap: {name: grafana-dash-argocd}
              - configMap: {name: grafana-dash-cnpg}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: grafana, namespace: monitoring, labels: {app.kubernetes.io/name: grafana}}
spec:
  ingressClassName: tailscale
  rules:
    - http:
        paths:
          - {path: /, pathType: Prefix, backend: {service: {name: grafana, port: {number: 3000}}}}
  tls:
    - hosts: [grafana]       # short name only; the full tailnet name is a host detail (see GF_SERVER_ROOT_URL)
```
Before the first sync the operator must delete any stale `grafana` device in the Tailscale admin console, otherwise the new one registers as `grafana-1` (same note as `talos/manifests/jellyfin/ingress.yaml` [repo]); then the real URL differs and `GF_SERVER_ROOT_URL` must match the real one.
`GF_UNIFIED_ALERTING_ENABLED=false`: single source of alert truth. [UNVERIFIED that `GF_ALERTING_ENABLED` is still accepted in Grafana 13; if the container logs an error about it, delete that single line and report.]

**5.2 Data source** `talos/manifests/monitoring/grafana-datasources.yml` (generated into ConfigMap `grafana-datasources`):
```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus.monitoring.svc.cluster.local:9090
    isDefault: true
    editable: false
    jsonData: {timeInterval: 60s}
```
**5.3 Dashboard provider** `grafana-dashboard-provider.yml` (ConfigMap `grafana-dashboard-provider`, key file name `dashboards.yml`):
```yaml
apiVersion: 1
providers:
  - name: homelab
    type: file
    disableDeletion: true
    allowUiUpdates: false
    updateIntervalSeconds: 60
    options: {path: /var/lib/grafana-dashboards, foldersFromFilesStructure: false}
```
Kustomize additions (append to `resources:` the file `grafana.yaml`; and to `configMapGenerator`):
```yaml
  - name: grafana-datasources
    files: [datasources.yml=grafana-datasources.yml]
  - name: grafana-dashboard-provider
    files: [dashboards.yml=grafana-dashboard-provider.yml]
  - name: grafana-dash-node-exporter
    files: [dashboards/node-exporter-full.json]
  - name: grafana-dash-kube-state
    files: [dashboards/kube-state-metrics-v2.json]
  - name: grafana-dash-argocd
    files: [dashboards/argocd.json]
  - name: grafana-dash-cnpg
    files: [dashboards/cloudnativepg.json]
```
**5.4 Dashboards by ID (downloaded by the executor, verified).** Download each JSON from grafana.com into `talos/manifests/monitoring/dashboards/`:
```bash
mkdir -p talos/manifests/monitoring/dashboards
curl -sSfL https://grafana.com/api/dashboards/1860/revisions/45/download  -o talos/manifests/monitoring/dashboards/node-exporter-full.json
curl -sSfL https://grafana.com/api/dashboards/13332/revisions/12/download -o talos/manifests/monitoring/dashboards/kube-state-metrics-v2.json
curl -sSfL https://grafana.com/api/dashboards/14584/revisions/1/download  -o talos/manifests/monitoring/dashboards/argocd.json
curl -sSfL https://grafana.com/api/dashboards/20417/revisions/4/download  -o talos/manifests/monitoring/dashboards/cloudnativepg.json
```
Verified on 2026-10-25 via https://grafana.com/api/dashboards/<id>: 1860 "Node Exporter Full" revision 45; 13332 "kube-state-metrics-v2" revision 12 (inputs `DS_PROMETHEUS`, `VAR_DATASOURCE`); 14584 "ArgoCD" revision 1; 20417 "CloudNativePG" revision 4 (inputs `DS_PROMETHEUS`, `DS_EXPRESSION`). If a revision number now differs (the download returns 404), use the number from `https://grafana.com/api/dashboards/<id>` (field `revision`) and report. Also consider: Velero dashboard 11055 (revision 2, 2019, old) is NOT imported: it targets old metric names; Velero is covered by alerts.
Fix the data-source placeholders so the JSON works unattended:
```bash
cd talos/manifests/monitoring/dashboards
for f in *.json; do
  sed -i.bak -e 's/\${DS_PROMETHEUS}/prometheus/g' -e 's/\${VAR_DATASOURCE}/prometheus/g' "$f" && rm -f "$f.bak"
  jq -e . "$f" >/dev/null && echo "$f valid JSON, $(wc -c <"$f") bytes"
  grep -c 'DS_PROMETHEUS\|DS_EXPRESSION' "$f"
done
```
Expected: each file "valid JSON"; the grep count `0` for node-exporter-full, argocd; if count is not 0 for kube-state or cnpg, open the file's `__inputs` and replace remaining `${DS_...}` the same way; for `DS_EXPRESSION` use `__expr__` (the Grafana built-in expression data source) and report. Then delete the top-level `__inputs` and `__requires` arrays with `jq 'del(.__inputs,.__requires)' f > f.new && mv f.new f` (file provisioning does not use them). Each file must stay below 1 MiB (ConfigMap limit): `wc -c`; if node-exporter-full is above 900 000 bytes STOP and report. The `ServerSideApply=true` sync option (4.11) avoids the 256 KiB annotation limit.
Dashboard datasources: the JSON of 1860 uses a datasource variable `ds_prometheus` of type `datasource` pointing at Prometheus: with exactly one Prometheus data source it resolves automatically.

**5.5 Validate.** `kustomize build talos/manifests/monitoring | grep -c 'name: grafana-dash-'` -> at least 8 lines (ConfigMap + projected source for each of four). Confirm the projected sources reference the hashed names (`grep -A8 'projected:'`). If they reference unhashed names, STOP and report (alternative: one ConfigMap per dashboard with `generatorOptions: {disableNameSuffixHash: true}` and a manual rollout: The operator's decision).

**5.6 Verify after sync (The operator syncs `monitoring` again).**
- `kubectl --context admin@<cluster> -n monitoring get pods` -> `grafana-...` `1/1 Running` on mini01.
- `kubectl --context admin@<cluster> -n monitoring get ingress grafana` -> an address; the operator opens `https://grafana.<tailnet-name>.ts.net` on a tailnet device; login `admin` + the password from Vaultwarden; opening Connections > Data sources shows `Prometheus` with "Successfully queried the Prometheus API" after "Save & test" (read-only click).
- Dashboards: folder "General" lists 4 dashboards; Node Exporter Full shows CPU/memory for `mini01` and `mini02`; ArgoCD dashboard shows apps; CloudNativePG shows `immich-pg`. `http://localhost:9090/targets` job `grafana` is now UP.
- If login fails: section 6 "Lost admin password".

**5.7 Rollback.** Remove the files, revert; Argo prunes Grafana; the PVC remains (Retain). **PR** `feat: Grafana for monitoring (tailnet, provisioned dashboards)`; description includes the dashboard IDs and revisions, "no secrets", the operator's steps in 5.6. STOP.

### WP6. Probes, MinIO, remaining jobs and alerts

Goal: reachability alerts for the services the operator uses; MinIO metrics. Branch `feat/monitoring-probes`. Preconditions: WP4 verified. Files: `blackbox.yaml`, `blackbox.yml`, edits to `prometheus.yml`, new `rules-probes.yml`, edits to `kustomization.yaml`, and one edit in `talos/manifests/backup-target/minio.yaml` (separate PR, 6.2).

**6.1 `blackbox.yml`** (ConfigMap `blackbox-config`, key `blackbox.yml`)
```yaml
modules:
  http_2xx:
    prober: http
    timeout: 10s
    http:
      method: GET
      valid_status_codes: []        # any 2xx
      follow_redirects: true
      preferred_ip_protocol: ip4
  http_any:
    prober: http
    timeout: 10s
    http:
      valid_status_codes: [200, 301, 302, 303, 307, 308, 401, 403]   # alive, even when it wants a login
  tcp_connect:
    prober: tcp
    timeout: 5s
```
`blackbox.yaml`: Service `blackbox-exporter` port 9115, Deployment on mini01, image `quay.io/prometheus/blackbox-exporter:v0.29.1@sha256:<DIGEST>`, args `--config.file=/etc/blackbox/blackbox.yml`, `runAsNonRoot` uid 65534, `readOnlyRootFilesystem: true`, drop ALL, `automountServiceAccountToken: false`, probes `httpGet /-/healthy` port 9115, resources requests 10m/24Mi, limits 100m/64Mi, priorityClassName `hs-interactive`, ConfigMap volume `blackbox-config`. Add generator `- name: blackbox-config, files: [blackbox.yml]` and `blackbox.yaml` to `kustomization.yaml`. (Same shape as the Deployments in 4.3/4.5; write it in full, do not abbreviate.)

**6.2 MinIO metrics (separate small PR `feat/minio-metrics-public`, touches `talos/manifests/backup-target/minio.yaml`).** Add to the container `minio` an `env:` entry `- {name: MINIO_PROMETHEUS_AUTH_TYPE, value: public}` (keep the existing `envFrom`). Why: MinIO otherwise requires a bearer token for `/minio/v2/metrics/cluster` (the token is a secret and would need a generated Secret) [UNVERIFIED: MinIO moved its documentation to https://docs.min.io/enterprise/aistor-object-store/operations/monitoring/metrics-and-alerts/; confirm the variable name and path there first; if it differs, use what that page says]. Exposure: MinIO's Service is cluster-internal only; the metrics reveal capacity and counts, not data. Sync the app `backup-target` (a pod restart: Velero and CNPG backups see a one-minute gap; do it away from 10:00 UTC). Verify read-only after sync: `kubectl --context admin@<cluster> -n velero get pods` -> `minio-...` `Running`; Prometheus target `minio` UP. If the endpoint 404s, drop the PR and keep only the blackbox probe (report).
Add to `prometheus.yml`:
```yaml
  - job_name: minio
    metrics_path: /minio/v2/metrics/cluster
    static_configs: [{targets: ["velero-backup-target.velero.svc.cluster.local:9000"]}]
```
**6.3 Probe jobs** (append to `prometheus.yml`). The service names and ports are the live ones [repo, 2026-10-25]; the health paths are [UNVERIFIED] for each application and must be confirmed by the executor in the app's own documentation (Jellyfin `/health`; Immich `/api/server/ping`; Vaultwarden `/alive`; AdGuard `/`; cp-reserva-bot `/`) before use, otherwise use `http_any` on `/`.
```yaml
  - job_name: blackbox-probes
    metrics_path: /probe
    params: {module: [http_2xx]}
    static_configs:
      - targets:
          - http://jellyfin.homeserver.svc.cluster.local:8096/health
          - http://immich-server.homeserver.svc.cluster.local:2283/api/server/ping
          - http://vaultwarden.homeserver.svc.cluster.local:80/alive
          - http://velero-backup-target.velero.svc.cluster.local:9000/minio/health/live
    relabel_configs:
      - {source_labels: [__address__], target_label: __param_target}
      - {source_labels: [__param_target], target_label: instance}
      - {target_label: __address__, replacement: "blackbox-exporter.monitoring.svc.cluster.local:9115"}
  - job_name: blackbox-probes-any
    metrics_path: /probe
    params: {module: [http_any]}
    static_configs:
      - targets:
          - http://adguard-web.adguard.svc.cluster.local:3000/
          - http://cp-reserva-bot.cp-reserva-bot.svc.cluster.local:80/
    relabel_configs:   # same three relabel rules as above
      - {source_labels: [__address__], target_label: __param_target}
      - {source_labels: [__param_target], target_label: instance}
      - {target_label: __address__, replacement: "blackbox-exporter.monitoring.svc.cluster.local:9115"}
  - job_name: blackbox-tcp
    metrics_path: /probe
    params: {module: [tcp_connect]}
    static_configs:
      - targets:
          - samba-nas.nas.svc.cluster.local:445
          - immich-pg-rw.homeserver.svc.cluster.local:5432
    relabel_configs:
      - {source_labels: [__address__], target_label: __param_target}
      - {source_labels: [__param_target], target_label: instance}
      - {target_label: __address__, replacement: "blackbox-exporter.monitoring.svc.cluster.local:9115"}
```
`up` for the probe jobs reflects the scrape of the blackbox exporter, not of the application, so `TargetDown` needs no change for them; probe success has its own rules (6.4).
Uses of Tailscale proxies: probes go to Services directly, so they prove the app, not the tailnet path. The proxies are covered by `TailscaleProxyDown` (KSM) in 4.10.

**6.4 `rules-probes.yml`** (add to the `prometheus-rules` generator `files:` list)
```yaml
groups:
  - name: probes
    rules:
      - alert: ProbeFailed
        expr: probe_success{job=~"blackbox-probes|blackbox-probes-any"} == 0
        for: 5m
        labels: {severity: critical}
        annotations: {summary: "{{ $labels.instance }} does not answer (HTTP probe failing for 5 min)"}
      - alert: TcpProbeFailed
        expr: probe_success{job="blackbox-tcp"} == 0
        for: 5m
        labels: {severity: critical}
        annotations: {summary: "{{ $labels.instance }} refuses TCP connections for 5 min"}
      - alert: ProbeSlow
        expr: probe_duration_seconds{job=~"blackbox-probes.*"} > 5
        for: 15m
        labels: {severity: warning}
        annotations: {summary: "{{ $labels.instance }} takes more than 5 s to answer"}
      - alert: MinioDown
        expr: up{job="minio"} == 0
        for: 5m
        labels: {severity: critical}
        annotations: {summary: "MinIO (backup target) metrics are unreachable"}
      - alert: MinioDiskOffline
        expr: minio_cluster_disk_offline_total > 0
        for: 5m
        labels: {severity: critical}
        annotations: {summary: "MinIO reports an offline disk"}
```
`minio_cluster_disk_offline_total` is [UNVERIFIED]: check on the target (`curl` from the operator's port-forward: `/graph` query `{job="minio"}` lists the real names). If the name is absent, delete that one rule and report.
`kustomization.yaml`: change the `prometheus-rules` generator to `files: [rules-core.yml, rules-probes.yml]`.
`promtool check rules` again (4.12 step 3) -> success.

**6.5 Verify.** After sync: targets `blackbox-*` UP; Graph `probe_success` -> value 1 for every instance; any 0 is a real finding or a wrong path: fix the path, not the alert. `http://localhost:9090/rules` shows group `probes` without errors.
**6.6 Rollback.** Revert; remove from `prometheus.yml`. **PR** `feat: monitoring probes and MinIO metrics` (two PRs as said), description with the `[UNVERIFIED]` paths confirmed. STOP.

### WP7. Disk SMART (optional; do only if the operator says yes)

Goal: SMART health for the physical disks. Preconditions: WP4 verified; the operator approved. Branch `feat/monitoring-smart`.
1. Files: `talos/manifests/monitoring/smartctl-exporter.yaml`. A DaemonSet like 4.6: `tolerations: [{operator: Exists}]`, `hostPID: false`, the container runs `privileged: true` and `runAsUser: 0` (the README example requires privileged and root [verified https://github.com/prometheus-community/smartctl_exporter/blob/master/README.md]; there is no smaller privilege set that I could verify), image `docker.io/prometheuscommunity/smartctl-exporter:v0.15.0@sha256:<DIGEST>` (see the image-name note in 3.1), port 9633, `readOnlyRootFilesystem: true`, `resources` requests 10m/24Mi limits 100m/64Mi, mounts `/dev` from hostPath `/dev` (read-only is not enough for ioctl: leave it default read-write; document it), label `app.kubernetes.io/name: smartctl-exporter`.
2. `prometheus.yml`: job `smartctl` with `kubernetes_sd_configs` role `pod` in namespace `monitoring`, keep label `app.kubernetes.io/name=smartctl-exporter`, relabel `__meta_kubernetes_pod_node_name` to `node`, port 9633 (declare `containerPort: 9633` named `metrics` in the DaemonSet and keep on port name `metrics` plus label match).
3. `rules-smart.yml` (add to the generator):
```yaml
groups:
  - name: smart
    rules:
      - alert: DiskSmartFailing
        expr: smartctl_device_smart_status == 0
        for: 5m
        labels: {severity: critical}
        annotations: {summary: "SMART overall health FAILED on a disk of {{ $labels.node }} (device {{ $labels.device }})"}
      - alert: DiskTemperatureHigh
        expr: smartctl_device_temperature > 60
        for: 15m
        labels: {severity: warning}
        annotations: {summary: "A disk of {{ $labels.node }} is above 60 C"}
      - alert: DiskReallocatedSectors
        expr: smartctl_device_attribute{attribute_name="Reallocated_Sector_Ct", attribute_value_type="raw"} > 0
        for: 1h
        labels: {severity: warning}
        annotations: {summary: "A disk of {{ $labels.node }} has reallocated sectors: plan a replacement"}
```
The metric names `smartctl_device_smart_status`, `smartctl_device_temperature`, `smartctl_device_attribute` are [UNVERIFIED]: the README fetched did not list them. After the pod runs, the operator's `/graph` for `{job="smartctl"}` shows the real names; fix the rules to the real ones.
4. **STOP conditions**: if after sync `{job="smartctl"}` returns no `smartctl_*` series for mini01 or mini02 (USB bridge, controller hides SMART) report exactly that and propose removing the app (a revert), do not try other privileges. Whether it works on these disks is the thing being tested.
5. Namespace note: this is the only privileged container; reason recorded in the PR. **PR** `feat: SMART disk health (optional)`.

### WP8. Alert delivery test and the dead-man's switch (The operator performs; executor writes the instructions in the PR)

Preconditions: WP4 verified; D1, D4. Branch: none needed (the test is made by the operator from his terminal, no repo change), except the optional rule below.

Copy-paste list for the operator:
1. Send a manual test alert to Alertmanager (this is not a cluster change; it is an HTTP call through a port-forward):
```bash
kubectl --context admin@<cluster> -n monitoring port-forward svc/alertmanager 9093:9093 &
sleep 3
curl -s -XPOST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d \
 '[{"labels":{"alertname":"TestAlert","severity":"critical","instance":"manual-test"},"annotations":{"summary":"Manual test of the alert path"}}]'
```
   Expected: within about 1 minute (`group_wait` 30 s) a message `[FIRING] TestAlert (critical)` arrives on the phone. After 5 minutes without resending the alert expires and `[RESOLVED]` arrives. Then `kill %1`.
2. Dead-man's switch: at the heartbeat service set the check's period to 10 minutes, its grace to 10 minutes, and its notification channel to the same phone. Within 10 minutes of the sync the service must show pings arriving every 5 minutes (status "up").
3. Real fire drill (optional, the operator's choice, outside the repo): he stops the heartbeat by deleting the Argo app `monitoring` for 20 minutes in the Argo UI; the service must alert him; re-sync the app afterwards.

What the dead-man's switch covers: Prometheus down, Alertmanager down, mini02 down, the notification secret broken (Watchdog uses a different receiver and a different secret key, so a broken Telegram token does not stop the heartbeat; the heartbeat service notifies on its own channel). What it does not cover: the whole homelab network or the internet connection being down (the heartbeat cannot be sent; the service pages, which is the desired result), and Telegram being down (use two channels at the heartbeat service if the operator wants).

Optional extra rule (add to `rules-core.yml` in a small PR `feat/monitoring-selfwatch`): none needed; `PrometheusAlertmanagerUnreachable`, `PrometheusNotificationsFailing`, `TargetDown` for jobs `prometheus`, `alertmanager` already watch the stack from inside, and the heartbeat watches from outside.

### WP9. Authentik OIDC for Grafana (optional, only when Authentik runs; D3)

Preconditions `[ASSUMED]`: Authentik in namespace `authentik`, reachable at an in-cluster Service `authentik-server` port 80 `[ASSUMED]` and on the tailnet at a URL the operator knows; the Authentik plan defines how an OAuth2/OIDC provider is created. Do not start until the Authentik plan reports done and the operator answers D3.
1. The operator, in the Authentik UI: create an OAuth2/OpenID provider and an application "Grafana" with redirect URI `<GF_SERVER_ROOT_URL>/login/generic_oauth` and scopes `openid profile email`; copy the client id and secret. `[UNVERIFIED]`: confirm the Grafana generic OAuth setting names in https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/#auth-genericoauth before use.
2. The operator seals Secret `monitoring/grafana-oidc` with keys: `GF_AUTH_GENERIC_OAUTH_CLIENT_ID`, `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET`, `GF_AUTH_GENERIC_OAUTH_AUTH_URL`, `GF_AUTH_GENERIC_OAUTH_TOKEN_URL`, `GF_AUTH_GENERIC_OAUTH_API_URL` (the three URLs contain the full tailnet name, so they are sealed too), using the WP3 recipe with the new name; file `talos/sealed-secrets/grafana-oidc.yaml`; list in the kustomization.
3. Edit the Grafana Deployment: add `envFrom: [{secretRef: {name: grafana-oidc}}]` and env `GF_AUTH_GENERIC_OAUTH_ENABLED=true`, `GF_AUTH_GENERIC_OAUTH_NAME=Authentik`, `GF_AUTH_GENERIC_OAUTH_SCOPES=openid profile email`, `GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP=true`, `GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=contains(groups[*], 'Grafana Admins') && 'Admin' || 'Viewer'` (group name is the operator's choice in Authentik). Keep the local admin login enabled as break-glass.
4. Verify: login page shows "Sign in with Authentik"; local admin still works. Rollback: remove the env vars. **PR** `feat: Grafana login through Authentik`.

### WP10. When `mini03` exists

Nothing to change for node-exporter (`tolerations: Exists`; it appears automatically). Check `up{job="node"}` has a third series. Add `mini03`'s disks to the SMART WP if it has physical disks (it has virtual ones: skip). If the operator wants Prometheus there (D5) change `nodeSelector` to `kubernetes.io/hostname: mini03`, remove the toleration, and note that its PVC will start empty (history is lost; accept or migrate manually).

## 8. Backup and restore

| Data | Covered by | Not covered |
|---|---|---|
| All manifests, rules, dashboards, data source, Alertmanager routes | git (this repository) | n/a |
| Secrets | sealed in git; plaintext values in the operator's Vaultwarden | the live Secret objects are not backed up separately; they are re-created from the sealed files |
| Grafana SQLite (`grafana-data`: users, preferences, API keys if any) | **nothing by default** (D7). Everything that matters is in git; losing it means re-creating the admin user from the sealed Secret and re-doing personal preferences | optional: D7 yes -> add namespace `monitoring` to the Velero schedule and annotate the Grafana pod `backup.velero.io/backup-volumes: data` (opt-in file-system backup, same mechanism as Immich and Vaultwarden [repo]) |
| Prometheus TSDB (`prometheus-data`) | nothing, on purpose: metrics are disposable (30 days) | history is lost if the PVC is lost |
| Alertmanager silences (`alertmanager-data`) | nothing | silences are lost; they are short-lived |

**Restore test (the executor writes this into the WP5 PR description; the operator performs it; tests the "everything in git" claim):**
1. The operator notes the dashboards visible in Grafana and the list of Prometheus targets.
2. The test is done through a PR, never by hand on live objects: `feat/monitoring-restore-test` changes the Grafana PVC name to `grafana-data-2` (and the volume reference), merged and synced; Grafana starts with a fresh database.
3. Expected: login with the sealed admin password works (the password is applied on first DB creation [verified]), the data source `Prometheus` and the 4 dashboards are present (provisioned), Prometheus data untouched.
4. Revert that PR (the old PVC still exists as `Retain` data). Record the result in the report.
For Prometheus: the equivalent test is the same with `prometheus-data-2`; expected: an empty TSDB that fills within minutes; alerts need up to the longest `for` period (36 h for `VeleroBackupMetricMissing`) before the history-dependent ones behave: acceptable.

## 9. Security

- **Exposure**: only Grafana, on the tailnet (Ingress class `tailscale`). Prometheus, Alertmanager, kube-state-metrics, blackbox and node-exporter have ClusterIP Services only, no auth, reachable from any pod in the cluster (there are no NetworkPolicies in this cluster [repo: none found]; adding them is out of scope, Q6). Nothing is public.
- **Authentication**: Grafana local admin with a sealed 24-byte random password, sign-up and anonymous access off; OIDC later (WP9). Prometheus' Web UI has no login: reached only by `port-forward` by the operator.
- **Least privilege**: Prometheus ServiceAccount is read-only (nodes, pods, services, endpoints, `nodes/proxy`, `/metrics`); kube-state-metrics list/watch only on nine resource kinds, **no Secrets, no ConfigMaps**; node-exporter, blackbox, Grafana, Alertmanager have `automountServiceAccountToken: false`. `nodes/proxy` is a powerful permission (it can reach kubelet APIs); it is needed because the kubelet certificates are self-signed. Accepted trade-off, noted for the operator; the alternative is rotating kubelet serving certificates (`talos/apps-src/metrics-server.yaml` mentions it as a follow-up).
- **Pod security**: namespace `privileged` (needed by node-exporter: hostPath `/proc`, `/sys`, `/`, hostPID; and by optional smartctl-exporter). Every container: `allowPrivilegeEscalation: false`, capabilities dropped (ALL), `readOnlyRootFilesystem: true`, `runAsNonRoot` (except smartctl-exporter, optional), `seccompProfile: RuntimeDefault`. node-exporter exposes hostPath read-only; it can read the whole node filesystem but cannot write.
- **Secrets**: notification token and heartbeat URL are files from a sealed Secret, never in ConfigMaps or env of the Alertmanager; Grafana password is an env var from a Secret.
- **Information leakage**: alert texts go to Telegram/ntfy and contain service and node names, no secrets. Do not put IPs or the tailnet name in alert summaries (the rules above do not).
- **Cardinality guard**: `metric_relabel_configs` on cAdvisor and apiserver, 7 GB TSDB cap, 768 Mi memory limit: a runaway exporter kills only Prometheus.

## 10. Operations

**Upgrade (all components)**: a PR that changes the image tag and digest in the manifest (one component per PR, read the project's release notes first: Prometheus v3 minors, Grafana major versions can change provisioning and dashboard JSON); `kustomize build`, `promtool check config/rules` (4.12 step 3), guards; the operator merges and syncs `monitoring`; watch the pod. Rollback: revert the PR. If a Grafana major upgrade fails to migrate its database, use the restore procedure in section 8 (everything that matters is in git).
**Dashboards**: to update one, re-download its revision (5.4), repeat the fix script, commit. To add one, add a file, a generator entry and a `projected` source; keep each file under 1 MiB.
**Rules**: edit `rules-*.yml`, `promtool check rules`, PR, sync; the hashed ConfigMap rolls Prometheus (about 30-60 s gap in scraping).
**Health checks**: `kubectl --context admin@<cluster> -n monitoring get pods`; `kubectl --context admin@<cluster> -n monitoring logs deploy/prometheus --tail=50`; the heartbeat service dashboard; Prometheus self-metrics (`prometheus_*`) can be queried in Grafana Explore.
**Resource watch**: `kubectl --context admin@<cluster> top pods -n monitoring`; compare with the table in section 4: Prometheus > 600 Mi or `prometheus_tsdb_head_series` > 80 000 means too many series: tighten relabelling. TSDB size: `prometheus_tsdb_storage_blocks_bytes`.
**Adding a new service to monitoring** (for later plans): (a) HTTP service: add its Service URL to the right `blackbox-probes` list; (b) app with a metrics port: annotate the Pod template `prometheus.io/scrape: "true"`, `prometheus.io/port: "<port>"`, `prometheus.io/path: "/metrics"` (the `annotated-pods` job picks it up, as Velero already does); (c) database: CNPG pods are discovered automatically by `cnpg-instances`.

**Troubleshooting**

| Symptom | Where to look | Likely cause | Fix |
|---|---|---|---|
| Pod `Pending` in `monitoring` | `kubectl -n monitoring describe pod <name>` Events | on mini02 without the toleration, or PVC `WaitForFirstConsumer` on a node without the path | add the toleration (4.3/4.7); PVC binds when the pod schedules |
| `node-exporter` DaemonSet rejected with `violates PodSecurity` | `kubectl -n monitoring get events` | namespace lacks the `privileged` label (WP2 not synced) | sync `namespaces` first |
| Prometheus `CrashLoopBackOff`, logs `permission denied` on `/prometheus` | `kubectl -n monitoring logs deploy/prometheus` | local-path directory owned by root, `fsGroup` ignored | add an init container `busybox` running `chown 65534:65534 /prometheus` as root (same pattern as `talos/manifests/backup-target/minio.yaml`), report |
| Prometheus OOMKilled | `describe pod`, `PodOOMKilled` alert | series explosion | check `prometheus_tsdb_head_series`; add `metric_relabel_configs`; only then raise the limit |
| All `kubelet`/`cadvisor` targets `403` | `/targets` error text | missing `nodes/proxy` in the ClusterRole | check 4.2 was applied exactly |
| `kubelet` targets `x509` errors | `/targets` | the job tries a direct kubelet address | the job must use `kubernetes.default.svc.cluster.local:443` (4.4) |
| `argocd` job has no targets | `/targets`, service discovery page | container ports not declared in the pod spec | report (WP1 step 5); do not add Services here |
| `node_zfs_*` missing | query `node_zfs_zpool_state` | collector sees no pool (no `/proc/spl` in the mount) | section 3.3 fallback; report to the operator |
| `node_filesystem_*` missing | node-exporter logs | non-root user cannot read `/proc/1/mountinfo` | set `runAsUser: 0` on node-exporter (keep other hardening) |
| No message on the phone | `kubectl -n monitoring logs deploy/alertmanager`; `Notify attempt failed` | wrong token or chat id; the bot has no message from the operator yet; D1 receiver typo | fix the Secret (re-seal) or `chat_id`; send the bot a message first |
| Heartbeat service says "down" but all pods Running | Alertmanager logs for `deadman` | wrong URL key, or `repeat_interval` > grace period | check key `deadman-url`, grace >= 10 min |
| Grafana shows "No data" | Explore, data source test | data source URL wrong or Prometheus down | `http://prometheus.monitoring.svc.cluster.local:9090` |
| Grafana links go to the wrong host | page URL | `GF_SERVER_ROOT_URL` differs from the real tailnet name (stale device `grafana-1`) | re-seal with the real URL |
| Alert flood after maintenance | Alertmanager UI | planned downtime | The operator silences in the Alertmanager UI via port-forward (silences are not git) |
| `VeleroBackupTooOld` firing but backups exist | Velero logs; `velero_backup_last_successful_timestamp` | Velero schedule label differs from the rule's names | fix the regex in 4.10 to the real names from WP1 step 6 |

## 11. Acceptance checklist and report format

**The operator should see, at the end:**

- [ ] `https://grafana.<tailnet-name>.ts.net` opens on his phone/laptop on the tailnet; admin login works; 4 dashboards with data.
- [ ] Prometheus `/targets` is green (after the expected-down list: none once WP5 and WP6 are synced; optional `smartctl` only if WP7 is done).
- [ ] Prometheus `/rules` shows the groups `meta nodes storage workloads backups gitops-and-certs probes` (and `smart`) all healthy.
- [ ] A test alert arrives on the phone and resolves (WP8).
- [ ] The heartbeat check is green at the service and a fire drill pages him (WP8, optional drill).
- [ ] `PodStuckPending` for `zfs-scrub` was seen (a real finding) and the operator has decided what to do about the CronJob toleration (separate PR).
- [ ] Alerts exist and are `inactive` for: Velero backup older than 36 h, Velero last status failed, ZFS pool not online, scrub failed, CNPG down, probe failed, PVC over 85%, node memory over 90%.
- [ ] `kubectl --context admin@<cluster> top nodes` after one day: mini01 memory up by about 300 Mi or less; mini02 by about 500 Mi or less.
- [ ] Guards 20 `OK` on `main`.

**Report format after every WP** (the executor writes exactly this):
```
WP<n>: done | blocked | needs decision
PR: <url or none>
Guards: 20 OK | <failures>
Verified: <commands run and results; quote the expected-vs-actual for each verification step>
Differences from the plan: <anything that did not match, with the evidence>
Needs from the operator: <decisions, sealing steps, digests, syncs>
```

## 12. Open questions and UNVERIFIED items

**Findings for the operator (not part of this plan's PRs).**
1. The live `zfs-scrub` Job pod is `Pending` for hours: `talos/storage/zfs-scrub/zfs-scrub-cronjob.yaml` has `nodeSelector kubernetes.io/hostname: mini02` but no toleration for the cordon taint `node.kubernetes.io/unschedulable`, so the scrub can never run (the sibling `samba-nas` and `minio` pods have it). A one-file PR adds the toleration; monitoring will alert on it until then. Not fixed here (one file, one concern).
2. Dependency note: the brief says Velero covers namespace `homeserver`; the live cluster also has `velero-cp-reserva-bot-nightly` (namespace `cp-reserva-bot`) and the repo's Talos values override only `homeserver-nightly` (daily). The 36 h alert covers both.

**UNVERIFIED items and how to confirm each.**

| # | Item | Confirm by |
|---|---|---|
| U1 | Quay/Docker registry paths and tags of prometheus, alertmanager, node-exporter, blackbox, KSM, Grafana, smartctl-exporter | `skopeo inspect` / `crane digest` (section 3.1); wrong name -> STOP |
| U2 | `node_zfs_zpool_state` exists with the Talos ZFS extension | step 4.13 query |
| U3 | node-exporter reads Talos hostPath mounts and runs as uid 65534 | step 4.13 `node_filesystem_*` |
| U4 | kubelet PVC stats for local-path volumes | step 4.13 `kubelet_volume_stats_*` |
| U5 | ZFS dataset quotas appear as filesystem sizes | step 4.13 |
| U6 | KSM resource label for the Intel GPU (`gpu_intel_com_i915`) | step 4.13 |
| U7 | Health paths of Jellyfin, Immich, Vaultwarden, AdGuard, cp-reserva-bot | each app's docs; else `http_any` on `/` |
| U8 | MinIO metrics path, env var `MINIO_PROMETHEUS_AUTH_TYPE`, metric `minio_cluster_disk_offline_total` | https://docs.min.io/enterprise/aistor-object-store/operations/monitoring/metrics-and-alerts/ and the live endpoint |
| U9 | `cert-manager` metric names | `/graph` after WP4 (no Certificates exist, so likely empty) |
| U10 | `grafana cli admin reset-admin-password --password-from-stdin` flag; `GF_ALERTING_ENABLED` accepted | `--help` in the Grafana pod; container logs |
| U11 | smartctl-exporter metric names and whether SMART is readable on these disks | WP7 |
| U12 | Official Talos metrics endpoint (apid/machined) | WP1 step 12 against https://docs.siderolabs.com/talos; none was found |
| U13 | kube-controller-manager/scheduler/etcd metrics reachability | not in v1; needs a Talos config decision (Q3) |
| U14 | `--no-collector.thermal_zone` flag exists in node-exporter v1.12.1 | pod logs; remove the flag if rejected |
| U15 | Resource figures for the stack comparison (kube-prometheus-stack 1.2 to 1.8 GiB, VictoriaMetrics savings) are estimates | `prometheus_tsdb_head_series` and `top` after WP4 |
| U16 | ntfy access tokens / self-hosted details | https://docs.ntfy.sh/ (only if D1 = ntfy) |
| U17 | Authentik service name/port and Grafana OAuth setting names | the Authentik plan and the Grafana config doc (WP9) |

**Open questions for the operator.** Q1: Is the Prometheus default (mini02, spinning disk) acceptable, or should the TSDB live on a faster disk later (D5)? Q2: Do you want host network interface graphs (needs `hostNetwork: true` for node-exporter, which exposes port 9100 on every node address)? Default no. Q3: Do you want control-plane component metrics (scheduler, controller-manager, etcd)? It needs a Talos machine-config change (`bind-address` extra args) and a node config apply, which is outside this plan. Q4: The tailnet HTTPS certificates (managed by Tailscale) cannot be monitored from inside the cluster; accept. Q5: PVC fullness for local-path volumes may rely on node filesystem alerts only (U4). Q6: Add NetworkPolicies later? Q7: Should Homepage show monitoring status (needs an Alertmanager or Grafana API read-only token `[ASSUMED]`)? Q8: Intel GPU utilisation graphs need a privileged exporter; yes or no later?
