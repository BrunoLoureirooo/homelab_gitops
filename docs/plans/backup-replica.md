# Plan: the backup replica on mini03 and the offsite copy of the photo library

Audience: a local language model working on this repository for the operator. Follow it literally, one work
package at a time. Where it says STOP, stop and report to the operator; do not decide for him.

Written 2026-10-25. Two parts in one document, one concern per pull request:

- Part A: a second copy of the Velero backups on mini03 (MinIO replica, fed by a mirror CronJob).
- Part B: a third copy of the Immich photo library (and the databases) outside the house, as a third
  Velero BackupStorageLocation in an S3-compatible cloud bucket (recommended: Backblaze B2).

Markers: `[verified <url>]` means a fact read from the official source on 2026-10-25 (or, for
`[verified live]`, read from the running cluster with a read-only command on that day).
`[UNVERIFIED]` means not confirmed; the text says how the executor confirms it. `[ASSUMED]` means an
interface owned by another plan that this plan expects to exist.

## 0. Purpose, scope, non-goals, definition of done

### Purpose

Today every backup lives on mini02: Velero data, the Vaultwarden Litestream replica and the Immich
Postgres WAL archive are all in MinIO on the ZFS dataset `tank/backups`, and the photo library itself
lives on `tank/immich` of the same pool. `talos/STORAGE-DECISION.md` ("Risk, stated plainly") says it:
losing mini02 (the machine, its network path, or both disks) loses the photos AND every backup of them.
This plan creates two more copies:

1. Part A, replica on mini03 (the VM on victus, still in a different failure domain than mini02, but in
   the same house and on a desktop). Protects against loss of mini02 or of the `tank` pool.
2. Part B, offsite in a cloud bucket. Protects against fire, theft, a power surge that kills mini02 and
   victus, and ransomware on the LAN. It is the only copy outside the house.

### Scope

- Part A: MinIO replica on mini03; mirror CronJob; two MinIO users plus a read-only restore user; the
  policies; sealed credentials; a read-only Velero BackupStorageLocation used for restore from the replica
  alone (through a separate scratch Velero, see WP6, because of a Velero name-collision limit); alerting
  hooks; sizing; a restore drill from the replica only.
- Part B: option comparison with current prices; a third BackupStorageLocation `offsite`; a schedule
  `homeserver-offsite`; a small mirror of the two database buckets; credentials; a restore drill.

### Non-goals

- No new backup tool. The operator decided Velero is the only backup tool (Kopia as a separate tool was removed,
  `docs/dr/talos-backups.md`, "Photo library"). Velero uses Kopia internally as its uploader; that is not
  a second tool. The only other binary used is `mc` (MinIO client) for bucket-to-bucket copies.
- Nothing backup-related goes back onto victus itself (the operator, 2026-10-17). The replica runs in the VM
  mini03, not on the victus host. (Option C of Part B, a USB disk on victus, conflicts with this and is
  presented as a decision.)
- No change to the primary backup target (`talos/manifests/backup-target`), to the existing schedules'
  cadence, or to Velero's default location.
- This plan builds nothing until mini03 exists (sibling plan `mini03-vm`). Part B does not need mini03.

### Definition of done (checklist)

Part A:

- [ ] `minio-replica` runs on mini03 over the `backups` volume; `velero-backup-replica` Service resolves.
- [ ] The three buckets exist on the replica; users `replica-writer` and `replica-restore` exist there;
      user `replica-reader` exists on the primary; policies attached.
- [ ] The CronJob `backup-replica-mirror` completed once by hand (first mirror) and once by schedule.
- [ ] Default mirror does NOT delete on the replica what the primary deleted; a suspended CronJob
      `backup-replica-prune-sync` exists for the manual clean-up.
- [ ] The 80% guard is proven (WP4 step 7).
- [ ] An alert fires on a failed or stale mirror (WP5; may be waiting for the monitoring plan).
- [ ] A restore drill from the replica ALONE passed: file count, sha256 sample of 200 files (WP6).
- [ ] Every credential is in the operator's password manager and sealed in `talos/sealed-secrets/`.

Part B:

- [ ] the operator answered decisions B1 to B8.
- [ ] A private bucket and a bucket-restricted application key exist; the key is sealed.
- [ ] BackupStorageLocation `offsite` is `Available`.
- [ ] A seed backup of namespace `homeserver` to `offsite` is `Completed`, with a `Completed`
      PodVolumeBackup for volume `data` of about 55 GB.
- [ ] Schedule `homeserver-offsite` runs; the database mirror to the bucket runs.
- [ ] A restore drill from the offsite copy alone passed (WP11).

## 1. Rules for the executor

1. You change files in the repository and open DRAFT pull requests. **Nothing else.** the operator merges and
   syncs Argo CD apps himself. Never change the live cluster. Do not suggest `kubectl apply`, `patch`,
   `edit` or any live change as a way to ship work. Steps that the operator runs by hand are marked
   "the operator" and are limited to: creating users and buckets inside MinIO and B2, sealing secrets, one-off
   Jobs created from a committed CronJob, and restore drills.
2. Allowed cluster access is read-only: `get`, `describe`, `logs`, `top`, and `exec ... -- <read-only
   command>`. Always pass `--context admin@<cluster>`. Forbidden for you: `apply`, `create`, `delete`,
   `patch`, `edit`, `scale`, `rollout`, `label`, `annotate`, `drain`, `cordon`, `taint`, any `talosctl`
   write command and any `argocd app sync`.
3. Secrets never enter the repository in clear text, a chat, a log or a PR description. Never run
   `get secret -o yaml/json/jsonpath` yourself. `describe secret` shows key names only. If a command prints
   a secret, stop and tell the operator.
4. Do not write IPv4 addresses, CIDRs, MAC addresses, disk serial numbers, `/dev/disk/by-id` names or any
   host name ending in the tailnet suffix into any committed file. Use `<node-ip>`, `<tailnet-name>`.
   In-cluster DNS names such as `velero-backup-replica.velero.svc.cluster.local` are fine. The B2 endpoint
   `s3.<region>.backblazeb2.com` is not a host detail and may be committed once the operator has chosen the
   region.
5. One concern per pull request. Branch from current `origin/main`:
   `git fetch origin && git switch -c <branch> origin/main`. Open PRs as drafts. Never push to `main`, never
   force-push, never merge, never delete a branch. Commit messages end with the line
   `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; PR descriptions end with the line
   `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
6. Before every commit run `bash .github/scripts/run-all-guards.sh`. All 20 lines must start with `OK`.
   Never edit a guard to make it pass.
7. After changing `talos/apps-src/*.yaml` run `talos/render-apps.sh --force` and commit the result under
   `talos/apps/`. Every new Application needs a line in `talos/test/empty-cluster-expectations.txt`
   (read two existing lines first and copy the column layout).
8. Every PVC sets `storageClassName: topolvm-fast` (the cluster's only StorageClass is not the default).
   This plan creates no PVC; if you find yourself writing one, you went wrong.
9. Every container sets explicit `resources`. Images are pinned by digest (section 3 says how).
10. If something here does not match what you see, trust what you see, write the difference in your
    report, and ask the operator. Do not guess. Never decide a decision of section 5.
11. STOP conditions (stop and report, do not continue): a guard fails and you cannot fix it by a
    legitimate change; `mini03` is not `Ready` (for Part A); an Argo diff shows a change to the primary
    MinIO or to the live Velero BackupStorageLocation `default`; a command prints a credential; a command
    you must run is not in this plan; any expected output differs and the troubleshooting table
    (section 10) does not explain it.

## 2. Prerequisites and dependencies

All commands read-only, with `--context admin@<cluster>`. Abbreviation used below:
`K="kubectl --context admin@<cluster>"` (write the full command in your shell; do not rely on a variable
persisting between calls).

| # | Needed | Proof command | Expected | If not |
|---|---|---|---|---|
| P1 | Cluster reachable | `kubectl --context admin@<cluster> get nodes` | mini01 `Ready`; mini02 `Ready,SchedulingDisabled` (cordoned on purpose) | STOP |
| P2 | Primary MinIO and Velero healthy | `kubectl --context admin@<cluster> -n velero get pods,backupstoragelocations` | `minio-*` and `velero-*` Running; BSL `default` phase `Available` | STOP, report |
| P3 | Nightly backups complete | `kubectl --context admin@<cluster> -n velero get backups.velero.io --sort-by=.metadata.creationTimestamp` | newest `velero-homeserver-nightly-*` has phase `Completed` (use `-o custom-columns=N:.metadata.name,PHASE:.status.phase`) | STOP |
| P4 | Part A only: node mini03 Ready | `kubectl --context admin@<cluster> get node mini03` | `Ready` | STOP Part A; Part B can proceed. Sibling plan `mini03-vm` owns the node |
| P5 | Part A only: mini03 taint and the `backups` volume | `kubectl --context admin@<cluster> get node mini03 -o jsonpath='{.spec.taints}'` | contains key `node-role.homeserver/tier`, value `mobile`, effect `NoSchedule` `[ASSUMED]` (taken from draft PR #71) | Use the taint you see in the manifests; report the difference |
| P6 | Part A only: the volume is mounted on mini03 at `/var/mnt/backups`, 128 GiB | After the replica Deployment exists: `kubectl --context admin@<cluster> -n velero exec deploy/minio-replica -c minio -- df -h /data` | Size about 128G (xfs) | STOP, tell the operator; the `mini03-vm` plan owns the volume |
| P7 | Sealed Secrets controller works | `kubectl --context admin@<cluster> -n velero describe secret minio-root` | shows key names `MINIO_ROOT_PASSWORD`, `MINIO_ROOT_USER` and annotation `sealedsecrets.bitnami.com/managed: true` | STOP |
| P8 | Part A drill and Part B drill: free space on mini01 for a restore of the 55 GB library | `kubectl --context admin@<cluster> get --raw /api/v1/nodes/mini01/proxy/stats/summary` and read `.node.fs.availableBytes` | on 2026-10-25: about 93 GB available of 107 GB `[verified live]` | If under 75 GB, ask the operator where to restore (decision A5) |
| P9 | Monitoring (alerts, WP5) | `kubectl --context admin@<cluster> get ns monitoring` and `kubectl --context admin@<cluster> get crd prometheusrules.monitoring.coreos.com` | both exist `[ASSUMED]` from the monitoring plan | Skip WP5, do the rest, report |
| P10 | Draft PR #71 state | `gh pr view 71 --json state,isDraft,headRefName` | on 2026-10-25: `OPEN`, draft, branch `talos/mini03-backup-replica` | See WP2 step 1 for both cases |

What depends on this plan:

- Disaster-recovery documentation (`docs/dr/mini03.md`, `docs/dr/talos-backups.md`) refers to the replica.
- The monitoring plan consumes the alert rule in WP5 `[ASSUMED]`.
- The NAS plan (`docs/plans/nas-completion.md`, decision D4 "second copy of the photo library") is answered
  by Part B.

## 3. Facts about this service

### 3.1 What exists today (read from the repo and the cluster on 2026-10-25)

| Fact | Value | Source |
|---|---|---|
| Velero | server `v1.18.1`, chart `velero-12.1.0`, plugin `velero-plugin-for-aws:v1.13.1`, uploader `kopia` | `[verified live]` `kubectl -n velero get deploy velero -o jsonpath` image; `argocd/apps/velero.yaml`; `argocd/values/velero.yaml` |
| Primary MinIO | Deployment `minio` in ns `velero`, hostPath `/var/mnt/tank/backups`, Service `velero-backup-target:9000`, root Secret `minio-root` | `talos/manifests/backup-target/minio.yaml` |
| MinIO server image | `cgr.dev/chainguard/minio@sha256:c93745c56fccdaf0e5dcb88999a96a65a136428beb045ef5d546255a80d747a7` (tag `chainguard-2026-10-17`) | `talos/dr/images.env` |
| mc image | `cgr.dev/chainguard/minio-client@sha256:d8a93c5d335509ff353774eefec8f82fa2a2a975e800139702232d8be3dbe6b9` (tag `chainguard-2026-10-17`) | `talos/dr/images.env`; has no shell, entrypoint is `mc` |
| `mc` inside the MinIO SERVER image | the server image also contains `mc` and `bash` (`mc --version` printed `mc version DEVELOPMENT.GOGET`; `ls /usr/bin` lists `bash`) | `[verified live]` `kubectl -n velero exec deploy/minio -c minio -- mc --version` |
| Buckets | `velero-backups`, `litestream`, `immich-pg`; users `velero`, `litestream`, `immich-pg` each scoped to its bucket (policy template `talos/dr/minio/policy.json.tmpl`) | `talos/dr/minio/setup-users.sh` |
| Sizes today | `tank/backups` quota 128G, used 53G (41%); `velero-backups` 52 GB (almost all `kopia/`), `litestream` 1.4 MB, `immich-pg` 380 MB | `[verified live]` `df -h /data` and `du -sh /data/<bucket>` via `exec deploy/minio -c minio` |
| Backup duration | nightly `homeserver` backup takes about 45 to 55 seconds (incremental, 10:00 UTC); PodVolumeBackup for volume `data` of about 54.9 GB | `[verified live]` `kubectl get backups.velero.io -o custom-columns=...` |
| Schedules | `velero-homeserver-nightly` `0 10 * * *`, ttl `720h`; `velero-cp-reserva-bot-nightly` `30 3 * * *` | `[verified live]`; `talos/values/velero.yaml` |
| Opt-in annotation | `backup.velero.io/backup-volumes: data` on the `immich-server` pod template (library at `/data` inside the pod); Vaultwarden carries it too | `[verified live]` |
| Library claim | PVC `immich-library-smb` 64Gi, static PV `immich-library-smb`, `storageClassName: ""`, backed by SMB share `immich` on mini02 | `[verified live]` |
| Postgres backups | CNPG `immich-pg`: WAL archive plus daily base backup 02:30 UTC to bucket `immich-pg`, retained 14 days. NOT covered by Velero | `docs/dr/talos-backups.md` |
| Vaultwarden | Litestream to bucket `litestream` every second, plus Velero | `docs/dr/talos-backups.md` |
| Credentials file format for Velero | Secret `cloud-credentials` (ns velero) key `cloud`, an AWS-style credentials file | `[verified live]` key name via `describe secret`; `docs/dr/talos-backups.md` |
| Sealed secrets | only in `talos/sealed-secrets/`, each file listed in its `kustomization.yaml`; delivered by auto-sync app `talos-sealed-secrets` | repo |
| Namespace `velero` | Pod Security `privileged` | `[verified live]` label; `talos/manifests/namespaces/namespaces.yaml` |
| Node resources now | mini01 CPU 1684m (42%), memory 5182Mi (46%); mini02 CPU 122m, memory 1192Mi (16%) | `[verified live]` `kubectl top nodes` on 2026-10-25 |
| Kopia maintenance | Velero runs `*-kopia-maintain-job-*` Jobs hourly (completed pods visible in ns velero) | `[verified live]` |

### 3.2 Facts about Velero used by this plan

- A backup goes to exactly ONE location; redundancy across locations is done with separate schedules.
  [verified https://velero.io/docs/v1.4/locations/] (older doc, restated by the search result summarising it;
  re-confirm on https://velero.io/docs/main/locations/ `[UNVERIFIED]` for 1.18).
- BackupStorageLocation fields: `provider`, `objectStorage.bucket`, `objectStorage.prefix`, `accessMode`
  (`ReadWrite` default, or `ReadOnly`), `credential.name`/`credential.key` (Secret in the Velero namespace),
  `backupSyncPeriod`, `validationFrequency`, `config`. [verified https://velero.io/docs/main/api-types/backupstoragelocation/]
- The Helm chart 12.1.0 template renders per-location `credential{name,key}`, `accessMode`, `prefix`,
  `validationFrequency`, `backupSyncPeriod`, `default`, and every `config` entry as a quoted string, and a
  Schedule supports `paused`, `skipImmediately`, and a `template` block. [verified by rendering/reading
  `velero/templates/backupstoragelocation.yaml` and `schedule.yaml` of chart 12.1.0, pulled with
  `helm pull velero --repo https://vmware-tanzu.github.io/helm-charts --version 12.1.0 --untar`]
- A list in Helm values is replaced, not merged: when `talos/values/velero.yaml` lists a location, it must
  repeat `default` (already noted in that file).
- aws plugin `config` keys: `region`, `s3ForcePathStyle`, `s3Url`, `checksumAlgorithm` (`CRC32` default,
  `CRC32C`, `SHA1`, `SHA256`, empty string disables), `serverSideEncryption`, `customerKeyEncryptionFile`,
  `customerKeyEncryptionSecret`, `profile`. [verified https://github.com/vmware-tanzu/velero-plugin-for-aws/blob/main/backupstoragelocation.md]
- Backblaze B2 needs `checksumAlgorithm: ""` with the aws plugin, otherwise `XAmzContentSHA256Mismatch`.
  [verified https://github.com/vmware-tanzu/velero-plugin-for-aws (README table, "Backblaze B2 | checksumAlgorithm=\"\"")
  and https://github.com/vmware-tanzu/velero/issues/8667]
- Kopia repository encryption: "Velero uses a static, common encryption key for all backup repositories it
  creates ... anyone who has access to your backup storage can decrypt your backup data." The password sits
  in Secret `velero-repo-credentials` key `repository-password`; changing it after the first backup breaks
  access to older backups. [verified https://velero.io/docs/main/file-system-backup/]
- Same backup name in two locations: Velero's sync controller had a bug/limitation where a backup name that
  already exists with another location is not shown (issue https://github.com/velero-io/velero/issues/3026).
  Current behaviour in 1.18 `[UNVERIFIED]`. The plan avoids the situation by design (a scratch Velero for the
  replica, WP6).
- Resource modifiers (JSON patch on restore) exist: ConfigMap in the Velero namespace with `version: v1` and
  `resourceModifierRules`, referenced with `velero restore create --resource-modifier-configmap NAME`.
  [verified https://velero.io/docs/main/restore-resource-modifiers/]. A patch of `/spec/volumeName` is not
  documented; WP6 tests it.

### 3.3 Facts about mc used by this plan

- `mc mirror SRC DST`: `--overwrite` overwrites objects that differ at the target (without it an existing
  object fails and is logged); `--remove` "removes object(s) on the Target that do not exist on the Source";
  without `--remove` target-only objects stay. `--dry-run`, `--retry`, `--skip-errors`, `--exclude`,
  `--limit-upload`, `--preserve` exist. [verified https://docs.min.io/enterprise/aistor-object-store/reference/cli/mc-mirror/]
- The alias can be given by environment variable `MC_HOST_<alias>=scheme://ACCESS:SECRET@host:port`; the
  draft PR #71 already uses `MC_HOST_primary` and `MC_HOST_replica`. The exact page for this variable was not
  re-read today: `[UNVERIFIED]` for the doc URL, but `mc` in the image prints it in `mc --help` under
  "ENVIRONMENT VARIABLES"; the executor confirms with `kubectl ... exec deploy/minio -c minio -- mc --help | grep MC_HOST`.

### 3.4 Backblaze B2 facts (prices read 2026-10-25)

| Fact | Value | Source |
|---|---|---|
| Storage price | "$6.95 / TB / mo", billed per 30 days on byte-hours; first 10 GB free | [verified https://www.backblaze.com/cloud-storage/pricing] |
| Egress | free up to 3x the average monthly stored data, then $0.01/GB | same |
| Transactions | Class A, B, C free; Class D $0.004 per 10,000, first 2,500 per day free | same |
| Minimum storage duration / minimum file size | none | same |
| S3 endpoint | `s3.<region>.backblazeb2.com` (region like `us-west-004`); HTTPS only; an account is tied to one region | [verified https://www.backblaze.com/apidocs/introduction-to-the-s3-compatible-api and https://help.backblaze.com/hc/en-us/articles/360047425453-Getting-Started-with-the-S3-Compatible-API] |
| Keys | the master key does NOT work with the S3 API; keyID = access key, applicationKey = secret; a bucket-restricted key needs the `listAllBucketNames` capability | same |
| Signatures | SigV4 only | same |
| Server-side encryption | SSE-B2 and SSE-C supported, SSE-KMS not | same |
| Lifecycle default | "Keep all versions"; hidden versions still count as stored data; "Keep only the last version" hides then deletes the old version one day later | [verified https://www.backblaze.com/docs/cloud-storage-lifecycle-rules] |
| Alternative: Cloudflare R2 | storage $0.015 per GB-month (about $15/TB), Class A $4.50 per million, Class B $0.36 per million, egress free, free tier 10 GB | [verified https://developers.cloudflare.com/r2/pricing/] |

## 4. Architecture and placement

```
 mini01 (Velero server runs on mini02, node-agent on mini01+mini02)

 immich-server pod --(SMB)--> share "immich" on mini02 (tank/immich)

 Velero (ns velero, on mini02)
   |-- schedule homeserver-nightly 10:00 UTC --> BSL "default" --> MinIO "minio"  (mini02, tank/backups)
   |                                                                   |  read-only user replica-reader
   |                                                                   v
   |                         CronJob backup-replica-mirror 13:00 UTC (mini03)   mc mirror --overwrite (no --remove)
   |                                                                   |  user replica-writer
   |                                                                   v
   |                                                         MinIO "minio-replica" (mini03, volume "backups" 128 GiB)
   |
   `-- schedule homeserver-offsite 11:00 UTC --> BSL "offsite" --> Backblaze B2 bucket (own Kopia repo, own backups)

 CronJob backup-offsite-db-mirror 03:30 UTC:  MinIO buckets immich-pg + litestream --mc mirror--> B2 (prefix db-mirror/)

 DR/drill only (manual-sync Argo app, namespace velero-drill):
   second Velero + node-agent, BSL "replica" (ReadOnly, mini03 MinIO)  and BSL "offsite" (ReadOnly, B2)
```

### Placement and reasoning

| Component | Node | Namespace | Storage | Why |
|---|---|---|---|---|
| `minio-replica` Deployment | mini03 (nodeSelector `kubernetes.io/hostname: mini03`, toleration for the mini03 taint `[ASSUMED]`) | `velero` (already privileged, hostPath allowed) | hostPath `/var/mnt/backups` (Talos user volume `backups`, 128 GiB xfs) | hostPath is the pattern of the primary; it is not a PVC, so Velero does not back it up (correct) |
| `backup-replica-mirror` CronJob | mini03 | `velero` | `emptyDir` for mc config; read-only hostPath for the size gate | the job writes to local MinIO over the pod network, reads the primary over the network |
| `backup-replica-prune-sync` CronJob (suspended) | mini03 | `velero` | same | manual clean-up with `--remove` |
| `backup-offsite-db-mirror` CronJob | unpinned (scheduler picks a schedulable worker) | `velero` | `emptyDir` | tiny; talks to MinIO and the internet |
| scratch Velero (`velero-drill`) | mini02 server like the primary? no: unpinned, node-agent on the nodes that can run it | `velero-drill` | none | isolates the replica BSL from the primary (name-collision) |

Resource sizing (reasoned against node capacity):

- `minio-replica`: requests 50m CPU / 256Mi, limits 500m CPU / 1Gi. mini03 has 4 vCPU and 8 GiB shared with
  the arr stack and torrent client (sibling plans); MinIO idle is tens of MiB. The draft sets no CPU limit;
  this plan adds 500m so the replica cannot starve the arr apps.
- Mirror pods: requests 50m / 64Mi, limits 500m CPU / 256Mi memory. `mc mirror` streams; on a 55 GB first
  copy it uses a few hundred MB at most with default workers. If the pod is OOM-killed (troubleshooting
  table) raise the limit to 512Mi in a PR.
- Offsite DB mirror: requests 25m / 32Mi, limits 250m / 128Mi (380 MB of data in total).
- Velero offsite upload runs inside the existing node-agent on mini01 (limits 500m CPU / 512Mi in
  `argocd/values/velero.yaml`). The first 55 GB upload will pin that limit for hours; mini01 is at 42% CPU.
  Do not raise limits in this plan; tell the operator it will be slow but safe (WP9).
- Network: the first mirror copies about 52 GB from mini02 to the VM on victus over the LAN; a gigabit LAN
  needs about 8 minutes of pure transfer, real 20 to 60 minutes. The draft README says "hours"; that is
  pessimistic. Report the real time.

### Sizing math: the 128 GiB replica volume against tank/backups

Measured on 2026-10-25 `[verified live]` (read-only `df`/`du` inside the primary MinIO pod, which sees the
`tank/backups` dataset):

| Item | Value |
|---|---|
| `tank/backups` quota | 128G |
| used | 53G (41%), available 76G |
| `velero-backups` | 52 GB (`kopia/` 52863 MB, `backups/` 6 MB) |
| `immich-pg` | 380 MB |
| `litestream` | 1.4 MB |

The replica volume is 128 GiB = 137.4 GB. At 53 GB used the first copy needs 39% of it.

Guard: the size gate refuses at `df` use >= 80% = 102.4 GiB = 110 GB. Headroom from today to the guard:
110 - 53 = 57 GB.

Why the default (no `--remove`) grows faster than the primary: Kopia's hourly maintenance deletes blobs
that no snapshot references any more (after TTL 720h expiry, and after content rewrites). The primary
shrinks back; the replica, which never removes, keeps them. Growth of the replica per month is therefore
(net photo growth) + (all blobs the primary garbage-collected that month). Neither number is measured yet:
there are only 8 days of history. The measurement plan (WP4 step 8): record `mc du` of both sides on the 1st
and 15th of each month for three months. Until then use the bracket:

| Scenario | Growth per month | Time from 53 GB to the 80% guard (57 GB headroom) |
|---|---|---|
| Photos only, 3 GB/month, no garbage | 3 GB | 19 months |
| 3 GB photos + 3 GB GC garbage | 6 GB | 9.5 months |
| 3 GB photos + 8 GB GC garbage | 11 GB | 5 months |

When the replica reaches 70% (96 GB) the operator runs the clean-up job (WP2 step 8, `backup-replica-prune-sync`,
which uses `--remove` once and brings the replica back to the primary's size, about 53 GB). Cost of that
clean-up: for one moment the replica equals the primary, so deleted-but-still-referenced history is gone
(the replica never held anything the primary lacks except things deleted by TTL). That is why it is manual.

Safety rule for the clean-up (also printed in the CronJob comment): never run it when the primary looks
wrong (empty, small, or after a restore of mini02). `--remove` would copy the emptiness onto the replica.
The operator checks the primary size by hand before creating the Job (WP4 step 9): the mc image has no shell,
so the Job cannot check it itself.

Part B size: the offsite copy starts at about 55 GB (the library) plus about 1 GB of everything else; see
Part B cost table.

## 5. Decisions for the operator

STOP at any package that depends on an unanswered decision. Defaults are proposals only.

### Part A

| Id | Question | Options and trade-offs | Recommended default | What changes otherwise |
|---|---|---|---|---|
| A1 | Mirror with or without `--remove`? | (a) no `--remove`: replica keeps what the primary deleted; protects against an accidental deletion or wipe on the primary propagating; grows faster (sizing table). (b) `--remove`: replica = primary; stays small; a wipe of the primary is copied within a day. The draft PR #71 uses (b). | (a) no `--remove`, plus a manually triggered clean-up Job with `--remove` | If (b): drop the prune CronJob, add `--remove` in the three mirror args, change section 4 sizing |
| A2 | Mirror schedule | daily 13:00 UTC (draft: 3 hours after the 10:00 backup; the backup takes under a minute so a mirror at 10:30 would also work); or hourly | daily 13:00 UTC | If hourly: change `schedule`, accept more wear and chatter; RPO of the replica improves from 27 h worst case to 1 h |
| A3 | Is `replica-restore` (read-only) enough for the drill? | read-only is least privilege but Kopia may want to write (e.g. repository maintenance lock) `[UNVERIFIED]`; then the drill must use `replica-writer` (safe because the replica is a copy; the next mirror with `--overwrite` fixes any difference) | try read-only first, fall back to writer for the drill only | Edit the drill secret only |
| A4 | Alerting channel | the monitoring plan decides where alerts go `[ASSUMED]` | use whatever the monitoring plan provides | WP5 only |
| A5 | Where to restore the 55 GB library for the drill | mini01 `topolvm-fast` (about 93 GB free now; fills it to about 88%), or mini03 staging (283 GiB, but not a StorageClass: needs a PV, more work) | mini01, delete right after the drill | If free space under 75 GB at drill time, pick mini03 staging and ask for a plan |
| A6 | How often to rerun the replica drill | each quarter; or only after changes | quarterly, and once now | calendar only |

### Part B

| Id | Question | Options and trade-offs | Recommended default | What changes otherwise |
|---|---|---|---|---|
| B1 | Which offsite copy? | (a) S3 cloud bucket (Backblaze B2) as third Velero location; (b) USB disk attached to victus; (c) both. See the comparison table in WP7. | (a) B2 | (b) conflicts with "nothing backup-related on victus" and is manual (disk must be plugged in); (c) adds a fourth location; plan the USB part separately |
| B2 | Provider | B2 about $6.95/TB/month (verified above), R2 about $15/TB/month, others not researched | B2 | Only values change (`s3Url`, `region`, checksum setting); R2's checksum requirements `[UNVERIFIED]` |
| B3 | Region and bucket name | B2 account region is fixed at account creation; EU vs US affects latency only. Bucket name is global; use a long random name | The operator picks at account creation; write `<b2-region>` in the PR only after he decided | none |
| B4 | Encryption stance | (a) accept Velero's static Kopia key + private bucket + bucket-scoped key + B2 SSE-B2; (b) replace `velero-repo-credentials` with a private password (global for all repos: forces new repositories for the primary too, losing old history; do this ONLY with a full re-seed plan); (c) true client-side encryption with another tool (rclone crypt) = contradicts "Velero only" | (a) now, revisit (b) only if the operator wants provider-proof secrecy | (b) needs its own plan; (c) rejected unless the operator reverses the one-tool decision |
| B5 | Retention of the offsite copy | `ttl` 720h (30 days, same as primary), or 2160h (90 days) | 720h: Kopia stores only changed blobs, cost is small either way; 90 days costs a little more and defends against slow corruption | change `ttl` in values |
| B6 | Offsite schedule | daily 11:00 UTC (after the 10:00 backup so the SMB read is not simultaneous), or weekly Sunday | daily | weekly: change cron; RPO up to 7 days |
| B7 | Mirror the databases (`immich-pg`, `litestream`) offsite too? | A photo-only restore loses albums, faces, tags (they live in Postgres). 380 MB + 1.4 MB, negligible cost. | yes, CronJob `backup-offsite-db-mirror` | If no: WP10 skips the CronJob; document that the offsite is photos-only |
| B8 | Two application keys (read-write for the schedule, read-only for drills)? | two keys: a leaked drill key cannot delete the offsite copy; one more secret | two keys | one key: use the same Secret for both |

## 6. Credentials and secret handling

Principles: The operator generates every secret on his Mac with a command that does not echo it (clipboard or
file with mode 0600 outside any git work tree), stores it in his password manager (Vaultwarden),
seals it with `kubeseal` against `argocd/sealed-secrets/pub-cert.pem`, and the executor only commits the
ciphertext file. The executor never sees a plaintext value.

### 6.1 Inventory

| # | Credential | What it is | Secret (namespace) and key(s) | Sealed file | Consumed by |
|---|---|---|---|---|---|
| C1 | Primary MinIO root pair | exists already | `minio-root` (velero): `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` | `talos/sealed-secrets/minio-root.yaml` (exists) | primary MinIO; admin work on the primary |
| C2 | Replica MinIO root pair | NEW, random, different from C1 | `minio-replica-root` (velero): `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` | `talos/sealed-secrets/minio-replica-root.yaml` | `minio-replica` (envFrom) |
| C3 | Primary read-only user `replica-reader` | MinIO user on the primary, policy `backup-replica-reader` | no Secret of its own; it is embedded in C5 | n/a | mirror |
| C4 | Replica user `replica-writer` | MinIO user on the replica, policy `backup-replica-writer` | embedded in C5 | n/a | mirror |
| C5 | mc alias pair | two environment variables with full URLs | `backup-replica-mirror` (velero): `MC_HOST_primary`, `MC_HOST_replica` | `talos/sealed-secrets/backup-replica-mirror.yaml` | mirror CronJobs (envFrom) |
| C6 | Replica user `replica-restore` | read-only MinIO user on the replica, policy `backup-replica-reader` | `replica-cloud-credentials` (velero-drill): `cloud` (an AWS-style credentials file) | `talos/sealed-secrets/velero-drill-replica-credentials.yaml` | scratch Velero BSL `replica` |
| C7 | B2 application key (read/write, bucket-restricted) | key ID + application key | `offsite-credentials` (velero): `cloud` | `talos/sealed-secrets/velero-offsite-credentials.yaml` | BSL `offsite` and the schedule |
| C8 | B2 application key (read-only, bucket-restricted) | key ID + application key | `offsite-readonly-credentials` (velero-drill): `cloud` | `talos/sealed-secrets/velero-drill-offsite-credentials.yaml` | scratch Velero BSL `offsite` |
| C9 | Mirror-to-B2 alias | `MC_HOST_primary` (the existing read-only `replica-reader` URL, reused) and `MC_HOST_offsite` (full URL with the C7 key) | `backup-offsite-mirror` (velero): `MC_HOST_primary`, `MC_HOST_offsite` | `talos/sealed-secrets/backup-offsite-mirror.yaml` | `backup-offsite-db-mirror` |
| C10 | Backblaze account login | e-mail + password + 2FA | The operator's password manager only; never in the cluster | n/a | The operator |
| C11 | Velero repository password | Velero's static default (`velero-repo-credentials`) | exists, created by Velero | not sealed, not changed here | Kopia |

### 6.2 Generating the values (the operator; nothing echoes)

All commands in a temporary shell. `umask 077`. Files go in a new directory OUTSIDE the repository, for
example `~/secrets-tmp/backup-replica` (delete it at the end). Set once:

```bash
umask 077; mkdir -p ~/secrets-tmp/backup-replica; cd ~/secrets-tmp/backup-replica
```

Generate (each writes to a file; nothing printed):

```bash
# C2: root pair of the replica (user name fixed, password random)
printf 'replicaroot' > c2-user.txt
openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40 > c2-pass.txt
# C3: replica-reader on the primary
openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32 > c3-reader.txt
# C4: replica-writer on the replica
openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32 > c4-writer.txt
# C6: replica-restore on the replica
openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32 > c6-restore.txt
```

Only letters and digits, so the URL form `http://ACCESS:SECRET@host:9000` needs no escaping. Copy each file's
content into Vaultwarden as an entry named `backup-replica C<n>` (use `pbcopy < file`, paste into the
vault). Keep the user names in the entry too (`replicaroot`, `replica-reader`, `replica-writer`,
`replica-restore`).

### 6.3 Sealing recipes (the operator, offline, no cluster access needed)

Run from the repository root of his checkout of the PR branch of WP3. The sealed file is the only thing
that is committed.

C2 `minio-replica-root`:

```bash
kubectl create secret generic minio-replica-root -n velero \
  --from-file=MINIO_ROOT_USER=$HOME/secrets-tmp/backup-replica/c2-user.txt \
  --from-file=MINIO_ROOT_PASSWORD=$HOME/secrets-tmp/backup-replica/c2-pass.txt \
  --dry-run=client -o json |
  KUBECONFIG=/dev/null kubeseal --cert argocd/sealed-secrets/pub-cert.pem --format yaml \
  > talos/sealed-secrets/minio-replica-root.yaml
```

C5 `backup-replica-mirror` (builds the two URLs in memory; `<primary-svc>` and `<replica-svc>` are the
in-cluster names, see below, no IP):

```bash
cd ~/secrets-tmp/backup-replica
P="http://replica-reader:$(cat c3-reader.txt)@velero-backup-target.velero.svc.cluster.local:9000"
R="http://replica-writer:$(cat c4-writer.txt)@velero-backup-replica.velero.svc.cluster.local:9000"
cd - >/dev/null
kubectl create secret generic backup-replica-mirror -n velero \
  --from-literal=MC_HOST_primary="$P" --from-literal=MC_HOST_replica="$R" \
  --dry-run=client -o json |
  KUBECONFIG=/dev/null kubeseal --cert argocd/sealed-secrets/pub-cert.pem --format yaml \
  > talos/sealed-secrets/backup-replica-mirror.yaml
unset P R
```

C6 `replica-cloud-credentials` in namespace `velero-drill` (the AWS-style file):

```bash
printf '[default]\naws_access_key_id=replica-restore\naws_secret_access_key=%s\n' \
  "$(cat ~/secrets-tmp/backup-replica/c6-restore.txt)" |
kubectl create secret generic replica-cloud-credentials -n velero-drill \
  --from-file=cloud=/dev/stdin --dry-run=client -o json |
  KUBECONFIG=/dev/null kubeseal --cert argocd/sealed-secrets/pub-cert.pem --format yaml \
  > talos/sealed-secrets/velero-drill-replica-credentials.yaml
```

C7, C8 (B2 keys, WP7 gives the key ID and key; typed, never echoed):

```bash
read -rs B2ID;  echo; read -rs B2KEY; echo
printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' "$B2ID" "$B2KEY" |
kubectl create secret generic offsite-credentials -n velero \
  --from-file=cloud=/dev/stdin --dry-run=client -o json |
  KUBECONFIG=/dev/null kubeseal --cert argocd/sealed-secrets/pub-cert.pem --format yaml \
  > talos/sealed-secrets/velero-offsite-credentials.yaml
unset B2ID B2KEY
```

Repeat with the read-only key, secret name `offsite-readonly-credentials`, `-n velero-drill`, output
`talos/sealed-secrets/velero-drill-offsite-credentials.yaml`.

C9 (reuses the stored `replica-reader` password from file `c3-reader.txt`; the B2 values typed again):

```bash
read -rs B2ID; echo; read -rs B2KEY; echo
P="http://replica-reader:$(cat ~/secrets-tmp/backup-replica/c3-reader.txt)@velero-backup-target.velero.svc.cluster.local:9000"
O="https://${B2ID}:${B2KEY}@s3.<b2-region>.backblazeb2.com"
kubectl create secret generic backup-offsite-mirror -n velero \
  --from-literal=MC_HOST_primary="$P" --from-literal=MC_HOST_offsite="$O" \
  --dry-run=client -o json |
  KUBECONFIG=/dev/null kubeseal --cert argocd/sealed-secrets/pub-cert.pem --format yaml \
  > talos/sealed-secrets/backup-offsite-mirror.yaml
unset B2ID B2KEY P O
```

If a B2 application key contains a character other than letters and digits (`/`, `+`, `=`), URL-encode it
before it goes into C9 (the key id is alphanumeric). Check by looking at the key once in the B2 page; if
unsure, create a new key until it is alphanumeric `[UNVERIFIED: B2 keys are normally alphanumeric]`.

Every sealed file must be listed under `resources:` in `talos/sealed-secrets/kustomization.yaml` and
carry `kind: SealedSecret` (the guard `check-backups-06.sh` enforces it). Namespace `velero-drill` must
exist before its sealed secrets apply: WP6 adds it to `talos/manifests/namespaces/namespaces.yaml`.

### 6.4 Where each credential is created in MinIO / B2

| Credential | Created where and when | Exact action |
|---|---|---|
| `replica-reader` (C3) | on the PRIMARY MinIO, WP3 step 3 | `mc admin user add` + policy attach, run inside the primary pod (recipe in WP3) |
| `replica-writer` (C4), `replica-restore` (C6) | on the REPLICA MinIO, after it runs, WP4 step 2 | same recipe |
| per-bucket users `velero`, `litestream`, `immich-pg` on the replica | NOT needed for the mirror. Not created. In a real disaster the operator re-creates them with `talos/dr/minio/setup-users.sh` (documented in `docs/dr/mini03.md`, "Restore from the replica") | |
| B2 keys | B2 web console, WP7 | steps there |

### 6.5 Retrieval later (the operator, clipboard only, never printed)

```bash
kubectl --context admin@<cluster> -n velero get secret minio-replica-root -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d | pbcopy
kubectl --context admin@<cluster> -n velero get secret minio-root -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d | pbcopy
kubectl --context admin@<cluster> -n velero get secret backup-replica-mirror -o jsonpath='{.data.MC_HOST_replica}' | base64 -d | pbcopy
kubectl --context admin@<cluster> -n velero get secret offsite-credentials -o jsonpath='{.data.cloud}' | base64 -d | pbcopy
```

(The last one copies a two-line file; paste it into a password-manager note, not a terminal.) The
password manager is the primary place; the cluster Secret is the fallback. The B2 application key is shown
by Backblaze only once at creation; if it is lost, create a new key (rotation below).

### 6.6 What breaks if a credential is lost, and rotation

| Credential | If lost | Rotate / reset |
|---|---|---|
| C2 replica root | cannot administer the replica (MinIO still serves the existing users). Data not lost | Seal a new pair (6.3), merge PR, `talos-sealed-secrets` syncs, the operator deletes the pod `minio-replica-*` so the Deployment recreates it (MinIO re-reads its environment on start). Root credential changes do not change the stored users |
| C3/C4 users | mirror stops (job fails, alert fires) | In the pod: `mc admin user add NAME NEWPASS` (it resets the secret of an existing user), then reseal C5 |
| C5 | mirror stops | rebuild from the password manager entries, reseal |
| C6 | drill cannot read the replica | as C3/C4 |
| C7/C8 | offsite backups fail (`offsite` goes `Unavailable`); data in B2 untouched | create a new key in B2 (the old keeps working until deleted), reseal, sync `talos-sealed-secrets`; verify `offsite` Available; THEN delete the old key in B2. Check whether Velero re-reads the Secret without a restart `[UNVERIFIED]`; if `offsite` stays Unavailable, the operator restarts the `velero` pod |
| C9 | DB mirror to B2 fails | as C7 |
| C10 | Backblaze account recovery through e-mail + 2FA recovery codes (store recovery codes in the vault) | n/a |
| C11 | the repository password is the Velero default; nothing to lose | do not change (section 3.2) |

"Lost admin password" recovery for MinIO (replica): the root pair is in Secret `minio-replica-root` and in
the vault. If both are gone: seal a new pair (6.3, C2) and let the pod restart; MinIO accepts the new root
pair because root credentials come from the environment, not from the data directory. The scoped users
(C4, C6) are stored in the data directory and survive.
For B2: use Backblaze's account recovery; a lost application key is replaced, never recovered.

### 6.7 "Password discovery" (first login)

There is no login screen: MinIO's console is bound to `127.0.0.1:9001` inside the pod (the manifests'
args) and is not exposed. All administration is `mc` from inside the pod (WP3/WP4). The credentials that
first matter are the ones the operator generated in 6.2.

## 7. Work packages

Order: WP1 (audit) first. Part A: WP2, WP3, WP4, WP5, WP6. Part B: WP7 (the operator), WP8, WP9 (the operator), WP10,
WP11. WP2 to WP6 wait for mini03 (P4). Part B is independent of mini03 and may run first.

Template for each package: goal; branch; preconditions; steps; verification; rollback; PR text; the operator's
post-merge steps; STOP.

### WP1: read-only audit (no PR, report only)

Goal: confirm every fact in sections 2 and 3 still holds and record the differences.

Branch: none. Preconditions: P1.

1. Run each proof command of the prerequisites table (P1 to P10) and record output.
2. `gh pr view 71 --json state,isDraft,headRefName,files` and `gh pr list --state all --limit 20` to see
   whether #49, #52, #71 merged. Record.
3. `git fetch origin && git log --oneline origin/main -5`. Record whether `talos/manifests/backup-replica`
   exists on main: `git ls-tree -r origin/main --name-only | grep backup-replica`. Expected on
   2026-10-25: no output.
4. Read, and list differences from section 3 for: `talos/manifests/backup-target/minio.yaml`,
   `talos/values/velero.yaml`, `talos/dr/images.env`, `talos/sealed-secrets/kustomization.yaml`,
   `talos/manifests/namespaces/namespaces.yaml`, `docs/dr/talos-backups.md`.
5. Primary sizes (read-only):
   `kubectl --context admin@<cluster> -n velero exec deploy/minio -c minio -- df -h /data` and
   `kubectl --context admin@<cluster> -n velero exec deploy/minio -c minio -- du -sh /data/velero-backups /data/litestream /data/immich-pg`.
   Expected (2026-10-25): about 53G used of 128G; 52G / 1.4M / 380M.
6. `kubectl --context admin@<cluster> -n velero exec deploy/minio -c minio -- mc --help` and check that
   `MC_HOST_` appears. If not: STOP and report (the credential design depends on it).
7. Confirm the mini03 taint and node labels if the node exists (P5).
8. Check `kubectl --context admin@<cluster> get storageclass` shows only `topolvm-fast` (not default).

Report: `WP1: done|blocked`. STOP. Wait for the operator's go and decisions A1, A2.

### WP2: Part A manifests (the replica, mirror, policies)

Goal: all repository files for the replica, deployable but not yet deployed.

Branch: `backup-replica/manifests`. Preconditions: WP1 done; decisions A1 (default no `--remove`) and A2
answered; P4 satisfied is NOT required to write the files, but the Application must not be synced until it is.

Step 1. Decide the base. Case A (PR #71 still open and unmerged): do NOT push to its branch and do NOT merge it.
Create the files fresh from this plan (they differ from the draft in the points listed in the PR text).
Tell the operator that PR #71 should be closed in favour of this PR, but never close it yourself. Case B (PR #71
merged): edit the merged files to match the content below.

Step 2. Create `talos/dr/minio/policy-replica-reader.json` (WHY: read-only list/get on the three buckets;
used on the primary for `replica-reader` and on the replica for `replica-restore`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": [
        "arn:aws:s3:::velero-backups",
        "arn:aws:s3:::litestream",
        "arn:aws:s3:::immich-pg"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": [
        "arn:aws:s3:::velero-backups/*",
        "arn:aws:s3:::litestream/*",
        "arn:aws:s3:::immich-pg/*"
      ]
    }
  ]
}
```

Step 3. Create `talos/dr/minio/policy-replica-writer.json` (WHY: the mirror needs list, read, write and
delete only on the replica; delete is listed because `--overwrite` replaces objects and the prune CronJob
uses `--remove`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"],
      "Resource": [
        "arn:aws:s3:::velero-backups",
        "arn:aws:s3:::litestream",
        "arn:aws:s3:::immich-pg"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::velero-backups/*",
        "arn:aws:s3:::litestream/*",
        "arn:aws:s3:::immich-pg/*"
      ]
    }
  ]
}
```

Step 4. Create `talos/manifests/backup-replica/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - minio.yaml
  - service.yaml
  - mirror-cronjob.yaml
  - prune-sync-cronjob.yaml
```

Step 5. Create `talos/manifests/backup-replica/service.yaml`:

```yaml
# The stable in-cluster name of the second backup copy (MinIO on mini03).
apiVersion: v1
kind: Service
metadata:
  name: velero-backup-replica
  namespace: velero
spec:
  selector:
    app: minio-replica
  ports:
    - name: s3
      port: 9000
      targetPort: s3
```

Step 6. Create `talos/manifests/backup-replica/minio.yaml`. Resolve the two digests first (WHY: pin by
digest). The pins are already in `talos/dr/images.env` (`CI_MINIO_IMAGE_DIGEST`, `CI_MC_IMAGE_DIGEST`);
copy them from there, do not invent. For busybox (`docker.io/library/busybox:1.37`, used by the primary too),
resolve its digest with a read-only registry query on the operator's Mac, because the template script only
resolves ghcr.io: `docker buildx imagetools inspect docker.io/library/busybox:1.37 | head -3` or
`crane digest docker.io/library/busybox:1.37`; if neither tool is available, keep the tag exactly as the
primary does (`talos/manifests/backup-target/minio.yaml`) and list "busybox digest" under "Needs from
The operator". The guard rejects `latest`, not tags.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio-replica
  namespace: velero
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: minio-replica
  template:
    metadata:
      labels:
        app: minio-replica
    spec:
      nodeSelector:
        kubernetes.io/hostname: mini03
      tolerations:
        - key: node-role.homeserver/tier   # [ASSUMED] taint of mini03, confirm with P5
          operator: Equal
          value: mobile
          effect: NoSchedule
      initContainers:
        - name: own-data
          image: docker.io/library/busybox:1.37   # pin by digest if available (step 6 text)
          command: ["sh", "-c", "chown 65532:65532 /data"]
          securityContext:
            runAsUser: 0
          resources:
            requests: {cpu: 10m, memory: 16Mi}
            limits: {cpu: 100m, memory: 64Mi}
          volumeMounts:
            - {name: data, mountPath: /data}
      containers:
        - name: minio
          image: cgr.dev/chainguard/minio@sha256:c93745c56fccdaf0e5dcb88999a96a65a136428beb045ef5d546255a80d747a7
          args: ["server", "/data", "--address", ":9000", "--console-address", "127.0.0.1:9001"]
          envFrom:
            - secretRef:
                name: minio-replica-root
          ports:
            - {name: s3, containerPort: 9000}
          resources:
            requests: {cpu: 50m, memory: 256Mi}
            limits: {cpu: 500m, memory: 1Gi}
          readinessProbe:
            httpGet: {path: /minio/health/ready, port: s3}
            periodSeconds: 10
          livenessProbe:
            httpGet: {path: /minio/health/live, port: s3}
            initialDelaySeconds: 20
            periodSeconds: 20
          securityContext:
            runAsUser: 65532
            runAsGroup: 65532
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - {name: data, mountPath: /data}
      volumes:
        - name: data
          hostPath:
            path: /var/mnt/backups
            type: Directory
```

Health endpoints `/minio/health/live` and `/minio/health/ready` on port 9000 are what the primary uses
(`talos/manifests/backup-target/minio.yaml`) and what MinIO documents `[verified live]` (the primary's
probes pass). Differences from the draft: explicit CPU limit; `runAsNonRoot`; resources on the init
container. `readOnlyRootFilesystem` is not set because MinIO writes `/tmp` and its config; leave it and note
it in section 9.

Step 7. Create `talos/manifests/backup-replica/mirror-cronjob.yaml`. Differences from the draft: NO
`--remove`; `--retry`; resources everywhere; `startingDeadlineSeconds`; the report container stays.
Comments explain WHY inside the file.

```yaml
# Daily mirror: primary MinIO (mini02) -> replica MinIO (mini03). 13:00 UTC, after the 10:00 UTC
# Velero schedule (takes under a minute) and the 02:30 Postgres base backup.
# NO --remove: what the primary deleted stays on the replica (decision A1). --overwrite is needed
# because Kopia rewrites small files in place (kopia.repository, kopia.maintenance...).
# Credentials: Secret backup-replica-mirror holds MC_HOST_primary (read-only user) and MC_HOST_replica.
# Failure is the alert: a Job that fails stays in the failed history (failedJobsHistoryLimit).
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup-replica-mirror
  namespace: velero
spec:
  schedule: "0 13 * * *"
  timeZone: Etc/UTC
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 3600
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 14400
      template:
        metadata:
          labels:
            app: backup-replica-mirror
        spec:
          restartPolicy: Never
          nodeSelector:
            kubernetes.io/hostname: mini03
          tolerations:
            - key: node-role.homeserver/tier
              operator: Equal
              value: mobile
              effect: NoSchedule
          initContainers:
            - name: size-gate
              image: docker.io/library/busybox:1.37
              command:
                - sh
                - -c
                - |
                  set -eu
                  use="$(df -P /data | awk 'NR==2 { gsub("%", "", $5); print $5 }')"
                  echo "backups volume use: ${use}%"
                  if [ "$use" -ge 80 ]; then
                    echo "the backups volume is at or above 80%: not mirroring (docs/plans/backup-replica.md)" >&2
                    exit 1
                  fi
              resources:
                requests: {cpu: 10m, memory: 16Mi}
                limits: {cpu: 100m, memory: 64Mi}
              volumeMounts:
                - {name: data, mountPath: /data, readOnly: true}
            - name: mirror-litestream
              image: cgr.dev/chainguard/minio-client@sha256:d8a93c5d335509ff353774eefec8f82fa2a2a975e800139702232d8be3dbe6b9
              args: ["mirror", "--overwrite", "--retry", "primary/litestream", "replica/litestream"]
              env:
                - {name: MC_CONFIG_DIR, value: /tmp/mc}
              envFrom:
                - secretRef:
                    name: backup-replica-mirror
              resources:
                requests: {cpu: 50m, memory: 64Mi}
                limits: {cpu: 500m, memory: 256Mi}
              securityContext:
                runAsUser: 65532
                runAsGroup: 65532
                runAsNonRoot: true
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              volumeMounts:
                - {name: tmp, mountPath: /tmp}
            - name: mirror-immich-pg
              image: cgr.dev/chainguard/minio-client@sha256:d8a93c5d335509ff353774eefec8f82fa2a2a975e800139702232d8be3dbe6b9
              args: ["mirror", "--overwrite", "--retry", "primary/immich-pg", "replica/immich-pg"]
              env:
                - {name: MC_CONFIG_DIR, value: /tmp/mc}
              envFrom:
                - secretRef:
                    name: backup-replica-mirror
              resources:
                requests: {cpu: 50m, memory: 64Mi}
                limits: {cpu: 500m, memory: 256Mi}
              securityContext:
                runAsUser: 65532
                runAsGroup: 65532
                runAsNonRoot: true
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              volumeMounts:
                - {name: tmp, mountPath: /tmp}
            - name: mirror-velero-backups
              image: cgr.dev/chainguard/minio-client@sha256:d8a93c5d335509ff353774eefec8f82fa2a2a975e800139702232d8be3dbe6b9
              args: ["mirror", "--overwrite", "--retry", "primary/velero-backups", "replica/velero-backups"]
              env:
                - {name: MC_CONFIG_DIR, value: /tmp/mc}
              envFrom:
                - secretRef:
                    name: backup-replica-mirror
              resources:
                requests: {cpu: 50m, memory: 64Mi}
                limits: {cpu: 500m, memory: 256Mi}
              securityContext:
                runAsUser: 65532
                runAsGroup: 65532
                runAsNonRoot: true
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              volumeMounts:
                - {name: tmp, mountPath: /tmp}
          containers:
            - name: report
              image: cgr.dev/chainguard/minio-client@sha256:d8a93c5d335509ff353774eefec8f82fa2a2a975e800139702232d8be3dbe6b9
              args: ["du", "replica/velero-backups"]
              env:
                - {name: MC_CONFIG_DIR, value: /tmp/mc}
              envFrom:
                - secretRef:
                    name: backup-replica-mirror
              resources:
                requests: {cpu: 25m, memory: 32Mi}
                limits: {cpu: 250m, memory: 128Mi}
              securityContext:
                runAsUser: 65532
                runAsGroup: 65532
                runAsNonRoot: true
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              volumeMounts:
                - {name: tmp, mountPath: /tmp}
          volumes:
            - name: data
              hostPath:
                path: /var/mnt/backups
                type: Directory
            - name: tmp
              emptyDir: {}
```

Order note: the small buckets first, the large `velero-backups` last, so that the databases are never
blocked behind a long copy. `readOnlyRootFilesystem: true` for the mc containers is set because `mc` is
given a writable `MC_CONFIG_DIR=/tmp/mc`; if the first run fails with a read-only error, report it (the
draft ran without that setting) and remove the line in a follow-up PR, do not guess.

Step 8. Create `talos/manifests/backup-replica/prune-sync-cronjob.yaml`: a SUSPENDED CronJob, run by hand
(`kubectl create job --from=cronjob/...`) when the replica passes 70%. It is `suspend: true` so it never
runs by schedule.

```yaml
# MANUAL clean-up: make the replica equal to the primary again (deletes what the primary deleted).
# NEVER run it when the primary looks wrong (small, empty, just restored): --remove copies that
# emptiness onto the replica. Before running, the operator checks the primary size (docs/plans/backup-replica.md,
# WP4 step 9). suspend: true, so it never runs on a schedule.
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup-replica-prune-sync
  namespace: velero
spec:
  schedule: "0 0 1 1 *"
  suspend: true
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 2
  jobTemplate:
    spec:
      backoffLimit: 0
      activeDeadlineSeconds: 14400
      template:
        spec:
          restartPolicy: Never
          nodeSelector:
            kubernetes.io/hostname: mini03
          tolerations:
            - key: node-role.homeserver/tier
              operator: Equal
              value: mobile
              effect: NoSchedule
          containers:
            - name: prune-velero-backups
              image: cgr.dev/chainguard/minio-client@sha256:d8a93c5d335509ff353774eefec8f82fa2a2a975e800139702232d8be3dbe6b9
              args: ["mirror", "--overwrite", "--remove", "primary/velero-backups", "replica/velero-backups"]
              env:
                - {name: MC_CONFIG_DIR, value: /tmp/mc}
              envFrom:
                - secretRef:
                    name: backup-replica-mirror
              resources:
                requests: {cpu: 50m, memory: 64Mi}
                limits: {cpu: 500m, memory: 256Mi}
              securityContext:
                runAsUser: 65532
                runAsGroup: 65532
                runAsNonRoot: true
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              volumeMounts:
                - {name: tmp, mountPath: /tmp}
          volumes:
            - name: tmp
              emptyDir: {}
```

Only `velero-backups` is pruned: that bucket is where garbage accumulates. `immich-pg` is 380 MB and is
left alone.

Step 9. Create `talos/apps-src/backup-replica.yaml` (manual sync on purpose; copy the shape of
`talos/apps-src/backup-target.yaml`):

```yaml
# Second copy of the backups: MinIO on mini03 plus the mirror CronJobs. Design and runbook:
# docs/plans/backup-replica.md. MANUAL SYNC. Do not sync before mini03 is Ready and the sealed
# Secrets minio-replica-root and backup-replica-mirror are on main.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: backup-replica
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/BrunoLoureirooo/homelab_gitops
    targetRevision: main
    path: talos/manifests/backup-replica
  destination:
    server: https://kubernetes.default.svc
    namespace: velero
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
    # Manual sync, no automated block.
```

Step 10. Run `talos/render-apps.sh --force`. Expected: a new file `talos/apps/backup-replica.yaml`;
`git status` shows exactly that plus your new files. If other files change, STOP and report.

Step 11. Add the expectation line to `talos/test/empty-cluster-expectations.txt`: read the existing
`backup-target` line (`backup-target * * # ...`) and add a sibling line `backup-replica * * # MinIO on
mini03; needs the minio-replica-root and backup-replica-mirror Secrets and the mini03 node` in the same
column layout. (WHY: the guard fails on a missing expectation line.)

Step 12. Create `talos/manifests/backup-replica/README.md` with a short pointer to this plan (two sentences:
what is here, "runbook in docs/plans/backup-replica.md"). Do not copy secrets text from the draft.

Verification (no cluster change): `bash .github/scripts/run-all-guards.sh` all OK;
`kubectl kustomize talos/manifests/backup-replica | kubectl apply --dry-run=client -f - ` is a client-side
check that does not touch the cluster; if `kubectl apply --dry-run=client` asks for a cluster it may fail
with the offline context; use `kubectl kustomize talos/manifests/backup-replica >/dev/null` and
`yq e '.' talos/manifests/backup-replica/*.yaml >/dev/null` instead. Expected: no errors.

Rollback: close the PR.

PR title: `docs: implementation plan for the backup replica and the offsite copy` is THIS plan's PR. For
WP2 use: `backup-replica: MinIO on mini03, mirror CronJob, users' policies (manual sync)`.

PR description (write exactly): what it adds; "differences from draft PR #71" (no `--remove`; suspended
prune job; CPU limits; runAsNonRoot; policies unchanged); "Deploys nothing: manual-sync Application";
The operator's steps after merge: none yet (WP3 first). End with the Claude Code line.

STOP: report; wait for the operator to merge.

### WP3: users, credentials, sealed secrets (The operator acts; executor writes the PR)

Goal: create the MinIO users, generate the credentials, seal them.

Branch: `backup-replica/sealed-secrets`. Preconditions: WP2 merged (the policy files exist on main) and
`mini03` Ready is NOT required for the primary-side step, but IS required for step 4.

Executor part: nothing to write until the operator hands over the sealed files. The executor prepares the PR
skeleton: `kustomization.yaml` edits listing `minio-replica-root.yaml` and `backup-replica-mirror.yaml`
under `resources:` plus two comment lines in the header block (copy the existing comment style). The
`velero-drill-*` files are added in WP6; the offsite ones in WP8/WP10.

The operator's copy-paste list (all in his Mac terminal; `K` below is written out in full):

1. Generate the values (section 6.2). Store them in the vault.
2. Create the policy on the primary and the reader user, inside the primary pod. The pod's environment
   already contains the root pair; the `bash` and `mc` of the server image are used (verified in section 3.1).
   The reader password is passed on standard input so it never appears in a command line or history:

   ```bash
   cd ~/Projects/homelab_gitops    # his checkout, after merging WP2 and pulling main
   P=talos/dr/minio/policy-replica-reader.json
   kubectl --context admin@<cluster> -n velero exec -i deploy/minio -c minio -- bash -c \
     'cat >/tmp/policy-replica-reader.json; export MC_HOST_p="http://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@127.0.0.1:9000"; mc admin policy create p backup-replica-reader /tmp/policy-replica-reader.json' < "$P"
   kubectl --context admin@<cluster> -n velero exec -i deploy/minio -c minio -- bash -c \
     'read -r pw; export MC_HOST_p="http://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@127.0.0.1:9000"; mc admin user add p replica-reader "$pw" && mc admin policy attach p backup-replica-reader --user replica-reader' \
     < ~/secrets-tmp/backup-replica/c3-reader.txt
   ```

   `127.0.0.1:9000` is the pod's own loopback, the same address the pod serves; the literal does not appear
   in a committed file. Expected output of the first command: `Created policy `backup-replica-reader` successfully.`;
   of the second: `Added user `replica-reader` successfully.` then `Attached Policies: [backup-replica-reader]`
   `[UNVERIFIED: exact wording varies by mc version]`.
   (The Chainguard `minio-client` image has no shell; that is why the server image, which does have
   `bash` and `mc`, is used for these admin commands. If a future image pin loses `bash`, fall back to
   `mc` installed on the Mac with `kubectl port-forward` to the Service.)

   If the temporary file `/tmp/policy-replica-reader.json` cannot be written (read-only root filesystem),
   report it; do not add a volume without telling the operator.
3. Verify the user is limited: list as the new user must work and write must fail:

   ```bash
   kubectl --context admin@<cluster> -n velero exec -i deploy/minio -c minio -- bash -c \
     'read -r pw; export MC_HOST_r="http://replica-reader:$pw@127.0.0.1:9000"; mc ls r/velero-backups; echo test | mc pipe r/velero-backups/should-fail.txt; echo "exit=$?"' \
     < ~/secrets-tmp/backup-replica/c3-reader.txt
   ```
   Expected: the listing shows `backups/` `kopia/` `restores/`; `mc pipe` prints `Access Denied`; `exit=1`.
4. Seal C2 and C5 (section 6.3) into `talos/sealed-secrets/`, add them to the kustomization, commit, push to
   the executor's PR branch (or the executor commits them if the operator hands over the two files).
5. After the PR merges, the app `talos-sealed-secrets` auto-syncs; verify:
   `kubectl --context admin@<cluster> -n velero describe secret minio-replica-root backup-replica-mirror`
   shows the key names above. (The Secret `backup-replica-mirror` already contains the replica-writer URL,
   but the writer user does not exist on the replica yet; that is created in WP4.)

Verification, rollback (`delete` the sealed files in a PR; the primary user can be removed with
`mc admin user remove p replica-reader`), STOP.

PR title: `sealed secrets: backup replica root and mirror credentials`. PR text: names of Secrets and keys
(no values), the vault entries the operator made.

### WP4: deploy the replica and run the first mirror (The operator acts)

Preconditions: WP2 and WP3 merged; mini03 Ready; P6.

The operator's copy-paste list:

1. In the Argo CD web UI: sync the app `backup-replica` (prune off). Watch: the Deployment becomes
   Available; the CronJobs appear. Then confirm read-only from the terminal:

   ```bash
   kubectl --context admin@<cluster> -n velero get pods -l app=minio-replica -o wide
   kubectl --context admin@<cluster> -n velero exec deploy/minio-replica -c minio -- df -h /data
   ```
   Expected: pod `Running 1/1` on `mini03`; size about 128G, xfs. If `Pending`: describe it; usual cause
   is the taint toleration (troubleshooting table).
2. Create the three buckets, the writer and the restore user on the REPLICA (root pair comes from the
   pod's env; passwords by stdin):

   ```bash
   cd ~/Projects/homelab_gitops
   R='kubectl --context admin@<cluster> -n velero exec -i deploy/minio-replica -c minio --'
   $R bash -c 'export MC_HOST_r="http://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@127.0.0.1:9000"; for b in velero-backups litestream immich-pg; do mc mb --ignore-existing r/$b; done'
   $R bash -c 'cat >/tmp/w.json; export MC_HOST_r="http://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@127.0.0.1:9000"; mc admin policy create r backup-replica-writer /tmp/w.json' < talos/dr/minio/policy-replica-writer.json
   $R bash -c 'cat >/tmp/r.json; export MC_HOST_r="http://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@127.0.0.1:9000"; mc admin policy create r backup-replica-reader /tmp/r.json' < talos/dr/minio/policy-replica-reader.json
   $R bash -c 'read -r pw; export MC_HOST_r="http://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@127.0.0.1:9000"; mc admin user add r replica-writer "$pw" && mc admin policy attach r backup-replica-writer --user replica-writer' < ~/secrets-tmp/backup-replica/c4-writer.txt
   $R bash -c 'read -r pw; export MC_HOST_r="http://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@127.0.0.1:9000"; mc admin user add r replica-restore "$pw" && mc admin policy attach r backup-replica-reader --user replica-restore' < ~/secrets-tmp/backup-replica/c6-restore.txt
   ```
   (`$R` unquoted works in zsh only if word splitting is on; in zsh use `setopt shwordsplit` first or write
   the full command each time.) Expected: three `Bucket created successfully` lines, two policies, two users.
3. Run the first mirror by hand (creating a Job from the CronJob is a the operator action):

   ```bash
   kubectl --context admin@<cluster> -n velero create job --from=cronjob/backup-replica-mirror first-mirror
   kubectl --context admin@<cluster> -n velero logs -f job/first-mirror --all-containers --max-log-requests=6
   ```
   Expected: `size-gate` prints `backups volume use: 1%`(or similar), the three mirrors print a final
   `Total: ... Transferred: ...` style summary, `report` prints the `du` line with about 52 GiB.
   Record the real duration (`kubectl -n velero get job first-mirror -o jsonpath='{.status.startTime} {.status.completionTime}'`).
4. Compare both sides:

   ```bash
   kubectl --context admin@<cluster> -n velero exec deploy/minio -c minio -- du -sk /data/velero-backups /data/immich-pg /data/litestream
   kubectl --context admin@<cluster> -n velero exec deploy/minio-replica -c minio -- du -sk /data/velero-backups /data/immich-pg /data/litestream
   ```
   Expected: the numbers equal or differ by a few percent (xfs vs ZFS accounting differ; MinIO metadata
   `.minio.sys` is separate). A difference of more than 5% on `velero-backups`: report, do not continue.
5. Delete the Job: `kubectl --context admin@<cluster> -n velero delete job first-mirror`.
6. Next day (after 13:00 UTC): `kubectl --context admin@<cluster> -n velero get cronjob,jobs` shows the
   scheduled Job `Complete`, `LAST SCHEDULE` recent.
7. Prove the 80% guard (one time, safe): the guard reads `df` of the volume. Do NOT fill the disk. Instead
   prove the code path with a dry run of the same command against a threshold you can reach:
   ask the executor to prepare a one-off Job manifest in the PR description (not committed) that runs the
   size-gate with `-ge 1`; the operator applies it with `kubectl create -f` from his terminal; expected: the init
   container exits 1, the Job fails with "not mirroring". Delete it afterwards. (Done this way, no volume
   is filled and nothing is changed.)
8. Start the measurement log: add to `docs/dr/mini03.md` a table "replica size over time" is NOT part of
   this PR; instead the operator notes in his own calendar: on the 1st and 15th, run the `du -sk` commands of
   step 4 and the `df -h /data` of the replica; three months; then set the clean-up threshold.
9. Clean-up job procedure (only when `df` of the replica shows 70% or more, or when the operator wants it):
   first check the primary is healthy and large:
   `kubectl --context admin@<cluster> -n velero exec deploy/minio -c minio -- du -sk /data/velero-backups`
   must be more than 20000000 (20 GB). Then
   `kubectl --context admin@<cluster> -n velero create job --from=cronjob/backup-replica-prune-sync prune-1`
   and watch its logs; afterwards compare sizes as in step 4 (expect equal) and delete the job.

Verification: items above. Rollback: Argo UI, delete app resources (the replica data directory stays on the
node volume; remove it deliberately only on the operator's word). STOP and report: real first-mirror duration,
sizes, the date of the first scheduled run result.

### WP5: alert hook for a failed or stale mirror (gated on the monitoring plan)

Goal: the mirror failing is noticed without the operator looking at the cluster.

Branch: `backup-replica/alerts`. Preconditions: P9 satisfied (`monitoring` namespace with kube-prometheus-stack
or an equivalent exposing kube-state-metrics `[ASSUMED]`). If not: do not write the file; instead write the
manual weekly check into the report: `kubectl --context admin@<cluster> -n velero get cronjob backup-replica-mirror`
and `... get jobs` must show the last Job `Complete`.

Step 1. Find out how the monitoring plan selects rules: `kubectl --context admin@<cluster> -n monitoring get prometheus -o jsonpath='{.items[*].spec.ruleSelector}'`
and `... get prometheusrule -A`. Use the same label (commonly `release: <helm-release-name>`) `[ASSUMED]`.

Step 2. Create `talos/manifests/backup-replica/prometheusrule.yaml` and add it to the kustomization ONLY
in this PR (not earlier, so the app does not fail on a missing CRD). Metric names are those of
kube-state-metrics (`kube_job_status_failed`, `kube_cronjob_status_last_successful_time`,
`kube_cronjob_spec_suspend`) `[UNVERIFIED]` against the installed version: confirm with a read-only query
once the monitoring stack exists (Prometheus UI or `kubectl exec` with promtool).

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: backup-replica
  namespace: velero
  labels:
    release: kube-prometheus-stack   # [ASSUMED] must match the Prometheus ruleSelector found in step 1
spec:
  groups:
    - name: backup-replica
      rules:
        - alert: BackupReplicaMirrorFailed
          expr: kube_job_status_failed{namespace="velero", job_name=~"backup-replica-mirror-.*"} > 0
          for: 5m
          labels: {severity: warning}
          annotations:
            summary: "The mirror to the mini03 replica failed"
            description: "Run: kubectl -n velero logs job/{{ $labels.job_name }} --all-containers. Likely the 80% size gate or a credential."
        - alert: BackupReplicaMirrorStale
          expr: time() - kube_cronjob_status_last_successful_time{namespace="velero", cronjob="backup-replica-mirror"} > 129600
          for: 30m
          labels: {severity: warning}
          annotations:
            summary: "No successful mirror to the replica for 36 hours"
        - alert: BackupReplicaVolumeFilling
          expr: (1 - node_filesystem_avail_bytes{mountpoint="/var/mnt/backups"} / node_filesystem_size_bytes{mountpoint="/var/mnt/backups"}) > 0.7
          for: 1h
          labels: {severity: warning}
          annotations:
            summary: "The replica volume is above 70%: run the clean-up job (docs/plans/backup-replica.md, WP4 step 9)"
```

The third rule needs node-exporter to see the Talos user volume `[UNVERIFIED]`: on Talos the node
exporter runs in a pod and sees host mounts only if configured; if the series is empty, drop that rule
and rely on the size gate (the Job fails at 80% and rule one fires).

Step 3. Guards, PR, the operator syncs `backup-replica` again. Verify in the Prometheus UI that the rules load
(Status then Rules) and none is firing.

Test of the alert (the operator): `kubectl --context admin@<cluster> -n velero create job --from=cronjob/backup-replica-prune-sync t1`
does not fail on purpose; instead use the size-gate test of WP4 step 7; after 5 minutes `BackupReplicaMirrorFailed`
should fire; delete the test Job and the alert resolves.

Rollback: remove the file from the kustomization. STOP.

### WP6: restore drill from the replica ALONE (scratch Velero)

Why a scratch Velero: the real Velero already has the same backup names (it wrote them). Registering the
replica as a second location in the real Velero would present the same backup names twice (section 3.2,
`[UNVERIFIED]` for 1.18). A second Velero in its own namespace sees only its own BSL, so it proves "the
replica alone is enough" without any risk to the live backup system.

Branch: `backup-replica/drill`. Preconditions: WP4 verified (the replica holds a mirrored copy of at least
one `homeserver-nightly` backup, i.e. `mc ls r/velero-backups/backups/` lists it); decision A5 answered.

Step 1. Namespace. Edit `talos/manifests/namespaces/namespaces.yaml`: append (WHY: the node agent mounts
host paths, so the namespace needs the privileged label, like `velero`):

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: velero-drill
  labels:
    pod-security.kubernetes.io/enforce: privileged # scratch Velero + node agent for restore drills (host paths)
```

Step 2. Values file `talos/values/velero-drill.yaml`:

```yaml
# Scratch Velero for restore drills FROM THE REPLICA (and later the offsite copy).
# Own namespace, own BSLs, no schedules, nothing here ever writes to a backup location.
# Docs: docs/plans/backup-replica.md, WP6 and WP11.
configuration:
  uploaderType: kopia
  backupStorageLocation:
    - name: replica
      provider: aws
      bucket: velero-backups
      accessMode: ReadOnly
      default: true
      credential:
        name: replica-cloud-credentials
        key: cloud
      config:
        region: minio
        s3Url: http://velero-backup-replica.velero.svc.cluster.local:9000
        s3ForcePathStyle: "true"
  volumeSnapshotLocation: []

credentials:
  useSecret: false          # each location names its own Secret (credential.name above)

deployNodeAgent: true
upgradeCRDs: false          # the CRDs belong to the real Velero release in namespace velero

initContainers:
  - name: velero-plugin-for-aws
    image: "velero/velero-plugin-for-aws:v1.13.1"   # same pin as argocd/values/velero.yaml
    volumeMounts:
      - mountPath: /target
        name: plugins

resources:
  requests: {cpu: 50m, memory: 128Mi}
  limits: {cpu: 500m, memory: 512Mi}
nodeAgent:
  resources:
    requests: {cpu: 100m, memory: 128Mi}
    limits: {cpu: 500m, memory: 512Mi}

schedules: {}
nodeSelector:
  kubernetes.io/hostname: mini02
tolerations:
  - key: node.kubernetes.io/unschedulable
    operator: Exists
    effect: NoSchedule
```

Notes: `credentials.useSecret: false` and per-location `credential` is the documented per-BSL form `[verified chart
template above]`; the chart default `credentials` block would otherwise try to create a Secret. Confirm
with `helm template velero velero --repo https://vmware-tanzu.github.io/helm-charts --version 12.1.0 -n velero-drill -f talos/values/velero-drill.yaml | grep -n -i "kind: Secret\|credential"` that no Secret
is rendered and the BSL carries `credential`. The server runs on mini02 next to the primary like the real
one (tolerates the cordon); change `nodeSelector` only after asking the operator. The node agent DaemonSet runs
on every node that can run it (mini01, mini02, and mini03 only if it tolerates the mini03 taint; for the
drill the volume lands on mini01, so the mini01 pod is the one that matters).

Step 3. Application `talos/apps-src/velero-drill.yaml` (manual sync; `skipCrds` so the existing CRDs and
their Argo tracking are not touched, which is the main hazard of a second release of the same chart):

```yaml
# Scratch Velero for restore drills. MANUAL SYNC, synced only for a drill and deleted afterwards
# (docs/plans/backup-replica.md). Must never take ownership of the Velero CRDs: skipCrds.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: velero-drill
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://vmware-tanzu.github.io/helm-charts
      chart: velero
      targetRevision: "12.1.0"
      helm:
        skipCrds: true
        valueFiles:
          - $values/talos/values/velero-drill.yaml
    - repoURL: https://github.com/BrunoLoureirooo/homelab_gitops
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: velero-drill
  syncPolicy:
    syncOptions:
      - CreateNamespace=false
    # Manual sync, no automated block.
```

`render-apps.sh` copies `apps-src` as is (`talos/overrides/15-06.yaml` comment). Run it with `--force`,
check `git status`. Add the expectation line for `velero-drill` (copy the layout of the `velero` line:
`velero * * # ...`). `helm.skipCrds` is an Argo CD field; confirm in https://argo-cd.readthedocs.io/en/stable/user-guide/helm/
(`[UNVERIFIED]`: not re-read today). If the field name differs, STOP and report.

Step 4. Sealed secret C6 for `velero-drill` (section 6.3) added to `talos/sealed-secrets/` and its
kustomization. The operator seals; the executor commits.

Step 5. Resource-modifier ConfigMap for the library claim. The claim `immich-library-smb` is a static
SMB-backed claim (`storageClassName: ""`, `volumeName: immich-library-smb`); restored as is into a scratch
namespace it would try to bind the live PV and stay Pending. File `talos/dr/replica/drill-resource-modifier.yaml`
(applied by the operator into `velero-drill`, not by Argo; it is data for the drill):

```yaml
version: v1
resourceModifierRules:
  - conditions:
      groupResource: persistentvolumeclaims
      resourceNameRegex: "^immich-library-smb$"
      namespaces:
        - homeserver
    patches:
      - operation: remove
        path: "/spec/volumeName"
      - operation: replace
        path: "/spec/storageClassName"
        value: "topolvm-fast"
```

The operator creates it: `kubectl --context admin@<cluster> -n velero-drill create configmap drill-pvc-modifier --from-file=drill-resource-modifier.yaml=talos/dr/replica/drill-resource-modifier.yaml`.
`[UNVERIFIED]`: the `remove /spec/volumeName` patch is not shown in the docs (section 3.2). If the PVC still
stays Pending, STOP: report `kubectl -n restore-drill-replica describe pvc immich-library-smb`.

Step 6. Drill script `talos/dr/replica-restore-drill.sh` is NOT written in this plan; instead the manual
procedure below is the contract. (A script may follow in a later PR; the existing
`talos/dr/velero-restore-drill.sh` calls `velero` against the current context and namespace, so it
needs `--namespace velero-drill` added to every `velero` call; do not edit it in this PR.)

The operator's drill steps (after the PR with the above is merged and `talos-sealed-secrets` synced):

1. In Argo CD, sync `velero-drill`. Expected: pods `velero-*` and `node-agent-*` Running in `velero-drill`.
   Check the location sees the replica:
   `kubectl --context admin@<cluster> -n velero-drill get backupstoragelocations` shows `replica` `Available`
   (can take up to a minute). If `Unavailable`: `describe` it; typical cause is the credential or the plugin
   (troubleshooting table).
2. Backups appear after the sync period: `kubectl --context admin@<cluster> -n velero-drill get backups.velero.io`
   lists the mirrored `velero-homeserver-nightly-*` backups. If empty after 5 minutes, check
   `kubectl -n velero-drill logs deploy/velero | tail -50`. Pick the newest `Completed` backup: `B=<name>`.
3. Make the checker data on the live side first (so the comparison does not depend on the restore). On the
   live Immich pod (read-only commands): count and a 200-file sample with hashes:

   ```bash
   kubectl --context admin@<cluster> -n homeserver exec deploy/immich-server -- sh -c 'find /data -type f | wc -l'
   ```
   Record `LIVE_COUNT`. (A new upload since the backup makes live larger; that is expected.)
4. Restore into a scratch namespace, with the resource modifier, only workloads' data we need
   (`--include-resources` as the existing drill does), never into `homeserver`:

   ```bash
   velero --namespace velero-drill restore create drill-replica-1 \
     --from-backup "$B" \
     --namespace-mappings homeserver:restore-drill-replica \
     --include-resources pods,deployments,replicasets,persistentvolumeclaims,secrets,configmaps,serviceaccounts \
     --selector 'app.kubernetes.io/name=immich-server' \
     --resource-modifier-configmap drill-pvc-modifier --wait
   ```
   `[UNVERIFIED]`: the label of the immich-server pod/PVC (the chart sets labels; read them first:
   `kubectl --context admin@<cluster> -n homeserver get deploy immich-server --show-labels`). If the PVC does not carry
   the label, drop `--selector` and add `--include-resources` only; restoring the whole namespace into the
   scratch namespace is acceptable only if the operator confirms (it would restore Jellyfin config PVC etc.; they
   are small). With `--wait`, expect phase `Completed` (`velero restore get`). The data is pulled file by
   file from the replica: about 55 GB, expect an hour or more. Watch:
   `kubectl --context admin@<cluster> -n restore-drill-replica get pods,pvc`.
5. When done, delete the restored workload so a checker pod can mount the claim (this deletes only objects
   in the scratch namespace):
   `kubectl --context admin@<cluster> -n restore-drill-replica delete deployments,replicasets,pods --all`.
6. Checker pod. Save as `/tmp/check.yaml` (The operator's machine, not committed), image the same pin as
   `DRILL_IMAGE_*` in `talos/dr/images.env` (alpine; its busybox has `sha256sum`, `find` and `sort -R`, so the
   sample is taken with `sort -R | head -n 200`; `shuf` is not assumed):

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata: {name: drill-check, namespace: restore-drill-replica}
   spec:
     restartPolicy: Never
     containers:
       - name: check
         image: docker.io/library/alpine:3.20.3   # use the digest from talos/dr/images.env once pinned
         command: ["sh", "-c"]
         args:
           - |
             echo "FILES=$(find /v -type f | wc -l)"
             find /v -type f | sort -R | head -n 200 | while read -r f; do sha256sum "$f"; done > /tmp/sample.txt
             cat /tmp/sample.txt
         resources:
           requests: {cpu: 50m, memory: 64Mi}
           limits: {cpu: 500m, memory: 256Mi}
         volumeMounts: [{name: v, mountPath: /v, readOnly: true}]
     volumes:
       - name: v
         persistentVolumeClaim: {claimName: immich-library-smb, readOnly: true}
   ```
   (The pod is created in the scratch namespace by the operator: `kubectl --context admin@<cluster> create -f /tmp/check.yaml`.)
   Run it, then `kubectl --context admin@<cluster> -n restore-drill-replica logs drill-check > /tmp/restored.txt`.
   Expect `FILES=<n>` close to `LIVE_COUNT` (within the uploads of the last day; 16,579 files at the
   2026-10-18 migration `[verified repo]`) and 200 hash lines. Note restored paths start with `/v/`; live
   paths start with `/data/`.
7. Compare with the live files (read-only): convert the paths and hash on live:

   ```bash
   sed -n 's#^[0-9a-f]\{64\}  /v/#/data/#p' /tmp/restored.txt > /tmp/paths.txt
   kubectl --context admin@<cluster> -n homeserver exec -i deploy/immich-server -- xargs -d '\n' sha256sum < /tmp/paths.txt | sed 's#  /data/#  /v/#' | sort > /tmp/live-hash.txt
   sed -n 's#^\([0-9a-f]\{64\}\)  \(/v/.*\)$#\1  \2#p' /tmp/restored.txt | sort > /tmp/restored-hash.txt
   diff /tmp/live-hash.txt /tmp/restored-hash.txt && echo SAMPLE-IDENTICAL
   ```
   Expected: `SAMPLE-IDENTICAL` (200 of 200 hashes equal, same bar the 2026-10-18 migration used). If paths
   with spaces break `xargs -d '\n'`, it is still correct because the delimiter is newline. A file present in
   the restored volume but deleted live in the meantime shows as a diff: re-run with another sample before
   concluding.
8. Clean up: `kubectl --context admin@<cluster> delete namespace restore-drill-replica`; in Argo, delete the
   `velero-drill` app resources (the namespace stays; sealed secrets stay); delete `drill-pvc-modifier`.
   Verify free space on mini01 returned (P8 command).
9. Report: duration, `FILES`, `LIVE_COUNT`, `SAMPLE-IDENTICAL`, and whether the read-only user
   `replica-restore` sufficed (decision A3). If Kopia needed write access (log lines `access denied` on the
   replica), edit the C6 secret to use `replica-writer` for the drill, redo, and write it into the report.

Rollback: Argo delete `velero-drill`; remove the namespace entry in a PR if abandoning. STOP.

PR title: `backup-replica: scratch Velero for restore drills from the replica`.

### WP7: offsite account, bucket and keys (The operator only; executor writes the checklist into the PR)

Comparison table (The operator reads this, then answers B1 to B3):

| | A. B2 cloud bucket (recommended) | B. USB disk on victus | C. both |
|---|---|---|---|
| Fits "Velero only" | yes, a normal BackupStorageLocation | no: Velero cannot write to a disk; needs a MinIO or an `mc` copy onto it, and an extra mount on victus | yes plus an extra mover |
| Fits "nothing backup-related on victus" (2026-10-17) | yes | NO, directly contradicts it | partly |
| Offsite (survives fire/theft) | yes | only if the disk is kept elsewhere; a disk plugged into the desktop is in the same house | yes |
| Cost | 55 GB about $0.31 to $0.38 per month at $6.95/TB (first 10 GB free); about $0.40 with the databases and a year of growth, still under $1; egress free up to 3x stored | one-time disk price (not researched, no verified price); electricity | A + disk |
| Ransomware/LAN-compromise safety | good (separate credentials; lifecycle; optional object lock) | poor while attached; good if unplugged | good |
| Upload effort | 55 GB over the internet once (table below) | local USB copy in about 10 to 20 min | both |
| Restore speed | limited by download speed (55 GB egress free) | fast | fast from disk |
| Automation | fully automatic | needs a human to plug/unplug for safety | partly |
| Encryption | Velero's static Kopia key + provider SSE (section 3.4, B4) | LUKS on the disk (real client-side encryption) | both |

R2 alternative: $0.015/GB-month = about $0.68 per month for 55 GB after the 10 GB free tier (about $0.83 without
it), free egress, S3 compatible; `checksumAlgorithm` and region requirements for the Velero plugin were not
researched `[UNVERIFIED]`. B2 is cheaper per TB (verified) and has a documented Velero setting.

Upload time for about 55 GB (4.4e11 bits) at full line rate; real throughput is roughly 70 to 85% of the
upload rate and the single node agent (limits 500m CPU) may be the bottleneck. The operator must give his
upload speed (decision input B9, run a speed test from the home network):

| Upload speed | Pure transfer | At 75% efficiency |
|---|---|---|
| 10 Mbit/s | 12.2 h | 16.3 h |
| 20 Mbit/s | 6.1 h | 8.1 h |
| 50 Mbit/s | 2.4 h | 3.3 h |
| 100 Mbit/s | 1.2 h | 1.6 h |
| 300 Mbit/s | 0.4 h | 0.5 h |

Kopia compression and encryption cost CPU on mini01; with the 500m limit expect a ceiling around
10 to 25 MB/s (about 80 to 200 Mbit/s) `[UNVERIFIED]`; measure. Daily incremental uploads afterwards are the
new photos only (a few hundred MB).

The operator's copy-paste checklist (browser; nothing here is committed):

1. Create the Backblaze account at https://www.backblaze.com (B2 Cloud Storage), enable two-factor
   authentication, save the recovery codes in the vault (C10). Choose the region (B3); note the endpoint
   shown in the bucket details (`s3.<region>.backblazeb2.com`).
2. Create bucket: private, name long and random (write the name in the vault), default encryption on
   (SSE-B2) `[UNVERIFIED: exact UI label]`, object lock off.
3. Lifecycle setting of the bucket: "Keep only the last version" (so the hidden versions that a delete
   creates are removed after a day; the default keeps all hidden versions and they are billed)
   [verified https://www.backblaze.com/docs/cloud-storage-lifecycle-rules]. Do not enable it on the first
   day before the seed backup if you want to inspect; enable it before WP10.
4. App Keys (not the master key; the master key does not work with the S3 API): create
   `velero-offsite-rw`: allow access to the ONE bucket, type Read and Write, with "Allow List All Bucket
   Names" ticked (required for bucket-restricted keys, verified above). Copy the keyID and applicationKey
   at once into the vault (shown only once). Create a second key `velero-offsite-ro`, same bucket, type
   Read Only, same checkbox (decision B8).
5. Note the S3 endpoint host and the region string (for example `us-west-004`) in the vault and tell the
   executor ONLY the region and the bucket name, not the keys.
6. Seal C7 and C8 and (decision B7) C9 as in section 6.3.

STOP: report decisions B1 to B9 answered.

### WP8: the offsite BackupStorageLocation (PR)

Branch: `backup-replica/offsite-bsl`. Preconditions: WP7 done (region and bucket name known; C7 sealed file
exists); decisions B1 to B4 answered.

Step 1. Add the sealed file `talos/sealed-secrets/velero-offsite-credentials.yaml` (from the operator) to
`talos/sealed-secrets/kustomization.yaml`.

Step 2. Edit `talos/values/velero.yaml`: replace the `backupStorageLocation` list with both entries (a list
is replaced, so `default` must be repeated unchanged). The existing comment 2 stays; add a comment 4.
Keep every other key as is. The final block:

```yaml
configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: velero-backups
      default: true
      config:
        region: minio
        s3Url: http://velero-backup-target.velero.svc.cluster.local:9000
        s3ForcePathStyle: "true"
    - name: offsite
      provider: aws
      bucket: <b2-bucket-name>          # from the operator (WP7); not a secret
      prefix: velero
      default: false
      accessMode: ReadWrite
      credential:
        name: offsite-credentials
        key: cloud
      config:
        region: <b2-region>             # for example us-west-004
        s3Url: https://s3.<b2-region>.backblazeb2.com
        s3ForcePathStyle: "true"
        checksumAlgorithm: ""           # B2 rejects the default CRC32 checksum header with XAmzContentSHA256Mismatch
```

Replace `<b2-bucket-name>` and `<b2-region>` with the values the operator gave (they are not host details; the
guard looks for private IPv4, tailnet names, MACs, fingerprints). `s3ForcePathStyle: "true"` is used because
B2 documents path-style bucket addressing `https://s3.<region>.backblazeb2.com/<bucket>` [verified
https://www.backblaze.com/apidocs/introduction-to-the-s3-compatible-api]. `checksumAlgorithm: ""` [verified
section 3.2]. The `credential` field is rendered per BSL by chart 12.1.0 [verified]. SSE-C
(`customerKeyEncryptionSecret`) is deliberately NOT set: Kopia writes the file data itself, and it is not
shown that the plugin setting applies to Kopia's blobs, so setting it would give a false sense of
encryption `[UNVERIFIED]`.

Step 3. Render check, offline:
`helm template velero velero --repo https://vmware-tanzu.github.io/helm-charts --version 12.1.0 -n velero -f argocd/values/velero.yaml -f talos/values/velero.yaml | yq 'select(.kind=="BackupStorageLocation") | .metadata.name'`
Expected: `default` and `offsite`. And
`... | yq 'select(.kind=="BackupStorageLocation" and .metadata.name=="offsite") | .spec.config'` shows
`checksumAlgorithm: ""`. If the value is missing (helm drops empty strings?) STOP: the chart quotes values
(`| quote`, so it prints `""`); if absent, report.

Step 4. Guards; commit; draft PR `velero: offsite BackupStorageLocation (Backblaze B2)`. No schedule yet.

The operator after merge: (a) `talos-sealed-secrets` auto-syncs; verify
`kubectl --context admin@<cluster> -n velero describe secret offsite-credentials` shows key `cloud`. (b) In the Argo UI open app `velero`,
look at the diff: it must show ONLY the new BackupStorageLocation `offsite` (and nothing on `default`, the
schedules, the Deployment); anything else: do not sync. (c) Sync `velero`. (d) Verify
`kubectl --context admin@<cluster> -n velero get backupstoragelocations` shows `default` Available and `offsite` Available within a few
minutes. If `offsite` is `Unavailable`: `kubectl --context admin@<cluster> -n velero describe backupstoragelocation offsite` message; see the troubleshooting table.

Rollback: revert the PR, sync `velero`; the bucket stays empty.

### WP9: seed backup to the offsite location (the operator)

Why separate from the schedule: the first upload is the whole library (about 55 GB) and takes hours
(table above). Creating the schedule first would start a competing run each day.

The operator's list (evening, so it does not compete with the 10:00 UTC nightly):

1. `velero backup create offsite-seed-1 --storage-location offsite --include-namespaces homeserver --ttl 720h`
   (Velero CLI against the live context). Opt-in volumes are the same pod annotation as the nightly, so the
   library and Vaultwarden are captured; no `--default-volumes-to-fs-backup` flag (it would drag in the
   CNPG volume; section 8 explains why that is excluded).
2. Watch: `velero backup describe offsite-seed-1 --details` and
   `kubectl --context admin@<cluster> -n velero get podvolumebackups.velero.io -o custom-columns=N:.metadata.name,VOL:.spec.volume,BYTES:.status.progress.bytesDone,TOTAL:.status.progress.totalBytes,PHASE:.status.phase`.
   Expected: one PVB for volume `data` growing to about 54.9 GB, then phase `Completed`; backup `Completed`.
   Record the duration (this is the real upload time for the operator's line; the table above is only an estimate).
3. If the backup ends `PartiallyFailed`/`Failed`: `velero backup logs offsite-seed-1 | tail -50`; do not
   delete anything; report. The node agent logs: `kubectl --context admin@<cluster> -n velero logs ds/node-agent --all-containers --tail=100`.
4. In the B2 web console: the bucket shows about the same size as the PVB (about 55 GB plus overhead).

STOP: report duration, size, phase.

### WP10: the offsite schedule and the database mirror (PR)

Branch: `backup-replica/offsite-schedule`. Preconditions: WP9 `Completed`; decisions B5, B6, B7 answered; C9
sealed if B7 is yes.

Step 1. In `talos/values/velero.yaml`, under `schedules:`, add (WHY `skipImmediately`: Velero otherwise runs
a backup the moment a schedule is created; the next run is then the cron time):

```yaml
schedules:
  homeserver-nightly:
    schedule: "0 10 * * *" # daily, 10:00 UTC (was Tuesdays only)
  homeserver-offsite:
    schedule: "0 11 * * *" # daily, 11:00 UTC, one hour after the nightly so the SMB read does not overlap
    skipImmediately: true
    template:
      storageLocation: offsite
      ttl: "720h0m0s"
      includedNamespaces:
        - homeserver
```

Keep the existing `homeserver-nightly` lines exactly as they are in the file (the snippet repeats them for
context only; change nothing else). Why the same `includedNamespaces`: the same opt-in annotation applies.
Expected rendered schedule name: `velero-homeserver-offsite` (chart prefix, as `velero-homeserver-nightly`).

Step 2 (only if B7 yes): this CronJob must not depend on mini03, so it lives in a separate small
kustomization `talos/manifests/backup-offsite/` with its own app. Create:

`talos/manifests/backup-offsite/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - db-mirror-cronjob.yaml
```

`talos/manifests/backup-offsite/db-mirror-cronjob.yaml`:

```yaml
# Copies the two database backup buckets from the primary MinIO to the B2 bucket (prefix db-mirror/),
# because Velero does not back up the CNPG volume: without this, an offsite restore has the photo FILES
# but not the Immich database (albums, faces, tags). No --remove: B2 keeps what MinIO expired, and the
# bucket lifecycle (Keep only the last version) removes only superseded versions.
# Credentials: Secret backup-offsite-mirror (MC_HOST_primary read-only user, MC_HOST_offsite B2 key).
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup-offsite-db-mirror
  namespace: velero
spec:
  schedule: "30 3 * * *"
  timeZone: Etc/UTC
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 3600
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 7200
      template:
        spec:
          restartPolicy: Never
          initContainers:
            - name: mirror-immich-pg
              image: cgr.dev/chainguard/minio-client@sha256:d8a93c5d335509ff353774eefec8f82fa2a2a975e800139702232d8be3dbe6b9
              args: ["mirror", "--overwrite", "--retry", "primary/immich-pg", "offsite/<b2-bucket-name>/db-mirror/immich-pg"]
              env:
                - {name: MC_CONFIG_DIR, value: /tmp/mc}
              envFrom:
                - secretRef:
                    name: backup-offsite-mirror
              resources:
                requests: {cpu: 25m, memory: 32Mi}
                limits: {cpu: 250m, memory: 128Mi}
              securityContext:
                runAsUser: 65532
                runAsGroup: 65532
                runAsNonRoot: true
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              volumeMounts:
                - {name: tmp, mountPath: /tmp}
          containers:
            - name: mirror-litestream
              image: cgr.dev/chainguard/minio-client@sha256:d8a93c5d335509ff353774eefec8f82fa2a2a975e800139702232d8be3dbe6b9
              args: ["mirror", "--overwrite", "--retry", "primary/litestream", "offsite/<b2-bucket-name>/db-mirror/litestream"]
              env:
                - {name: MC_CONFIG_DIR, value: /tmp/mc}
              envFrom:
                - secretRef:
                    name: backup-offsite-mirror
              resources:
                requests: {cpu: 25m, memory: 32Mi}
                limits: {cpu: 250m, memory: 128Mi}
              securityContext:
                runAsUser: 65532
                runAsGroup: 65532
                runAsNonRoot: true
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              volumeMounts:
                - {name: tmp, mountPath: /tmp}
          volumes:
            - name: tmp
              emptyDir: {}
```

03:30 UTC is one hour after the 02:30 Postgres base backup. Replace `<b2-bucket-name>`. The scheduler will
pick any schedulable worker (mini01, since mini02 is cordoned); requests are tiny. The B2 destination
path form `offsite/<bucket>/<prefix>` is how `mc` addresses an S3 bucket; `mc` talking to B2 through the
S3 API is not documented in a page read today `[UNVERIFIED]`: The operator proves it with the manual Job below
before relying on it.

`talos/apps-src/backup-offsite.yaml`: copy the shape of `talos/apps-src/backup-target.yaml` with
`path: talos/manifests/backup-offsite`, destination namespace `velero`, MANUAL sync (no `automated`
block), comment pointing at this plan. Run `talos/render-apps.sh --force`; add the expectation line.
Add `talos/sealed-secrets/backup-offsite-mirror.yaml` (C9) to the kustomization.

Step 3. Guards. PR title `velero: offsite schedule and database mirror to B2`. PR text includes the reasoning
for the 11:00 UTC cron and `skipImmediately`.

The operator after merge: sync `velero` (diff must show only the new Schedule, nothing else); sync
`backup-offsite`; run the DB mirror once:
`kubectl --context admin@<cluster> -n velero create job --from=cronjob/backup-offsite-db-mirror first-db-offsite`, watch its logs,
expect both mirrors to finish and the B2 console to show `db-mirror/immich-pg/...` (about 380 MB);
delete the job. Next day verify
`kubectl --context admin@<cluster> -n velero get backups.velero.io --sort-by=.metadata.creationTimestamp` shows
`velero-homeserver-offsite-<date>` `Completed` and a small PVB for `data` (only new data). Then enable the
B2 lifecycle rule (WP7 step 3) if not yet.

Rollback: set the schedule to disabled by reverting the PR; Velero removes the Schedule only after the app
syncs.

### WP11: restore drill from the offsite copy

Branch: `backup-replica/offsite-drill`. Preconditions: WP6 merged (`velero-drill` exists); WP10 done; the
C8 sealed secret exists.

Step 1. Add to `talos/values/velero-drill.yaml` a second location (the `replica` one stays; drop
`default: true` from `replica`, set it on neither: the drill passes `--storage-location` explicitly? Velero
restore does not take a location, it takes the backup name, so both can coexist because the backup names
differ):

```yaml
    - name: offsite
      provider: aws
      bucket: <b2-bucket-name>
      prefix: velero
      accessMode: ReadOnly
      credential:
        name: offsite-readonly-credentials
        key: cloud
      config:
        region: <b2-region>
        s3Url: https://s3.<b2-region>.backblazeb2.com
        s3ForcePathStyle: "true"
        checksumAlgorithm: ""
```

Add sealed C8 (`talos/sealed-secrets/velero-drill-offsite-credentials.yaml`) to the kustomization.

The operator's drill: identical to WP6 steps 1 to 9 with these changes: the backup `B` is the newest
`velero-homeserver-offsite-*`, the scratch namespace is `restore-drill-offsite`, the restore name
`drill-offsite-1`; and a database step:

DB restore proof (small): in `restore-drill-offsite` the executor does NOT restore Postgres (CNPG recovery
is its own procedure, `talos/dr/immich-pg-recovery.yaml`). The proof for the DB copy is that the objects exist
and have the right size: in the B2 console `db-mirror/immich-pg/` shows `base/` and `wals/` and the total
is about the primary's 380 MB; and a download check of the newest base backup file's size equal to
`mc ls` of the primary. State the result in the report.

Restore speed note: download is limited by the operator's download speed; 55 GB is within the free egress of
B2 (3x average stored data) [verified section 3.4]; repeated drills count toward that allowance: do the full
library drill once a year, and use a small-volume drill (Vaultwarden PVC, 1 Gi) at other times:
`--selector 'app.kubernetes.io/name=vaultwarden'` `[UNVERIFIED label]`, read the real label first.

Rollback and clean-up as WP6 step 8. Acceptance: `SAMPLE-IDENTICAL`, count within tolerance, durations
recorded. STOP.

## 8. Backup and restore

What each mechanism covers (after this plan):

| Data | Primary (mini02 MinIO) | Replica (mini03 MinIO) | Offsite (B2) |
|---|---|---|---|
| Immich library (volume `data` of immich-server, via the opt-in annotation `backup.velero.io/backup-volumes`) | `homeserver-nightly` 10:00 UTC, ttl 720h | mirror of the primary's Kopia repository, daily 13:00 UTC; keeps what the primary deleted | `homeserver-offsite` 11:00 UTC, its own repository, ttl 720h |
| Vaultwarden volume and the rest of `homeserver` PVCs that carry the annotation | same | same | same |
| Vaultwarden vault (SQLite) continuous | Litestream, bucket `litestream` | mirror | `db-mirror/litestream` (daily) |
| Immich Postgres | CNPG WAL + daily base backup, bucket `immich-pg`; NOT in Velero | mirror | `db-mirror/immich-pg` (daily) |
| cp-reserva-bot | `velero-cp-reserva-bot-nightly` | mirror | NOT covered (not in `homeserver`); say so to the operator, add a second offsite schedule only if he wants it |
| Jellyfin media on the mini01 disks (hostPath) | not covered | not covered | not covered (decision of 2026-10-19; unchanged here) |
| Kubernetes objects of `homeserver` | in each backup | mirrored | in each offsite backup |
| Samba shares `nas` | not covered by Velero | | |

Not covered by this plan: the other namespaces (adguard, nas, argocd), the Jellyfin media, the secrets key
(`docs/dr/talos-backups.md` "Sealing key" has its own rule).

Recovery objective: the replica lags the primary by up to 27 hours (backup at 10:00, mirror at 13:00,
worst case a failure just before the next one); offsite lags up to 24 hours plus the DB mirror up to 24 hours.
WAL files make the Postgres RPO from the primary seconds, but offsite and replica copies of `immich-pg` are
daily copies of the bucket.

Consistency caveat of copying a Kopia repository with `mc mirror`: if a Velero backup or Kopia
maintenance writes while the mirror runs, the replica can briefly hold an inconsistent repository
(an index blob referencing a blob not yet copied). The mirror runs 3 hours after a backup that takes under
a minute, and the next run corrects it; the restore drill (WP6) is the proof that a given replica state is
usable. If a drill fails on a Kopia consistency error, rerun the mirror by hand and retry; if it persists,
report.

Restore tests (the executor writes the procedures, the operator performs them): WP6 (replica alone), WP11
(offsite alone), plus the existing in-cluster drill `talos/dr/velero-restore-drill.sh` against the primary
(unchanged). Real disaster recovery from the replica when mini02 is gone:
`docs/dr/mini03.md` "Restore from the replica" (a Velero installed against the replica's Service with the
`replica-restore` or a fresh scoped `velero` user created by `talos/dr/minio/setup-users.sh --alias
REPLICA`, then `velero restore create --from-backup NAME`); keep the scratch-Velero technique above in mind:
the new Velero has no other location, so the name collision does not arise.

## 9. Security

- Exposure: nothing is exposed. `velero-backup-replica` is a ClusterIP Service; the MinIO console is bound to
  loopback inside the pod; no Ingress, no tailnet Service. The B2 bucket is private; access only by bucket-
  restricted keys. Nothing on the public internet except Velero's and `mc`'s outbound HTTPS to the B2 endpoint.
- Authentication: MinIO root pair only for administration; the mirror uses scoped users (reader on the
  primary cannot write or delete, so a bug or compromise of the mirror cannot damage the primary; the writer
  exists on the replica only; the restore user is read-only).
- Network access: [UNVERIFIED] whether the cluster has NetworkPolicies; none were found in the repo audit
  for namespace `velero` (WP1 step 4: `grep -rn NetworkPolicy talos/ argocd/`). If none, the replica
  Service is reachable from every pod, as is the primary: same posture as today. Do not add policies in
  this plan.
- Pod security: the `velero` namespace is `privileged` (needed by the node agent); the pods added here are
  hardened anyway: non-root, `allowPrivilegeEscalation: false`, all capabilities dropped; the mirror pods
  also `readOnlyRootFilesystem: true` with an `emptyDir` on `/tmp`. The MinIO server pod does not set
  `readOnlyRootFilesystem` (the primary does not either); the two busybox init containers run briefly (the
  `own-data` one as root to `chown` the data directory, the same as the primary).
- ServiceAccounts: none of the new workloads call the Kubernetes API; they use the namespace default
  ServiceAccount. If you want to be strict, set `automountServiceAccountToken: false` in the pod specs in
  a follow-up; not done here to stay identical to the primary.
- Encryption at rest and in transit: in-cluster traffic to MinIO is plain HTTP, as the primary
  (accepted on the pod network). To B2: HTTPS only (B2 accepts nothing else). At rest in B2: Kopia's
  repository encryption with Velero's static shared key (section 3.2): anyone who gets the bucket
  contents AND knows that public default can decrypt. Mitigations in place: private bucket, a key restricted to
  that bucket, SSE-B2 on the bucket (provider-side), two-factor on the account. What Velero offers beyond
  that: change `velero-repo-credentials` (global, breaks existing repositories, so it is a separate plan,
  decision B4 option b); `serverSideEncryption`/`customerKeyEncryptionSecret` apply to the plugin's own
  object writes (metadata), not shown to cover Kopia's blobs `[UNVERIFIED]`. True client-side encryption
  of the photos needs a tool outside Velero (decision B4 option c) and is NOT designed here: do not invent
  one.
- Ransomware: the B2 key used by the schedule can delete objects. The read-only key exists only for drills.
  Optional hardening for the operator: B2 Object Lock with a retention period, which Velero's TTL deletion would
  then fail against (so it conflicts with TTL clean-up); not recommended without a plan.
- Secret hygiene: all values only in the vault and as SealedSecrets; the temporary directory
  `~/secrets-tmp/backup-replica` is deleted after WP6 (`rm -r`); `unset` of shell variables after sealing.

## 10. Operations

### Upgrade procedure

- MinIO and mc: bump the digest in a PR. Read the new tag's digest from `talos/dr/pin-images.sh` output
  (needs network and crane/skopeo/docker buildx) or from the registry page of Chainguard
  (`cgr.dev/chainguard/minio`, `.../minio-client`; they publish only `latest` plus dated tags, the pin is
  the digest). Change the same digest in `talos/dr/images.env`, `talos/manifests/backup-target/minio.yaml`,
  `talos/manifests/backup-replica/minio.yaml` and the mirror CronJobs in one PR (the guard compares
  images.env with the manifests). Update the primary and the replica on different days.
- Velero and the aws plugin: unchanged by this plan; when bumping, keep `velero-drill` in lockstep
  (`targetRevision` and the plugin tag).
- B2 settings change by edits of `talos/values/velero.yaml` only.

### Health checks (the operator, weekly for the first month, then monthly)

```bash
kubectl --context admin@<cluster> -n velero get backupstoragelocations
kubectl --context admin@<cluster> -n velero get cronjob,jobs
kubectl --context admin@<cluster> -n velero get backups.velero.io --sort-by=.metadata.creationTimestamp
kubectl --context admin@<cluster> -n velero exec deploy/minio-replica -c minio -- df -h /data
```

Expected: `default` and `offsite` Available; the newest `backup-replica-mirror-*` Job `Complete`; the newest
`velero-homeserver-nightly-*` and `velero-homeserver-offsite-*` `Completed`; the replica volume under 70%.

### Logs

`kubectl --context admin@<cluster> -n velero logs job/<job> --all-containers`; MinIO:
`kubectl --context admin@<cluster> -n velero logs deploy/minio-replica -c minio`; Velero:
`kubectl --context admin@<cluster> -n velero logs deploy/velero`; node agent:
`kubectl --context admin@<cluster> -n velero logs ds/node-agent --all-containers`.

### Resource watch

`kubectl --context admin@<cluster> top nodes` and `kubectl --context admin@<cluster> -n velero top pods`.
During the WP9 seed expect the node-agent pod on mini01 at its 500m CPU limit for hours; mini01 was
at 42% CPU on 2026-10-25, so it stays below saturation; if Jellyfin or Immich get sluggish, tell the operator (do
not change limits).

### Troubleshooting

| Symptom | Where to look | Likely cause | Fix |
|---|---|---|---|
| `minio-replica` Pending | `describe pod`, events | taint not tolerated, nodeSelector wrong, mini03 not Ready | align the toleration with `kubectl get node mini03 -o jsonpath='{.spec.taints}'` in a PR |
| `minio-replica` CrashLoop, `Access Denied` or permission error on `/data` | pod logs, init container logs | `own-data` init did not run or the volume mount path differs | check `df` shows the volume; fix the hostPath in a PR |
| Mirror Job fails at `size-gate` | init container log "at or above 80%" | replica volume full | WP4 step 9 clean-up; if already equal, prune primary retention or enlarge the disk (sizing section) |
| Mirror Job fails with `Access Denied` or `signature does not match` | `logs job/<name> -c mirror-...` | wrong or rotated key in `backup-replica-mirror`; user missing on a side; policy not attached | check `mc admin user list` in the pod; reset password and reseal (6.6) |
| Mirror Job fails, `no such host` / timeout | same | Service name wrong; primary pod down; cross-node network | `get svc velero-backup-target`; `get pods -l app=minio` |
| Mirror pod OOMKilled | `describe pod` | many objects, mc memory | raise limit to 512Mi in a PR |
| Mirror runs but replica smaller than primary by more than 5% | WP4 step 4 | job incomplete, `--retry` exhausted | rerun; read the log tail |
| Replica grows faster than expected | sizing table | no `--remove`; Kopia GC garbage | run the clean-up Job (WP4 step 9) |
| `offsite` BSL `Unavailable` | `describe backupstoragelocation offsite` | wrong key; missing `listAllBucketNames`; wrong endpoint region; `checksumAlgorithm` missing | fix the key in B2 (new key, reseal) or the values in a PR |
| Offsite backup `XAmzContentSHA256Mismatch` | `velero backup logs` | `checksumAlgorithm: ""` missing (verified above) | add it |
| Offsite backup very slow | node-agent logs, `top` | upload bandwidth or the 500m CPU limit | wait; note speed; do not change limits without the operator |
| `velero-homeserver-offsite` backup missing | `get schedule` | `skipImmediately` waits for the next cron time; paused | wait until 11:00 UTC |
| B2 bill higher than expected | B2 console | hidden versions accumulate (default "Keep all versions") | set lifecycle "Keep only the last version" (WP7 step 3) |
| Drill: replica BSL Available but `backups` list is empty | `logs deploy/velero -n velero-drill` | sync period not elapsed; bucket prefix; credentials read-only user lacking `ListBucket` on the bucket | wait 5 minutes; check policy file |
| Drill: restore `PartiallyFailed`, Kopia error `access denied`/write | restore logs `velero restore logs` | read-only user cannot write the repository lock | use `replica-writer` for the drill (decision A3) |
| Drill: PVC Pending | `describe pvc` | the volumeName patch did not apply / storage class | check the resource modifier ConfigMap; report |
| Argo shows `velero` OutOfSync with more than the new BSL/schedule | Argo diff | drift | do NOT sync; report |

## 11. Acceptance checklist and report format

The operator should see, at the end:

- [ ] `kubectl --context admin@<cluster> -n velero get pods -l app=minio-replica` shows `Running` on mini03.
- [ ] `kubectl --context admin@<cluster> -n velero get cronjob` lists `backup-replica-mirror` (not suspended),
      `backup-replica-prune-sync` (suspended), and, if B7 yes, `backup-offsite-db-mirror`.
- [ ] Replica and primary `du` of the three buckets agree within 5%.
- [ ] A mirror ran by schedule and `Complete`d; alert rule loaded (or the manual check recorded).
- [ ] The default mirror does not delete: demonstration (optional, the operator): note a backup name that Velero
      expired on the primary after its TTL; it is still listed on the replica
      (`mc ls` through `exec deploy/minio-replica`).
- [ ] Replica drill: `FILES` within tolerance, `SAMPLE-IDENTICAL` (200 of 200).
- [ ] BSL `offsite` Available; seed backup `Completed`, PVB about 55 GB; schedule produced a backup.
- [ ] Offsite drill passed; B2 lifecycle set; B2 cost on the first invoice about $0.40 or less.
- [ ] Credentials C2, C3 to C9 and the B2 login are in Vaultwarden; the temporary directory is deleted.

Report format after each package (the executor writes exactly this):

```
WP<n>: done|blocked|needs decision
PR: <url or none>
Guards: 20/20 OK | list of FAIL
Verified: <commands run and the outputs that matched>
Differences from the plan: <anything that did not match, with the exact output>
Needs from the operator: <list, or none>
```

## 12. Open questions and UNVERIFIED items

| # | Item | How to confirm |
|---|---|---|
| U1 | Taint key/value on mini03 (`node-role.homeserver/tier=mobile`) comes from draft PR #71 | `kubectl get node mini03 -o jsonpath='{.spec.taints}'` (P5) |
| U2 | `MC_HOST_<alias>` doc page not re-read today (the variable is used by the draft and the image help lists it) | WP1 step 6 `mc --help` |
| U3 | A same-named backup in two locations in one Velero 1.18 | not needed: design avoids it; read https://github.com/velero-io/velero/issues/3026 for status if the operator wants the replica registered in the live Velero |
| U4 | `readOnlyRootFilesystem: true` on the mc containers with `MC_CONFIG_DIR=/tmp/mc` (draft did not set it) | first mirror run (WP4 step 3) |
| U5 | Kopia can restore from a ReadOnly location with a read-only user | WP6 (decision A3) |
| U6 | `remove /spec/volumeName` resource-modifier patch on a static-bound PVC | WP6 step 5 |
| U7 | `helm.skipCrds` field in the Argo Application (and that it leaves the live CRDs untouched) | Argo CD Helm docs; Argo diff must show no CRD change |
| U8 | Pod/PVC labels for `--selector` of the restores | read-only `get ... --show-labels` |
| U9 | B2 SSE-B2 default encryption UI label; effect of an S3 delete on a versioned bucket (hidden version) | B2 console / docs when creating the bucket |
| U10 | Whether Velero rereads a rotated credentials Secret without restart | rotation test, 6.6 |
| U11 | `mc` against B2 (S3 API) for the DB mirror | manual Job in WP10 |
| U12 | Kopia upload throughput under the node agent's 500m CPU limit | measured in WP9 |
| U13 | kube-state-metrics metric names and node-exporter visibility of `/var/mnt/backups` (WP5) | query once monitoring exists |
| U14 | Cloudflare R2 compatibility with the Velero plugin | only if the operator chooses R2 |
| U15 | The operator's upload speed | speed test (B9) |
| U16 | USB disk price (not researched) | only if the operator chooses option B or C |
| U17 | Whether to keep only the last 30 or 90 days offsite (B5) | decision |

Contradictions between the repo and the brief, found while writing: (1) the brief says the mc image has
no shell and to use `kubectl exec ... -- mc`; the `mc-only` pod does not stay running, and the MinIO server
image of this cluster does contain `bash` and `mc` (verified live), so admin commands exec into the server
pods with `bash -c` and feed passwords by standard input. (2) Draft PR #71 mirrors with `--remove` and
says the first copy takes hours; this plan defaults to no `--remove` (the brief) and estimates minutes on a
fast LAN. (3) `docs/dr/mini03.md` is on branch `talos/victus-vm` and not on main; the sizing numbers
were re-measured live instead.
