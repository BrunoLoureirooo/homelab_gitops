# Implementation plan: Paperless-ngx (document management with OCR)

Status: plan only, nothing is deployed. Written 2026-10-25 for a local-LLM executor working under the operator's
supervision. Follow it literally. Where it says STOP, stop and report.

Marker legend: `[verified <url>]` = read in the project's official documentation or release data on
2026-10-25. `[UNVERIFIED]` = could not be confirmed; the plan says how to confirm. `[ASSUMED]` = an interface
owned by another plan that this plan cannot read.

## 0. Purpose, scope, non-goals, definition of done

Purpose: run Paperless-ngx in namespace `paperless` so the operator can scan or photograph paper, drop the file in a
network folder (or upload in the web UI), and get OCR'd, searchable, tagged documents, reachable on the
tailnet only.

In scope:
- Namespace `paperless` with Pod Security `baseline` (cluster default; see section 9).
- Paperless webserver (one Deployment), Valkey broker, a CNPG PostgreSQL cluster `paperless-pg`.
- Originals, consume folder and exporter output on the NAS (SMB), search index and data on a `topolvm-fast` PVC.
- Tailnet Ingress, sealed Secret, CNPG backups to MinIO, a Velero schedule for the PVC, a `document_exporter`
  CronJob, a restore test.
- Optional (decision D2): Apache Tika and Gotenberg for Office documents and emails.
- Later, separate work package (decision D8): single sign-on with Authentik.

Out of scope (non-goals): changing the Samba pod (that is `docs/plans/nas-completion.md`), creating the
`authentik` namespace, the second-copy backup on `mini03`, exposing the NAS share on the tailnet, mail
ingestion rules (IMAP) beyond what is written in D5, running anything on `mini02`.

Definition of done (every box must be true):
- [ ] `docs/plans/paperless.md` decisions D1 to D9 are answered by the operator and recorded in the PR.
- [ ] Argo app `paperless` is Synced and Healthy; pods `paperless-web`, `paperless-broker`, `paperless-pg-1` Ready.
- [ ] the operator logs in at `https://paperless.<tailnet-name>` and is NOT asked to accept a certificate warning.
- [ ] A PDF dropped in the consume share appears as a processed document within 5 minutes with searchable text.
- [ ] A PDF uploaded through the web UI is processed.
- [ ] CNPG `ScheduledBackup` has a `Completed` backup; the bucket `paperless-pg` has objects.
- [ ] The exporter CronJob ran once and the backups share holds `manifest.json`.
- [ ] A Velero backup of namespace `paperless` contains a `Completed` PodVolumeBackup for volume `data`.
- [ ] The restore test (section 8) passed once.
- [ ] All 20 guards print OK on every PR.

## 1. Rules for the executor

1. PR-only. Never push to `main`, never force-push, never merge, never delete a branch. Every PR is a DRAFT.
   the operator merges and syncs Argo apps himself in the Argo web UI.
2. The cluster is read-only for you. Allowed: `get`, `describe`, `logs`, `top`, always with
   `--context admin@<cluster>`. Forbidden: `apply`, `patch`, `edit`, `delete`, `create`, `exec`, `scale`,
   `rollout`, `port-forward` with writes. (`exec` and `create` that the operator must run are listed in his
   copy-paste lists; you never run them.)
3. Never print or decode secret values. Never run `get secret -o yaml|json|jsonpath`. `describe secret` shows
   key names only and is allowed.
4. No secret values, tokens or passwords in any file, PR text, commit message or report. Use placeholders.
5. No host details in committed files: no IPv4 addresses or CIDRs, no MAC addresses, no disk serials or
   `/dev/disk/by-id` names, no host name that ends with the tailnet domain. Write `<tailnet-name>` and
   `<node-ip>`. The guard `.github/scripts/check-no-host-details.sh` rejects them. Ciphertext inside a
   SealedSecret is allowed.
6. One concern per PR. The work packages (WP) below are one PR each. Branch from `origin/main`:
   `git fetch origin && git switch -c <branch> origin/main`.
7. Before every commit run `bash .github/scripts/run-all-guards.sh`. All 20 must be OK. Never edit a guard to
   make it pass; if a guard fails on your file, fix your file, and if you cannot, STOP.
8. Commit message ends with the line `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. PR
   description ends with the line `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
9. Never decide a the operator decision. Section 5 lists them. If a package depends on an unanswered decision, STOP
   at that package and report `needs decision`.
10. Never use the tag `latest`. Pin every image by tag AND digest (`image: repo:tag@sha256:...`).
11. Every PVC sets `storageClassName: topolvm-fast` (the only class; not the default, so a missing class
    leaves the claim Pending forever). Every container sets explicit `resources` requests and limits.
12. STOP conditions (stop and report, change nothing further): a guard fails and you cannot fix it by editing
    your own file; a read-only check in section 2 fails and its "if not" instruction says STOP; the output
    of any command differs from "expected" in a way the plan does not explain; you are about to need a
    secret value; an image tag or setting marked `[UNVERIFIED]` cannot be confirmed; `mini01` memory is
    above 85 percent in `kubectl top nodes`.
13. If the repo contradicts this plan, trust the repo, change your file accordingly and list the difference
    in your report under "Differences from the plan".

## 2. Prerequisites and dependencies

Run each check from the repo root. "Expected" is what must appear.

| # | Needs | Read-only proof | If not ready |
|---|---|---|---|
| P1 | Argo CD works | `kubectl --context admin@<cluster> -n argocd get applications.argoproj.io` lists apps | STOP |
| P2 | CNPG operator installed | `kubectl --context admin@<cluster> get crd clusters.postgresql.cnpg.io` prints the CRD; `kubectl --context admin@<cluster> -n cnpg-system get pods` shows a Running controller | STOP; the operator syncs app `cnpg-operator` first |
| P3 | csi-driver-smb installed | `kubectl --context admin@<cluster> get csidriver smb.csi.k8s.io` prints a row | STOP; the operator syncs app `csi-driver-smb` |
| P4 | Samba NAS pod running, share `paperless` and `backups` exist | `kubectl --context admin@<cluster> -n nas get pods` shows `samba-nas` Running; `grep -n "paperless\|backups" talos/manifests/samba-nas/deployment.yaml` shows both `SAMBA_VOLUME_CONFIG_` lines | STOP |
| P5 | SMB credentials Secret for CSI exists | `kubectl --context admin@<cluster> -n nas describe secret smb-csi-credentials` shows keys `username` and `password` | STOP |
| P6 | Tailscale operator works | `kubectl --context admin@<cluster> -n tailscale get pods` Running; `kubectl --context admin@<cluster> get ingressclass tailscale` prints a row | STOP |
| P7 | MinIO backup target reachable by service name | `kubectl --context admin@<cluster> -n velero get svc velero-backup-target` prints a row | STOP |
| P8 | A MinIO bucket `paperless-pg` with its own scoped user exists | Cannot be read from the cluster. It is the operator step B1 in WP2. | WP2 waits for B1 |
| P9 | Sealing tools | The operator has `kubeseal` and `jq`; the certificate `argocd/sealed-secrets/pub-cert.pem` exists (`ls argocd/sealed-secrets/pub-cert.pem`) | STOP |
| P10 | Capacity | `kubectl --context admin@<cluster> top nodes` | see section 4; STOP if mini01 memory is above 85 percent |
| P11 | `mini03` (only if decision D4 = mini03) | `kubectl --context admin@<cluster> get node mini03` shows Ready. [ASSUMED] plan `mini03-vm` delivers it | D4 stays on `mini01` |
| P12 | Authentik (only WP7) | `kubectl --context admin@<cluster> -n authentik get pods` Running [ASSUMED namespace `authentik`, in-cluster Service `authentik-server`, port 80, see WP7] | skip WP7 |
| P13 | Per-share Samba accounts (only if decision D3 = separate) | `nas-completion.md` WP4 is merged and synced. [ASSUMED] new Secret `smb-csi-credentials-paperless` in namespace `nas`, keys `username`, `password` | use D3 = shared |
| P14 | Tools on the executor machine | `yq --version` (mikefarah v4), `kubectl kustomize --help`, `curl`, `jq` | install or STOP |

What depends on this service: Authentik SSO is optional and configured here in WP7 (it only reads Authentik).
Nothing else depends on Paperless. Related: the `backup-replica` plan [ASSUMED] may copy the `backups` share
off the pool; this plan only writes the export to that share.

## 3. Facts about this service

All from the official Paperless-ngx sources, read 2026-10-25.

### 3.1 Images and versions

| Component | Image | Version to use | Source |
|---|---|---|---|
| Paperless-ngx | `ghcr.io/paperless-ngx/paperless-ngx` | newest stable release was `v3.3.4` (2026-10-22); the container tag has no leading `v`, so use `3.3.4` [UNVERIFIED tag form: confirm with the registry query below] | [verified https://api.github.com/repos/paperless-ngx/paperless-ngx/releases] |
| Broker | `docker.io/valkey/valkey` | the official compose file uses the floating tag `9-alpine`; pin a concrete `9.x.y-alpine` tag [UNVERIFIED which] | [verified https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/dev/docker/compose/docker-compose.postgres.yml] |
| Database | CNPG-managed PostgreSQL (the official compose uses `postgres:18`) | use the CNPG default image of the installed operator, major 17 or 18 [UNVERIFIED: confirm Paperless 3.3.x supports your chosen major in `docs/setup.md` "Requirements"] | same compose file |
| Tika (optional) | `docker.io/apache/tika` | pin a concrete tag [UNVERIFIED which] | official compose `docker-compose.postgres-tika.yml` [UNVERIFIED: file name, confirm in the repo folder `docker/compose/`] |
| Gotenberg (optional) | `docker.io/gotenberg/gotenberg` | pin a concrete `8.x` tag [UNVERIFIED which] | same |

Getting the digest (a read-only registry query; the template script resolves only `ghcr.io`):
- For `ghcr.io/paperless-ngx/paperless-ngx:3.3.4` the script `docs/templates/ghcr-app/new-app.sh` resolves it;
  for a manual query use
  `curl -sI -H "Authorization: Bearer $(curl -s 'https://ghcr.io/token?scope=repository:paperless-ngx/paperless-ngx:pull' | jq -r .token)" -H 'Accept: application/vnd.oci.image.index.v1+json' https://ghcr.io/v2/paperless-ngx/paperless-ngx/manifests/3.3.4 | grep -i docker-content-digest`.
  If that prints nothing, ask the operator (WP1 step 3 puts it on his list).
- For Docker Hub images: `crane digest docker.io/valkey/valkey:<tag>` or
  `skopeo inspect --format '{{.Digest}}' docker://docker.io/valkey/valkey:<tag>`. If neither tool exists,
  put it on the operator's list. Never guess a digest, never leave one out.
- The digest must be the multi-arch index digest (the node is amd64; the index digest also works).

### 3.2 Ports, paths, health

- Webserver listens on port 8000 (the official compose publishes 8000) [verified compose file above].
- Container paths [verified compose file]: `/usr/src/paperless/data` (search index, classifier model, logs),
  `/usr/src/paperless/media` (originals, archive PDFs, thumbnails), `/usr/src/paperless/consume` (inbox),
  `/usr/src/paperless/export` (target for the exporter).
- Broker mount `/data`. Valkey speaks the Redis protocol on 6379.
- Health: the official docs content read mentions no dedicated health endpoint. Probes use HTTP GET `/` on
  port 8000, which answers 200 or a redirect to the login page [UNVERIFIED: confirm with
  `kubectl logs` after the first start that `/` returns a status below 400].
- The container starts as root under s6-overlay, then runs the application as a user whose ids come from
  `USERMAP_UID` / `USERMAP_GID` (both default 1000) [verified https://docs.paperless-ngx.com/configuration/
  via the raw file https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/dev/docs/configuration.md].

### 3.3 Environment variables used by this plan

All [verified https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/dev/docs/configuration.md]:

| Variable | Meaning here |
|---|---|
| `PAPERLESS_SECRET_KEY` | Required, no default; Paperless will not start without it. Signs sessions and sensitive data. |
| `PAPERLESS_URL` | Public URL, no trailing slash and no path. Feeds `PAPERLESS_ALLOWED_HOSTS`, `PAPERLESS_CORS_ALLOWED_HOSTS` and `PAPERLESS_CSRF_TRUSTED_ORIGINS`, so this single value covers all three. |
| `PAPERLESS_ADMIN_USER`, `PAPERLESS_ADMIN_PASSWORD`, `PAPERLESS_ADMIN_MAIL` | At startup creates a superuser; needs both user and password; does not change the password of or recreate an existing user. Mail default `root@localhost`. |
| `PAPERLESS_DBHOST`, `PAPERLESS_DBPORT`, `PAPERLESS_DBNAME`, `PAPERLESS_DBUSER`, `PAPERLESS_DBPASS` | PostgreSQL connection. The engine variable `PAPERLESS_DBENGINE` appears in the official compose [verified]; the value for PostgreSQL is `postgresql` [UNVERIFIED: confirm in configuration.md "PAPERLESS_DBENGINE"; Paperless picks PostgreSQL when `PAPERLESS_DBHOST` is set in v2, v3 uses the engine variable]. |
| `PAPERLESS_DB_OPTIONS` | v3 replacement for `PAPERLESS_DBSSLMODE` (removed in v3). Not needed in-cluster. |
| `PAPERLESS_REDIS` | Broker URL, default `redis://localhost:6379`. |
| `PAPERLESS_OCR_LANGUAGE` | Tesseract codes joined with `+`, for example `por+eng`; default `eng`. |
| `PAPERLESS_OCR_LANGUAGES` | Docker only: space-separated extra language packages to install at start (needs internet from the pod; adds start time). |
| `PAPERLESS_OCR_MODE` | `auto` (default) skips pages that already have text. |
| `PAPERLESS_TIKA_ENABLED`, `PAPERLESS_TIKA_ENDPOINT`, `PAPERLESS_TIKA_GOTENBERG_ENDPOINT` | Office and email support, default off. |
| `PAPERLESS_CONSUMER_POLLING_INTERVAL` | The documented name (not `PAPERLESS_CONSUMER_POLLING`). `0` = filesystem notifications; a positive number = poll every N seconds, "useful for NFS or SMB". SMB needs polling. |
| `PAPERLESS_CONSUMER_RECURSIVE` | Also watch subfolders; default false. |
| `PAPERLESS_CONSUMER_DELETE_DUPLICATES` | Delete files in the consume folder whose content already exists; default false. |
| `PAPERLESS_DATA_DIR`, `PAPERLESS_MEDIA_ROOT`, `PAPERLESS_CONSUMPTION_DIR` | Paths; the image already points them at the mounts above, so leave unset. |
| `PAPERLESS_TASK_WORKERS` (default 1), `PAPERLESS_THREADS_PER_WORKER` (default `max(floor(cpus / workers), 1)`), `PAPERLESS_WEBSERVER_WORKERS` (default 1; more = more RAM) | Memory and CPU control. |
| `PAPERLESS_TIME_ZONE` | Default UTC. |
| `PAPERLESS_FILENAME_FORMAT` | Optional naming template, default none. Leave unset. |
| `PAPERLESS_APPS`, `PAPERLESS_SOCIALACCOUNT_PROVIDERS`, `PAPERLESS_DISABLE_REGULAR_LOGIN`, `PAPERLESS_SOCIAL_AUTO_SIGNUP`, `PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS` | SSO (WP7). |
| `PAPERLESS_EMAIL_HOST`, `_PORT`, `_HOST_USER`, `_HOST_PASSWORD`, `_FROM`, `_USE_TLS`, `_USE_SSL` | Outgoing mail (decision D5). |
| `PAPERLESS_ENABLE_HTTP_REMOTE_USER` | Leave false: the proxy must not be trusted to set a user header. |

Variable suffix `_FILE` (read the value from a file): [UNVERIFIED] not confirmed in the pages read. This plan
does not use it; every secret goes through `envFrom` / `secretKeyRef`.

### 3.4 Management commands

[verified https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/dev/docs/administration.md]
- `createsuperuser` (inside the container; Docker form is `docker compose exec webserver createsuperuser`).
- `document_exporter <target>` with flags `-c` (compare checksums), `-d` (delete files in the target that no
  longer belong to the export), `-f` (use the filename format), `-z` (zip), `--no-progress-bar`,
  `--passphrase`, `--data-only`. A second run updates the target and writes only changed files. Never point
  it at a folder holding unrelated files when using `-d`.
- `document_importer <source>`: only into a completely empty installation (database and directories empty);
  the Paperless version should match the export; API tokens are not exported and must be regenerated.
- Docs advice: pause consumption before a backup.

### 3.5 Resource needs

The official pages read give no memory figure [UNVERIFIED]. Practical knowledge: the webserver container
(gunicorn/uvicorn, celery worker, consumer, scheduler in one container) idles near 500 to 800 MiB and OCR of
a multi-page scan can add 500 MiB to 1.5 GiB per task. Section 4 sets limits and says how to measure.

### 3.6 Upgrade and migration notes

Version 3 removed `PAPERLESS_DBSSLMODE` [verified configuration.md]. Exports can only be imported into the same
Paperless version [verified administration.md]. Database migrations run automatically at start. Read the
release notes of every version between the old and the new tag before bumping (section 10).

## 4. Architecture and placement

### 4.1 Capacity (read 2026-10-25 with `kubectl --context admin@<cluster> top nodes`)

```
mini01  740m CPU (18%)  5077Mi memory (45%)   Ready, control-plane (12 GiB RAM, 4 cores)
mini02  125m CPU (3%)   1193Mi memory (16%)   Ready,SchedulingDisabled (cordoned on purpose; 7.6 GiB)
mini03  not in the cluster yet (planned VM on victus: 4 vCPU, 8 GiB)
```

Re-run the command at the start of WP0 and quote the new numbers in the report. mini01 has roughly 6.5 GiB
free, shared with Jellyfin (requests 1 GiB, limit 4 GiB), Immich, Vaultwarden, AdGuard. Paperless adds about
2.5 GiB of requests at most (see 4.4).

### 4.2 Node choice (decision D4, recommended: mini01 now)

- `mini02`: cordoned on purpose, runs the NAS and MinIO. Do not put Paperless there.
- `mini01`: has the free RAM today, is where the CNPG operator pattern (Immich Postgres) already lives, and
  the SMB library mount for Immich is already proven from this node. Recommended default.
- `mini03`: not yet in the cluster; 8 GiB RAM would suit OCR bursts better, but depends on plan `mini03-vm`
  [ASSUMED]. If the operator picks it, every Pod below gets `nodeSelector: kubernetes.io/hostname: mini03` instead
  of `mini01`; the `topolvm-fast` PVCs then live on mini03's disk, and the node agent of Velero must run there.
  The first start of the image downloads nothing at runtime, but `PAPERLESS_OCR_LANGUAGES` does.

Pods are pinned with `nodeSelector` because the `topolvm-fast` volumes are node-local: after the first bind a
claim can only be used on that node.

### 4.3 Diagram

```
 phone / scanner (LAN)                          the operator's browser (tailnet)
        | SMB 445                                      | https://paperless.<tailnet-name>
        v                                              v
 +-----------------+                       +-------------------------+
 | samba-nas (nas) |                       | Tailscale Ingress       |
 | mini02          |                       | class tailscale         |
 | share paperless |                       +------------+------------+
 | share backups   |                                    | :8000
 +--^--------^-----+                                    v
    | SMB     | SMB                  +----------------------------------+      +-------------------+
    | (CSI)   | (CSI)                | Deployment paperless-web         |----->| Valkey broker     |
    |         |                      | mini01, ns paperless             | 6379 | Deployment        |
    |         +--- /export (CronJob) | /consume /media (subPath, SMB)   |      +-------------------+
    +------------- /consume /media   | /data (PVC topolvm-fast)         |
                                     +----------------+-----------------+
                                                      | 5432 (secret paperless-pg-app)
                                                      v
                                     +----------------------------------+      S3 (WAL + base)
                                     | CNPG Cluster paperless-pg        |--------------------> MinIO
                                     | 1 instance, PVC topolvm-fast     |  velero-backup-target.velero
                                     +----------------------------------+  bucket paperless-pg
 CronJob paperless-export (daily): document_exporter -> share backups, folder paperless-export
 Optional: Deployments paperless-tika (9998) and paperless-gotenberg (3000)
```

### 4.4 Resources (requests / limits) and reasoning

| Container | CPU request / limit | Memory request / limit | Reason |
|---|---|---|---|
| paperless-web | 250m / 2 | 1536Mi / 3Gi | OCR bursts; the 3 GiB limit protects Jellyfin and Immich. `PAPERLESS_TASK_WORKERS=1`, `PAPERLESS_THREADS_PER_WORKER=2`, `PAPERLESS_WEBSERVER_WORKERS=1` keep the burst near 2 GiB. If the pod is OOM-killed (`kubectl describe pod` shows `OOMKilled`), raise the limit by 512Mi in a PR; if mini01 cannot afford it, STOP and ask the operator about D4. |
| paperless-pg-1 | 100m / 1 | 256Mi / 512Mi | Few users, small data. |
| paperless-broker | 25m / 200m | 32Mi / 128Mi | Task queue only, no persistence. |
| paperless-export (CronJob) | 100m / 1 | 256Mi / 768Mi | Runs once a day at night. |
| tika (optional) | 100m / 1 | 512Mi / 1Gi | JVM. |
| gotenberg (optional) | 100m / 1 | 512Mi / 1Gi | Headless Chromium. |

Total requests without Tika and Gotenberg: about 1.8 GiB. Total limits about 3.7 GiB, but they rarely coincide.
Tika and Gotenberg add 1 GiB of requests: with mini01 at 45 percent used they fit, but the operator should answer D2.

### 4.5 Storage

| What | Where | Why |
|---|---|---|
| Originals and archive PDFs and thumbnails (`media`) | NAS share `paperless`, folder `media`, through PV `paperless-share-smb` and its claim | Big, grows, on the ZFS mirror. |
| Consume inbox (`consume`) | NAS share `paperless`, folder `consume`, same claim | Scanner and phone drop files here from the LAN. |
| Search index, classifier model, logs (`data`) | PVC `paperless-data`, `topolvm-fast`, 5Gi, RWO | Small, needs POSIX behaviour and speed; rebuildable (`document_index reindex`, [UNVERIFIED] confirm command name in administration.md) but backed up by Velero anyway. |
| Exporter output | NAS share `backups`, folder `paperless-export`, through PV `paperless-backups-smb` | Independent logical copy of documents plus database content. |
| PostgreSQL | CNPG PVC `topolvm-fast`, 5Gi | Database; backed up by CNPG, never by Velero. |

SMB mount options follow `talos/overlays/immich-infra/library-smb.yaml`: `dir_mode=0775`, `file_mode=0664`,
`vers=3.1.1`, `nobrl`, credentials from the sealed `smb-csi-credentials` in namespace `nas`. Difference from
Immich: Immich runs as root (uid/gid 0); Paperless drops to `USERMAP_UID`/`USERMAP_GID`, so the mount presents
every file as uid/gid 1000, which is also the owner of the `paperless` and `backups` directories (the Samba
init container does `chown 1000:1000`, see `talos/manifests/samba-nas/deployment.yaml`) and the Samba account
`homelab` has `UID_homelab=1000`. Files that a scanner writes as `homelab` and files Paperless writes both
therefore look like uid 1000.

Known risk: the image's start scripts try to `chown` the data, media and consume directories. On a CIFS mount
with fixed uid/gid, `chown` fails silently or noisily [UNVERIFIED]. The first start logs show it; a harmless
`chown: Operation not permitted` is acceptable if the web UI works and a test document is stored. A start
that exits is a STOP (see section 10 troubleshooting).

## 5. Decisions for the operator

The executor must STOP at any package that depends on an unanswered decision (dependency in the last column).

| ID | Question | Options and trade-offs | Recommended default | If decided otherwise | Blocks |
|---|---|---|---|---|---|
| D1 | OCR languages (`PAPERLESS_OCR_LANGUAGE`, and `PAPERLESS_OCR_LANGUAGES` for packs not preinstalled) | Give a list, for example Portuguese and English. More languages = slower OCR, more disk, and each extra pack is downloaded at pod start. | `por+eng` [ASSUMED: The operator is Portuguese-speaking; confirm] | Edit `PAPERLESS_OCR_LANGUAGE` and `PAPERLESS_OCR_LANGUAGES` in WP3 deployment | WP3 |
| D2 | Install Tika and Gotenberg (Word, Excel, emails)? | No: PDFs and images only, 1 GiB less RAM, fewer pods. Yes: Office files and `.eml` can be consumed. | No now; add later in a one-PR WP3b (Appendix A). | WP3b | WP3 (flag), WP3b |
| D3 | NAS credential for the CSI mounts and the scanner | A: reuse the single account `homelab` (`smb-csi-credentials`, simplest; scanner has access to every share). B: separate account for the `paperless` and `backups` shares from `nas-completion.md` WP4 (least privilege; needs that plan done first). | A until `nas-completion.md` D3 is decided; switch is one edit later | If B: change `nodeStageSecretRef.name` in both PVs of WP3 to the new Secret [ASSUMED name `smb-csi-credentials-paperless`, namespace `nas`] | WP3 (name of the Secret) |
| D4 | Node | `mini01` (recommended, RAM is free today) or `mini03` (needs the VM, more headroom) | mini01 | replace `mini01` by `mini03` in every nodeSelector; re-check Velero node agent | WP3 |
| D5 | Outgoing mail (password reset, document notifications) | None: no reset by mail; recovery is the command in section 6.6. SMTP: needs a host, port, user, password (a new credential). | None | Add keys `PAPERLESS_EMAIL_HOST_PASSWORD` to the sealed Secret and plain `PAPERLESS_EMAIL_HOST` etc. to the Deployment env | optional WP3c |
| D6 | Where the exporter output must also live | The `backups` share is on the same ZFS pool as the originals (one pool, a mirror protects against one disk, not against pool loss). A copy off the pool needs the `backup-replica` plan [ASSUMED]. | Accept the same pool for now, ask the replica plan to include the share | Add the folder to the replica job | WP5 acceptance |
| D7 | First admin login method | A: sealed `PAPERLESS_ADMIN_USER` / `PAPERLESS_ADMIN_PASSWORD` / `PAPERLESS_ADMIN_MAIL` applied on the first start (simple, but the password stays in a Secret). B: no admin variables; the operator runs `createsuperuser` in the pod once (password never stored in the cluster). | B (The operator runs one command; nothing to rotate) | A: add the three keys in WP2 | WP2, WP3 |
| D8 | SSO with Authentik | Now, later, or never. Needs the Authentik plan [ASSUMED] done and an OIDC client created in Authentik. | Later (WP7 is separate and optional) | skip WP7 | WP7 |
| D9 | Admin user name and mail | The operator chooses; the name is not secret. | `<operator>`, mail `<email>` (the operator's own address) | any | WP2/first login |

## 6. Credentials and secret handling

### 6.1 Inventory

| # | Credential | What it is | Created by | Secret name (namespace) | Key | Sealed file | App receives it as |
|---|---|---|---|---|---|---|---|
| C1 | Paperless secret key | Signs sessions and sensitive data | The operator, section 6.2 | `paperless-secrets` (`paperless`) | `PAPERLESS_SECRET_KEY` | `talos/sealed-secrets/paperless-secrets.yaml` | env var through `envFrom` |
| C2 | External URL | `https://paperless.<tailnet-name>`; not secret but contains the full tailnet name, which the guard rejects in plain files | The operator | `paperless-secrets` | `PAPERLESS_URL` | same file | env var through `envFrom` |
| C3 | Database password | Generated by CNPG for user `paperless` | CNPG operator when it creates the cluster | `paperless-pg-app` (`paperless`) [UNVERIFIED key names: CNPG 1.25 documents keys `username`, `password`, `dbname`, `host`, `port`, `uri` in this Secret; confirm with `kubectl --context admin@<cluster> -n paperless describe secret paperless-pg-app` after WP3] | `password` | none (never sealed, never in git) | `PAPERLESS_DBPASS` via `secretKeyRef` |
| C4 | MinIO S3 access for CNPG backups | Scoped MinIO user for bucket `paperless-pg` | The operator (step B1 of WP2), generated by `talos/dr/minio/setup-users.sh` | `paperless-pg-s3` (`paperless`) | `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY` | `talos/sealed-secrets/paperless-pg-s3.yaml` | CNPG `s3Credentials` |
| C5 | Admin login (only if D7 = A) | First superuser | The operator | `paperless-secrets` | `PAPERLESS_ADMIN_USER`, `PAPERLESS_ADMIN_PASSWORD`, `PAPERLESS_ADMIN_MAIL` | same file | env var through `envFrom` |
| C6 | Admin login (D7 = B) | Chosen interactively by the operator at `createsuperuser` | The operator | not stored in the cluster (it lives hashed in the database) | n/a | n/a | n/a |
| C7 | NAS password | Samba account `homelab` | exists | `smb-csi-credentials` (`nas`) | `username`, `password` | `talos/sealed-secrets/smb-csi-credentials.yaml` (exists) | CSI driver for the PVs |
| C8 | Exporter passphrase (optional) | Encrypts sensitive fields inside the export | The operator, only if he wants it | `paperless-secrets` | `EXPORT_PASSPHRASE` [plan-local name, used by the CronJob] | same file | env var read by the CronJob command |
| C9 | OIDC client secret (WP7 only) | Authentik client secret | Authentik | `paperless-secrets` | `PAPERLESS_SOCIALACCOUNT_PROVIDERS` (whole JSON, contains the secret and the Authentik URL) | same file | env var |
| C10 | SMTP password (D5 only) | Mail account | The operator | `paperless-secrets` | `PAPERLESS_EMAIL_HOST_PASSWORD` | same file | env var |

How the full tailnet name stays out of git: `PAPERLESS_URL` is a key of the sealed Secret; the Deployment
reads all of `paperless-secrets` with `envFrom`. Paperless derives allowed hosts, CORS origins and CSRF trusted
origins from `PAPERLESS_URL` [verified configuration.md], so no other plain file needs the name. The Ingress
uses only the short host `paperless` in `tls.hosts`, exactly like `talos/manifests/jellyfin/ingress.yaml`.
The sealed file is written into the sealed-secret directory, listed in `talos/sealed-secrets/kustomization.yaml`
and delivered by the auto-sync app `talos-sealed-secrets` (prune off).

### 6.2 Generating and sealing (the operator, WP2 step B2)

Never echo. The secret key (C1) is generated straight into the clipboard:

```bash
openssl rand -base64 48 | tr -d '\n' | pbcopy
```

Seal everything with the recipe below (the namespace is `paperless`, so the helper
`docs/templates/ghcr-app/seal-secret.sh`, which hard-codes `homeserver`, must NOT be used). Values come from
hidden prompts; nothing is written to a file or shell history:

```bash
cd <repo-root>
read -rs SECRET_KEY;  echo     # paste C1 (clipboard) here
read -rs APP_URL;     echo     # type the full URL: https://paperless.<tailnet-name>   (no trailing slash)
# add only if D7 = A:   read -rs ADMIN_PW; echo
kubectl create secret generic paperless-secrets -n paperless --dry-run=client -o json \
  --from-literal=PAPERLESS_SECRET_KEY="$SECRET_KEY" \
  --from-literal=PAPERLESS_URL="$APP_URL" |
  KUBECONFIG=/dev/null kubeseal --cert argocd/sealed-secrets/pub-cert.pem --format yaml \
  > talos/sealed-secrets/paperless-secrets.yaml
unset SECRET_KEY APP_URL
grep -c 'kind: SealedSecret' talos/sealed-secrets/paperless-secrets.yaml    # must print 1
```

`kubectl create secret ... --dry-run=client` needs no cluster access. Add `--from-literal` lines for C5, C8,
C10 only when their decision says so. For D7 = A also add
`--from-literal=PAPERLESS_ADMIN_USER=<name> --from-literal=PAPERLESS_ADMIN_MAIL=<mail>` and the password read
with `read -rs`. Then list the file in `talos/sealed-secrets/kustomization.yaml` (WP2).

The S3 pair for C4 is sealed the same way with `-n paperless`, name `paperless-pg-s3`, keys
`ACCESS_KEY_ID` and `ACCESS_SECRET_KEY`, output `talos/sealed-secrets/paperless-pg-s3.yaml`, values read from
the files written by `setup-users.sh` (never printed).

### 6.3 First login ("password discovery")

- D7 = B (default): after the pod is Ready the operator runs, in his terminal:
  `kubectl --context admin@<cluster> -n paperless exec -it deploy/paperless-web -- createsuperuser`
  [verified command name, administration.md; the `exec` form on Kubernetes is the analogue of
  `docker compose exec webserver createsuperuser`]. It asks for username, mail and password (typed twice, not
  shown). He saves the password in Vaultwarden. If `createsuperuser` is not found on the PATH [UNVERIFIED],
  use `kubectl ... exec -it deploy/paperless-web -- python3 manage.py createsuperuser` (the working directory
  of the image is `/usr/src/paperless/src` [UNVERIFIED]).
- D7 = A: the three `PAPERLESS_ADMIN_*` variables apply only when the user does not exist: they do not change
  an existing user's password or recreate it [verified]. So later changes of the sealed value change nothing.
  the operator logs in with the password he sealed. After the first successful login he should change the password in
  the UI (user menu, "My Profile") and may then remove the three keys in a later PR.
- Login page: `https://paperless.<tailnet-name>/` . The Django admin is at `/admin/`.

### 6.4 Retrieving later (the operator, clipboard only)

```bash
kubectl --context admin@<cluster> -n paperless get secret paperless-secrets -o jsonpath='{.data.PAPERLESS_SECRET_KEY}' | base64 -d | pbcopy
kubectl --context admin@<cluster> -n paperless get secret paperless-pg-app -o jsonpath='{.data.password}' | base64 -d | pbcopy
```
The user password (C6) cannot be retrieved: only reset (6.6). Everything is also stored in Vaultwarden.

### 6.5 What breaks if lost or rotated

| Credential | If lost | If rotated |
|---|---|---|
| C1 secret key | Pods fail to start (no default). Seal a new one. | Sessions are invalidated (everyone is logged out). Fields Paperless signed or encrypted with the old key become invalid; for stored mail account passwords or API-related signed data [UNVERIFIED which], re-enter them. Documents and database content are not encrypted with this key [UNVERIFIED: the docs read say the exporter passphrase is separate from the secret key]. Rotate only in a quiet moment: seal the new key, merge, restart the pod, log in again. Keep the old key in Vaultwarden until confirmed. |
| C3 DB password | Regenerated only if the CNPG Cluster is recreated; the Secret `paperless-pg-app` is owned by CNPG. | Delete of the Secret is a cluster change, do not do it. To rotate CNPG-managed credentials follow the CNPG documentation in a separate PR [UNVERIFIED]. |
| C4 S3 pair | WAL archiving fails, backups stop (CNPG status shows the archive error). Re-run `setup-users.sh`, re-seal. | Seal the new pair, merge, wait for sync, confirm the next `Backup` is `Completed`. |
| C8 export passphrase | Old exports cannot be imported [verified]. | Exports made earlier still need the old one. Keep both. |
| C7 NAS password | Mounts fail ("mount error" in `describe pod`). | Owned by the NAS plan. |

### 6.6 Lost admin password recovery

1. The operator, in his terminal: `kubectl --context admin@<cluster> -n paperless exec -it deploy/paperless-web -- python3 manage.py changepassword <username>`
   (Django command; [UNVERIFIED] that the image working directory is the Django `src` folder; if the command
   cannot find `manage.py`, run `ls /usr/src/paperless/src` inside the pod first).
2. If the user is gone or no superuser exists: run `createsuperuser` as in 6.3 with a new name.
3. Neither needs a restart. Save the new password in Vaultwarden.

## 7. Work packages

Order: WP0, WP1, WP2, WP3, WP4, WP5, WP6, then optional WP3b, WP7. One draft PR each. After each, write the
report in the format of section 11. Never start the next package before the operator merged and synced the previous
one, except WP0 (no PR).

Common files to know:
- App definition: `talos/apps-src/paperless.yaml`; generated copy `talos/apps/paperless.yaml` (by
  `bash talos/render-apps.sh --force`, commit both).
- Expectation line: `talos/test/empty-cluster-expectations.txt`.
- Manifests: `talos/manifests/paperless/`.
- Sealed secrets: `talos/sealed-secrets/`.

### WP0. Read-only audit (no PR)

Goal: prove the prerequisites and capture facts.
1. Run every command of section 2 (P1 to P14). Record expected versus actual.
2. `kubectl --context admin@<cluster> top nodes` and quote the output.
3. `kubectl --context admin@<cluster> get storageclass` : expected exactly `topolvm-fast`.
4. `kubectl --context admin@<cluster> get ns` : confirm no namespace `paperless` exists yet (if it exists, STOP).
5. `kubectl --context admin@<cluster> -n cnpg-system get deploy -o jsonpath='{.items[*].spec.template.spec.containers[0].image}'`
   (image of the operator, not a secret) and read its version; the plan assumes 1.25 (see
   `docs/dr/talos-backups.md`, "Immich Postgres"). If the version is 1.26 or newer, the in-tree
   `barmanObjectStore` block of WP3 may be deprecated [UNVERIFIED]: STOP and ask the operator.
6. `kubectl --context admin@<cluster> get cluster.postgresql.cnpg.io -A` : record the image of `immich-pg`
   (`kubectl ... -n homeserver get cluster immich-pg -o jsonpath='{.status.image}'`) for the PostgreSQL image choice
   in step WP3-4.
7. Confirm the repo facts: `ls talos/overlays/immich-infra talos/apps-src docs/templates/ghcr-app`;
   `grep -n "paperless" talos/manifests/samba-nas/deployment.yaml`.
8. Confirm the image facts marked UNVERIFIED in section 3.1 using the registry (section 3.1 commands) and
   `https://github.com/paperless-ngx/paperless-ngx/pkgs/container/paperless-ngx`, plus Paperless "Requirements"
   in `docs/setup.md` for supported PostgreSQL majors.
Report: the audit table and the numbers. STOP point: The operator answers D1 to D9 (or says "use the defaults").

### WP1. Namespace and Argo application

Branch: `feat/paperless-namespace`. Preconditions: WP0 done, D4 answered.

Steps:
1. Why: the namespace and the Application must exist before anything else. Edit
   `talos/manifests/namespaces/namespaces.yaml`: append (keep the existing style; no Pod Security label,
   because Paperless needs only the cluster default `baseline`):
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: paperless
```
2. Create `talos/apps-src/paperless.yaml` (manual sync like jellyfin):
```yaml
# Paperless-ngx (docs/plans/paperless.md). Manual sync on purpose: The operator syncs it after the sealed Secrets
# and the MinIO bucket exist. Namespace `paperless` is created by the `namespaces` app, CreateNamespace is a
# safety net only.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: paperless
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/BrunoLoureirooo/homelab_gitops
    targetRevision: main
    path: talos/manifests/paperless
  destination:
    server: https://kubernetes.default.svc
    namespace: paperless
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```
3. Create `talos/manifests/paperless/kustomization.yaml` containing only the header and an empty list
   (WP3 fills it) so the Application has a valid path:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: paperless
resources: []
```
   Check `kubectl kustomize talos/manifests/paperless` prints nothing and exits 0. If your `kubectl` rejects an
   empty list, instead put a placeholder `configmap-placeholder.yaml` (an empty ConfigMap `paperless-placeholder`)
   and remove it in WP3.
4. Add to `talos/test/empty-cluster-expectations.txt`, keeping column alignment, after the `jellyfin` line:
   `paperless                *       *       # manual sync; needs the CNPG operator, the SMB CSI driver and sealed Secrets`
5. Generate: `bash talos/render-apps.sh --force` (needs `yq`). Expected: `git status` shows the new
   `talos/apps/paperless.yaml` and no other generated change; if other files change, STOP and report.
6. `bash .github/scripts/run-all-guards.sh` : 20 OK.
Verification: `git diff --stat` lists exactly the five files above (namespaces.yaml, apps-src, apps,
kustomization, expectations).
Rollback: close the PR. Nothing is deployed.
PR title: `feat: paperless namespace and Argo application (plan WP1)`.
PR description: what changed; "the operator after merging: sync app `namespaces` (auto-syncs), then confirm
`kubectl --context admin@<cluster> get ns paperless`; do NOT sync `paperless` yet". Ends with the required line.
STOP point: wait for the merge.

### WP2. Sealed secrets and the MinIO bucket (The operator does the secret work)

Branch: `feat/paperless-secrets`. Preconditions: WP1 merged; D7, D5, D9 answered.

The operator copy-paste list (the executor prints this list into the PR description):
- B1 MinIO bucket and user for the CNPG backups. Read `docs/dr/minio-standalone.md` and
  `talos/dr/minio/setup-users.sh` first: the script creates fixed buckets (`velero-backups`, `litestream`,
  `immich-pg`). Add `paperless-pg` to it in WP2 (step 3 below), merge, then on the machine that has the `mc`
  alias run `bash talos/dr/minio/setup-users.sh --alias <alias> --out <dir-outside-the-repo>` (the dry run
  first, as the doc says). Result: bucket `paperless-pg`, a scoped user, and a credentials file in `<dir>` with
  mode 0600. Do not paste its contents anywhere.
- B2 Seal C1, C2 (and C5, C8, C10 if chosen): the recipe in section 6.2.
- B3 Seal C4: same recipe with `-n paperless`, name `paperless-pg-s3`, output
  `talos/sealed-secrets/paperless-pg-s3.yaml`.
- B4 Commit nothing else; give the two files to the executor by pushing them on the branch
  `feat/paperless-secrets` or by telling the executor to take them from his working tree.

Executor steps:
1. Read `talos/dr/minio/setup-users.sh` and `talos/dr/minio/policy.json.tmpl`. Describe in the report exactly
   how a new bucket is declared there. If the script has a list of buckets, add `paperless-pg` and the matching
   policy, in the same style, and run the script's own test if the repo has one (`grep -rn "setup-users" .github talos/test`).
   If the script cannot be extended without redesign, STOP and report.
2. After the operator supplies the two sealed files, verify (each prints `1`):
   `grep -c 'kind: SealedSecret' talos/sealed-secrets/paperless-secrets.yaml talos/sealed-secrets/paperless-pg-s3.yaml`
   and check `grep -n 'namespace: paperless' talos/sealed-secrets/paperless-*.yaml` shows the namespace in
   `metadata` and in `template.metadata`.
3. Edit `talos/sealed-secrets/kustomization.yaml`: add the two lines under `resources:` and two comment lines
   in the table at the top, in the same format:
```yaml
#   paperless-secrets.yaml      paperless/paperless-secrets      PAPERLESS_SECRET_KEY, PAPERLESS_URL (and other keys per decisions)
#   paperless-pg-s3.yaml        paperless/paperless-pg-s3        ACCESS_KEY_ID, ACCESS_SECRET_KEY (MinIO user paperless-pg)
...
  - paperless-secrets.yaml
  - paperless-pg-s3.yaml
```
4. `kubectl kustomize talos/sealed-secrets | grep -c 'kind: SealedSecret'` : the count is 2 more than on main.
5. Guards: 20 OK (the ciphertext is allowed; if `check-no-raw-secrets` complains, STOP).
Rollback: revert the PR; delete the Secrets by the operator only if they were created.
PR title: `feat: sealed secrets for paperless (plan WP2)`.
PR description: lists keys by name, never values; the operator after merging: "the app `talos-sealed-secrets` syncs
itself; confirm `kubectl --context admin@<cluster> -n paperless describe secret paperless-secrets` lists the
keys, and the same for `paperless-pg-s3`".
STOP point: the two Secrets exist in the cluster.

### WP3. Paperless, Valkey, PostgreSQL, storage, Ingress

Branch: `feat/paperless-app`. Preconditions: WP2 done; D1, D2, D3, D4 answered; digests resolved (section 3.1).
Placeholders below in angle brackets are values the executor resolves from section 3.1 and the decisions;
`<node>` is `mini01` or `mini03` (D4). Never leave a placeholder in a committed file.

Directory `talos/manifests/paperless/`. Replace `kustomization.yaml` with:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: paperless
resources:
  - smb-volumes.yaml
  - pvc.yaml
  - cnpg-cluster.yaml
  - scheduled-backup.yaml
  - broker.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```
Step 1. `smb-volumes.yaml` (why: the originals, consume folder and exporter target come from the NAS; the
pattern is `talos/overlays/immich-infra/library-smb.yaml`). Two PVs and their claims. `source` has no
trailing slash. The names of the PVs are cluster-wide, so they carry the app name.
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: paperless-share-smb
spec:
  capacity:
    storage: 200Gi            # informational for SMB; the real limit is the 256G quota of dataset tank/nas
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions:
    - dir_mode=0775
    - file_mode=0664
    - uid=1000
    - gid=1000
    - vers=3.1.1
    - nobrl
  csi:
    driver: smb.csi.k8s.io
    volumeHandle: mini02-samba-nas#paperless#paperless-share-smb
    volumeAttributes:
      source: //samba-nas.nas.svc.cluster.local/paperless
    nodeStageSecretRef:
      name: smb-csi-credentials      # D3 = B: the per-share Secret name [ASSUMED smb-csi-credentials-paperless]
      namespace: nas
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: paperless-share
  namespace: paperless
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  volumeName: paperless-share-smb
  resources:
    requests:
      storage: 200Gi
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: paperless-backups-smb
spec:
  capacity:
    storage: 100Gi
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions:
    - dir_mode=0775
    - file_mode=0664
    - uid=1000
    - gid=1000
    - vers=3.1.1
    - nobrl
  csi:
    driver: smb.csi.k8s.io
    volumeHandle: mini02-samba-nas#backups#paperless-backups-smb
    volumeAttributes:
      source: //samba-nas.nas.svc.cluster.local/backups
    nodeStageSecretRef:
      name: smb-csi-credentials
      namespace: nas
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: paperless-backups
  namespace: paperless
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  volumeName: paperless-backups-smb
  resources:
    requests:
      storage: 100Gi
```
Step 2. `pvc.yaml` (the search index and data; names the class explicitly):
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: paperless-data
  namespace: paperless
  labels:
    app.kubernetes.io/name: paperless
spec:
  storageClassName: topolvm-fast
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
```
Step 3. `cnpg-cluster.yaml` (pattern: `argocd/manifests/immich-infra/immich-cluster.yaml` plus
`talos/overlays/immich-infra/backup-patch.yaml`). Note the `Prune=false` annotation on CNPG Clusters, because
fields are immutable. No `bootstrap.initdb.secret`: CNPG then generates the password and stores it in
`paperless-pg-app`.
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: paperless-pg
  namespace: paperless
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  instances: 1
  # imageName: omit to use the operator's default image, or set the exact image WP0 step 6 recorded
  # (a PostgreSQL major that Paperless 3.3 supports, section 3.1), pinned by digest.
  priorityClassName: hs-interactive
  affinity:
    nodeSelector:
      kubernetes.io/hostname: <node>
  bootstrap:
    initdb:
      database: paperless
      owner: paperless
  storage:
    size: 5Gi
    storageClass: topolvm-fast
  resources:
    requests: { cpu: "100m", memory: 256Mi }
    limits: { cpu: "1", memory: 512Mi }
  backup:
    retentionPolicy: "14d"
    barmanObjectStore:
      destinationPath: s3://paperless-pg/
      endpointURL: http://velero-backup-target.velero.svc.cluster.local:9000
      s3Credentials:
        accessKeyId:
          name: paperless-pg-s3
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: paperless-pg-s3
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
      data:
        compression: gzip
```
`priorityClassName: hs-interactive` exists in the cluster (checked with `get priorityclass`). `affinity.nodeSelector`
is the CNPG field for node selection [UNVERIFIED in the 1.25 API: confirm with
`kubectl --context admin@<cluster> explain cluster.spec.affinity`]; if absent, use the field `explain`
shows and report it. The LimitRange in `homeserver` does not apply to namespace `paperless`, but the
resources are explicit anyway.

Step 4. `scheduled-backup.yaml` (six cron fields, seconds first, like the Immich one; 02:45 UTC avoids the
02:30 Immich backup):
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: paperless-pg-daily
  namespace: paperless
spec:
  schedule: "0 45 2 * * *"
  backupOwnerReference: self
  immediate: false
  cluster:
    name: paperless-pg
```
Step 5. `broker.yaml` (Valkey without persistence; the queue is disposable; probes by TCP):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: paperless-broker
  namespace: paperless
  labels: {app.kubernetes.io/name: paperless-broker}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector:
    matchLabels: {app.kubernetes.io/name: paperless-broker}
  template:
    metadata:
      labels: {app.kubernetes.io/name: paperless-broker}
    spec:
      nodeSelector:
        kubernetes.io/hostname: <node>
      securityContext:
        runAsNonRoot: true
        runAsUser: 999          # [UNVERIFIED] the uid of the valkey user in the alpine image; confirm with the image docs, else remove runAsUser and keep runAsNonRoot only if the image sets a numeric user
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: valkey
          image: docker.io/valkey/valkey:<9.x.y-alpine>@sha256:<digest>
          args: ["--save", "", "--appendonly", "no"]
          ports: [{name: redis, containerPort: 6379}]
          resources:
            requests: {cpu: 25m, memory: 32Mi}
            limits: {cpu: 200m, memory: 128Mi}
          readinessProbe: {tcpSocket: {port: redis}, periodSeconds: 10}
          livenessProbe: {tcpSocket: {port: redis}, initialDelaySeconds: 15, periodSeconds: 20}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          volumeMounts:
            - {name: data, mountPath: /data}
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: paperless-broker
  namespace: paperless
spec:
  selector: {app.kubernetes.io/name: paperless-broker}
  ports:
    - {name: redis, port: 6379, targetPort: redis}
```
Step 6. `deployment.yaml` for the webserver. `envFrom` reads the sealed Secret (C1, C2, optional C5, C8, C10);
the database password uses `secretKeyRef` into the CNPG-generated Secret. The init container makes the
folders on the share (the share starts with only the directories the Samba init container made). The pod
runs as root initially because the image's s6 start scripts need it (baseline Pod Security allows it); only
capabilities are reduced to what the image needs [UNVERIFIED: if the pod crash-loops with permission errors
at start, report the log lines to the operator rather than adding capabilities yourself].
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: paperless-web
  namespace: paperless
  labels: {app.kubernetes.io/name: paperless-web}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector:
    matchLabels: {app.kubernetes.io/name: paperless-web}
  template:
    metadata:
      labels: {app.kubernetes.io/name: paperless-web}
      annotations:
        # Velero opt-in file-system backup of the search index volume only. The SMB volumes are NOT listed
        # on purpose (originals live on the NAS and are covered by the exporter, section 8).
        backup.velero.io/backup-volumes: data
    spec:
      priorityClassName: hs-interactive
      nodeSelector:
        kubernetes.io/hostname: <node>
      initContainers:
        - name: share-dirs
          image: docker.io/library/busybox:1.37@sha256:<digest>
          command: ["sh", "-c", "mkdir -p /share/consume /share/media && ls -la /share"]
          resources:
            requests: {cpu: 10m, memory: 16Mi}
            limits: {cpu: 100m, memory: 64Mi}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
          volumeMounts:
            - {name: share, mountPath: /share}
      containers:
        - name: paperless
          image: ghcr.io/paperless-ngx/paperless-ngx:3.3.4@sha256:<digest>
          ports: [{name: http, containerPort: 8000}]
          envFrom:
            - secretRef: {name: paperless-secrets}
          env:
            - {name: PAPERLESS_REDIS, value: "redis://paperless-broker.paperless.svc.cluster.local:6379"}
            - {name: PAPERLESS_DBENGINE, value: postgresql}        # [UNVERIFIED value, section 3.3]
            - {name: PAPERLESS_DBHOST, value: paperless-pg-rw.paperless.svc.cluster.local}
            - {name: PAPERLESS_DBPORT, value: "5432"}
            - {name: PAPERLESS_DBNAME, value: paperless}
            - {name: PAPERLESS_DBUSER, value: paperless}
            - name: PAPERLESS_DBPASS
              valueFrom:
                secretKeyRef: {name: paperless-pg-app, key: password}
            - {name: USERMAP_UID, value: "1000"}
            - {name: USERMAP_GID, value: "1000"}
            - {name: PAPERLESS_TIME_ZONE, value: Europe/Lisbon}    # [ASSUMED] the operator's zone; confirm
            - {name: PAPERLESS_OCR_LANGUAGE, value: "<D1 value, e.g. por+eng>"}
            # - {name: PAPERLESS_OCR_LANGUAGES, value: "<space-separated packs, only if not preinstalled>"}
            - {name: PAPERLESS_CONSUMER_POLLING_INTERVAL, value: "30"}   # SMB: no filesystem notifications
            - {name: PAPERLESS_CONSUMER_RECURSIVE, value: "true"}
            - {name: PAPERLESS_CONSUMER_DELETE_DUPLICATES, value: "true"}
            - {name: PAPERLESS_TASK_WORKERS, value: "1"}
            - {name: PAPERLESS_THREADS_PER_WORKER, value: "2"}
            - {name: PAPERLESS_WEBSERVER_WORKERS, value: "1"}
            # D2 = yes: also PAPERLESS_TIKA_ENABLED=true, PAPERLESS_TIKA_ENDPOINT=http://paperless-tika:9998,
            # PAPERLESS_TIKA_GOTENBERG_ENDPOINT=http://paperless-gotenberg:3000 (Appendix A)
          resources:
            requests: {cpu: 250m, memory: 1536Mi}
            limits: {cpu: "2", memory: 3Gi}
          startupProbe:
            httpGet: {path: /, port: http}
            periodSeconds: 10
            failureThreshold: 60        # up to 10 minutes: migrations and language packs
          readinessProbe:
            httpGet: {path: /, port: http}
            periodSeconds: 15
          livenessProbe:
            httpGet: {path: /, port: http}
            periodSeconds: 30
            failureThreshold: 5
          securityContext:
            allowPrivilegeEscalation: false
            seccompProfile: {type: RuntimeDefault}
          volumeMounts:
            - {name: data, mountPath: /usr/src/paperless/data}
            - {name: share, mountPath: /usr/src/paperless/media, subPath: media}
            - {name: share, mountPath: /usr/src/paperless/consume, subPath: consume}
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: paperless-data}
        - name: share
          persistentVolumeClaim: {claimName: paperless-share}
```
Note the PAPERLESS_ADMIN_* variables come only from the Secret and only when D7 = A. `PAPERLESS_URL` comes
from the Secret (section 6.1). The mail settings (D5) go in WP3c, not here.
Step 7. `service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: paperless
  namespace: paperless
  labels: {app.kubernetes.io/name: paperless-web}
spec:
  selector: {app.kubernetes.io/name: paperless-web}
  ports:
    - {name: http, port: 8000, targetPort: http}
```
Step 8. `ingress.yaml` (the short host only; the tailnet name is a host detail):
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: paperless
  namespace: paperless
  labels: {app.kubernetes.io/name: paperless-web}
spec:
  ingressClassName: tailscale
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: paperless
                port:
                  number: 8000
  tls:
    - hosts:
        - paperless
```
Step 9. Validate without a cluster: `kubectl kustomize talos/manifests/paperless > /tmp/paperless-render.yaml`
(exit 0), then `grep -c 'image:' /tmp/paperless-render.yaml` and
`grep -n 'image:' /tmp/paperless-render.yaml | grep -v '@sha256:'` must print nothing. Then
`grep -rn 'latest' talos/manifests/paperless` must print nothing.
Step 10. `bash .github/scripts/run-all-guards.sh` : 20 OK.
Verification after the operator's sync (the executor runs these read-only after the operator says "synced"):
- `kubectl --context admin@<cluster> -n paperless get pods -o wide` : `paperless-pg-1`, `paperless-broker-*`,
  `paperless-web-*` all `Running` and `1/1` (the web pod can take up to 10 minutes).
- `kubectl --context admin@<cluster> -n paperless get cluster paperless-pg` : `Cluster in healthy state`.
- `kubectl --context admin@<cluster> -n paperless get pvc` : `paperless-data`, `paperless-share`,
  `paperless-backups` all `Bound` (`paperless-data` only after the first pod mounts it: WaitForFirstConsumer).
- `kubectl --context admin@<cluster> -n paperless describe secret paperless-pg-app` shows the key `password`.
  If the key names differ, STOP: the `secretKeyRef` in the Deployment needs the real name.
- `kubectl --context admin@<cluster> -n paperless logs deploy/paperless-web --tail=100` : no Python
  traceback; a line stating the web server started. Report any `chown` messages.
- `kubectl --context admin@<cluster> -n paperless get ingress paperless` shows the Tailscale address once ready.
Rollback: The operator deletes nothing by hand; revert the PR, sync `paperless` (resources are removed; CNPG Cluster
has `Prune=false`, so the database and its PVC remain until the operator deletes them deliberately; PVs have reclaim
`Retain` so NAS files stay).
PR title: `feat: paperless-ngx, valkey and postgres (plan WP3)`.
PR description includes the operator's steps after merging: 1. In the Argo web UI sync app `paperless`
(ServerSideApply is on). 2. Watch `kubectl --context admin@<cluster> -n paperless get pods -w` until Ready.
3. Create the first user (section 6.3). 4. If the Tailscale device appears as `paperless-1`, delete the stale
`paperless` device in the Tailscale admin console and re-sync the Ingress (see the note in
`talos/manifests/jellyfin/ingress.yaml`). 5. Open `https://paperless.<tailnet-name>`.
STOP point: The operator can log in.

### WP3b (optional, only if D2 = yes). Tika and Gotenberg

Branch `feat/paperless-tika`. Create `talos/manifests/paperless/office.yaml` with two Deployments and Services
(`paperless-tika` port 9998 image `docker.io/apache/tika:<tag>@sha256:<digest>`; `paperless-gotenberg` port
3000 image `docker.io/gotenberg/gotenberg:<8.x tag>@sha256:<digest>`, arguments
`["gotenberg", "--chromium-disable-javascript=true", "--chromium-allow-list=file:///tmp/.*"]` [UNVERIFIED:
copy the exact command from the official `docker-compose.postgres-tika.yml`]), same nodeSelector, resources
from section 4.4, `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`, probes by TCP. Add
`office.yaml` to the kustomization and uncomment the three Tika variables in `deployment.yaml`. Guards, PR
`feat: paperless tika and gotenberg (plan WP3b)`; the operator syncs `paperless`; verify by consuming a `.docx`.

### WP3c (optional, only if D5 = SMTP). Mail

Branch `feat/paperless-mail`. Add plain env vars `PAPERLESS_EMAIL_HOST`, `PAPERLESS_EMAIL_PORT`,
`PAPERLESS_EMAIL_HOST_USER`, `PAPERLESS_EMAIL_FROM`, `PAPERLESS_EMAIL_USE_TLS` (values from the operator; the user
name is not secret) and put `PAPERLESS_EMAIL_HOST_PASSWORD` in the sealed Secret (re-seal: the file is
regenerated, so the operator re-runs section 6.2 with the extra key; the executor replaces the sealed file).

### WP4. Velero schedule for the namespace

Branch `feat/paperless-velero`. Preconditions: WP3 synced. Why: the existing schedule `homeserver-nightly`
covers only namespace `homeserver` (`argocd/values/velero.yaml`), and the Talos copy only changes its cron
(`talos/values/velero.yaml`).
1. Read `talos/values/velero.yaml` and `argocd/values/velero.yaml` completely. The key `schedules` in the
   Talos file is merged by Helm map over the repo values.
2. Add under `schedules:` in `talos/values/velero.yaml`:
```yaml
  paperless-nightly:
    schedule: "15 10 * * *" # daily, 10:15 UTC, after homeserver-nightly (10:00)
    template:
      ttl: "720h0m0s"
      includedNamespaces:
        - paperless
```
   The pod annotation `backup.velero.io/backup-volumes: data` (WP3 step 6) opts in only the volume `data`, so
   no `defaultVolumesToFsBackup` is set here, exactly as the repo's `homeserver` schedule does.
   Do NOT include the CNPG volume: it has no annotation and the Cluster is restored from its own backups.
3. `bash talos/render-apps.sh --force` must change nothing (the values file is not generated); run the guards.
Verification (after the operator syncs `velero` and a run happened): `kubectl --context admin@<cluster> -n velero get schedules.velero.io`
lists `paperless-nightly`; after the first run `kubectl --context admin@<cluster> -n velero get backups.velero.io | grep paperless`
shows `Completed`, and `kubectl --context admin@<cluster> -n velero get podvolumebackups.velero.io | grep paperless`
shows a `Completed` row for volume `data`.
PR title: `feat: velero schedule for paperless (plan WP4)`. The operator after merge: sync app `velero`; to run now:
`velero backup create paperless-test --from-schedule paperless-nightly` (his terminal).
STOP point: one Completed backup with a PodVolumeBackup.

### WP5. Exporter CronJob

Branch `feat/paperless-export`. Preconditions: WP3 working, at least one test document ingested, D6 read.
Create `talos/manifests/paperless/export-cronjob.yaml` and add it to the kustomization. The job runs the
Paperless image with the same database and media mounts as the web pod, bypassing the s6 init, and writes
to the `backups` share folder `paperless-export`. It runs while the web pod is up (consumption may continue;
the docs say to pause it for a backup, so the night hour was chosen to avoid scans; see the troubleshooting
row about inconsistent exports).
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: paperless-export
  namespace: paperless
spec:
  schedule: "30 3 * * *"          # daily 03:30 (cluster time is UTC)
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          restartPolicy: Never
          nodeSelector:
            kubernetes.io/hostname: <node>
          securityContext:
            runAsUser: 1000
            runAsGroup: 1000
            runAsNonRoot: true
            seccompProfile: {type: RuntimeDefault}
          initContainers:
            - name: export-dir
              image: docker.io/library/busybox:1.37@sha256:<digest>
              command: ["sh", "-c", "mkdir -p /backups/paperless-export"]
              resources:
                requests: {cpu: 10m, memory: 16Mi}
                limits: {cpu: 100m, memory: 64Mi}
              securityContext:
                allowPrivilegeEscalation: false
                capabilities: {drop: [ALL]}
              volumeMounts:
                - {name: backups, mountPath: /backups}
          containers:
            - name: export
              image: ghcr.io/paperless-ngx/paperless-ngx:3.3.4@sha256:<digest>   # same digest as the Deployment
              workingDir: /usr/src/paperless/src                                  # [UNVERIFIED path, confirm with `ls` in the running web pod]
              command: ["python3", "manage.py", "document_exporter", "/usr/src/paperless/export", "-c", "-d", "--no-progress-bar"]
              envFrom:
                - secretRef: {name: paperless-secrets}
              env:
                - {name: PAPERLESS_REDIS, value: "redis://paperless-broker.paperless.svc.cluster.local:6379"}
                - {name: PAPERLESS_DBENGINE, value: postgresql}
                - {name: PAPERLESS_DBHOST, value: paperless-pg-rw.paperless.svc.cluster.local}
                - {name: PAPERLESS_DBPORT, value: "5432"}
                - {name: PAPERLESS_DBNAME, value: paperless}
                - {name: PAPERLESS_DBUSER, value: paperless}
                - name: PAPERLESS_DBPASS
                  valueFrom:
                    secretKeyRef: {name: paperless-pg-app, key: password}
                - {name: PAPERLESS_DATA_DIR, value: /tmp/paperless-data}
              resources:
                requests: {cpu: 100m, memory: 256Mi}
                limits: {cpu: "1", memory: 768Mi}
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: false
                capabilities: {drop: [ALL]}
              volumeMounts:
                - {name: share, mountPath: /usr/src/paperless/media, subPath: media, readOnly: true}
                - {name: backups, mountPath: /usr/src/paperless/export, subPath: paperless-export}
                - {name: tmp, mountPath: /tmp}
          volumes:
            - name: share
              persistentVolumeClaim: {claimName: paperless-share}
            - name: backups
              persistentVolumeClaim: {claimName: paperless-backups}
            - name: tmp
              emptyDir: {}
```
Notes the executor must repeat in the PR: (a) `-d` removes export files of deleted documents and the
target folder holds only this export, so it is safe. (b) The passphrase (C8) is not used by default; if the operator
wants it, add `--passphrase "$EXPORT_PASSPHRASE"` to a `sh -c` wrapper and the key to the sealed Secret.
(c) `PAPERLESS_DATA_DIR=/tmp/paperless-data` avoids mounting the RWO `data` volume a second time; if the
exporter refuses to run without the real data directory [UNVERIFIED], mount `paperless-data` as in the
Deployment (same node, allowed for a local RWO volume) and report it. (d) The exact CLI call
`python3 manage.py document_exporter` is the Django form of the documented `document_exporter` [verified the
command and flags; UNVERIFIED the invocation form: The operator tests with the manual run below].
Verification (the operator): `kubectl --context admin@<cluster> -n paperless create job --from=cronjob/paperless-export export-test`;
then the executor: `kubectl --context admin@<cluster> -n paperless get job export-test` shows
`Complete 1/1`; `kubectl --context admin@<cluster> -n paperless logs job/export-test` ends without error.
To see the files (the executor must not use `exec`), the operator runs
`kubectl --context admin@<cluster> -n nas exec deploy/samba-nas -c samba -- ls /shares/nas/backups/paperless-export`
in his terminal, or opens the `backups` share from his Mac, and reports the listing: expected files `manifest.json` and folders for
documents. Rollback: remove the file from the kustomization.
PR title: `feat: paperless document exporter cronjob (plan WP5)`.
STOP point: `manifest.json` exists on the share.

### WP6. Acceptance and documentation

Branch `docs/paperless-runbook`. Update `docs/BACKLOG.md` row `Paperless | Planned` to `Running (see docs/plans/paperless.md)`
and add a section `## Paperless-ngx` to `docs/dr/talos-backups.md` summarising sections 8 and 10 in the
style of the neighbouring sections (CNPG backup names, Velero schedule, exporter, restore test). Guards. PR
`docs: paperless runbook and backlog (plan WP6)`. (This is the only package that touches those two files.)

### WP7 (optional, only if D8 = now). SSO with Authentik

Branch `feat/paperless-sso`. Preconditions: P12; Authentik reachable. [ASSUMED] Authentik runs in namespace
`authentik` with public tailnet URL `https://authentik.<tailnet-name>`.
Facts [verified https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/dev/docs/advanced_usage.md and
configuration.md]: Paperless loads allauth through `PAPERLESS_APPS="allauth.socialaccount.providers.openid_connect"`
and reads the provider from `PAPERLESS_SOCIALACCOUNT_PROVIDERS`, a JSON object with key `openid_connect`
whose `APPS` list has `provider_id`, `name`, `client_id`, `secret` and `settings.server_url` (the
`.well-known/openid-configuration` URL).
The operator steps:
1. In Authentik create an OAuth2/OpenID provider and application `paperless`: client type confidential,
   redirect URI `https://paperless.<tailnet-name>/accounts/oidc/authentik/login/callback/` [UNVERIFIED: this
   is the django-allauth callback pattern `/accounts/oidc/<provider_id>/login/callback/`; confirm in the allauth
   page `https://docs.allauth.org/en/latest/socialaccount/providers/openid_connect.html`], scopes `openid
   profile email` (add `groups` only for group sync). Copy the client id and secret into Vaultwarden.
2. The OIDC discovery URL for Authentik is `https://authentik.<tailnet-name>/application/o/paperless/.well-known/openid-configuration`
   [UNVERIFIED: Authentik's URL pattern is `/application/o/<slug>/`; confirm in the Authentik provider page].
3. Seal the new key (re-run section 6.2 with the extra line; the file is regenerated, so all keys are re-entered):
```bash
read -rs OIDC_JSON; echo   # paste ONE line of JSON:
# {"openid_connect":{"APPS":[{"provider_id":"authentik","name":"Authentik","client_id":"<id>","secret":"<secret>","settings":{"server_url":"https://authentik.<tailnet-name>/application/o/paperless/.well-known/openid-configuration"}}]}}
```
   then add `--from-literal=PAPERLESS_SOCIALACCOUNT_PROVIDERS="$OIDC_JSON"` to the kubeseal recipe.
Executor steps: add plain env vars to the web Deployment:
```yaml
            - {name: PAPERLESS_APPS, value: "allauth.socialaccount.providers.openid_connect"}
            - {name: PAPERLESS_SOCIAL_AUTO_SIGNUP, value: "false"}   # the operator links his existing account instead (profile page, verified in advanced_usage.md)
            # keep PAPERLESS_DISABLE_REGULAR_LOGIN unset until SSO login works at least once
```
Everything with the full name travels in the sealed key `PAPERLESS_SOCIALACCOUNT_PROVIDERS`. Verification:
login page shows the "Authentik" button; the operator logs in with the local account first, links Authentik from
"My Profile", then logs out and in with SSO. Only afterwards may a later PR set
`PAPERLESS_DISABLE_REGULAR_LOGIN=true` (the Django `/admin/` and `createsuperuser` stay available as the
break-glass path [verified: the setting only hides the frontend form]). Rollback: remove the three settings.
PR `feat: paperless sso with authentik (plan WP7)`.

## 8. Backup and restore

| Data | Mechanism | Frequency / retention | Notes |
|---|---|---|---|
| PostgreSQL (metadata, tags, users, OCR text) | CNPG continuous WAL + `ScheduledBackup` `paperless-pg-daily` to bucket `paperless-pg` on MinIO (mini02) | WAL continuous; base daily 02:45 UTC; 14 days | NOT covered by Velero. |
| Search index and data (`data` PVC) | Velero schedule `paperless-nightly` with opt-in annotation `backup.velero.io/backup-volumes: data` | daily 10:15 UTC, 30 days | Rebuildable; backed up for convenience. |
| Originals, archive PDFs, thumbnails (`media`) | live on the NAS share (ZFS mirror `tank`); logical copy by the exporter CronJob to the `backups` share | daily 03:30 UTC | Same pool as the originals: protects against deletion and bugs, NOT against pool loss. Off-pool copy: D6. |
| Consume inbox | none (transient) | | Files vanish after consumption. |
| Sealed secrets | git (`talos/sealed-secrets/`) | | Decrypt only with the controller key (see `docs/dr/talos-backups.md`). |
| Secrets in Vaultwarden | by the Vaultwarden plan | | |

Not covered: the Tailscale device, MinIO data itself (a second copy is the `backup-replica` plan [ASSUMED]).

### Restore test (the executor writes it as `docs/dr/paperless-restore-test.md` in WP6; the operator performs it)

Goal: prove that a database restore from MinIO plus the exporter output reproduce the documents in a scratch
namespace, without touching production. Everything below runs in namespace `paperless-restore-test`
(delete it afterwards). Paperless must be the same version as the export [verified].
1. Create the namespace and a CNPG Cluster `paperless-pg` there that recovers from the production backup:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: paperless-pg
  namespace: paperless-restore-test
spec:
  instances: 1
  storage: {size: 5Gi, storageClass: topolvm-fast}
  bootstrap:
    recovery:
      source: prod
  externalClusters:
    - name: prod
      barmanObjectStore:
        destinationPath: s3://paperless-pg/
        endpointURL: http://velero-backup-target.velero.svc.cluster.local:9000
        s3Credentials:
          accessKeyId: {name: paperless-pg-s3, key: ACCESS_KEY_ID}
          secretAccessKey: {name: paperless-pg-s3, key: ACCESS_SECRET_KEY}
        wal: {compression: gzip}
```
   the operator first copies the Secret `paperless-pg-s3` into the test namespace without printing it:
   `kubectl --context admin@<cluster> -n paperless get secret paperless-pg-s3 -o json | jq 'del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.ownerReferences,.metadata.annotations,.metadata.labels)' | kubectl --context admin@<cluster> -n paperless-restore-test apply -f -`
   (output of `get ... -o json` is piped, never displayed). Use `kubectl ... apply --dry-run=client` first. Reference: `talos/dr/immich-pg-recovery.yaml` for the recovery style.
   Expected: pod `paperless-pg-1` Ready; `kubectl ... -n paperless-restore-test get cluster` healthy.
2. Count the documents in both databases. The operator, in his terminal: for each namespace
   `kubectl --context admin@<cluster> -n <ns> exec paperless-pg-1 -c postgres -- psql -U postgres -d paperless -tAc "select count(*) from documents_document"`.
   The two numbers match (the restored one may be lower only by documents added after the last backup).
3. Check the export: The operator compares the number of document entries in `manifest.json` of the export folder
   with production: `grep -c '"model": "documents.document"' <export>/manifest.json` [UNVERIFIED format of
   manifest.json, adjust the pattern after looking at the file].
4. Full proof (optional, once): deploy a throwaway Paperless in the test namespace using a copy of WP3
   manifests (no Ingress, other PVC names, empty `data`, `media` = an emptyDir, no consume) then run
   `document_importer /export` against the mounted copy of the export folder (importer needs a completely empty
   installation [verified]). Compare the document count and open one document's PDF through
   `kubectl port-forward` on the operator's Mac.
5. Delete: `kubectl --context admin@<cluster> delete namespace paperless-restore-test` (the operator). The PVs of the
   NAS are not touched (do not create PVs with the same names).
Pass criteria: restored database reachable, document counts match within the backup interval, one document
opens.

## 9. Security

- Exposure: tailnet only, through the Tailscale Ingress; no public route. The NAS share is reachable from the
  LAN by SMB (scanner intake) with the `homelab` account; the share is not on the tailnet (nas-completion D2).
- Authentication: Paperless user accounts; superuser created per section 6.3; optional SSO (WP7). The
  header-login setting `PAPERLESS_ENABLE_HTTP_REMOTE_USER` stays off.
- Pod Security: namespace `paperless` uses the cluster default `baseline` (no label). The Paperless image
  starts as root for its s6 init and then drops to uid 1000; `baseline` allows that. `allowPrivilegeEscalation:
  false` and the default seccomp profile are set. A read-only root filesystem and `runAsNonRoot` are NOT set
  for the web pod because the image needs to write to its own tree and to chown at start [UNVERIFIED]; the
  rootless variant of the image is documented upstream [UNVERIFIED] and is a possible later hardening.
  Valkey and the exporter run non-root with all capabilities dropped; Valkey's root filesystem is read-only.
- Least privilege: no ServiceAccount token is needed; add `automountServiceAccountToken: false` to every pod
  spec in WP3 and WP5 (the executor adds it to each Deployment and the CronJob template spec). No RBAC objects
  are created.
- Network: the cluster has no NetworkPolicy convention in the repo [UNVERIFIED: `grep -rn NetworkPolicy talos/`];
  none is added by this plan. CNPG's `paperless-pg-rw` is reachable cluster-wide; accepted for a homelab.
- Secrets: only sealed; the DB password never leaves the cluster; the export contains document text and the
  database content, so protect the `backups` share like the originals (D3).
- Data sensitivity: documents are personal (IDs, tax). The sensitive-field encryption of the export needs
  `--passphrase` (C8); decide with D6 when the export leaves the pool.

## 10. Operations

Upgrade procedure (a PR each time):
1. Read the GitHub release notes for every version between the current and the target tag.
2. Make sure the last CNPG backup is `Completed` and the last export finished.
3. Resolve the new digest (section 3.1); replace the image in `deployment.yaml` AND `export-cronjob.yaml`
   (same tag and digest in both; the exporter and importer need matching versions [verified]).
4. Guards, draft PR, the operator merges and syncs `paperless`. The migration runs on start; watch
   `kubectl --context admin@<cluster> -n paperless logs deploy/paperless-web -f`.
5. Roll back by reverting the PR only if no migration ran; after a migration restore from the CNPG backup
   (section 8).
Valkey and Tika/Gotenberg: bump the digest the same way.

Health checks (read-only):
- `kubectl --context admin@<cluster> -n paperless get pods,cluster,scheduledbackup,backup,cronjob,job`
- `kubectl --context admin@<cluster> -n paperless top pods`
- `kubectl --context admin@<cluster> top nodes` (mini01 memory stays under 85 percent)
- Paperless "Tasks" and "Status" page in the UI shows consumer, index, classifier health.
- Logs: `kubectl --context admin@<cluster> -n paperless logs deploy/paperless-web --tail=200`.

Troubleshooting:

| Symptom | Where to look | Likely cause | Fix |
|---|---|---|---|
| web pod `CrashLoopBackOff`, log says secret key missing | `logs`, `describe secret paperless-secrets` | sealed Secret absent or `PAPERLESS_SECRET_KEY` missing | WP2: reseal and sync |
| web pod `CreateContainerConfigError` | `describe pod` | `paperless-pg-app` or `paperless-secrets` missing, or key name differs | confirm the key with `describe secret`; fix the `secretKeyRef` in a PR |
| pod stays `ContainerCreating` | `describe pod` events | SMB mount error (credentials, `samba-nas` down) or PVC Pending | check `nas` pods and `smb-csi-credentials`; check the PV/PVC status |
| `chown` errors in the start log, container exits | `logs` | the s6 scripts cannot chown the SMB mount | report to the operator; the fix is a mount option or a different `subPath` layout decided by him (do not guess) |
| Login page: "CSRF verification failed" or "Bad Request (400)" | browser, `logs` | `PAPERLESS_URL` differs from the address used (http vs https, name typo) | reseal `PAPERLESS_URL` with the exact address; if the proxy does not pass the scheme, add `PAPERLESS_PROXY_SSL_HEADER='["HTTP_X_FORWARDED_PROTO", "https"]'` [UNVERIFIED setting, confirm in configuration.md] |
| Files in consume are not picked up | `logs`, Status page | polling interval, wrong subfolder, filename ignored | wait 30 s plus OCR time; check `PAPERLESS_CONSUMER_POLLING_INTERVAL=30`; the file must be in `consume` (or a subfolder with RECURSIVE) |
| Document fails with OCR error | Tasks page, `logs` | missing language pack or out-of-memory | set `PAPERLESS_OCR_LANGUAGES`; for `OOMKilled` see section 4.4 |
| Search index empty after restore | UI | index rebuilt separately | run the reindex command from administration.md [UNVERIFIED name] |
| Ingress has no address | `describe ingress`, `-n tailscale logs` | tailscale operator, stale device `paperless` | section WP3 PR step 4 |
| CNPG backup `Failed` / WAL archive error | `kubectl -n paperless describe cluster paperless-pg` | bucket or user missing, wrong S3 pair | B1/B3 in WP2 |
| Exporter job fails | `logs job/<name>` | wrong working dir, DB unreachable | adjust `workingDir`; check the Service name `paperless-pg-rw` |
| Pod cannot be scheduled | `describe pod` | node memory | free memory or decide D4 |

## 11. Acceptance checklist and report format

The operator should see all of this:
- [ ] `https://paperless.<tailnet-name>` shows the login page with a valid certificate.
- [ ] Login works; the user list shows only the operator's user.
- [ ] A PDF in the consume share becomes a searchable document; searching a word inside a scanned page finds it.
- [ ] Phone/scanner upload to the LAN share `paperless/consume` works with the NAS account.
- [ ] `kubectl --context admin@<cluster> -n paperless get cluster paperless-pg` is healthy and `get backup` has a `completed` entry.
- [ ] `paperless-nightly` produced a Completed backup with a PodVolumeBackup for `data`.
- [ ] `manifest.json` exists in the `backups` share folder `paperless-export`.
- [ ] Restore test passed; scratch namespace deleted.
- [ ] Credentials C1, C2 (and C5/C8/C10 when used) are saved in Vaultwarden.
- [ ] `docs/BACKLOG.md` and `docs/dr/talos-backups.md` updated (WP6).

Report format after each package:
```
WP<n>: done|blocked|needs decision
PR: <url>
Guards: <20 OK | the failing guard and file>
Verified: <the commands run and their results>
Differences from the plan: <anything you changed or found different>
Needs from the operator: <the exact list>
```

## 12. Open questions and UNVERIFIED items

Open decisions: D1 to D9 (section 5).

UNVERIFIED (each with how to confirm):
1. Container tag form `3.3.4` and its digest: registry query, section 3.1.
2. Concrete Valkey, Tika, Gotenberg tags and the Gotenberg command line: official compose files in
   `docker/compose/` of the Paperless repository; Docker Hub tag pages.
3. Supported PostgreSQL major for Paperless 3.3 and the CNPG default image: Paperless `docs/setup.md`
   requirements; `kubectl ... get cluster immich-pg -o jsonpath='{.status.image}'`.
4. Value of `PAPERLESS_DBENGINE` for PostgreSQL: `configuration.md`.
5. Health endpoint: first-start log; `/` returns below 400.
6. `chown` behaviour on the CIFS mount with fixed uid/gid, and whether the image tolerates it.
7. Memory use under OCR (no official figure): watch `kubectl top pods` during the first 20 documents and
   adjust limits.
8. Command forms in a Kubernetes pod (`createsuperuser`, `python3 manage.py ...`, working directory
   `/usr/src/paperless/src`, `changepassword`, reindex command name): `ls` and `--help` inside the pod
   (the operator) and `administration.md`.
9. CNPG Secret key names in `paperless-pg-app` and `affinity.nodeSelector` in the 1.25 API.
10. Authentik OIDC URL pattern and allauth callback path (WP7).
11. `PAPERLESS_PROXY_SSL_HEADER` and `_FILE` suffix support.
12. Exporter run through `manage.py` in a separate pod without `PAPERLESS_DATA_DIR`; manifest.json format.
13. Effect of rotating `PAPERLESS_SECRET_KEY` on stored signed data (only sessions confirmed by general
    Django behaviour, not the Paperless pages read).
14. Whether `kubectl kustomize` accepts an empty `resources: []` (WP1 step 3 has a fallback).
15. `[ASSUMED]` interfaces: namespace `authentik`; Secret `smb-csi-credentials-paperless`; `mini03` node
    name; the `backup-replica` plan copying the `backups` share; OCR languages `por+eng`; time zone
    `Europe/Lisbon`.

## Appendix A. Notes for D2 (Tika and Gotenberg)

Enable only after WP3 works. Resource cost 1 GiB requests. The two Services must be named exactly
`paperless-tika` and `paperless-gotenberg` so the three environment variables in WP3 step 6 resolve. A
failing Tika or Gotenberg does not stop PDF and image consumption; it only fails Office and email documents.
