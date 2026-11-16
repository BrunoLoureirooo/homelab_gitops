> **SUPERSEDED (2026-10-17).** The backup target now runs on mini02 on the ZFS dataset `tank/backups`
> (`talos/manifests/backup-target`), behind the same in-cluster name `velero-backup-target`. Nothing
> backup-related stays on victus. The victus MinIO, its unit and its data were REMOVED on 2026-11-04.
> This page is kept only as history of how it was set up; do not follow it. The second copy of the
> backups is the replica on mini03 (`docs/dr/mini03.md`).

# MinIO outside the cluster (victus)

Plan 15-06 Task 6. The Talos cluster replaces the one that hosts MinIO today (an in-cluster Deployment
on victus, hostPath `/srv/backup`), so the backup target has to outlive the cluster. This document
runs MinIO as a systemd service on victus, over the same data directory, and keeps it installed but
**disabled** until you start it on purpose.

## The one rule

**Never run two MinIO processes on the same data directory.** The in-cluster pod must be scaled to 0
before the standalone service starts, and the standalone service must be stopped before the in-cluster
one is ever started again.

```bash
kubectl -n velero scale deploy/minio --replicas=0     # in-cluster first, always
kubectl -n velero get pods -l app=minio                # confirm it is gone
sudo systemctl start minio-standalone                  # only then
```

## Parameters

Everything that differs between the dry run and the real thing is in one file, `/etc/minio-standalone.env`
(mode 0600, owned by root; never in the repository):

| Variable | Dry run | Real |
|---|---|---|
| `BACKUP_DIR` | `/srv/backup-trial` | `/srv/backup` |
| `MINIO_IMAGE` | the image the in-cluster pod runs today, by digest | same |
| `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` | new throwaway values | the existing root pair (sealed as `minio-creds` today) |

Get the exact image the in-cluster pod runs now (it is `latest` in the chart, so the digest is what
pins it): `kubectl -n velero get pod -l app=minio -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'`.
Use that value as `MINIO_IMAGE` so the standalone server is byte for byte what ran before.

## Install (disabled)

```bash
sudo install -m 0644 talos/dr/minio/minio-standalone.service /etc/systemd/system/
sudo install -m 0600 /dev/null /etc/minio-standalone.env && sudo "${EDITOR:-vi}" /etc/minio-standalone.env
sudo systemctl daemon-reload                 # do NOT enable
sudo pacman -S --needed podman               # the unit runs the container with podman
```

The data directory must be writable by the container user. The in-cluster chart runs `chmod 0777 /data`
once; do the same on the directory you are about to use if MinIO reports a permission error.

## Dry run on a second directory (before cutover)

1. `sudo mkdir -p /srv/backup-trial && sudo chmod 0777 /srv/backup-trial`; set `BACKUP_DIR=/srv/backup-trial`.
2. `sudo systemctl start minio-standalone` (the real `/srv/backup` is untouched and the in-cluster pod can
   keep running because it uses a different directory).
3. `mc alias set trial http://localhost:9000 ROOTUSER ROOTPASS` (use a temporary shell so nothing lands in history).
4. `bash talos/dr/minio/setup-users.sh --alias trial --out ~/minio-trial-creds` creates the three
   buckets (`velero-backups`, `litestream`, `immich-pg`) and one bucket-scoped user
   each, and writes their credentials as mode-0600 files in that directory (outside the repository).
5. Confirm the buckets exist: `mc ls trial`. Stop it: `sudo systemctl stop minio-standalone`.

## Cutover (plan 15-07 drives this; the order matters)

1. Scale the in-cluster MinIO to 0 and confirm the pod is gone.
2. Set `BACKUP_DIR=/srv/backup`, `sudo systemctl start minio-standalone`.
3. Run `setup-users.sh` against the real alias once; `velero-backups` already exists with the old
   backups, and `velero` already has a user (the script keeps existing users and prints that it did).
4. From the new cluster, the in-cluster name `velero-backup-target` must reach it (a pod running
   `wget -qO- http://velero-backup-target.velero.svc.cluster.local:9000/minio/health/live`).
   If the short hostname `victus` does not resolve inside pods, use the selector-less Service form in
   `talos/manifests/backup-target/service.yaml` and apply the Endpoints by hand.
5. Enable it only after the cutover has passed: `sudo systemctl enable minio-standalone`.

## Rollback

Stop the standalone service first (`sudo systemctl stop minio-standalone`), then scale the in-cluster
MinIO back up. The data directory is the same, so the old backups are intact either way.
