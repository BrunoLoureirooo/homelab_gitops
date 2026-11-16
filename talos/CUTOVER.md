# Cutover: mini01 from Debian + k3s (512 disk) to Talos (256 disk)

The one hardware session of the Talos trial (plan 15-07). The 256 GB disk, today
victus's secondary disk, goes into mini01 and receives Talos. mini01's 512 GB disk
goes into victus and is not wiped, mounted for writing or reused before gate G2.
Everything here is operator-run. Allow an evening; do not start unless you can finish
or roll back.

## Record (fill in as you go; verdicts and names only)

The scripts read these lines. A value that still starts with `<` counts as empty.
Never write addresses, MAC addresses, device identifiers or keys in this file.

```text
LIVE-DISK-CONFIRMED: Samsung 512 GB NVMe (hw-capture 2026-10-17: system on LVM, /srv/media on a Toshiba)
DISK-256-CONTENT: nothing to keep (victus's secondary LUKS disk, temporary; the operator 2026-10-17). The backups already live on the 1 TB.
BACKUP-DISK: the 1 TB (read-only check 2026-10-15: /srv/backup is a bind mount of a directory on the 1 TB disk)
TOSHIBA: two 320 GB disks, both formatted by Talos. The first is empty (2.1 MB used); the second holds an old Linux install, wiped on purpose (The operator 2026-10-17).
SECURE-BOOT: off
RESTORE-DRILL: <PASS date, from the 15-06 live drill>
SEALING-KEY-MATCH: 2026-10-17 (fingerprints compared by hand: stick copy equals the live key)
PRE-CUTOVER-ASSET-COUNT: 6335
ASSET-COUNT-NOTE: 6335 is the restored count (Oct 17 02:00 dump). G2-3 reads 6337 after 2026-10-17 18:22 UTC because the phone uploaded one image and one video to the new server (6335 + 2); that is new data, not a restore error.
COPY-256-DIR: NOT-NEEDED
COPY-256-PRECOPY: NOT-NEEDED
COPY-256-FINAL: NOT-NEEDED
UPGRADE-REHEARSAL: PASS (confirmed by the operator 2026-11-06; not re-run or re-checked by Claude)
JELLYFIN-QSV: PASS (confirmed by the operator 2026-11-06; no transcode in the server logs of the last 3 days)
```

`SECURE-BOOT` values: `off` = the UKI installer (the `iso-secureboot` image) with Secure Boot left
unenforced in the firmware and no keys enrolled (decision D1 (b), the answer on record); `try` =
the same image with Sidero's keys enrolled (D1 (a)); `classic` = the classic installer and the
plain ISO (D1 (c)).

`G2: PASS <date>` is written at the very end, on its own line, only by you.

## Safety rules

1. Nothing is wiped and no disk leaves a machine until `cutover-preflight.sh` shows
   no FAIL (BRUNO lines you confirm by hand).
2. HARD STOP: before the 256 leaves victus, all its data (including `/srv/backup` if
   it lives there) is copied to victus's 1 TB disk and verified with a sha256
   manifest compared on both sides. The copy stays on the 1 TB disk until the 512 is
   back in victus and G2 has passed.
3. The 512 disk stays untouched until G2. Never mount, fsck or write to it.
4. No script chooses the install disk: you confirm it against the printed disk list.
5. This session does not start unless `G1 DECISION: go` is in `talos/FINDINGS.md`
   and no decision in `talos/DECISIONS.md` is still `DEFAULT`.
6. Rollback is possible at every step before G2 (see `## Rollback`).

Variables used below, none committed: `MINI01` the node's LAN address during
install; `MINIO_ENDPOINT` the standalone MinIO on victus; `COPY_DIR` the value of
`COPY-256-DIR`; `OLD` the kubectl context of the current k3s cluster.

## Part 1: preparation (live system untouched, can span days)

### 1. Hardware facts (read-only)

On the current Debian mini01: `bash talos/scripts/hw-capture.sh mini01`. On victus:
`bash talos/scripts/hw-capture.sh victus`. It prints disk models and sizes, the NIC
chip family, firmware messages, the GPU family, the render and video group ids, TPM
and Secure Boot state and whether `/srv/media` is empty. It never prints device
identifiers or hardware addresses.

Check against the schematic in `talos/schematics/mini01.yaml`:

- A Realtek NIC with a `firmware: failed to load` line means the schematic needs the
  Realtek firmware extension (already listed in plan 15-02).
- The GPU must be an i915-era Intel part (HD 530). A newer one: tell me before the
  image is built.
- Copy the two numeric ids from `HW-gids` into `talos/manifests/jellyfin/gids-patch.yaml`
  and commit. They are the ids on the CURRENT Debian system; confirm them against the
  Talos node in G2 step 2 (`ls -ln /dev/dri` from a debug pod) and correct if they differ.
- Write `TOSHIBA: empty` or `TOSHIBA: has data` in the Record. If it has data, copy
  it with `disk256-copy.sh` (step 3) before Talos formats it.

On victus read the LVM lines too (`HW-lvm-pv`, `HW-lvm-lv`). The inventory places the
backup storage on a logical volume of a volume group on victus, so before anything
is pulled you must know which physical volume each logical volume sits on. If the
volume group spans the 256 (a volume with extents on it, or the backup volume
among them), STOP: pulling the disk leaves the group without a member and it will
not activate. Move the data off that physical volume first (copy the volume to the
1 TB disk, or `pvmove`, your choice) and say so in `BACKUP-DISK`.

Mark which disk is which. Write `LIVE-DISK-CONFIRMED`, `DISK-256-CONTENT` and
`BACKUP-DISK` in the Record. STOP and reply if they contradict "the 512 is live in
mini01 and the 256 is victus's secondary disk".

### 2. Prove the restore path first

Plan 15-06 Task 6 gives the live restore drill. Paste `DRILL PASS` and its date as
`RESTORE-DRILL:`. Verify the sealing key against the offline copy
(`talos/dr/verify-sealing-key.sh`, expect `MATCH`) and write the date as
`SEALING-KEY-MATCH:`.

### 3. Pre-copy the 256 data (first pass of the HARD STOP, everything still live)

**Skipped (the operator, 2026-10-17):** the 256 holds nothing to keep; the backups are on the 1 TB already, so the three `COPY-256-*` lines in the Record say `NOT-NEEDED` and the preflight and G2 accept that. If that ever changes, replace them with `PASS` and a directory and do the copy below.

On victus, with the 256 mounted and the 1 TB disk mounted:

```bash
bash talos/scripts/disk256-copy.sh copy <mountpoint of the 256> <dir on the 1 TB disk>
bash talos/scripts/disk256-copy.sh verify <mountpoint of the 256> <dir on the 1 TB disk>
```

Expect `COPY-VERIFY PASS files=<n> bytes=<n>`. Anything else: stop. The script
refuses when the destination is inside the source, when both are on one physical
disk, and when the source is the root filesystem. Write `COPY-256-DIR:` and
`COPY-256-PRECOPY: PASS`. The 256 stays in victus.

### 4. Decisions

`bash .github/scripts/check-talos-config.sh --require-decisions`; expect exit 0
(Secure Boot, endpoint form, key custody, disk selectors answered in
`talos/DECISIONS.md`). D1 is answered (b), so the Record says `SECURE-BOOT: off`.

### 5. Build and pin the ISO

```bash
bash talos/fetch-assets.sh mini01 iso-secureboot   # first run: exit 3, prints the hash
```

Exit 3 with `FIRST-FETCH ASSET_MINI01_ISO_SECUREBOOT_SHA256=<hash>` is expected the
first time: check the hash (the Factory has no vendor checksum on the free tier, so
the hash is yours; download once more on another network or another day for extra
assurance), put it in `talos/versions.env`, commit, and rerun: expect the cached path
and exit 0. The plain `iso` is only needed for `SECURE-BOOT: classic`, but its pin must still be
valid (the preflight checks it). Write the ISO to the stick,
confirming first that the device is the stick and not an internal disk:

```bash
diskutil list                                   # macOS: find the stick
sudo dd if=<iso path> of=/dev/rdiskN bs=4m
```

### 6. Pre-flight

```bash
MINIO_ENDPOINT=<standalone MinIO URL> MC_ALIAS=<mc alias> bash talos/scripts/cutover-preflight.sh
```

Expect every line PASS or BRUNO (confirm the BRUNO ones yourself). Any FAIL: stop,
fix, rerun. It is read-only and exits 2 if the old cluster is unreachable.

## Part 2: the cutover session

Roll back at any step before G2 by following `## Rollback`. Have the phone ready
not to upload.

### Quiesce and back up (old cluster, 512 disk)

1. Pause writers: pause backup in the Immich phone app, pause all jobs in the Immich
   admin UI, do not open Vaultwarden, and do not message the cp-reserva bot. Record the Immich asset count as
   `PRE-CUTOVER-ASSET-COUNT:`. The count `g2-check.sh` compares against is the
   database row count:
   `kubectl --context $OLD -n homeserver exec <immich-pg primary pod> -c postgres -- psql -U postgres -d immich -tAc "select count(*) from asset"`
   (the table is `asset` in current Immich and `assets` in older releases; unverified).
   Cross-check the Immich statistics page, which can be lower because it leaves out
   trashed items.
2. Manual dumps while the pods run: `bash talos/dr/immich-dump.sh --context $OLD --out <file on your Mac>`;
   expect `DUMP size=<n> sha256=<hash>`. For Vaultwarden's SQLite database use its
   admin "backup database" action or the `sqlite3 .backup` command in
   `docs/dr/talos-backups.md`, and copy the file to your Mac. Keep both files.
3. Final Velero backup, pods still running:
   `velero backup create cutover-final --include-namespaces homeserver,cp-reserva-bot --wait`.
   Both namespaces are needed: the bot's WhatsApp session volume is in `cp-reserva-bot`, not in
   `homeserver`. The Velero CLI is not installed on mini01 (and mini01 has no passwordless sudo): run
   it from your Mac against the old cluster, or create the same Backup with kubectl
   (`kubectl --context $OLD apply -f -`):

   ```yaml
   apiVersion: velero.io/v1
   kind: Backup
   metadata: {name: cutover-final, namespace: velero}
   spec:
     includedNamespaces: [homeserver, cp-reserva-bot]
     storageLocation: default
     ttl: 720h0m0s
   ```

   then poll `kubectl --context $OLD -n velero get backups.velero.io cutover-final -o jsonpath='{.status.phase}'`
   until it says `Completed`.
   Expect `Phase: Completed` and `Errors: 0` in `velero backup describe cutover-final --details`,
   and every PVC of Immich, Vaultwarden and cp-reserva-bot listed under pod volume
   backups (or snapshots) as Completed. A partial or any warning: stop and fix.
   (Unverified: whether the old Velero setup uses pod volume backups or CSI snapshots;
   read `docs/dr/talos-backups.md`.)
4. Prove it is in MinIO: on victus `mc ls <alias>/velero-backups/backups/cutover-final/`
   lists the backup files. Run `bash talos/dr/verify-sealing-key.sh <offline file>`
   once more; expect `MATCH`.
5. Freeze: `bash talos/scripts/freeze.sh freeze --context $OLD`. It records every replica
   count, scales the Argo CD controller, everything in `homeserver` and in
   `cp-reserva-bot` and any other MinIO to 0, and waits until no Immich, Vaultwarden, cp-reserva or MinIO pod is
   Running. Expect `FREEZE DONE targets=<n>`. This also stops the writer of
   `/srv/backup`.
6. Final copy (HARD STOP; skipped while `COPY-256-FINAL: NOT-NEEDED`, only the k3s-agent line applies): on victus `sudo systemctl disable --now k3s-agent`
   (reversible), then
   `bash talos/scripts/disk256-copy.sh copy <mountpoint of the 256> $COPY_DIR --final`
   and `verify ... --final`; expect `COPY-VERIFY PASS ... pass=final`. Copy the two
   dump files from your Mac into `$COPY_DIR/dumps` and verify again. Write
   `COPY-256-FINAL: PASS`. If `BACKUP-DISK` is the 256, `BACKUP_DIR` is the copied
   `srv/backup` path inside `$COPY_DIR`; otherwise the original `/srv/backup`. Do not
   go on without `COPY-256-FINAL: PASS`.

### Swap

7. Power off mini01 cleanly (`sudo systemctl poweroff`) and victus. Disconnect the
   SATA cables of BOTH Toshibas on mini01 (the old media disk and the second one in the optical bay) so the installer cannot see them. Remove the 512 from
   mini01 and label it "512 LIVE ROLLBACK". Remove the 256 from victus. Install the 256
   in mini01 and the 512 in victus as its secondary disk. Boot victus: `lsblk` and
   `findmnt` must show the 512 NOT mounted; if `vgs` shows its old volume group
   active, `sudo vgchange -an <vg>`. Never mount, fsck or write to it.
8. Tailnet cleanup, now that nothing is online with those names: in the Tailscale admin
   console delete the old devices `mini01` (host), `vaultwarden`, `immich`,
   `cp-reserva-bot` and the operator's own device. Not victus. Otherwise they come back
   as `...-1` and Vaultwarden's `DOMAIN` breaks.
9. Secure Boot (decision D1 (b), `SECURE-BOOT: off`): leave the firmware's Secure Boot
   disabled and do NOT clear the Platform Key or enrol any keys. The UKI installer boots
   with Secure Boot off, so nothing about the BIOS changes and the Debian rollback needs no
   key restore. Boot the stick. After the install check
   `talosctl -n $MINI01 get securitystate --insecure`; expect `SECUREBOOT` `false`, and put an
   accepted-risk line in `talos/FINDINGS.md`.
   Only if you later change the answer to `try`: put Secure Boot in setup mode (clear the
   Platform Key; the menu varies and this is the untested part), boot the stick, press Esc at
   startup and pick `Enroll Secure Boot keys: auto`, and expect `SECUREBOOT` `true`; if the
   BIOS refuses, power off and go back to `SECURE-BOOT: off`.

### Install and bootstrap

10. In maintenance mode `talosctl -n $MINI01 get disks --insecure`: expect only the 256
    NVMe (both Toshibas are still disconnected). Confirm with your own eyes that
    `the install selector (UnattendedInstallConfig)` in `talos/nodes/mini01.yaml` matches only that disk.
    Render with the real secrets bundle (`bash talos/render.sh mini01`) and apply:
    `talosctl apply-config --insecure -n $MINI01 -f talos/out/mini01.yaml`. The node installs
    and reboots; remove the stick when it restarts. Then, once only,
    `talosctl bootstrap -n $MINI01 -e $MINI01`, then
    `talosctl kubeconfig -n $MINI01 -e $MINI01`; `kubectl get nodes` should show `Ready`
    within about 10 minutes. Power off, reconnect both Toshibas, boot, and expect
    `/var/mnt/media` and `/var/mnt/media2` in `talosctl -n $MINI01 mounts`. Both disks are
    formatted, each pinned by serial from `talos/secrets/disks-mini01.sops.yaml`
    (`talos/secrets/README.md` section 3b); the second disk held an old Linux install and is wiped on purpose.
11. Standalone MinIO on victus: confirm the in-cluster MinIO is gone (the agent is
    disabled and the pod scaled to 0) and nothing else uses `$BACKUP_DIR`; then follow
    `docs/dr/minio-standalone.md`, pointing the unit at `$BACKUP_DIR` with the same image
    and credentials as the old MinIO. Expect `mc ls <alias>/velero-backups/backups/` to
    list `cutover-final`.
12. Restore, in the order of `talos/bootstrap-argocd.sh`: `bash talos/bootstrap-argocd.sh --live`
    (it prints the context and wants it typed back). It restores the sealing key FIRST,
    then syncs namespaces, secrets, the Talos sealed secrets, platform and storage apps,
    and stops at `volume-restore-pause`. At that pause run the Velero restore with the
    storage-class map from `talos/FINDINGS.md` and WITHOUT the Immich database volume:
    `velero restore create cutover-restore --from-backup cutover-final --selector '!cnpg.io/cluster' --wait`.
    Expect `Phase: Completed`, `Errors: 0`. Type `restored`. The script syncs `immich-infra`
    (a fresh `immich-pg` cluster) and stops at `db-restore-pause`: run
    `bash talos/dr/immich-restore.sh --dump $COPY_DIR/dumps/<file> --context <new context>`;
    expect `RESTORE ROWS=<n>` equal to `PRE-CUTOVER-ASSET-COUNT`. Type `restored`; the
    script syncs the remaining apps.
13. Verify: `kubectl get pods -A` all Running, Vaultwarden reachable at its tailnet URL
    with the right `DOMAIN`, then `bash talos/scripts/g2-check.sh | grep -E '^G2-(1|2|3) '`;
    expect three PASS.

## Rollback

Valid until G2. Power off mini01 and victus. Take the 256 (now Talos) out of mini01 and
the 512 out of victus. Put the 512 back into mini01 and reconnect the Toshiba. Put the
256 back into victus: if it held `/srv/backup`, re-create its filesystem (Talos is being
abandoned, so this wipe is intended) and copy `$COPY_DIR` back with
`disk256-copy.sh copy $COPY_DIR <256 mountpoint>` and `verify` BEFORE re-enabling
anything. Stop the standalone MinIO (`systemctl stop` its unit) so two MinIO processes
never share a directory. Boot mini01 and on victus `sudo systemctl enable --now k3s-agent`.
The old cluster comes back with workloads scaled to zero:
`bash talos/scripts/freeze.sh unfreeze --context $OLD` restores the recorded counts
(MinIO first, the Argo CD controller last). If Secure Boot keys were cleared or replaced,
restore the BIOS factory keys first (menu name unverified) or the signed Debian shim
will not boot. The deleted tailnet devices re-register: re-authenticate the host with a
fresh key from the admin console (`sudo tailscale up --auth-key=<key>`, never pasted into
the repo) and check that `vaultwarden` came back under its old name; if it is
`vaultwarden-1`, delete the duplicate and restart the proxy pod.

## Part 3: gate G2

1. cp-reserva-bot: confirm it is still logged into WhatsApp. If it asks to pair again, the
   session volume did not restore: note `CP-SESSION: re-paired` (not a G2 fail, but a
   Velero gap to record).
2. Jellyfin: deploy by manual sync (`talos/apps-src/jellyfin.yaml`), confirm the group ids
   (`ls -ln /dev/dri` from a debug pod must show the ids in
   `talos/manifests/jellyfin/gids-patch.yaml`), copy one H.264 test video around 1080p to
   `/var/mnt/media`, add a library on `/media`, play it from a client with quality set below
   the source to force a transcode. `bash talos/scripts/g2-check.sh`; expect
   `G2-5 jellyfin-qsv PASS`. If the aggregator cannot find the log (the path is unverified),
   the Jellyfin dashboard "Playback" must show hardware transcoding; record
   `JELLYFIN-QSV: PASS` by hand.
3. Hourly backup: wait for two backups of schedule `homeserver-hourly` at least 50 minutes
   apart (`velero backup get`); both `Completed`.
4. Upgrade rehearsal: on a throwaway branch bump `talos/versions.env` to the next patch
   version and build its installer reference with `bash talos/fetch-assets.sh mini01 installer-secureboot-ref`
   (mini01 installs from the UKI installer, `INSTALLER=installer-secureboot` in `talos/nodes/mini01.env`)
   (do not merge). `talosctl -n $MINI01 version` (record), then
   `talosctl -n $MINI01 upgrade --image <installer ref> --wait`. Expect a reboot, the API
   unavailable for a few minutes while the apps keep running, then Ready and the new version.
   Then `talosctl -n $MINI01 rollback`; expect another reboot and the old version. Put a marker
   file on a user volume before and check it and the Vaultwarden data after both reboots.
   Record `UPGRADE-REHEARSAL: PASS`, or FAIL and STOP: that is the unknown from plan 15-04
   showing up in real life.
5. `bash talos/scripts/g2-check.sh`: every line PASS (BRUNO lines confirmed above;
   `G2-9`: the `COPY-256-DIR` directory is still on victus). Only then add `G2: PASS <date>`.

After G2: the 512 may be wiped or reused. Recommended: keep it in victus, unmounted, for two
weeks of normal use; then wipe it deliberately, make it victus's backup disk, move
`/srv/backup` onto it (`disk256-copy.sh copy` and `verify`, then repoint the standalone MinIO)
and only then delete `$COPY_DIR` on the 1 TB disk. Decided 2026-10-15 (the operator): the 512 is
the storage of the Talos worker VM mini03 that runs on victus (64 GiB OS, 128 GiB second copy of
the backups, 283 GiB torrent staging; revised 2026-10-19), provisioned by a host role that stays
off until this wipe (`docs/dr/mini03.md`). Plan 15-09
Task 5 retires the Ansible deploy path; plan 15-05 Task 4 brings in mini02.

## Drill record (verdicts only)

| Step | Result | Date | Note |
|---|---|---|---|
| Pre-flight | | | |
| Final backup verified | | | |
| Final copy of the 256 | | | |
| Swap and boot | | | |
| Install and bootstrap | | | |
| Restore (volumes) | | | |
| Restore (database) | | | |
| G2 aggregator | | | |
| Upgrade and rollback | | | |

G2: PASS 2026-11-06
