# Rebuild mini03 from the repo

mini03 is a Talos worker VM on the victus desktop. This is the order of steps and the things that
went wrong the first time. Design and sizes: `docs/dr/mini03.md`, `ansible/README.md`.
Steps marked (victus) run on victus; the rest on the Mac that has the repo, `talosctl` and `sops`.

## What the repo does not hold

| Item | Where it lives | What to do |
|---|---|---|
| Control-plane LAN address | untracked `talos/local/cluster.local.env` | copy `talos/cluster.local.env.example` there and set `ENDPOINT_HOST` |
| VM variables (MAC, ISO path, switches) | untracked `~/victus-vm.local.yml` | copy `ansible/victus-vm.local.yml.example` |
| Tailscale auth key | `talos/secrets/tailscale-mini03.sops.yaml`, but the key inside is single-use and expires after a day | mint a new one (untagged, single-use, one day; `tag:talos` is a possible future improvement) and re-encrypt |
| age key | `~/.config/sops/age/keys.txt` | needed for every `sops` call (`SOPS_AGE_KEY_FILE`) |

## Steps

1. **Host and disk (victus).** The 512 GB NVMe must be blank. Run
   `ansible-playbook victus.yml -e @$HOME/victus-vm.local.yml --check --diff`, then once with
   `victus_vm_disk_provision: true`, then back to false. The role finds the disk by serial.
2. **Reinstall only: clear the old volumes.** If the logical volumes were used before, run
   `wipefs --all` and `blkdiscard` on all three (`mini03-os`, `mini03-backups`, `mini03-staging`)
   so the VM sees blank disks.
3. **ISO.** `talos/fetch-assets.sh mini03 iso` checks the pinned hash. Run it from `main`: a stale
   branch fails with "SCHEMATIC_MINI03_ID is not a pinned 64-hex id". Copy the ISO to victus and
   set `victus_vm_install_iso`.
4. **Tailscale key.** In the Tailscale admin console create a single-use, one-day key
   (untagged; `tag:talos` is a possible future improvement). From the `talos/` directory, with `SOPS_AGE_KEY_FILE` set, write the
   `ExtensionServiceConfig` (see `talos/secrets/README.md` section 3) to a temp file, `sops -e` it
   into a second temp file, then `mv` that over `secrets/tailscale-mini03.sops.yaml`. Running sops
   from another directory ignores `.sops.yaml` and leaves a 0-byte file. Never commit plaintext.
5. **Start the VM (victus).** Run the playbook with `victus_vm_start: true`. The VM boots the ISO
   into Talos maintenance mode.
6. **See the console.** The VNC display listens on victus's 127.0.0.1:5900 only:
   `ssh -L 5900:127.0.0.1:5900 victus`, then a VNC client on `localhost:5900`.
   `virsh -c qemu:///system screenshot mini03` also works. The serial console stays blank.
7. **Find its address.** The network is macvtap (`victus_vm_network_mode: direct`), so victus
   itself can never reach the VM. Read the address from the console or the router and test from
   the Mac or another machine.
8. **Render and apply.**
   - Put the control plane's LAN address in `talos/local/cluster.local.env`: the node cannot
     resolve the short name `mini01` from maintenance mode (it showed errors resolving `mini01`
     at 127.0.0.53).
   - `talos/render.sh mini03` (needs `SOPS_AGE_KEY_FILE`).
   - First apply, in maintenance mode only:
     `talosctl apply-config --insecure -n <ip> -f talos/out/mini03.yaml`.
   - Any later apply is authenticated and names the endpoint:
     `talosctl apply-config -n <ip> -e <ip> -f talos/out/mini03.yaml`. `--insecure` no longer
     works once the node is configured.
9. **Install disk.** `talos/nodes/mini03.env` selects the disk with `DISK_SIZE_EXPR='< 100GB'`
   and `DISK_SIZE_MIN_GB=50`. The floor is needed because the ISO's read-only loop devices are
   also under 100 GB and the installer otherwise targets `/dev/loop0`.
10. **Join.** The node installs, reboots and appears in `kubectl get nodes`. Check the labels
    `tier=mobile` and `pool=media-backup`, the `NoSchedule` taint and the `data`, `backups`,
    `staging` volumes. Then set `victus_vm_install_iso: ""` so it boots from its own disk.

## Sealing secrets

Seal against the live controller, never the repo copy: fetch its certificate with
`kubeseal --fetch-cert` and pass it with `kubeseal --cert`. The file
`argocd/sealed-secrets/pub-cert.pem` did not match the live controller when checked on
2026-11-05. `talos/dr/minio/replica-setup.sh` does this for the replica login.

## About `--check`

`ansible-playbook --check` on a host without the packages used to die at libvirtd and at the
sleep-inhibitor unit. The role now skips those steps when the package or unit would only be
created by the same run, so `--check` works from a bare host. Reporting `changed` there is
expected.
