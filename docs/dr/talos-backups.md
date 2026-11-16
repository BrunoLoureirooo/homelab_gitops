# Talos backups: what is backed up, how often, how it comes back

Plan 15-06. Everything here assumes the Talos route (the cluster that replaces k3s on mini01).
Nothing in this document changes the live k3s cluster. The backup target is MinIO running
standalone on victus (`docs/dr/minio-standalone.md`), reached from the cluster through the stable
in-cluster name `velero-backup-target.velero.svc` (`talos/manifests/backup-target`).

## What is protected, and how much can be lost

| Data | Mechanism | Loss window |
|---|---|---|
| Vaultwarden vault (SQLite) | Litestream stream to S3, plus Velero nightly | seconds |
| Immich database (Postgres, CNPG `immich-pg`) | WAL archive and daily base backup to S3 | seconds to minutes |
| Immich photo library (volume `immich-library-smb`) | Velero `homeserver-nightly` file-system backup of the immich-server volume `data` (the only copy tool for the library) | up to 24 hours |
| cp-reserva-bot (100Mi WhatsApp session) | Velero nightly | up to 24 hours (a session can be re-paired) |
| Everything else in `homeserver` | Velero nightly | up to 24 hours |

**Be honest about "on every change".** Velero has no backup-on-write. The continuous parts are
Litestream (SQLite) and WAL archiving (Postgres). Files are covered by the nightly Velero
backup, not by a per-write hook. If the machine dies, up to 24 hours of new photos and other
files can be gone. The phone still holds a photo until you delete it: **do not delete a photo
from the phone until a `homeserver-nightly` backup that started after the upload has completed
(up to 24 hours)** (see `## Photo library`).

## Velero

- Config: `argocd/values/velero.yaml` (unchanged) plus `talos/values/velero.yaml`, which sets the
  schedule `homeserver-nightly` to daily (`0 10 * * *`, UTC) and points the backup location at the
  stable service name. Applied only to the Talos Application (`talos/overrides/15-06.yaml`).
- Volumes are opt-in per Pod (`backup.velero.io/backup-volumes`; `defaultVolumesToFsBackup` is
  unset on purpose so the CNPG volume is not dragged in). `argocd/values/immich.yaml` annotates the
  immich-server pod with `data`, which is the pod-level volume name of the library claim, so the
  library IS captured. Confirmed live: the nightly backup carries a Completed PodVolumeBackup for
  `immich-server` volume `data` of about 55 GB. `velero backup describe <name> --details` lists the
  volumes a backup took.
- CI proof: `talos/test/jobs/velero-roundtrip.sh` backs up three volume shapes (SQLite in WAL
  mode, a 100Mi tree like the bot, 300 MB of nested files like the library), destroys the whole
  cluster, restores into a scratch namespace on a new cluster and compares checksums.
- Restore drill: `talos/dr/velero-restore-drill.sh --backup NAME (--ci | --live CONTEXT)`
  restores into `restore-drill` only. It refuses a wrong context (exit 3), an existing scratch
  namespace (exit 4) and a backup that is not Completed (exit 5). It prints `FILES`, `BYTES`,
  `SQLITE integrity_check ok` and `DRILL PASS`.
- At cutover, restore everything except the CNPG volume (it comes back from the WAL archive or the
  dump): `velero restore create ... --selector '!cnpg.io/cluster'`. The roundtrip job proves the
  selector syntax; if Velero ever rejects it, plan 15-07 step 12 must use a label-matching form.
- Accepted risk: the Velero repository password stays the chart default. Bucket access is the real
  boundary (Velero is the only backup tool, so there is no second repository).

## Sealing key

The Sealed Secrets private key must be in the cluster BEFORE the controller starts, and the
`secrets` app syncs only after that. The cutover order is: restore the key (`talos/dr/restore-sealing-key.sh
FILE --live CONTEXT`), then the controller, then `secrets`, then `talos-sealed-secrets`.

- Keep the offline copy on an encrypted medium that is not mini01 and not inside the cluster
  (the medium and where you keep copies are your choice; this repository never records
  addresses or names). `talos/dr/verify-sealing-key.sh FILE` prints `MATCH` or `DIFFERENT`
  and nothing else.
- `keyrenewperiod` stays `"0"` so the offline copy cannot go stale. If it is ever changed,
  take a fresh backup after every renewal.
- CI proof: `talos/test/jobs/sealing-key.sh` shows the object decrypting after a restore-first
  start, and, as a control, NOT decrypting in a cluster where the controller generated its own key.
- Objects sealed against the CURRENT cluster's certificate (as in `## Sealing the credentials`)
  decrypt in the Talos cluster only if this old key is restored first. That is the point.

## Vaultwarden

- Litestream runs as a sidecar and replicates `/data/db.sqlite3` to bucket `litestream` every
  second. An init container restores an empty volume from the replica before Vaultwarden starts
  (`-if-db-not-exists -if-replica-exists`: harmless when the database exists or there is no replica yet).
  Config: `talos/values/vaultwarden.yaml`, only in the Talos Application.
- Cost: one more container (about 20 to 40 MiB of memory) and a Deployment recreate on first sync
  (the chart already recreates it, see the note in `argocd/values/vaultwarden.yaml`), a brief
  vault outage: sync at a quiet moment.
- Velero hourly still backs the volume up. Restore order at cutover: restore the volume from
  Velero first (the "volume restore pause"), and the Litestream init only restores if the volume
  turns out empty.
- Litestream needs WAL. The roundtrip job reads the journal mode of the database the real image
  creates and FAILS with `JOURNAL_MODE=<mode>` if it is not `wal`, so you decide before trusting it.
- Assumption to confirm: Vaultwarden uses SQLite, because the values set no `DATABASE_URL`.
  Task 6 asks you to check live with one read-only command. If there is no `db.sqlite3`, drop the
  sidecar and rely on Velero hourly alone.
- Residual exposure (accepted): the replica holds a copy of the database; vault entries are
  encrypted by the clients, and the `litestream` bucket has its own scoped user.
- CI proof: `talos/test/jobs/litestream-roundtrip.sh` (real image, real chart, both values files),
  deletes the Pod AND the claim and requires an intact database with the last committed row.

## Immich Postgres

- The cluster is `immich-pg` (CNPG). It has no backup today. The overlay `talos/overlays/immich-infra`
  adds continuous WAL archiving, a base backup retained 14 days and a daily `ScheduledBackup`
  (02:30 UTC) to bucket `immich-pg`, without touching `argocd/manifests/immich-infra` (the overlay
  only patches; `talos/overlays/render.sh` builds it into `talos/manifests/immich-infra`, which the
  Talos Application deploys; `check-backups-06.sh` fails on drift).
- Operator: CNPG **1.25.0**, the version plan 01-09 records for the live cluster, in the Talos set as
  `talos/apps-src/cnpg-operator.yaml` (manual sync). **Confirm the live version** with
  `kubectl -n homeserver get cluster immich-pg -o jsonpath='{.status.image}'` and
  `kubectl get deploy -A | grep cnpg` before cutover; a version change is a separate decision.
  The in-tree `barmanObjectStore` method used here exists in 1.25; newer operators move to the
  Barman Cloud plugin.
- The CNPG Cluster is NOT backed up by Velero (its volume is excluded at restore), so the WAL
  archive and the cutover dump are the only database backups.
- **Cutover dump (manual, during the write freeze, no CronJob):**
  `bash talos/dr/immich-dump.sh --context CTX --out FILE` prints `DUMP size=... sha256=...`;
  `bash talos/dr/immich-restore.sh --dump FILE --context CTX` prints `RESTORE ROWS=<n>`.
  `talos/test/jobs/pgdump-restore.sh` proves identical rows and checksum after losing the cluster.
- **Recovery** (point in time or latest) uses `talos/dr/immich-pg-recovery.yaml`, applied instead
  of the normal Cluster. A recovered cluster archives under a NEW `serverName`
  (`immich-pg-r1`, then `r2`, ...) because CNPG refuses to archive into a path that holds
  another history; update the normal manifest's `serverName` to match afterwards.
  `talos/test/jobs/cnpg-pitr.sh` proves recovery to a target time returns exactly the rows
  committed before it.

## Photo library

- Velero is the single backup tool for everything, including the Immich library on the SMB claim
  `immich-library-smb`. There is no separate Kopia job (it was removed; see
  `## Removing the old Kopia library backup`). The nightly `homeserver-nightly` schedule backs the
  library up through file-system backup of the immich-server volume `data`.
- Freshness and RPO are daily. Check with `velero backup get` that the newest `homeserver-nightly`
  is `Completed` and has a `Completed` PodVolumeBackup for `immich-server` volume `data`.
- Restoring the library is slow and serial: Velero restores the volume file by file from MinIO
  (tens of GB, expect hours), and the pod waits for it. Plan for that, and rehearse with
  `talos/dr/velero-restore-drill.sh` into a scratch namespace.
- The library is a live tree, not an atomic snapshot: a file written during the backup is picked up
  by the next night's run.

## Removing the old Kopia library backup (the operator, after merge)

Do this only after a `homeserver-nightly` (or a manual `homeserver` backup) that started after the
merge shows the `immich-server` volume `data` PodVolumeBackup `Completed`. In this order:

1. Sync the root app so the `library-backup` Application is removed. The Application has
   `prune: false` for its children, so confirm the CronJobs are gone and delete them if not:
   `kubectl -n homeserver get cronjob`, then
   `kubectl -n homeserver delete cronjob library-backup library-backup-prune`.
   Delete the Application too if it lingers: `kubectl -n argocd delete application library-backup`.
2. `kubectl -n homeserver delete secret library-backup-repo library-backup-s3`.
3. Remove the bucket data and the scoped MinIO user with `mc` run from a pod in the cluster,
   using the `minio-root` Secret (never print it):
   `mc alias set t http://velero-backup-target.velero.svc.cluster.local:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"`
   (both read from the Secret into the pod's env, not typed), then
   `mc rb --force t/library-backup`, `mc admin user remove t library-backup`,
   `mc admin policy remove t backup-library-backup`. Touch no other bucket or user.
4. Confirm `tank/backups` usage dropped (expect about 51 GB freed from 103 GB), for example
   `zfs list tank/backups` on mini02.

The Kopia repository password is no longer needed after step 3; the offline copy can be discarded.

## Sealing the credentials (the operator, plan 15-06 Task 6)

> **Done 2026-10-17 on the mini02 MinIO.** The buckets `velero-backups`, `litestream`
> and `immich-pg` exist (plus the old `library-backup`, pending removal below), each with one bucket-scoped user (policy `backup-<bucket>` from
> `talos/dr/minio/policy.json.tmpl`), and all the sealed files below are committed. Velero now runs on the
> scoped `velero` user, not the root pair. `minio-root` is sealed too (same value, adopted in place).
> Retrieve any value with `kubectl -n <ns> get secret <name> -o jsonpath='{.data.<key>}' | base64 -d`.

Plaintext exists only in a temporary file OUTSIDE the repository, deleted afterwards. Seal offline
against the current cluster's public certificate; no cluster access is needed.

1. Create the scoped MinIO users on the standalone MinIO (dry run first, `docs/dr/minio-standalone.md`):
   `bash talos/dr/minio/setup-users.sh --alias NAME --out DIR` writes one mode-0600 file per bucket
   (outside any git work tree) with the generated access key and secret.
2. For each Secret below, build the Secret in memory and pipe it through `kubeseal`:

   | Sealed file in `talos/sealed-secrets/` | Namespace and Secret name | Keys |
   |---|---|---|
   | `litestream-s3.yaml` | `homeserver/litestream-s3` | `access-key-id`, `secret-access-key` |
   | `immich-pg-s3.yaml` | `homeserver/immich-pg-s3` | `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY` |
   | `velero-cloud-credentials.yaml` | `velero/cloud-credentials` | `cloud` (an AWS-style credentials file for the `velero` user) |

   Pattern (keeps the value off the screen and out of shell history):

   ```bash
   read -rs VALUE
   printf %s "$VALUE" | kubectl create secret generic litestream-s3 -n homeserver \
       --from-literal=access-key-id=ACCESS --from-file=secret-access-key=/dev/stdin \
       --dry-run=client -o json |
     KUBECONFIG=/dev/null kubeseal --cert argocd/sealed-secrets/pub-cert.pem --format yaml \
       > talos/sealed-secrets/litestream-s3.yaml
   unset VALUE
   ```

3. List each file under `resources:` in `talos/sealed-secrets/kustomization.yaml` and commit.
   `.github/scripts/check-backups-06.sh` fails if a file there is not a `SealedSecret`.

## Pinning (images and tools)

- Image tags are in `talos/dr/images.env` and in the manifests; the guard fails if they differ, and on
  `latest`. Digests are added by `bash talos/dr/pin-images.sh` (needs network and crane, skopeo or
  docker buildx). The jobs print a warning while a digest is missing.
- The Velero and kubeseal CLIs are verified against `VELERO_CLI_SHA256` and `KUBESEAL_SHA256` when
  set; the jobs print `TOOL <name> <version> sha256=...` so the pin can be copied in.
- Litestream: the tag `0.3.13` was chosen without network access. Re-check the release page when you
  pin the digest and use the newest release whose config keys (`sync-interval`, `snapshot-interval`,
  `retention`, `force-path-style`) match `talos/values/vaultwarden.yaml`.
