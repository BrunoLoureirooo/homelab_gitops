# Ansible: victus and mini04

Ansible manages the two machines that sit outside the Talos cluster:

| Host | What it is | Playbook |
|---|---|---|
| `victus` | the operator's Arch desktop. It keeps Tailscale permanently and can host the `mini03` Talos worker as a libvirt VM (`roles/victus_vm`, off by default). | `victus.yml` |
| `mini04` | a Debian 13 display host: `cage` plus a Chromium kiosk showing a Grafana dashboard (`roles/kiosk`). | `mini04.yml` |

The cluster nodes (`mini01`, `mini02`, `mini03`) run Talos and are configured from `talos/`
(see `talos/README.md` and `docs/rebuild-node.md`), not from here. The earlier k3s, Argo CD
bootstrap and service-layer playbooks were removed; nothing in this directory touches the
cluster.

Both hosts are in the `standalone` group of `inventory.yml` and are reached by their
MagicDNS short names over Tailscale.

## Layout

- `victus.yml` runs `host_config`, then `host_config_victus`, then `victus_vm` (only when
  `victus_vm_enabled: true`).
- `mini04.yml` runs `host_config`, then `kiosk`.
- `roles/host_config` is the universal layer for every host: the Tailscale package and service
  (plus the Debian apt repo), an opt-in tailnet join, the `Europe/Lisbon` timezone, sshd
  password-auth hardening (`sshd -t` validates before any reload) and authorizing the CI deploy
  key.
- `roles/host_config_victus` is specific to that laptop: the `headless-peripherals` script and
  its sudoers rule, and guards that keep the retired data-disk crypttab line and the retired
  `/srv/backup` bind mount absent. It never creates, formats or resizes a disk.
- `roles/kiosk` is documented in `roles/kiosk/README.md`.
- `roles/victus_vm` is described under "The mini03 worker VM" below.
- `group_vars/all/vault.yml` is an Ansible Vault file; `vault.yml.example` lists every
  variable it must hold (never commit an unencrypted copy).

Every task is idempotent, so a run against a live host reports `changed=0` when nothing
drifted, and `--check --diff` is a faithful preview.

## Day 0: before Ansible can touch anything

Ansible needs a working SSH pubkey login and a sudo-capable user, and it cannot bootstrap that
first step itself. On a raw install, do this once, by hand, per box:

1. **Create the user (with sudo) and get sshd running.**
   - *mini04 (Debian)*: see `roles/kiosk/README.md` "Day 0".
   - *victus (Arch)*: `archinstall`'s user step creates the account, adds it to `wheel`, and
     can install and enable `openssh`. Manually: `useradd -m -G wheel <user>`, set a password,
     uncomment `%wheel ALL=(ALL:ALL) ALL` via `visudo`, then
     `pacman -S openssh && systemctl enable --now sshd`.
   - The login name differs per host. Match whatever `inventory.yml` has for `ansible_user`.
2. **Copy your key over once**: `ssh-copy-id <user>@<host>`, then confirm
   `ssh <user>@<host> sudo -v` works.

### The chicken-and-egg: the inventory addresses hosts by MagicDNS name

3. **Join the tailnet first.** `inventory.yml` sets `ansible_host` to each host's MagicDNS
   short name (`victus`, `mini04`), so Ansible cannot reach a box that is not on the tailnet
   yet. Join the mesh at first boot over whatever network already works (LAN or console),
   before the config-management layer looks for the host on it. Pick one:
   - **By hand (simplest)**: `sudo tailscale up --authkey=tskey-... --hostname=<victus|mini04>`
     over the LAN or console SSH session from step 2. Use a reusable or ephemeral key from the
     Tailscale admin console and never commit it.
   - **Through Ansible**: point it at the box's current LAN address for this one run, with the
     key as an extra var:
     ```bash
     ansible-playbook mini04.yml -e ansible_host=<lan-ip> -e tailscale_authkey=tskey-...
     ```
     The join task in `host_config` fires because the node is not logged in yet. From the next
     run on, drop both overrides.
   - Omitting `tailscale_authkey` (the default) leaves tailnet login untouched, so the opt-in
     is never a behavior change for an already-joined host.
4. Once the host answers on its MagicDNS name, `ansible-playbook victus.yml` or `mini04.yml`
   does the rest (Tailscale repo and package, ssh hardening, the host-specific role).

## One-time setup

Install the collections declared in `requirements.yml`:

```bash
cd ansible
ansible-galaxy install -r requirements.yml
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
# fill in the real values, then:
ansible-vault encrypt group_vars/all/vault.yml
```

## Running it

```bash
cd ansible
ansible-playbook victus.yml --check --diff --ask-become-pass --ask-vault-pass   # preview
ansible-playbook victus.yml --ask-become-pass --ask-vault-pass                  # for real
ansible-playbook mini04.yml --check --diff --ask-become-pass --ask-vault-pass
ansible-playbook mini04.yml --ask-become-pass --ask-vault-pass
```

Each playbook touches only its own host, so they can be run on different days in any order.
Keep your current SSH session open through the first real run of the sshd hardening, just in
case.

## CI-driven runs (GitHub-hosted runners over Tailscale)

`.github/workflows/deploy.yml` runs the victus and mini04 playbooks
non-interactively on **GitHub-hosted runners** (`ubuntu-24.04`). Each job joins
the tailnet for its own length (`tailscale/github-action`, OAuth client, ephemeral
node tagged `tag:ci`), then SSHes to the host by its MagicDNS short name with a
dedicated deploy key. Nothing runs on your own machines.

**Triggers:** `push` to `main` (path-filtered to what `mini04.yml` reads)
auto-applies mini04 for real; the safety gate is the PR review. victus is
`workflow_dispatch` only (`target: victus`), as is a manual mini04 run. `mode:
check` is an `--check --diff` preview against live state, `mode: apply` the real
run. **Never `pull_request` or `pull_request_target`**: the jobs hold the vault
password and a key that reaches live hosts (`check-workflow-safety.sh` rule G).

### One-time setup

1. **Tailnet policy**: `tagOwners` for `tag:ci`, and a grant letting `tag:ci`
   reach only victus and mini04 on port 22 (see the PR that introduced this).
2. **OAuth client** (Tailscale admin, Settings, OAuth clients) with the
   `auth_keys` write scope and tag `tag:ci`.
3. **Repo secrets**: `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`, `CI_DEPLOY_SSH_KEY`
   (private half of the deploy key), `ANSIBLE_VAULT_PASSWORD`. **Repo variable**
   `MINI04_USER` (mini04's login).
4. **Environment `victus`** holding victus's `ANSIBLE_BECOME_PASSWORD`. mini04's
   sudo password comes from the vault.
5. **Authorize the deploy key once from your Mac**: its public half is
   `host_config_ci_runner_pubkey` in `inventory.yml`; run `victus.yml` and
   `mini04.yml` by hand so `host_config` puts it in `authorized_keys`. For
   mini04's first tailnet join also pass `-e tailscale_authkey=...`.
6. **Verify manually first**: Actions, "Deploy (GitHub-hosted + Tailscale)", Run
   workflow with `mode: check`, read the diff, then `mode: apply`.

Both `--vault-password-file` and `--become-password-file` point at tiny
committed scripts (`.github/scripts/ansible-vault-pass.sh` /
`ansible-become-pass.sh`) that just echo the corresponding secret; nothing
secret is written to disk, and GitHub masks the value in logs.

## The mini03 worker VM (off by default)

victus is the operator's desktop. It also hosts **mini03**, a Talos worker run by
libvirt/QEMU on this Arch host (design: `docs/dr/mini03.md`). The VM runs
the arr stack, qBittorrent with a VPN sidecar, and the second copy of the backups. The host's own
Tailscale stays up permanently: it is how the desktop reaches tailnet apps, and this role never
touches it. Ansible defines the VM and its disk layout; everything inside it (the Talos node
`mini03`) belongs to the Talos configs in `talos/`, applied by the Talos deploy workflow.

`roles/victus_vm` does nothing until `victus_vm_enabled: true` is set for victus in
`inventory.yml`, which stays false until the operator decides to build the VM. What it does when on:

- checks `/dev/kvm` and the network settings (the wired NIC exists and is not Wi-Fi);
- finds the 512 GB NVMe **by serial and model** (never by device name), refuses anything that
  does not match, is mounted, or is outside a sane size band, and checks (or, only with
  `victus_vm_disk_provision: true`, builds) one GPT partition, the volume group `victus512` and
  three logical volumes. It never touches the 1 TB system disk;
- installs libvirt, QEMU, OVMF and lvm2, enables `libvirtd`;
- sets a low CPU weight on `machine.slice` (default 25 against the session's 100) so games and
  the desktop win when the CPU is contended;
- defines the domain `mini03` from `templates/domain.xml.j2` (4 vCPU, 8 GiB, UEFI, Secure Boot
  off, **three raw virtio disks** that are the three volumes, a macvtap NIC, RNG, a guest-agent
  channel, boot order disk first then the ISO) and sets autostart;
- optionally holds a sleep and lid-switch inhibitor (`victus-vm-awake.service`);
- starts the VM only when `victus_vm_start: true`.

### The 512 GB disk layout

The disk is 476.9 GiB (512 GB decimal). One partition, one volume group, three volumes; the VM
sees them as `vda`, `vdb` and `vdc` (with serials `mini03-os`, `mini03-backups`,
`mini03-staging`):

| Volume | Size | Becomes in the VM |
|---|---|---|
| `mini03-os` | 64 GiB | Talos install disk: OS, containerd images, arr config (local-path) |
| `mini03-backups` | 128 GiB | Talos user volume `backups`, mounted at `/var/mnt/backups` (second backup copy) |
| `mini03-staging` | 283 GiB | Talos user volume `staging`, mounted at `/var/mnt/staging` (torrents) |

64 + 128 = 192 GiB; 476.9 - 192 = 284.9 GiB left; staging takes 283 GiB, so about 1.9 GiB of
the group stays unallocated (LVM metadata, alignment, room to grow a volume with `lvextend`).
Logical volumes are never resized or recreated by the role.

### Wipe the 512 GB disk (the operator, by hand, on purpose)

The disk holds an old Debian LVM (`vg0`). The role refuses a disk that is not blank, so nothing
is ever wiped automatically. After the interim second copy of the backups and the library has
been verified (see the design doc, phase P0), on victus, from a local or tailnet SSH session:

```
lsblk -o NAME,SERIAL,MODEL,SIZE,MOUNTPOINTS      # confirm the serial matches vault_victus_vm_disk_serial and nothing is mounted
sudo vgchange -an vg0                            # deactivate the old volume group
sudo vgremove vg0                                # (and `pvremove` the partition it lived on)
sudo wipefs --all /dev/nvme0n1                   # after checking nvme0n1 is the 512 GB disk
```

Check the device name against the serial every time; the 1 TB disk is the other NVMe.

### Before enabling it

A template for every local variable is `victus-vm.local.yml.example`; copy it to
`~/victus-vm.local.yml` and pass it with `-e @$HOME/victus-vm.local.yml`. The full rebuild order is
in `docs/dr/mini03-rebuild.md`.

1. Put the 512 GB disk's serial in the vault (`vault_victus_vm_disk_serial`; the inventory
   passes it to `victus_vm_disk_serial`, whose role default is empty and makes the role refuse
   to run). Put the VM's MAC in the vault (`vault_victus_vm_mac`, see `vault.yml.example`) and set
   `victus_vm_mac: "{{ vault_victus_vm_mac }}"` for victus; reserve an address for it in the
   router. MAC addresses are never committed.
2. **Networking needs no manual step.** The default `victus_vm_network_mode: direct` is macvtap on
   the wired NIC `eno1`: no bridge, no address moved, nothing that can cut off SSH or the tailnet
   to the host. The only trade-off is that the host itself cannot reach the VM over that NIC (the
   LAN and the tailnet can). `bridge` (an existing bridge, never created here) and `nat` remain
   as options; see the design doc for why `direct` is the default.
3. Download the Talos ISO (`talos/fetch-assets.sh mini03 iso`) and set `victus_vm_install_iso` to
   its path for the first boot; clear it after Talos is installed.
4. Run `ansible-playbook --check --diff victus.yml` first. For the one run that builds the layout
   set `victus_vm_disk_provision: true` (and set it back to false afterwards), then start the VM on
   purpose (`virsh -c qemu:///system start mini03`) and apply the Talos config.

The disk-state decision has an offline test:
`cd ansible && ansible-playbook -i localhost, -c local tests/victus_vm_disk_state.yml`.

**Desktop effects:** the VM needs the machine awake and on AC; a suspended machine drops the
worker from the cluster. Rebooting into another OS takes the node offline.

## SSH hardening (universal)

`host_config` deploys `/etc/ssh/sshd_config.d/50-harden.conf` to every managed host. It is the
one task that touches how you get into the machine, so it fails safe: `sshd -t` validates the
merged config before the reload handler may fire. If validation fails, Ansible stops the play
for that host, the bad drop-in stays on disk, and sshd keeps running under its last-known-good
config. Pubkey auth is never touched either way.
