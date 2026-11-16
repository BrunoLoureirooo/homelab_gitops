# mini02 storage decision (plan 15-05)

Status: PROVISIONAL. The ZFS mirror was chosen as the goal by the operator on
2026-10-12 (two disks exist to give live redundancy). It becomes MEASURED when
the CI job `zfs-mirror` has run and its verdicts are filled in below. If that
job FAILS, the line `Option taken:` must be changed to 2 and the reason added in
the same commit; ZFS is never kept on documentation alone.

Option taken: 1

## Options and verdicts

| # | Option | What it is | Measured verdict | Cost if we fall back |
|---|---|---|---|---|
| 1 | ZFS mirror | official `siderolabs/zfs` extension, pool `tank` created once by `talos/storage/zfs-pool-job.yaml`, mounted under `/var/tank` | NOT YET MEASURED: run `talos/test/jobs/zfs-mirror.sh` (CI job `vm (zfs-mirror)`) | live redundancy lost, see option 2 |
| 2 | One data disk + second copy | a UserVolume on one drive, a scheduled copy (rsync pod) to the other | NOT YET MEASURED (no CI job needed until option 1 fails) | a disk failure loses up to one copy interval of data |
| 3 | RAID in a NAS pod | privileged pod running mdadm against raw disks | NOT PLANNED | works around the platform, last resort only |

The `mdadm` Talos extension is a deprecated no-op (checked in the extensions
catalog 2026-10-12), so the old "RAID1 by hand" design has no direct equivalent.

What `zfs-mirror` must show for option 1 to stand (`ASSERT` lines in its log):
`pool-created`, `job-idempotent`, `hash-before-reboot`, `pool-online-after-reboot`,
`hash-after-reboot`, `degraded-state-reported`, `degraded-readable`. The job also
records `IMPORT_ON_BOOT=auto|manual-needed` and the ZFS version. A
`manual-needed` result does not by itself fail option 1, but it means the plan
needs an import step at boot (a documented follow-up task) before mini02 is trusted.

Facts from the extension README (checked 2026-10-12): the kernel module is loaded
through machine config (`talos/patches/volumes-mini02.yaml`), pools are created
from a privileged pod and not from machine config, a pool must mount under
`/var`, SELinux contexts must be disabled on the pool. Not documented and left to
the CI job: ZFS version, import on boot, scrub behaviour.

## Samba and SMB access

Samba is a pod (`talos/manifests/samba-nas/`) over `/var/tank/shares` (or the
UserVolume path under option 2), pinned to the mini02 worker, with per-app shares
`media`, `music`, `paperless`, `immich`. It runs as one account; its credential
is a sealed Secret sealed by the operator (never in this repo).
CI proof: `talos/test/jobs/nas-pod.sh` (write and read back over SMB) and
`talos/test/jobs/csi-smb.sh` (a PV through `csi-driver-smb`).
`csi-smb.sh` first measures whether the Talos kernel has CIFS. If it does not,
the job records `CIFS=missing`, this file is updated, and apps do not mount the
share through the CSI driver. The recorded fallbacks, in order:
1. an NFS export from a small NFS server pod over the same dataset, mounted by
   apps through a normal NFS PV (needs the NFS client in the kernel, which Talos
   ships), or
2. the application mounts the Samba share itself inside its own pod through an
   init container.
Which one is taken is decided when `csi-smb.sh` has reported; until then this
section is a plan, not a result.

## Jellyfin library (local disks, not the NAS)

Decision (the operator, 2026-10-19): the Jellyfin media is NOT on the NAS. It lives on mini01's two local
Toshiba disks, the Talos user volumes `u-media` (`/var/mnt/media`) and `u-media2` (`/var/mnt/media2`),
mounted into the Jellyfin pod read-only as `/media/disk1` and `/media/disk2` through hostPath volumes
(`talos/manifests/jellyfin/deployment.yaml`; the pod is pinned to mini01 because the disks are node-local).
Content is split by folder so each film or series stays whole on one disk: disk1 = Films, Absolutely
Anything, anime, Captures; disk2 = TopGear, The.Grand.Tour. In the Jellyfin setup wizard add the library
paths `/media/disk1` and `/media/disk2` (or `/media` for both).

- No redundancy: the two disks are independent XFS filesystems (no RAID, no mirror). One disk failing loses
  its half of the library.
- Not backed up by Velero: hostPath volumes are not PVCs and Velero's volume backup is opt-in per pod
  annotation, which Jellyfin does not carry, so nothing breaks and nothing is copied. Only the small
  `jellyfin-config` claim is in the namespace backup. The original files on victus are the only other copy.
- The Samba shares are `shared` (general files, tank/nas), `paperless` and `immich`. The earlier `media`, `music` and `backups` shares were empty and unused and were removed (2026-10-25); the real Velero backups are in MinIO on tank/backups, which is never shared over SMB.

## Immich originals

The originals live on the mini02 dataset (mirrored under option 1), served
through SMB or a local PV. They move there only after both are true:
1. a Velero restore of the photo library into a scratch namespace
   reproduces the file count and a sha256 sample of the live volume, and
2. The operator confirms after the hardware step (plan 15-05 Task 4, `docs/dr/mini02-talos.md`).
Nothing in this plan moves any photo. Until both are true the library stays where
it is.

### Migration plan for the Immich library (written 2026-10-17, EXECUTED 2026-10-18)

**Result (2026-10-18):** the library (16,579 files, 54,993,549,023 bytes) was copied with rsync while Immich
ran, then a final pass with Immich stopped. Verified before the switch: `rsync -c` dry run showed 0
differences, file count and byte total equal on both sides, 200 of 200 random files matched by sha256.
PV/PVC `immich-library-smb` use `uid=0,gid=0` because Immich runs as root. Velero backs up the same
claim (volume `data`). See talos/overlays/immich-infra/library-smb.yaml.

State on that day: the library (55 GB, PVC `immich-library-pvc`, a `local` PV on mini01's
`data` volume) lives on mini01. mini02 now has the ZFS mirror `tank` mounted at
`/var/mnt/tank`; dataset `tank/immich` (quota and reservation 128 GB) is served by the Samba pod
as the share `immich`, and `csi-driver-smb` is installed. A scratch SMB volume was proven
end to end (write on mini01, read from a fresh pod, file visible on mini02's disk).

Steps, each a stop point (The operator confirms before step 4):
1. **Copy, never move.** A Job in `homeserver` mounts the old PVC read-only and a NEW PVC
   (`immich-library-smb`, a static PV `smb.csi.k8s.io`, source
   `//samba-nas.nas.svc.cluster.local/immich`, mount options `uid=1000,gid=1000,
   file_mode=0664,dir_mode=0775,vers=3.1.1`, secret `smb-csi-credentials`) and runs
   `rsync -a --info=progress2`. Immich keeps running during the copy; a second
   pass after step 3 catches uploads made in between.
2. **Verify.** Same file count and total bytes on both sides, and `sha256sum` of at least 200
   random files (`shuf -n 200`) compared old vs new. Any difference stops the plan.
3. **Cut over in a short window.** Scale `immich-server` to 0, run the final rsync pass,
   re-verify the count, change the chart's existing claim to `immich-library-smb`
   (talos/values/immich*.yaml `existingClaim`), scale back to 1, open the web UI and check that
   an old and a brand-new photo both load.
4. **Keep the old PVC** (the PV is `Retain`) until the operator confirms, then remove it by hand.

What stays on mini01: the Postgres database (`immich-pg`, CNPG). A database does not belong
on SMB (locking and fsync semantics), and it is small. Vaultwarden stays local for the same
reason (SQLite).

Backups of the SMB volume: Velero file-system backup reads a pod volume from the node's
kubelet pod directory. It does not support `hostPath` volumes (we hit exactly this on
2026-10-17: restores into hostPath PVs failed), but it handles CSI-backed volumes, including
SMB-type volumes such as Azure Files, because it resolves the PV name under
`volumes/kubernetes.io~csi/<pv>/mount`. Confidence: fairly high from the Velero
documentation and how the node agent finds the volume, but NOT tested on this cluster. The
first real check is step 3: take a backup right after the cutover and confirm a
PodVolumeBackup for the library reaches `Completed` with the expected size.

**Risk, stated plainly.** After the cutover Immich's photos live only on mini02, so
mini02 (or its network path, or the Samba pod) being down makes the photo library
unavailable. The ZFS mirror protects against ONE disk dying, not against losing the
machine or deleting files. The Velero backups also land on the same `tank` pool
(`tank/backups`), so they do NOT protect against losing mini02 or both of its disks. Until a
copy exists somewhere else (an offsite or external-disk copy; not victus, which no longer
holds anything backup-related), the library has one physical location. That second copy is a
decision for the operator before step 4.

## Library backup

Velero is the single backup tool for the Immich library too (decision 2026-10-18; the separate
Kopia CronJob was dropped to avoid duplicate machinery). The nightly `homeserver-nightly` schedule
backs up the immich-server volume `data` (the `immich-library-smb` claim) by file-system backup.
RPO is daily, so the rule is: do not delete anything from the phone until a backup that started
after the upload has completed (up to 24 hours). Restoring the library is slow and serial.
