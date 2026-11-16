# backup-replica: the second copy of the backups on mini03

Design and sizing: `docs/dr/mini03.md` (on the mini03 branches until they merge). Nothing here is
deployed: the Application `backup-replica` is manual sync and every pod is pinned to the node `mini03`,
which does not exist until phase P2 of that plan. **Do not sync it before mini03 is Ready and the two
Secrets below are sealed.**

## What is here

| File | What |
|---|---|
| `minio.yaml` | `Deployment/minio-replica`, pinned to mini03, hostPath `/var/mnt/backups` (the Talos user volume `backups`, 128 GiB) |
| `service.yaml` | `Service/velero-backup-replica` (restore: use it as a Velero BackupStorageLocation) |
| `mirror-cronjob.yaml` | daily 13:00 UTC `mc mirror` primary -> replica for `velero-backups`, `litestream`, `immich-pg`, behind an 80% size gate |

## Secrets the operator creates and seals (none is in the repository)

Both go in namespace `velero`, sealed against the cluster certificate as in `docs/dr/talos-backups.md`
("Sealing the credentials"), into `talos/sealed-secrets/` and listed in its `kustomization.yaml`.

| Secret | Keys | Purpose |
|---|---|---|
| `minio-replica-root` | `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` | root of the replica MinIO (new random values, not the primary's) |
| `backup-replica-mirror` | `MC_HOST_primary`, `MC_HOST_replica` | each `http://ACCESS:SECRET@HOST:9000`; the read-only user on the primary and the writer on the replica, below |

### Users (scoped, same pattern as `talos/dr/minio/setup-users.sh`)

On the **primary** (mini02), a read-only user for the mirror. It can list and read the three buckets and
nothing else, so the mirror can never change or delete the primary:

```bash
mc admin policy create PRIMARY backup-replica-reader talos/dr/minio/policy-replica-reader.json
mc admin user add PRIMARY replica-reader "$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
mc admin policy attach PRIMARY backup-replica-reader --user replica-reader
```

On the **replica**, once it runs: create the three buckets and a read-write user for the mirror, and (for a
restore, later) the usual per-bucket users:

```bash
bash talos/dr/minio/setup-users.sh --alias REPLICA --out DIR_OUTSIDE_THE_REPO   # buckets + per-bucket users
mc admin policy create REPLICA backup-replica-writer talos/dr/minio/policy-replica-writer.json
mc admin user add REPLICA replica-writer "$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
mc admin policy attach REPLICA backup-replica-writer --user replica-writer
```

Do these from a temporary shell with the passwords read with `read -rs` so nothing lands in shell history,
and write the generated secrets only to files outside the work tree. `PRIMARY` and `REPLICA` are `mc`
aliases you set with the root credentials; the primary's root pair is in the Secret `minio-root`.

## First run

```bash
kubectl -n velero create job --from=cronjob/backup-replica-mirror first-mirror
kubectl -n velero logs job/first-mirror --all-containers
```

The first run copies about 60 GB; expect hours. The size gate refuses to run at 80% of the volume
(about 110 GB); the failed Job is the alert (`docs/dr/mini03.md`, "Size math").

## Restore

`docs/dr/mini03.md`, "Restore from the replica".
