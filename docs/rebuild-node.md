# Rebuild a node (Talos)

> Status: written before the first cutover drill (plan 15-09). Steps marked
> "as run" in `talos/CUTOVER.md` are the ground truth; correct this file from
> its drill record once G2 has passed. Placeholders in angle brackets
> (`<node>`, `<MINIO_ENDPOINT>`) are filled from your own notes; no address,
> tailnet name or key is ever written in this repository.

## Warning: this erases the target disk

Installing Talos wipes the disk it is installed on. Before any step below, be
certain which physical disk is the target (`talosctl get disks --insecure` lists
what the installer sees) and that nothing on it is the only copy of anything. The
disk that held the previous system is kept untouched as the rollback until the
gate checks in `## Verify (gate checks)` pass.

## Pre-flight

Do not start until all of these are true; `talos/scripts/cutover-preflight.sh`
prints PASS, FAIL or BRUNO (confirm by hand) for each.

1. A restore drill (D-REBUILD) passed after the last application change, and a
   Velero backup newer than 24 hours is `Completed` in the standalone MinIO.
2. The sealed-secrets key matches the offline copy (`talos/dr/verify-sealing-key.sh`
   prints `MATCH`), checked in the last 7 days.
3. Every decision in `talos/DECISIONS.md` is answered (no `DEFAULT`), and gate G1 in
   gate G2 is recorded as passed in `talos/CUTOVER.md`. (The G1 findings file was never written:
   the cutover went ahead without the full G1 CI run.)
4. The old tailnet devices of the node and its services are listed for deletion
   (they must be deleted after power-down and before first boot, or the new devices
   register with a `-1` suffix and break application URLs).
5. You know which physical disk is which, and everything on a disk that will be
   overwritten has been copied elsewhere and verified (`## Disk roles and the data copy`).

## Build and pin the install media

The Image Factory publishes no vendor checksum on the free tier, so the hash is
ours. The schematic is `talos/schematics/<node>.yaml`; the Talos version and every
hash are pinned in `talos/versions.env` (this file references them, it never copies
a hash).

`bash talos/fetch-assets.sh <node> iso-secureboot` (or `iso` for a plain install)
downloads the media and checks it against the pin. The first run for a new pin
exits 3 and prints the computed hash: review it, put it in `talos/versions.env`,
commit, and rerun. A mismatch exits 1 and deletes the file. Write the media to a
USB stick after confirming the stick's device name; never use a device you have not
identified.

## Disk roles and the data copy

When two disks swap roles, the disk that will be overwritten is copied first to a
third disk and verified with a sha256 manifest compared on both sides:

    bash talos/scripts/disk256-copy.sh copy <source mount> <destination dir>
    bash talos/scripts/disk256-copy.sh verify <source mount> <destination dir>

Expect `COPY-VERIFY PASS`. Run it again after writers are frozen (`--final`). Keep the
copy until the previous disk is back in service and the gate checks have passed.

## Secure Boot decision

Decided at install time because a plain install cannot become a Secure Boot install
without a reinstall. Try the Secure Boot media first: put the firmware in setup mode,
choose `Enroll Secure Boot keys: auto` at the boot menu, and confirm with
`talosctl -n <node> get securitystate --insecure`. If the firmware refuses, install
from the plain media and record "Secure Boot off" as an accepted risk (see
`## Accepted risks`).

## Boot, install and bootstrap

1. Boot the stick. `talosctl -n <node> get disks --insecure` must list the target disk
   and not the disk you are keeping; the selector in `talos/nodes/mini01.yaml` must
   match only the target.
2. Render the configuration with the real secrets (`bash talos/render.sh mini01`) and
   apply it: `talosctl apply-config --insecure -n <node> -f <rendered file>`. The node
   installs and reboots; remove the stick.
3. Once only: `talosctl bootstrap -n <node> -e <node>`. Then
   `talosctl kubeconfig -n <node> -e <node>` and wait for `kubectl get nodes` to show
   Ready.
4. `talosctl -n <node> health` and `talosctl -n <node> mounts` confirm the node and
   its data volumes.

## Platform and restore order

The order is scripted in `talos/bootstrap-argocd.sh` and described in
`argocd/OPERATIONS.md`; do not re-order it by hand.

1. Restore the sealing key FIRST (`talos/dr/restore-sealing-key.sh`), before the
   sealed-secrets application starts, or the controller generates a new key and no
   existing sealed secret decrypts.
2. Namespaces, secrets, the Talos sealed secrets, then the platform and storage
   applications.
3. Pause at `volume-restore-pause`: restore the data volumes with Velero from the
   standalone MinIO, using the storage-class map (`topolvm-fast` is the live class), and
   leaving out the database volume.
4. Pause at `db-restore-pause`: restore the database from the manual dump
   (`talos/dr/immich-restore.sh`) or from the WAL archive, as described in
   `docs/dr/talos-backups.md`.
5. Sync the remaining applications. Vaultwarden restores its database from its own
   replica when its volume is empty (`docs/dr/talos-backups.md`).
6. Standalone MinIO on the backup host (`docs/dr/minio-standalone.md`): the in-cluster
   MinIO must be scaled to 0 before it is started, never two processes on one
   directory.

## Verify (gate checks)

`bash talos/scripts/g2-check.sh` prints one line per check: node Ready, the
Vaultwarden URL matches its configured domain, Immich restored with the recorded
asset count, the bot session volume bound, a real hardware transcode, the media disk
mounted, two hourly backups at least 50 minutes apart, an upgrade rehearsal, and the
data copy still present. Only when every line is PASS (or confirmed by hand) is the
rebuild proven; then the previous disk may be reused after a hold.

## Upgrade and rollback

`talosctl -n <node> upgrade --image <installer ref> --wait`, where the installer ref
comes from `bash talos/fetch-assets.sh <node> installer-ref` (or `installer-secureboot-ref` for a node whose
`INSTALLER` is `installer-secureboot`, as mini01's is). The node reboots into the
new image; a failed boot rolls back by itself. A manual rollback is
`talosctl -n <node> rollback`. `talosctl -n <node> version` shows what is running.
On a single control plane the API is unavailable for a few minutes while the
applications keep running. Always rehearse on a throwaway version bump (D-UPGRADE)
and check that data volumes survive both reboots.

## Add the mini02 worker

mini02 joins as a worker only: it has no etcd. Its storage layout, the ZFS mirror and
the Samba pod are in `talos/STORAGE-DECISION.md` and `docs/dr/mini02-talos.md`; its
machine configuration is `talos/nodes/mini02.yaml`. Apply the worker configuration with
`talosctl apply-config --insecure -n <node> -f <rendered file>` and confirm with
`kubectl get nodes`.

## Accepted risks

- Secure Boot state is whatever `SECURE-BOOT:` in `talos/CUTOVER.md` records.
- Disk encryption is deferred.
- One control plane: when the control-plane node is down the cluster API is down;
  running pods on other nodes keep running.
- The backup copy lives on one host until a second location exists.
- Non-database volumes can lose up to an hour of changes (the hourly schedule).

## Drill catalogue

Each drill has a stable id used by `docs/mini01-coverage.md`. Run them on a scratch
namespace or a scratch cluster, never on live data.

- D-REBUILD: rebuild a node from bare metal with this file and restore all
  applications; the full cutover is the first run.
- D-VW: restore the Vaultwarden backup into a scratch namespace and open the
  database with an integrity check.
- D-PG: restore the Immich database from the manual dump and from the WAL archive
  into a scratch cluster and compare row counts.
- D-LIB: restore the Immich library backup into a scratch volume and time it.
- D-CP: restore the bot's session volume and confirm it starts without re-pairing.
- D-UPGRADE: upgrade to the next patch version, roll back, and confirm the data
  volumes and applications survived both reboots.
- D-ETCD: take `talosctl -n <node> etcd snapshot` and restore it into a scratch
  cluster.
- D-DISKLOSS: with the previous disk still safe, simulate losing the system disk and
  recover with this file only.

### Drill record

| Drill | Result | Date | Note |
|---|---|---|---|
| D-REBUILD | PENDING | | first run is the cutover |
| D-VW | PENDING | | |
| D-PG | PENDING | | |
| D-LIB | PENDING | | |
| D-CP | PENDING | | |
| D-UPGRADE | PENDING | | |
| D-ETCD | PENDING | | |
| D-DISKLOSS | PENDING | | |
