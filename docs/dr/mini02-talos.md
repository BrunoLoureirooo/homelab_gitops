# mini02 on Talos: hardware steps (operator-run)

Plan 15-05 Task 4. STOP POINT: nothing here runs until the mini01 cutover (plan
15-07) has passed gate G2, because mini02 joins a working control plane. The
decision this implements is in `talos/STORAGE-DECISION.md`.

Placeholders in angle brackets are for you to fill in locally. Do not paste
serial numbers, MAC addresses or addresses into the repo or a pull request: reply
with pass or fail and driver names only.

## Before you start

- mini02 has its two 1 TB data drives and an SSD for the system, as planned. The two data drives are the burn-in drives: step 3 WIPES
  both. Confirm they hold nothing you need.
- The mini02 installer ISO comes from `bash talos/fetch-assets.sh mini02 iso`
  (pinned in `talos/versions.env`, checked against our own hash, exactly like the
  mini01 ISO in plan 15-07). Write it to a USB stick.
- G2 has passed and the mini01 control plane is `Ready`.

## 1. Read-only hardware facts (maintenance mode, nothing applied yet)

Boot mini02 from the USB stick, then from your Mac:

    talosctl -n <mini02> get disks --insecure
    talosctl -n <mini02> get links --insecure
    talosctl -n <mini02> dmesg --insecure | grep -i -E "r8169|r8125|firmware"

Expected: both 1 TB drives listed with their transport, the NIC driver named, and
no "firmware missing" line. Record the driver names (not serials, not MACs) in
`talos/FINDINGS.md`. If firmware is missing, add `siderolabs/realtek-firmware`
(or the one the dmesg names) to `talos/schematics/mini02.yaml` where the marker
comment `# firmware: decided in Task 4` is, rebuild the ISO, repeat.

## 2. Apply the worker config

Render and apply (the exact commands are in `talos/README.md` from plan 15-02):

    bash talos/render.sh mini02 --out talos/out
    talosctl apply-config --insecure -n <mini02> -f talos/out/mini02.yaml

Expected: `kubectl get nodes` shows mini02 `Ready` within a few minutes, role
worker, labelled and tainted as the Phase 6 design says.

## 3. Create the pool (option 1 only)

Make a local copy of `talos/storage/zfs-pool-job.yaml` with the two
`/dev/disk/by-id` names of the data drives in the ConfigMap (get them from step 1;
never commit them), then:

    kubectl apply -f <your local copy>

Expected: `kubectl -n kube-system logs job/zfs-pool-create` ends with a
`zpool status tank` showing `ONLINE` and both drives under `mirror-0`.
THIS WIPES BOTH DRIVES. If you chose option 2 in `STORAGE-DECISION.md`, skip this
step and use the UserVolume from the decision file instead.

## 4. Datasets and quotas

If the pool was created by step 3, datasets with quotas must be created. The repo
contains a Job for this:

Apply the Job (fill in the quota values before running):

    NAS_QUOTA=256G IMMICH_QUOTA=128G BACKUPS_QUOTA=128G \
      kubectl apply -f talos/storage/zfs-datasets-job.yaml

Expected: `kubectl -n kube-system logs job/zfs-datasets` ends with a list of
datasets and their quotas. The Job is idempotent; running it again changes nothing.

## 6. Samba

Seal the credential (you choose the value; it never goes in the repo):

    kubectl -n nas create secret generic samba-nas-credentials \
      --from-literal=credential=<your choice> --dry-run=client -o yaml | \
      kubeseal --format yaml > talos/sealed-secrets/samba-nas.sealedsecret.yaml

Commit that file (ciphertext only), sync the `talos-sealed-secrets` app, then
sync `samba-nas` by hand after `argocd app diff samba-nas`. From the Mac, mount a
share and copy a few files: `open smb://<mini02-short-name>/shared`.

## 7. Restore test, then (only if it passes) move the originals

Run the library restore test written in `talos/STORAGE-DECISION.md`
(`## Immich originals`): restore the library into a scratch namespace and compare
the file count and a sha256 sample with the live volume. Only if it matches, move
the Immich originals as that section says.

## Reply with

Pass or fail for steps 1 to 7, the NIC driver names, and any firmware lines. Not
the raw logs.
