# Plan: mini03, the Talos worker VM on victus

Audience: a local language model working for the operator. Follow it literally, one work package (WP) at a
time. Where it says STOP, stop and report to the operator; never decide for him. Written 2026-10-25.

Facts are marked `[verified <source>]` (a repo path or a URL read on the date above) or
`[UNVERIFIED]` with how to confirm them. Repo paths marked "(branch ...)" exist only on an open draft PR
until it merges (section 2, WP0).

## 0. Purpose, scope, non-goals, definition of done

**Purpose.** victus is the operator's desktop (Arch Linux, gaming, dev). The cluster side of victus is a Talos
WORKER named `mini03`, a libvirt/QEMU virtual machine on that Arch host. mini03 will run the arr stack,
the torrent client behind a VPN sidecar, and the second copy of the backups (a MinIO replica). This plan
takes the machine from today's state to a running, joined, labelled, tested node, and hands it over to
those services.

**In scope** (each is a work package in section 7):

1. Cleaning up the victus host (leftover standalone MinIO, a recovery folder, a nearly full root disk,
   leftover services).
2. Wiping the 512 GB NVMe (The operator types the destructive command himself).
3. Enabling the Ansible role `victus_vm`: LVM volume group with three volumes (64, 128, 283 GiB), the
   libvirt domain (network, MAC, autostart, CPU weight, no GPU), the keep-awake unit.
4. Booting Talos from the Image Factory ISO, applying the machine config, joining the cluster, labels and
   taint, `TALOS_NODES`, a smoke-test Pod, Velero node-agent coverage, flannel/MTU and time-sync checks.
5. Failure modes, rollback, and the hand-over interface for the services that run on mini03.

**Non-goals.** Deploying the arr stack, qBittorrent/gluetun or the backup replica (their own plans and
PRs; this plan only prepares and verifies the node for them). GPU passthrough. A local LLM on the VM
(shelved by the operator). Touching mini01 or mini02. Changing the host's Tailscale (it stays on the tailnet
permanently). Creating or reshaping a host bridge.

**Definition of done** (all must be true):

- [ ] WP1 audit report delivered; PRs #49, #52 and #71 are merged or the operator decided how to proceed.
- [ ] victus host cleanup done by the operator (WP2) and the report shows root disk below 70% used.
- [ ] The 512 GB NVMe is blank and the volume group `victus512` has the three volumes (WP3, WP4).
- [ ] `virsh -c qemu:///system dominfo mini03` shows `Autostart: enable`; the domain runs.
- [ ] `kubectl --context admin@<cluster> get node mini03` is `Ready`, with label
      `node-role.homeserver/tier=mobile`, label `node-role.homeserver/pool=media-backup` and taint
      `node-role.homeserver/tier=mobile:NoSchedule`.
- [ ] `talosctl get volumestatus` on mini03 shows `data`, `backups`, `staging` mounted (WP7).
- [ ] The smoke-test Pod ran on mini03, wrote to the `data` volume, and was removed (WP8).
- [ ] Velero `node-agent` runs on mini03 (WP9, merged PR + the operator's sync).
- [ ] Flannel pod-to-pod traffic works both ways across nodes and the MTU check passes (WP10).
- [ ] Time is in sync on mini03 (WP10).
- [ ] The host survives a reboot test: VM comes back by itself (WP11).
- [ ] Rollback steps written down and understood (section 7, WP12).

## 1. Rules for the executor

1. **PR-only for the repository, read-only for the cluster.** Allowed cluster commands: `get`,
   `describe`, `logs`, `top`, `exec ... -- <read-only command>`, always with `--context admin@<cluster>`.
   Forbidden for the executor: `apply`, `create`, `delete`, `patch`, `edit`, `scale`, `rollout`,
   `replace`, `label`, `annotate`, `drain`, `cordon`, `uncordon`, `taint`, `talosctl apply-config`,
   `upgrade`, `reset`, `bootstrap`, any `argocd app sync`, any `virsh` verb that changes state. Those
   steps are in boxes titled "BRUNO RUNS THIS"; the executor prints them for the operator and waits.
   the operator's standing rule (memory: no live changes) is that changes to the cluster go through PR plus
   Argo sync. The only exceptions in this plan are node-level actions that cannot be a PR (`talosctl`
   on a node that is not yet in the cluster, `virsh`, `ansible-playbook` on victus, the one-off
   smoke-test Pod in WP8). They are operator-run and each is called out.
2. **Everything destructive is operator-run.** `wipefs`, `vgremove`, `lvremove`, `rm -rf`, `pacman`, `virsh
   undefine` and the like are never run by the executor, even if the executor has an SSH session to
   victus. The executor writes the command, the operator reads it and types it.
3. **No secrets.** Never print, decode or paste a secret value. Never run `get secret -o yaml/json/jsonpath`.
   `describe secret` (key names only) is fine. If any command prints a secret, stop and tell the operator.
4. **No host details in the repo or in PR text.** Do not write IPv4 addresses or CIDRs (the pod and
   service ranges included), MAC addresses, disk serial numbers, `/dev/disk/by-id` names or full tailnet
   host names (`<name>.<tailnet>.ts.net`). Use `<node-ip>`, `<mini03-mac>`, `<disk-device>`,
   `<tailnet-name>`. The guard `.github/scripts/check-no-host-details.sh` rejects them.
5. **Draft PRs, one concern per PR.** Branch from current `origin/main`: `git fetch origin && git switch
   -c <branch> origin/main`. Never push to `main`, never force-push, never merge, never delete a branch.
   Commit message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; PR description
   ends with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
6. **Guards.** Before every commit run `bash .github/scripts/run-all-guards.sh`. Every line must start
   with `OK`. Never edit a guard to make it pass.
7. **Generated files.** After changing `talos/apps-src/*.yaml` run `talos/render-apps.sh --force` and commit
   `talos/apps/`. Every Application needs a line in `talos/test/empty-cluster-expectations.txt`.
8. **STOP conditions.** Stop and report (do not improvise) when: a command prints something different from
   the "expected" text and the plan does not say what to do; a device name or size does not match;
   any the operator decision in section 5 is unanswered and the WP depends on it; a guard fails; a command would
   change the live cluster; you are asked to type a disk-destroying command.
9. **Never decide a the operator decision** (section 5). Use the recommended default only to write a draft, and
   say so in the report.
10. **If the repo and this plan disagree, trust what you see**, write the difference in the report
    ("Differences from the plan") and ask the operator.

## 2. Prerequisites and dependencies

### 2.1 What must be ready first

| # | Dependency | Read-only proof | If not ready |
|---|---|---|---|
| P1 | Cluster healthy, two nodes Ready (mini02 `SchedulingDisabled` on purpose) | `kubectl --context admin@<cluster> get nodes` shows mini01 `Ready`, mini02 `Ready,SchedulingDisabled` | STOP, report |
| P2 | PR #49 (Ansible role `victus_vm`), PR #52 (Talos node files and `docs/dr/mini03.md`), PR #71 (backup replica manifests, not needed to build the node) | `gh pr view 49 --json state -q .state` (and 52, 71). On 2026-10-25 all three were `OPEN` drafts | Ask the operator to review and merge #49 and #52 (WP0). Do not build from a draft |
| P3 | Gate G2 of the cutover passed | `grep -n "G2" talos/CUTOVER.md | head` and the cluster has run for a while; the operator confirms. Cutover is done in reality (nodes Ready for 8 days) | Ask the operator; the design says "never during the cutover" |
| P4 | The interim second copy of the backups and Immich library on victus `/home` (design phase P0) is taken and verified, OR the operator decides to skip it knowing the 512 GB NVMe holds the old Debian install and the only copy outside mini02 | The operator states it (Decision D8) | STOP before WP3 (the wipe) |
| P5 | sops/age key and the secrets bundle usable by the operator | `ls talos/secrets` shows `secrets.sops.yaml`, `tailscale-mini01.sops.yaml`, `tailscale-mini02.sops.yaml`; the operator has the age private key on his Mac | STOP, the operator must restore the key (`talos/secrets/README.md`) |
| P6 | A Tailscale admin console where the operator can make a tagged auth key (untagged) | The operator's confirmation | STOP at WP6 |
| P7 | Router access for a DHCP reservation | The operator's confirmation | STOP at WP5 |
| P8 | Ansible control node (The operator's Mac) with `ansible-core`, `ansible-vault` and SSH to victus | `ansible --version` | The operator installs it (`ansible/README.md`) |

### 2.2 What depends on this node

| Dependent | What it needs from mini03 |
|---|---|
| `backup-replica` (PR #71, namespace `velero`) | node named `mini03`, volume `backups` at `/var/mnt/backups`, taint toleration [ASSUMED: the manifests use `nodeSelector: kubernetes.io/hostname: mini03` plus a toleration for `node-role.homeserver/tier=mobile`] |
| arr stack (namespace `arr`) | node `mini03`, `data` volume for local-path PVCs (class `topolvm-fast`), `staging` volume at `/var/mnt/staging` for downloads [ASSUMED] |
| qBittorrent + gluetun (namespace `arr` per the brief; the design doc proposes its own privileged namespace `torrent`) | `/dev/net/tun` on the node (checked in WP10), the taint toleration [ASSUMED] |
| Velero backups of mini03 volumes | node-agent DaemonSet pod on mini03 (WP9) |

Hand-over contract (stated in section 7 WP13): node name `mini03`; label
`node-role.homeserver/tier=mobile`; label `node-role.homeserver/pool=media-backup`; taint
`node-role.homeserver/tier=mobile:NoSchedule`; mounts `/var/mnt/data` (local-path), `/var/mnt/backups`,
`/var/mnt/staging`.

## 3. Facts about this service

### 3.1 Cluster facts read on 2026-10-25 (read-only)

- Nodes: mini01 (control plane, v1.36.4, Talos v1.14.2), mini02 (worker, cordoned). `kubectl top nodes`:
  mini01 846m CPU (21%), 5164Mi (46% of about 11 GiB); mini02 122m (3%), 1204Mi (16%).
- **Both nodes report their Tailscale address as `InternalIP`** (`kubectl get nodes -o wide`): the kubelet
  picks the tailnet address. Flannel runs the VXLAN backend (`Network` from the flannel ConfigMap, port
  4789, nftables on) over those addresses. [verified live, read-only]. The design document
  `docs/dr/mini03.md` (branch `talos/victus-vm`) says "check the InternalIP is its LAN address, not the
  Tailscale one". **This disagrees with the live cluster.** Treat "mini03's InternalIP equals what the other
  nodes do" as the test: see WP10 and Decision D9. [UNVERIFIED which is better; the operator decides]
- StorageClass `topolvm-fast` (provisioner `rancher.io/local-path`, WaitForFirstConsumer, reclaim Retain). The
  local-path provisioner stores under `/var/mnt/data/local-path` on every node that is not listed, so
  mini03 needs a Talos user volume named `data` [verified `talos/apps-src/local-path-provisioner.yaml`].
- DaemonSets in `kube-system` tolerate any taint: `kube-flannel`, `kube-proxy`, `pod-udp-snat`
  (`operator: Exists`) and `csi-smb-node` (`operator: Exists`) [verified live]. The Velero `node-agent`
  DaemonSet in namespace `velero` has NO tolerations, so on a tainted mini03 it would not run until a PR adds
  one [verified live: `kubectl -n velero get ds node-agent -o jsonpath='{.spec.template.spec.tolerations}'`
  prints nothing].
- Velero: image `velero/velero:v1.18.1`, uploader `kopia` [verified `argocd/values/velero.yaml`, live].
  Schedules `homeserver-nightly` (10:00 UTC daily) [verified `talos/values/velero.yaml`].
- Talos pins: `TALOS_VERSION=v1.14.2`, `K8S_VERSION=v1.36.4`, Image Factory `https://factory.talos.dev`
  [verified `talos/versions.env`]. mini03 schematic id and ISO hash are added by PR #52
  (`SCHEMATIC_MINI03_ID`, `ASSET_MINI03_ISO_SHA256`) [verified branch `talos/victus-vm`, `talos/versions.env`].
- Cluster endpoint: `ENDPOINT_HOST=mini01`, port 6443, in `talos/cluster.env`. A short name must resolve from
  the VM. Per the operator's notes the live endpoint was set to a LAN address in the untracked
  `talos/local/cluster.local.env` (not in the repo; the folder does not exist in a fresh checkout)
  [verified `talos/cluster.env` comment; local file UNVERIFIED]. The render uses that file if present.

### 3.2 The node files (branch `talos/victus-vm`, PR #52)

- `talos/nodes/mini03.env`: `HOSTNAME=mini03`, `ROLE=worker`, `SCHEMATIC=mini03`,
  `DISK_SIZE_EXPR='< 100GB'` (only the 64 GiB OS disk is under 100 GB).
- `talos/nodes/mini03.yaml`: `HostnameConfig` (hostname `mini03`, `auto: "off"`), `UnattendedInstallConfig`
  (wipe true, disk selector from the env), `KubeNodeConfig` with labels `node-role.homeserver/tier: mobile`
  and `node-role.homeserver/pool: media-backup` and taint `node-role.homeserver/tier: mobile:NoSchedule`.
- `talos/patches/volumes-mini03.yaml`: `VolumeConfig EPHEMERAL` on the system disk capped at 24GiB;
  `UserVolumeConfig data` on the system disk (min 8GiB, grow); `UserVolumeConfig backups` selecting
  `!system_disk && disk.size > 130u * GB && disk.size < 145u * GB`, xfs, min 100GiB; `UserVolumeConfig staging`
  selecting `!system_disk && disk.size > 290u * GB && disk.size < 320u * GB`, xfs, min 200GiB.
- `talos/schematics/mini03.yaml`: extensions `siderolabs/qemu-guest-agent` and `siderolabs/tailscale`.
- `talos/versions.env` additions: `SCHEMATIC_MINI03_ID`, `ASSET_MINI03_ISO_SHA256`.
- Size arithmetic (exact): the disk is about 476.9 GiB. 64 + 128 + 283 = 475 GiB of volumes; about 1.9 GiB stays
  free in the volume group. 64 GiB = about 68.7 GB (below the 100 GB ceiling); 128 GiB = about 137.4 GB
  (inside 130 to 145 GB); 283 GiB = about 303.9 GB (inside 290 to 320 GB). The bands do not overlap.
- Not verified anywhere: that the selectors match the real virtio disks [UNVERIFIED: confirm in WP7 step 3
  with `talosctl get disks --insecure` before applying].

### 3.3 The host role (branch `victus-vm-libvirt`, PR #49)

Files: `ansible/roles/victus_vm/{defaults,tasks,handlers,templates}`, `ansible/victus.yml`,
`ansible/inventory.yml`, `ansible/group_vars/all/vault.yml.example`, `ansible/README.md`. Variables
(`defaults/main.yml`) that matter:

| Variable | Default | Meaning |
|---|---|---|
| `victus_vm_enabled` | `false` | master switch; the role is skipped when false |
| `victus_vm_start` | `false` | whether the play may start the domain |
| `victus_vm_name` | `mini03` | libvirt domain name |
| `victus_vm_vcpus`, `victus_vm_memory_mib` | `4`, `8192` | VM size (Decision D3) |
| `victus_vm_disk_provision` | `false` | DESTRUCTIVE switch; builds GPT, PV, VG and LVs only on a provably blank disk |
| `victus_vm_disk_serial`, `victus_vm_disk_model_regex` | a pinned serial, `(?i)samsung` | how the role finds the 512 GB disk |
| `victus_vm_disk_min_size_gib`, `..._max_size_gib` | `400`, `600` | sanity band |
| `victus_vm_vg` | `victus512` | volume group name |
| `victus_vm_lv_os_gib`, `_backups_gib`, `_staging_gib` | `64`, `128`, `283` | logical volume sizes |
| `victus_vm_network_mode` | `direct` | `direct` (macvtap), `bridge` (existing bridge only) or `nat` |
| `victus_vm_nic` | `eno1` | the wired NIC for macvtap |
| `victus_vm_mac` | empty | must be a MAC address in direct and bridge mode; never committed |
| `victus_vm_install_iso` | empty | ISO path for the first boot |
| `victus_vm_slice_cpu_weight` | `25` | `CPUWeight` of `machine.slice` against 100 for the user session |
| `victus_vm_inhibit_sleep` | `true` | installs `victus-vm-awake.service` (sleep and lid-switch inhibitor) |
| `victus_vm_autostart` | `true` | `virsh autostart` |
| `victus_vm_packages` | `libvirt qemu-base edk2-ovmf dnsmasq lvm2` | Arch packages |

What the domain template renders (`templates/domain.xml.j2`): UEFI firmware (`firmware='efi'`, secure boot
and enrolled keys OFF), q35, `host-passthrough` CPU, three raw virtio block disks on
`/dev/victus512/mini03-os`, `mini03-backups`, `mini03-staging` (targets `vda`, `vdb`, `vdc`, serials equal to
the LV names, `cache=none`, `io=native`, `discard=unmap`), the ISO as a SATA CD-ROM after the disk in boot
order, a virtio NIC (`type=direct` macvtap in bridge mode for `direct`), a pty serial console, a guest-agent
channel, virtio RNG and balloon. No GPU device is defined.
[verified branch `victus-vm-libvirt`]

**Discrepancies found in the branch (report them, do not fix them in this PR):**

- Decision D10 is done: `defaults/main.yml` leaves the 512 GB disk's serial empty and `ansible/inventory.yml`
  reads it from the vault (`vault_victus_vm_disk_serial`).
- `ansible/inventory.yml` sets `ansible_become_password: "{{ vault_become_password_victus }}"` for victus, but
  `vault.yml.example` has no `vault_become_password_victus` entry, and the inventory does NOT set
  `victus_vm_mac` from `vault_victus_vm_mac` even though the README says to. This plan avoids the problem
  with a local variables file (WP4).
- `ansible_host` for victus in the inventory is its old tailnet address; the operator's `ssh victus` entry
  uses the LAN address because the host is reached that way [verified memory note 2026-10-17; UNVERIFIED
  now]. WP4 step 1 tests which address works.
- `.github/workflows/deploy.yml` auto-applies on every push to `main` that touches `ansible/**` (not `.md`,
  not `*.example`), on the self-hosted runners including victus [verified file]. Merging PR #49 therefore runs
  `victus.yml` for real on victus once, with `victus_vm_enabled: false` (so the new role is skipped, but
  `host_config` and `host_config_victus` run). Tell the operator before merge. Whether the victus runner is still
  registered: `gh api repos/BrunoLoureirooo/homelab_gitops/actions/runners` (The operator runs it) [UNVERIFIED].

### 3.4 External facts

- Talos has no dedicated KVM install guide; Sidero says Talos is known to work on KVM, points to the
  Vagrant+libvirt guide, and says virtio and e1000 are the supported NIC models
  [verified https://docs.siderolabs.com/talos/v1.9/platform-specific-installations/virtualized-platforms/kvm].
  The newer docs site was moved (old talos.dev pages redirect to https://docs.siderolabs.com/talos).
- Talos configuration documents used here (`HostnameConfig`, `UnattendedInstallConfig`, `KubeNodeConfig`,
  `VolumeConfig`, `UserVolumeConfig`) are the ones already rendered for mini01 and mini02 in this repo
  and checked by `talosctl validate --mode metal` in CI [verified repo]; whether every field behaves the
  same in a VM on Talos v1.14.2 is [UNVERIFIED], confirmed in WP7.
- User volumes mount under `/var/mnt/<name>` and the kubelet can see mounts only below `/var/mnt`
  [verified repo notes: `docs/dr/mini03.md` branch; mini02 notes in `talos/STORAGE-DECISION.md`].
- macvtap: the host cannot talk to a macvtap guest over the same NIC [standard Linux macvlan behaviour;
  stated in `docs/dr/mini03.md`; UNVERIFIED by an upstream URL here]. Confirm in WP10 step 6.
- Arch libvirt package set (`libvirt`, `qemu-base`, `edk2-ovmf`, `dnsmasq`, `lvm2`) is what the role installs;
  [UNVERIFIED] that these package names are still current on Arch on the day of the run. The `--check`
  run in WP4 step 3 would fail on a missing package; STOP and report.

## 4. Architecture and placement

```
                        the operator's Mac (talosctl, kubectl, ansible, sops+age)
                               |  tailnet / LAN
  router (DHCP reservation for mini03's MAC) ----------------------------+
                               |                                         |
 +-------------- victus (Arch, desktop; host Tailscale stays) -----+     |
 | eno1 (wired) ---- macvtap ---------------------------------+   |     |
 |                                                             |   |     |
 | NVMe 1 TB: Arch (never touched)                             |   |     |
 | NVMe 512 GB: LVM  victus512                                 |   |     |
 |   mini03-os (64G) ---- vda --+                              |   |     |
 |   mini03-backups (128G) vdb -+-- libvirt domain "mini03" ---+---+-----+--> mini01 :6443 (control plane)
 |   mini03-staging (283G) vdc -+   4 vCPU / 8 GiB, UEFI       |   |        mini02 (worker, MinIO, NAS)
 | machine.slice CPUWeight=25 (game wins)                      |   |
 | victus-vm-awake.service (no sleep)                          |   |
 +-------------------------------------------------------------+   |
   inside the VM: Talos worker "mini03"                            |
     vda: STATE/EPHEMERAL(24G cap)/data -> /var/mnt/data (local-path PVCs)
     vdb: backups -> /var/mnt/backups   vdc: staging -> /var/mnt/staging
     taint tier=mobile:NoSchedule; Tailscale extension; qemu-guest-agent
```

- **Node:** `mini03`. **Namespaces:** none created by this plan. **Storage:** raw LVM volumes passed as
  virtio disks (no filesystem on the host between guest and disk), xfs user volumes in the guest.
- **Capacity.** victus: 8 cores / 16 threads, about 30 GiB RAM, 2.7 GB used idle on 2026-10-15
  [verified `docs/dr/mini03.md` branch; re-measure in WP1]. The VM takes at most 4 threads and 8 GiB. Talos
  worker idle about 1 GB; the planned load (arr 3 x 300 MB, qBittorrent + gluetun about 1 GB, MinIO about
  300 MB plus page cache) is 3 to 4 GB, so 8 GiB leaves room for page cache. Cluster nodes today: mini01 46% of
  RAM in use, mini02 16%; mini03 adds the headroom. Estimates are marked as such; re-measure after one
  week with `kubectl top nodes`.
- **Resource isolation.** `machine.slice` CPU weight 25 vs 100; libvirt's own `<cputune>` is not used because
  it only weights VMs against each other.
- **Network.** macvtap on the wired port (recommended, Decision D1): the host's network is not changed, so a
  mistake cannot cut off SSH or the tailnet. Cost: the host cannot reach the VM over `eno1`; use the tailnet
  or the cluster for that.

## 5. Decisions for the operator

The executor must STOP at any package that depends on an unanswered decision.

| Id | Question | Options and trade-offs | Recommended default | If decided otherwise |
|---|---|---|---|---|
| D1 | macvtap or bridge for the VM NIC? | **macvtap** (`direct`): no host network change, safe over SSH; host cannot reach the VM over that NIC, host Tailscale reaches the VM's Tailscale by relay. **bridge** `br0`: host and VM talk directly, but moving `eno1` into a bridge remotely can drop the host off the LAN and tailnet; needs a keyboard. **nat**: libvirt default NAT; the control plane cannot connect inbound; not recommended | macvtap | bridge: The operator creates `br0` himself first; set `victus_vm_network_mode: bridge`, `victus_vm_bridge: br0` in the local vars file; WP4 unchanged otherwise. nat: do not use |
| D2 | MAC address of the VM and router reservation | The operator generates a locally administered MAC (`52:54:00:` prefix plus three random bytes), keeps it only in his password manager or the vault, and reserves an address in the router. Without a reservation the node address changes and the Talos endpoint breaks | generate with the command in WP5 | If no reservation is possible: use a static address in the Talos config (a new PR, not in this plan) |
| D3 | VM size | 4 vCPU / 8 GiB (current, local-LLM idea shelved). 4 vCPU / 6 GiB (design says enough if memory stays free after a week). More vCPU adds contention with games | 4 / 8 GiB | Change `victus_vm_memory_mib`/`victus_vm_vcpus` in the local vars file; re-run WP4 step 5; the domain must be stopped and started to apply |
| D4 | Mirror delete policy for the backup replica (affects the 128 GiB volume only) | `--remove` (replica equals primary; mistaken deletion on the primary is mirrored within a day) vs keep everything (survives mistakes, grows without bound; 128 GiB is about 44% used today by about 60 GB) | `--remove` as drafted in PR #71 | Owned by the `backup-replica` plan; not changed here |
| D5 | Does mini03 need a taint? | **Taint** (`tier=mobile:NoSchedule`, as in PR #52): only pods that tolerate it land on a machine that is also a desktop and may be offline. **No taint**: any pod could land there and vanish when the desktop reboots or games. DaemonSets must tolerate the taint (Velero PR in WP9) | taint | Without taint: remove `taints:` from `talos/nodes/mini03.yaml` in a PR; WP9 is unnecessary |
| D6 | Autostart on host boot | **on**: the VM returns after a reboot (the guest agent shuts it down cleanly). **off**: The operator starts it by hand after boot | on (`victus_vm_autostart: true`) | off: set false; the node stays down after each reboot |
| D7 | Keep victus awake | The role installs a sleep/lid inhibitor (`victus_vm_inhibit_sleep: true`) | on | off: the node drops whenever the desktop suspends |
| D8 | Safety copy before the wipe | The 512 GB NVMe holds an old Debian install that is the only copy of some data outside mini02. Take the interim copy (design phase P0) first, or accept the loss knowingly | take the copy | If skipped, the operator writes "skip, I accept" in the PR; WP3 step 1 changes accordingly |
| D9 | Node address for kubelet and flannel: Tailscale or LAN | Live nodes use Tailscale addresses as `InternalIP`. Tailscale: consistent with mini01/mini02, works through any network, but VXLAN over the tailnet interface has a small MTU. LAN: faster, needs the reservation and the VM reachable by mini01 on the LAN | same as the other nodes (Tailscale), because that is what is proven | LAN: needs a kubelet `nodeIP` valid-subnets patch (new PR; not in this plan) |
| D10 | Remove the committed disk serial from `ansible/roles/victus_vm/defaults/main.yml` | Keep (a serial is not a secret; role finds the disk by it) or move to the local vars file / vault and set the default to empty | move out | Done: the default is empty and the inventory reads the vault |
| D11 | When to enable the role: before or after the two-week hold of the cutover | Design says only after the hold and after the operator wipes the disk | after | If earlier, the old rollback disk is destroyed |

## 6. Credentials and secret handling

mini03 has no application admin login. Its credentials are infrastructure credentials. None is stored in
this repository in clear text; none is created by the executor.

| # | Credential | Who creates it and how | Where it lives / key | How it is received | First-login / discovery | How the operator retrieves it later | If lost | Rotation |
|---|---|---|---|---|---|---|---|---|
| C1 | Talos secrets bundle (cluster CA, tokens) | Already exists (`talosctl gen secrets`, encrypted with sops+age) | `talos/secrets/secrets.sops.yaml` (encrypted, committed) | `render.sh` decrypts for one render and deletes the plaintext | None; it is the cluster identity | Needs the age private key on the operator's Mac (offline copy; see `talos/secrets/README.md`) | Cannot render mini03 or any node; a lost key and bundle means a new cluster identity | `talos/secrets/README.md` section 4 |
| C2 | age private key | Already exists (`age-keygen`) | The operator's offline media and Mac; never in the repo or cluster. Note: per the operator's notes the copy on the Ventoy stick is plaintext (cleanup item) | `SOPS_AGE_KEY_FILE=<keyfile>` in his terminal, or the key in `$SOPS_AGE_KEY_FILE`'s default location | n/a | His storage | Cannot decrypt secrets | New key pair, `sops updatekeys` |
| C3 | `talosconfig` (client certificate for `talosctl`) | Produced with the bundle (`talosctl gen config`) or exported by the existing workflow | The operator's Mac, e.g. `~/.talos/config`; the deploy workflow gets it from the `SOPS_AGE_KEY`-protected bundle. Never committed. [UNVERIFIED which path the operator uses; `TALOSCONFIG` env var overrides] | `talosctl --talosconfig <path>` or `TALOSCONFIG=<path>` | n/a | his Mac | Re-derive from the bundle (`talosctl gen config` with the same secrets, `render.sh` flow) | with the bundle |
| C4 | Tailscale auth key for mini03 | The operator creates in the Tailscale admin console: single-use, pre-approved, untagged, one-day expiry | encrypted file `talos/secrets/tailscale-mini03.sops.yaml` (a full `ExtensionServiceConfig` named `tailscale`, per `talos/secrets/README.md` section 3) | `render.sh` includes it in the rendered config | the key is shown once in the console; copy straight into the temp file | not retrievable; expired keys are replaced | Make a new key and re-encrypt; the node re-registers when its config is re-applied | one-day expiry by design |
| C5 | Ansible vault password | The operator chose it | **Not stored anywhere on disk** (README: "the vault password isn't stored anywhere"); locally the operator types it at the `--ask-vault-pass` prompt; for CI it is the GitHub repo secret `ANSIBLE_VAULT_PASSWORD`, served by `.github/scripts/ansible-vault-pass.sh` which only echoes the environment variable | `--ask-vault-pass` | n/a | his password manager | `group_vars/all/vault.yml` cannot be decrypted: rebuild the file | `ansible-vault rekey` |
| C6 | sudo (become) password on victus | The operator's account password on victus | Kept by the operator; in the inventory `ansible_become_password` reads the vault variable `vault_become_password_victus` (inside the encrypted `group_vars/all/vault.yml`); CI uses the GitHub Environment `victus` secret `ANSIBLE_BECOME_PASSWORD` via `.github/scripts/ansible-become-pass.sh` | either from the vault (then only `--ask-vault-pass` is needed) or typed at `--ask-become-pass` | n/a | his password manager | reset the account password on the host | change the account password and update the vault/Environment secret |
| C7 | MAC address of the VM | The operator generates (WP5 step 1) | the vault key `vault_victus_vm_mac` or a local variables file outside the repository | Ansible variable `victus_vm_mac` | n/a | the same file | regenerate and change the router reservation | n/a |
| C8 | Backup replica / MinIO credentials | Not created here | Owned by the `backup-replica` plan (four sealed secrets, `talos/manifests/backup-replica/README.md`) | n/a | n/a | n/a | n/a | n/a |
| C9 | VPN provider credentials | Not created here | Owned by the torrent plan (`gluetun-vpn`) | n/a | n/a | n/a | n/a | n/a |

**Where the operator looks to supply them (without anyone reading a value):**

- vault password: his password manager; typed at the prompt;
- sudo password for victus: either inside the vault (check by key presence only:
  `ansible-vault view group_vars/all/vault.yml | grep -c '^vault_become_password_victus:'` prints `1` or `0`,
  never the value; the operator runs this himself), or typed with `--ask-become-pass`;
- age key: his offline media; the file path goes in `SOPS_AGE_KEY_FILE`.

**Lost "admin" access recovery for this node.**

- Lost `talosctl` access to mini03 only (client cert fine, node odd): `talosctl -n mini03 health`; if
  unreachable, use the libvirt console (`virsh -c qemu:///system console mini03`) to see the Talos dashboard.
- Lost talosconfig: regenerate from the secrets bundle (C1) with the same procedure used for mini01
  (`talos/CUTOVER.md`), then `talosctl config merge`.
- Lost sudo password on victus: reset on the machine with a local recovery boot; that is outside this repo.
- Lost age key and bundle: the node can still run, but cannot be rebuilt or reconfigured; the cluster identity
  is lost (see `talos/secrets/README.md` section 4). Treat as an incident.

## 7. Work packages

Order: WP0, WP1 (audits and PRs), WP2 (host cleanup), WP3 (wipe), WP4 (host role), WP5 (MAC, reservation,
ISO), WP6 (Talos config PR items and the Tailscale key), WP7 (boot and apply), WP8 (labels, smoke test),
WP9 (Velero PR), WP10 (network and time checks), WP11 (host reboot test), WP12 (rollback), WP13 (hand-over).

### WP0. Merge state (The operator decides; executor reads)

**Goal.** Know whether PRs #49, #52 and #71 are merged. **Branch.** none. **Preconditions.** none.

1. Run `gh pr view 49 --json state,isDraft,mergedAt,title`; same for 52 and 71. WHY: the plan reads files that
   exist only on those branches.
2. If merged: from now on read the files on `main` (`git fetch origin`, then `git switch -c docs/plan-mini03-vm
   origin/main` already includes them). If still OPEN: read them with `git show origin/<branch>:<path>`
   after `git fetch origin victus-vm-libvirt talos/victus-vm talos/mini03-backup-replica`.
3. Report the states and these facts: the merge of #49 triggers a real Ansible apply on victus (section 3.3);
   merging #52 triggers the Talos deploy workflow (`talos-deploy.yaml` runs on `talos/nodes`, `talos/patches`,
   `talos/schematics`, `talos/versions.env`) which waits at the `talos-apply` environment for the operator's approval:
   he must NOT approve an apply while mini03 does not exist in `TALOS_NODES` (it is not listed yet, so nothing
   would be applied to it).

**STOP point.** WP2 onwards need #49 and #52 merged (The operator's decision).
**Report** per section 11.

### WP1. Read-only audit

**Goal.** A written snapshot of the cluster and the repo before any change. **Branch.** none (no commit).

1. Cluster state (all read-only):
   ```
   kubectl --context admin@<cluster> get nodes -o wide
   kubectl --context admin@<cluster> top nodes
   kubectl --context admin@<cluster> get sc
   kubectl --context admin@<cluster> -n kube-system get ds
   kubectl --context admin@<cluster> -n velero get ds
   kubectl --context admin@<cluster> -n velero get ds node-agent -o jsonpath='{.spec.template.spec.tolerations}'
   ```
   Expected: two nodes, no `mini03`; `topolvm-fast` only; node-agent with 2 desired pods and empty tolerations.
2. Repo files exist (after #49/#52 merge, on main; else `git show`): `talos/nodes/mini03.env`,
   `talos/nodes/mini03.yaml`, `talos/patches/volumes-mini03.yaml`, `talos/schematics/mini03.yaml`,
   `ansible/roles/victus_vm/tasks/main.yml`, `docs/dr/mini03.md`. Check the pins:
   `grep -n MINI03 talos/versions.env` prints both `SCHEMATIC_MINI03_ID` and `ASSET_MINI03_ISO_SHA256`.
3. Check there is no pending-pin marker: `ls talos/PINS-PENDING` must say "No such file".
4. Check whether `talos/secrets/tailscale-mini03.sops.yaml` exists: `ls talos/secrets`. Expected: absent (WP6).
5. Check `TALOS_NODES`: the executor cannot read repository variables; ask the operator to run
   `gh variable list` and paste the NAMES and whether `mini03` appears in `TALOS_NODES` (values contain
   short names only, which are allowed, but ask the operator to confirm before pasting).
6. Ask the operator for these host facts (his terminal on victus, outputs without serials/addresses pasted back;
   only yes/no or sizes): `df -h /`, `free -h`, `uname -r`, `lscpu | grep -E 'Model name|Virtualization'`
   (expects `AMD-V`), `ls -l /dev/kvm`, `systemctl is-active libvirtd`.
7. Report all findings. No PR.

**Verification.** Report complete. **Rollback.** n/a. **STOP point.** After the report.

### WP2. victus host cleanup (BRUNO RUNS ALL OF THIS WITH sudo)

**Goal.** Remove the stopgaps from the 2026-10-17 install, lock down recovery data, free the 85%-full root
disk. **Preconditions.** the operator confirms (a) the new backup target on mini02 has run several daily cycles
(first nightly 2026-10-18; check `kubectl --context admin@<cluster> -n velero get backups` shows recent
`Completed`), (b) the apps work, (c) the interim copy of D8 does not live in `/srv/backup` (it lives under
`/home`). **List first, never guess; delete only what the listing shows.**

All steps run on victus as the operator. The executor prints the commands; it never runs them.

```
# 1. LIST: what is there. Nothing is changed by these.
sudo ls -la /srv/backup /srv/backup/recovery
sudo du -sh /srv/backup /srv/backup/* 2>/dev/null
ls -l /etc/minio-standalone.env /etc/systemd/system/minio-standalone.service 2>&1
systemctl list-units --all --no-pager | grep -i -E 'minio|qbittorrent|caddy|plex|k3s'
systemctl list-unit-files --no-pager | grep -i -E 'minio|qbittorrent|caddy|plex|k3s'
podman ps -a 2>&1 | head
findmnt | grep -E '/srv|/mnt'
```
Expected: `/srv/backup` holds the MinIO data (a `.minio.sys` folder and bucket folders such as
`velero-backups`, `litestream`, `immich-pg`) and `recovery`; `/etc/minio-standalone.env` exists (mode 0600);
the unit `minio-standalone.service` exists but is not enabled. `findmnt` may show the `/srv/backup` bind
mount and old mounts under `/mnt/old512` (the old 512 GB disk mounted read-only for recovery; see step 6).
Anything else: STOP, paste the listing (names only) to the chat, ask.

```
# 2. Stop the standalone MinIO and confirm nothing writes to /srv/backup
sudo systemctl stop minio-standalone 2>&1; systemctl is-active minio-standalone
sudo systemctl disable minio-standalone 2>&1
sudo podman ps -a | grep -i minio
```
Expected: `inactive`; no running MinIO container. (If the service shows `active`, stop and ask why.)

```
# 3. Lock down the recovery folder (it holds recovered application data, root-owned)
sudo chown -R root:root /srv/backup/recovery
sudo chmod -R go-rwx /srv/backup/recovery
sudo ls -ld /srv/backup/recovery
```
Expected: `drwx------ ... root root`. Keep the folder until the operator has confirmed the apps for a while; deleting it
is a later, separate decision (it is the last recovery copy of the post-2026-10-15 data).

```
# 4. Remove the old MinIO data and its env file (ONLY after step 1 listing was read and after the operator confirms:
#    mini02 holds the live Velero target, and WP-P0 interim copy exists if D8 says so)
sudo rm -i /etc/minio-standalone.env
sudo rm -i /etc/systemd/system/minio-standalone.service
sudo systemctl daemon-reload
# data: remove only the MinIO data folders shown in step 1, one by one, not the recovery folder:
sudo rm -rI /srv/backup/<folder-from-the-listing>
```
Expected: each `rm` asks first. Do NOT run `rm -rf /srv/backup`. If the folder is a bind mount, do not unmount
or remove the mount point itself in this step; `host_config_victus` manages it (WP4 note).

```
# 5. Free the root disk
df -h /
sudo pacman -Scc          # answer y to both questions: clears package cache
sudo journalctl --vacuum-size=200M
sudo journalctl --disk-usage
df -h /
```
Expected: usage drops; target below 70%. If still above 80%, run `sudo du -xh / --max-depth=2 2>/dev/null | sort -h | tail -20`
and ask; do not delete unknown folders.

```
# 6. The old 512 GB mounts (only if findmnt showed them, and only after the operator decided the data is safe)
findmnt | grep old512
# Later, in WP3 step 2, not now.
```

```
# 7. Leftover services and containers
systemctl --failed --no-pager
systemctl list-unit-files --no-pager | grep -i -E 'qbittorrent|caddy|plex|minio'
sudo podman ps -a; sudo docker ps -a 2>&1 | head
tailscale status | head -3
```
Expected: no `qbittorrent`, `caddy`, `plex` or `minio` unit enabled or running; no containers. The host's
Tailscale must be `Running` and stays on (do NOT run `tailscale down`). If something shows, list it, ask
The operator; remove with `sudo systemctl disable --now <unit>` and `sudo pacman -Rns <package>` only for the exact
names he approves.

**Verification.** `df -h /` below 70%; `systemctl is-enabled minio-standalone` says "not-found" or "disabled";
`sudo ls -ld /srv/backup/recovery` is `drwx------ root root`; `tailscale status` works.
**Rollback.** Deleted data is not recoverable from the host; the mini02 backup target and the optional interim
copy are the recovery. That is why step 4 needs the operator's confirmation.
**PR.** None (host-only). **The operator afterwards:** update memory note "temporary cleanup" items 1, 4 and 13.
The operator also removes the matching leftover sealed secrets if any remain (`cloud-credentials-victus`, `mc-old`,
`mc-new` were already deleted on 2026-10-19 [verified memory]).
**STOP point.** Report the before/after of `df -h /`.

### WP3. Wipe the 512 GB NVMe (BRUNO TYPES THE COMMAND; THE EXECUTOR NEVER RUNS IT)

**Goal.** A completely blank disk, which is the only state in which the Ansible role will build on it.
**Preconditions.** D8 answered; the interim copy verified (or skipped by the operator in writing); WP2 done; the 1 TB
disk holds Arch and is never touched. **This plan contains no serial number on purpose.**

The operator runs, on victus (local session or tailnet SSH):

```
# 1. IDENTIFY. Compare the SIZE, MODEL and SERIAL columns with the label on the physical drive / your notes.
lsblk -o NAME,SIZE,MODEL,SERIAL,MOUNTPOINTS
```
Expected: two NVMe disks. The 1 TB one has partitions mounted at `/`, `/boot` (or `/efi`) and `/home`. The
512 GB one shows about `476.9G`, model "Samsung ...", and usually partitions that belong to the old Debian
install (an LVM volume group `vg0`, some of which may be mounted under `/mnt/old512`). Write down its
device name; below it is called `<disk-device>`, e.g. the `nvme?n?` shown in the NAME column.

```
# 2. CONFIRM NOTHING IS IN USE
findmnt | grep <disk-device>              # must print nothing
grep <disk-device> /etc/fstab             # must print nothing
grep -i -E 'old512|vg0' /etc/fstab /etc/crypttab    # must print nothing
sudo pvs; sudo vgs; sudo lvs              # note vg0 and which disk its PV is on
```
If `findmnt` shows mounts of the disk (for example `/mnt/old512/*`), unmount them: `sudo umount /mnt/old512/<each>`
then `sudo vgchange -an vg0`. If anything of the 1 TB disk shows up in `pvs`, STOP: you picked the wrong disk.
If the disk is in `fstab`, remove that line by hand first (backup the file) and run `sudo systemctl daemon-reload`.

```
# 3. DOUBLE-CHECK the device is the right one, three independent ways:
lsblk -b -d -o NAME,SIZE <disk-device>       # SIZE should be about 512110190592 bytes
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS /dev/<disk-device>    # no mountpoint on it or its children
findmnt -n -o SOURCE /                        # the root filesystem's device must NOT be on <disk-device>
```
All three must agree: size about 512 GB (476.9 GiB), no mounts, root not on it. Compare the model/serial from
step 1 against the physical label once more. If you are not sure, STOP.

```
# 4. WIPE (type it yourself; replace <disk-device> after the final check). This destroys the old Debian install.
sudo vgchange -an vg0           # deactivate the old volume group
sudo vgremove vg0               # answer y; removes the volume group and its LVs
sudo pvremove /dev/<disk-device>p<N>    # the partition shown by 'pvs' that held vg0, if any
sudo wipefs --all /dev/<disk-device>
```
Optional, slower, only if the operator wants secure erase: `sudo blkdiscard /dev/<disk-device>` (NVMe discard; it
erases all data on the disk).

```
# 5. VERIFY BLANK
sudo wipefs /dev/<disk-device>          # prints nothing
lsblk -o NAME,SIZE,FSTYPE /dev/<disk-device>    # one line, no partitions
sudo pvs; sudo vgs                       # no vg0
```
Expected: no signatures, no partitions. This is what the Ansible role calls "provably blank".
**Rollback.** None: this is the point of no return.
**PR.** None. **Report.** Executor asks the operator to answer only "wiped and verified blank: yes/no".
**STOP point.** Do not continue to WP4 without "yes".

### WP4. Enable the Ansible role and build the host side (BRUNO RUNS; executor prepares text)

**Goal.** Volume group `victus512` with three logical volumes, libvirt installed, domain `mini03` defined (not
started), keep-awake unit running, CPU weight set. **Preconditions.** WP0 (#49 merged), WP3 yes, D1, D2, D3,
D6, D7 answered; WP5 steps 1 and 2 done (MAC) and the ISO downloaded (WP5 step 3), because the domain XML
needs both.

**Why a local variables file, not the inventory.** Enabling the role in `inventory.yml` and merging would make
`deploy.yml` auto-apply it on the victus runner at merge time (section 3.3), including the destructive
switch. So everything that turns the role on lives in a file the operator keeps OUTSIDE the repository, passed with
`-e @file`.

1. Create the local variables file on the operator's Mac (path outside the repo, mode 600):
   ```
   umask 077
   cat > ~/victus-vm.local.yml <<'EOF'
   victus_vm_enabled: true
   victus_vm_start: false
   victus_vm_disk_provision: false      # set true ONLY for the single run in step 4
   victus_vm_network_mode: direct
   victus_vm_nic: eno1
   victus_vm_mac: "<mini03-mac>"
   victus_vm_install_iso: "/var/lib/libvirt/images/<iso-file-name>"
   victus_vm_vcpus: 4
   victus_vm_memory_mib: 8192
   victus_vm_autostart: true
   victus_vm_inhibit_sleep: true
   EOF
   ```
   Replace `<mini03-mac>` by the MAC from WP5 and the ISO name from WP5. WHY: variable names are exactly those
   of section 3.3. If the host has no `eno1` (check `ip -br link`), put the wired NIC name instead.
2. Check connectivity. From the `ansible/` folder:
   ```
   cd ansible
   ansible -i inventory.yml victus -m ping --ask-vault-pass
   ```
   Expected: `pong`. If it fails because the address is stale (inventory still has the old tailnet address),
   the host is reached by the name in the operator's `~/.ssh/config`: run with `-e ansible_host=victus` (the SSH
   alias). STOP if neither works.
3. Dry run, no changes:
   ```
   ansible-playbook victus.yml --check --diff --ask-vault-pass -e @$HOME/victus-vm.local.yml
   ```
   If the vault does not contain the become password, add `--ask-become-pass`. Expected: tasks of the
   role listed; "Assert exactly one disk has that serial" passes (role finds the 512 GB disk); "Assert this is
   the disk we pinned" passes; the disk state is "blank" (the role reports it). Failure meanings:
   `/dev/kvm is missing` (enable AMD-V/SVM in firmware), `Expected exactly one whole disk with serial` (the
   disk is not the pinned one or not installed; STOP, Decision D10), `Refusing to touch it` (mounted or wrong
   size).
4. The one destructive run (builds the layout). Edit the file: set `victus_vm_disk_provision: true`, then:
   ```
   ansible-playbook victus.yml --ask-vault-pass -e @$HOME/victus-vm.local.yml
   ```
   Then immediately set `victus_vm_disk_provision: false` again in the file.
5. Verify on victus:
   ```
   sudo vgs victus512
   sudo lvs victus512
   sudo vgs -o vg_name,vg_size,vg_free victus512
   virsh -c qemu:///system dominfo mini03
   virsh -c qemu:///system dumpxml mini03 | grep -E "source dev|mac address|source dev=|boot order"
   systemctl is-active libvirtd victus-vm-awake.service
   systemctl show machine.slice -p CPUWeight
   systemd-inhibit --list | grep mini03
   ```
   Expected: `victus512` with `mini03-os` 64.00g, `mini03-backups` 128.00g, `mini03-staging` 283.00g and about
   1.9g free; `dominfo` shows `State: shut off` and `Autostart: enable`; the dumpxml shows the three LV paths and the
   MAC from step 1; `libvirtd` and the inhibitor service `active`; `CPUWeight=25`; the inhibit list shows
   `mini03`.
6. Idempotence: re-run step 3 (check mode). Expected: no changes.
7. The standalone offline test (any machine, harmless):
   `cd ansible && ansible-playbook -i localhost, -c local tests/victus_vm_disk_state.yml` expects all scenarios
   pass [verified README of the branch].

**Verification** as above. **Rollback.** WP12. **PR.** None (local file). If the operator wants the settings in git:
that is a separate PR to `ansible/inventory.yml` with the vault MAC variable, after he accepts that the merge
triggers an auto-apply (set `victus_vm_disk_provision` false there).
**STOP point.** Report the output of step 5 (no serials: remove the SERIAL column if pasted).

### WP5. MAC address, router reservation, ISO

**Goal.** A stable identity for the VM and the install media. **Preconditions.** D1, D2.
(BRUNO RUNS steps 1, 2; the executor does step 3 only as instructions.)

1. Generate a MAC (locally administered, QEMU prefix) on the Mac:
   `printf '52:54:00:%02x:%02x:%02x\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) | pbcopy`
   WHY: no echo on screen. Paste it into `~/victus-vm.local.yml` (`victus_vm_mac`) and into his password manager.
   It is never written into the repo or a PR.
2. Router: create a DHCP reservation for that MAC, the name `mini03`; if the router does DNS for its DHCP
   clients, check later that `mini03` resolves (WP7). Also confirm `mini01` resolves from a machine on the LAN
   (`getent hosts mini01`): the Talos endpoint is the short name `mini01` (`talos/cluster.env`). If it does
   not resolve, the untracked `talos/local/cluster.local.env` carries the endpoint (it does not enter the repo).
3. ISO: from the repo root (after #52 is merged), `bash talos/fetch-assets.sh mini03 iso`.
   Expected: it prints a path (default cache `./.cache`) after checking the pinned hash. Exit 3 means the pin
   is unpinned (it prints a hash to review; STOP); exit 1 means a hash mismatch (the file is deleted; STOP).
   Copy the ISO to victus: `scp <printed path> victus:/tmp/` then on victus
   `sudo install -m 0644 -o root -g root /tmp/<iso-file-name> /var/lib/libvirt/images/`. The path must be
   readable by `libvirt-qemu` (user used by the role); check `sudo -u libvirt-qemu head -c 4 /var/lib/libvirt/images/<iso-file-name>`.
   Set it as `victus_vm_install_iso`.
**Verification.** ISO file exists on victus; MAC in the local file; reservation exists. **STOP point.** Report yes/no.

### WP6. Repository changes for the node (executor PRs) and the Tailscale key (the operator)

**Goal.** The Talos side is complete in the repo. **Branch.** `talos/mini03-join`. **Preconditions.** WP0.

1. Confirm the node files from PR #52 are on `main` (WP1 step 2). If they differ from section 3.2, STOP.
2. **The operator creates the Tailscale auth key** (executor cannot): admin console, Settings, Keys: generate an auth key,
   reusable OFF, ephemeral OFF, pre-approved ON, no tag, expiry 1 day. Then, on his Mac (the same recipe
   as `talos/secrets/README.md` section 3): copy `talos/patches/tailscale.yaml`, add the auth key
   environment entry as done for `tailscale-mini02.sops.yaml` (open that sops file with `sops
   talos/secrets/tailscale-mini02.sops.yaml` to see the SHAPE; do not print the key), then
   `sops -e --filename-override secrets/tailscale-mini03.sops.yaml --input-type yaml --output-type yaml <tmpfile> > talos/secrets/tailscale-mini03.sops.yaml`
   and `rm -P <tmpfile>`. The encrypted file may be committed.
3. Executor PR (one concern: the sops file): add only `talos/secrets/tailscale-mini03.sops.yaml`
   (the encrypted result the operator placed), plus a check that `render.sh` accepts it: The operator runs
   `bash talos/render.sh mini03 --out talos/out` once to prove the render; expected: a file `talos/out/mini03.yaml`
   (mode 600, gitignored). `bash talos/render.sh --check-secrets-clean` expects "no leftovers".
   `talos validate`: `talosctl validate --mode metal --config talos/out/mini03.yaml` expects no errors.
   Delete the plain render after use: `shred -u talos/out/mini03.yaml` or `rm -P`.
4. `TALOS_NODES` repository variable: The operator edits it (Settings, Secrets and variables, Actions, Variables):
   append ` mini03=<mini03-short-name>` (name=endpoint, short MagicDNS name) AFTER the existing pairs; control plane
   first. Do this only after WP7 completes so the workflow does not try to reach a missing node
   [`docs/dr/talos-deploy.md`].
5. Guards, commit, draft PR: title "talos: encrypted Tailscale auth key for mini03", description lists the
   tag, expiry, and says "ciphertext only".
**Verification.** Guards all OK. **Rollback.** Close the PR; revoke the key in the console.
**The operator after merging.** Nothing to sync (Argo is not involved). The `talos-deploy` workflow starts; he lets it
wait or cancels it (mini03 is not in `TALOS_NODES` yet). **STOP point.** Wait for the operator's confirmation before WP7.

### WP7. Boot Talos, apply the machine config, join the cluster (BRUNO RUNS)

**Goal.** mini03 is a Ready node. **Preconditions.** WP4 done, WP5 done, WP6 done. D1, D9 answered.

1. Start the VM (the operator, on victus): `virsh -c qemu:///system start mini03`; watch the console:
   `virsh -c qemu:///system console mini03` (leave with `Ctrl+]`). Expected: Talos boots in maintenance mode
   and shows a dashboard with its address (given by DHCP according to the reservation). If the screen shows no
   address: failure table section 10.
2. Find the address (do not paste it into the repo): on the router lease list, or from the console dashboard.
   Call it `<mini03-ip>` in the commands below (in his terminal only).
3. Read-only look at what the installer sees:
   ```
   talosctl -n <mini03-ip> get disks --insecure
   talosctl -n <mini03-ip> get links --insecure
   ```
   Expected: three disks, sizes about 68.7 GB, 137.4 GB, 303.9 GB (roughly 64, 128, 283 GiB), all virtio; one link up.
   If a disk is missing or has another size, STOP (section 10).
4. Render with the real secrets and apply:
   ```
   bash talos/render.sh mini03 --out talos/out
   talosctl apply-config --insecure -n <mini03-ip> -f talos/out/mini03.yaml
   ```
   Expected: the call returns; the VM installs Talos to `vda` and reboots (a few minutes). Then
   `shred -u talos/out/mini03.yaml` (`rm -P` on macOS) and `bash talos/render.sh --check-secrets-clean`.
   WHY `--insecure`: the node is in maintenance mode and has no certificate yet.
5. After the reboot: the ISO is still attached but the disk is first in the boot order, so it boots from the
   disk (the domain defines `<boot order='1'/>` for `vda`). Check on the console that Talos shows "Ready".
   Then, to detach the ISO: set `victus_vm_install_iso: ""` in `~/victus-vm.local.yml` and run the check then real
   playbook (`ansible-playbook victus.yml --ask-vault-pass -e @$HOME/victus-vm.local.yml`); this re-defines
   the domain; it takes effect at the next stop and start (WP11). Not urgent.
6. Join: a worker joins on its own once configured; there is NO `bootstrap` for a worker (never run
   `talosctl bootstrap` here: that is for the first control plane only).
   ```
   kubectl --context admin@<cluster> get nodes -o wide -w
   ```
   Expected within about 10 minutes: `mini03` appears and becomes `Ready`; `INTERNAL-IP` shows an address
   (per D9 the same kind as the other two nodes).
7. Talos checks (talosconfig must point to the cluster; `-e` is a control-plane endpoint):
   ```
   talosctl -n mini03 version
   talosctl -n mini03 get volumestatus
   talosctl -n mini03 mounts | grep -E 'var/mnt'
   talosctl -n mini03 get extensions
   talosctl -n mini03 health
   ```
   (After the node is on the tailnet, `mini03` resolves through MagicDNS; before that, use `<mini03-ip>`.)
   Expected: `version` shows `v1.14.2`; volumestatus lists `data`, `backups`, `staging` as `ready`
   (or the equivalent state), mounted at `/var/mnt/data`, `/var/mnt/backups`, `/var/mnt/staging`;
   extensions list `qemu-guest-agent` and `tailscale`; `health` OK. If volume status shows `staging` or `backups` missing: section 10 "disk selectors".
8. Tailscale: in the admin console, confirm a new device `mini03` (untagged; no `-1` suffix; if it is `mini03-1`,
   a stale device exists: delete the old one and re-apply).
9. Add `mini03=<mini03-short-name>` to `TALOS_NODES` (WP6 step 4).
**Verification.** `kubectl get node mini03` is Ready. **Rollback.** WP12. **STOP point.** Report outputs without addresses.

### WP8. Labels, taint check and smoke test (BRUNO RUNS the pod; temporary)

**Goal.** Prove placement, the taint and the `data` volume. **Preconditions.** WP7.

1. Read-only (executor allowed):
   ```
   kubectl --context admin@<cluster> get node mini03 --show-labels
   kubectl --context admin@<cluster> get node mini03 -o jsonpath='{.spec.taints}'
   kubectl --context admin@<cluster> describe node mini03
   ```
   Expected labels include `node-role.homeserver/tier=mobile` and `node-role.homeserver/pool=media-backup` and
   `kubernetes.io/hostname=mini03`; taints `[{"effect":"NoSchedule","key":"node-role.homeserver/tier","value":"mobile"}]`.
   If missing: the `KubeNodeConfig` document did not apply; section 10.
2. Smoke test. This is a throwaway diagnostic Pod, an exception to "no live changes" that the operator runs and deletes
   himself. Save as `~/mini03-smoke.yaml` (NOT in the repo):
   ```yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: mini03-smoke
     labels:
       pod-security.kubernetes.io/enforce: baseline
   ---
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: smoke-data
     namespace: mini03-smoke
   spec:
     accessModes: [ReadWriteOnce]
     storageClassName: topolvm-fast
     resources:
       requests:
         storage: 1Gi
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: smoke
     namespace: mini03-smoke
   spec:
     nodeSelector:
       kubernetes.io/hostname: mini03
     tolerations:
       - key: node-role.homeserver/tier
         operator: Equal
         value: mobile
         effect: NoSchedule
     securityContext:
       runAsNonRoot: true
       runAsUser: 1000
       runAsGroup: 1000
       fsGroup: 1000
       seccompProfile:
         type: RuntimeDefault
     containers:
       - name: smoke
         image: docker.io/library/alpine:3.22
         command: ["sh", "-c", "echo ok > /data/probe && cat /data/probe && date && sleep 600"]
         securityContext:
           allowPrivilegeEscalation: false
           capabilities:
             drop: ["ALL"]
         resources:
           requests: { cpu: 10m, memory: 16Mi }
           limits: { cpu: 100m, memory: 64Mi }
         volumeMounts:
           - name: data
             mountPath: /data
     volumes:
       - name: data
         persistentVolumeClaim:
           claimName: smoke-data
   ```
   (`alpine:3.22` is the tag pinned for CI in `talos/versions.env` `ALPINE_TAG`; a throwaway test image does not
   need a digest.) the operator: `kubectl --context admin@<cluster> apply -f ~/mini03-smoke.yaml`.
3. Verify: `kubectl --context admin@<cluster> -n mini03-smoke get pod smoke -o wide` shows `Running` on `mini03`;
   `kubectl ... -n mini03-smoke logs smoke` prints `ok`; `kubectl ... get pvc -n mini03-smoke` is `Bound`
   (the WaitForFirstConsumer binding follows the pod; the volume directory is under `/var/mnt/data/local-path`
   on mini03). Negative test: a copy of the Pod without the toleration (named `smoke-no-tol`, same nodeSelector)
   must stay `Pending` with an event about the taint. Run and delete it the same way.
4. Clean up (the operator): `kubectl --context admin@<cluster> delete namespace mini03-smoke`. Because the class has
   reclaim Retain, the PV stays `Released`: `kubectl get pv | grep smoke` then delete that PV by name, and
   remove the directory from the node if desired (needs a node shell; skip, it is 1 MB).
**Rollback.** The delete above. **STOP point.** Report.

### WP9. Velero node-agent coverage on mini03 (executor PR)

**Goal.** The Velero `node-agent` DaemonSet runs on mini03 so mini03's volumes can be backed up with
file-system backup. **Branch.** `talos/velero-nodeagent-mini03`. **Preconditions.** D5 = taint; mini03 Ready.

1. Read the current value file and wiring: `talos/values/velero.yaml` and `talos/apps-overrides.yaml` (verify
   the values file is wired into the velero Application: `grep -n velero talos/apps-overrides.yaml`). Memory notes
   say the repo wiring exists; if not, STOP.
2. Confirm the chart key name: `helm show values vmware-tanzu/velero | grep -n -A12 '^nodeAgent'` shows a
   `tolerations: []` key under `nodeAgent` [UNVERIFIED for the chart version in use; repo
   `argocd/values/velero.yaml` already sets `nodeAgent.resources`, so the `nodeAgent` map is right]. Get the chart
   version from `talos/apps/velero.yaml` (`targetRevision`). If the key does not exist: STOP.
3. Edit `talos/values/velero.yaml`: append (this is the only change):
   ```yaml
   # mini03 is tainted (tier=mobile:NoSchedule): the node agent must tolerate it to back up volumes there.
   nodeAgent:
     tolerations:
       - key: node-role.homeserver/tier
         operator: Equal
         value: mobile
         effect: NoSchedule
   ```
   WHY: the file already merges over the repo values; a list is replaced, not merged, so this is the whole list
   and the node agent has no other tolerations today (verified live, section 3.1).
4. The opt-in annotation for pod volumes is `backup.velero.io/backup-volumes` [verified `talos/values/velero.yaml`
   header and `docs/dr/mini03.md`]. It is set by each app's own PR. The torrent staging volume is NOT opted in.
5. Run `talos/render-apps.sh --force` (no app source changed, so expect no diff; commit nothing generated if none),
   `bash .github/scripts/run-all-guards.sh` all OK. Draft PR "velero: node agent tolerates the mini03 taint".
**The operator after merging.** In Argo, open app `velero`, click Diff, expect only the DaemonSet `node-agent` pod
template changing (a tolerations entry), then Sync. Watch `kubectl --context admin@<cluster> -n velero get
pods -o wide`: a `node-agent-*` pod appears on `mini03`, the two existing ones restart or stay.
**Verification.** `kubectl -n velero get ds node-agent` shows `DESIRED 3 READY 3`.
**Rollback.** Revert the PR and sync. **STOP point.** Report.

### WP10. Network, MTU and time checks (read-only for the executor, the operator runs the node commands)

**Goal.** Prove the node is a good cluster citizen.

1. InternalIP kind: `kubectl --context admin@<cluster> get nodes -o wide` and compare mini03 with the others
   (D9). If mini03 reports a LAN address while the others report tailnet addresses (or vice versa), flannel can
   still work, but the two kinds of address must reach each other: continue with the tests below.
2. Flannel and kube-proxy pods on mini03 are running: `kubectl --context admin@<cluster> -n kube-system get pods
   -o wide | grep mini03` shows `kube-flannel-*`, `kube-proxy-*`, `pod-udp-snat-*`, `csi-smb-node-*` all `Running`.
3. Cross-node pod traffic (the operator, uses the smoke pod from WP8 if still present, otherwise a copy): from the pod
   `wget -qO- --timeout=5 http://<service>.<namespace>.svc.cluster.local:<port>/` to an HTTP service on mini01,
   for example AdGuard's UI or Jellyfin's service (find with `kubectl get svc -A`); and the reverse: from a pod
   on mini01 to a pod on mini03 (use `kubectl get pod -o wide` to read the pod IP; do not write it in the repo).
   `exec` into pods is read-only enough for tests but is a command run in a container: The operator runs it.
4. MTU: flannel VXLAN needs the pod interface MTU to be the underlay MTU minus 50. Read the underlay and pod
   interface MTUs: `talosctl -n mini03 get links` (look at the MTU column of the Tailscale link and of the
   `flannel.1` / `eth0` links; the Tailscale link is typically 1280, so the flannel MTU would be about 1230)
   and compare with mini01 and mini02 the same way. They should match each other [UNVERIFIED value; expected from
   how Tailscale works]. Large packet test: from the smoke pod to a mini01 service `wget` a file larger than 2 MB
   (e.g. a Jellyfin web asset); a stall at 0 bytes while small requests work means an MTU problem (section 10).
5. Time sync: Talos syncs time by default (`talos/patches/common.yaml` notes this):
   `talosctl -n mini03 get timestatus` expects `SYNCED: true`; `talosctl -n mini03 time` shows a time close to
   `date -u` on the Mac. Why it matters here: a VM clock can jump after the host sleeps; then certificates fail.
6. Host to VM (macvtap): from victus, `ping -c2 <mini03-ip>` is expected to FAIL (known macvtap limit, D1) while
   from the Mac it works. If the reverse, nothing is wrong either. The host reaches the node over the tailnet:
   `ping mini03` from victus (needs the host and VM Tailscale up; may be relayed).
7. `/dev/net/tun` (needed by gluetun later): `talosctl -n mini03 ls /dev/net` expects `tun`. If absent: report
   to the torrent plan owner; this is its first proof (design phase P4). Not a failure of this plan.
8. Resource view: `kubectl --context admin@<cluster> top nodes` (needs metrics-server: present as an app) shows
   mini03 CPU and memory; note the idle numbers (expected about 1 GB used).
**STOP point.** Report numbers, no addresses.

### WP11. Host reboot test and autostart (BRUNO RUNS)

**Goal.** The VM comes back after the host reboots, and the node re-joins. **Preconditions.** WP7 done; nobody is
gaming.

1. `kubectl --context admin@<cluster> get nodes` (before). `sudo systemctl reboot` on victus.
2. After login: `virsh -c qemu:///system list --all` expects `mini03   running` (autostart). `systemctl is-active
   victus-vm-awake.service` expects `active`.
3. `kubectl --context admin@<cluster> get nodes -w`: `mini03` returns to `Ready` within a few minutes.
   `kubectl get pods -A -o wide | grep mini03` pods restart.
4. Test a graceful shutdown: `virsh -c qemu:///system shutdown mini03` (guest agent / ACPI), expect `shut off`
   within a minute; start again `virsh -c qemu:///system start mini03`.
5. Suspend check: the inhibitor must block it: `systemd-inhibit --list` shows `mini03` with `block`.
**Rollback.** If autostart fails: `virsh -c qemu:///system autostart mini03`.
**STOP point.** Report.

### WP12. Rollback (BRUNO RUNS ONLY; the executor never runs any of this)

Each level undoes the previous ones; stop at the level you need.

**A. Take the node out of the cluster (data stays):**
```
kubectl --context admin@<cluster> drain mini03 --ignore-daemonsets --delete-emptydir-data
kubectl --context admin@<cluster> delete node mini03
```
Expected: pods leave; the node object disappears. mini01 and mini02 are unaffected (a worker is not part of
etcd). Also remove `mini03=...` from the `TALOS_NODES` variable and delete the `mini03` device in the Tailscale
admin console (otherwise the next join becomes `mini03-1`). If the Talos side should be forgotten:
`talosctl -n mini03 reset --graceful=false --reboot` wipes the node (data volumes included) and returns it to
maintenance mode: DESTRUCTIVE for the VM's disks only.

**B. Stop the VM:**
```
virsh -c qemu:///system shutdown mini03          # or: virsh -c qemu:///system destroy mini03 (hard power-off)
virsh -c qemu:///system autostart mini03 --disable
```

**C. Remove the VM definition:**
```
virsh -c qemu:///system undefine mini03 --nvram
sudo rm -i /etc/libvirt/mini03.xml
sudo systemctl disable --now victus-vm-awake.service
```
Set `victus_vm_enabled: false` in `~/victus-vm.local.yml`. WHY: if the role is run with the switch true
again it recreates the domain.

**D. Remove the logical volumes (destroys all data in the VM disks; the operator types each line):**
```
sudo lvs victus512
sudo lvremove victus512/mini03-os victus512/mini03-backups victus512/mini03-staging
sudo vgremove victus512
sudo pvremove /dev/<disk-device>p1
```
Check `sudo lvs` shows nothing of `victus512`. Do NOT use `-f`. Never touch the 1 TB disk's volumes.

**E. Return the packages if wanted:** `sudo pacman -Rns libvirt qemu-base edk2-ovmf dnsmasq lvm2` only after
checking nothing else uses them.

**Node object only (VM keeps running):** if the node is `NotReady` forever and you want to re-join, do A, then
reset (`talosctl reset`) and re-apply the config as in WP7.

### WP13. Hand-over to the services that will run on mini03

**Goal.** One block of facts the other plans can copy. The executor writes this into its report; no repo file.

- Node name `mini03`; selector `nodeSelector: kubernetes.io/hostname: mini03`.
- Toleration to use in every pod, Deployment or CronJob that must run there:
  ```yaml
  tolerations:
    - key: node-role.homeserver/tier
      operator: Equal
      value: mobile
      effect: NoSchedule
  ```
- Storage: PVCs with `storageClassName: topolvm-fast` land in `/var/mnt/data/local-path` on mini03 (about 33 GiB
  available). The `backups` volume is `/var/mnt/backups` (hostPath, 128 GiB, for the replica). The `staging`
  volume is `/var/mnt/staging` (hostPath or local PersistentVolume, 283 GiB, disposable). Kubelet can only see
  mounts below `/var/mnt`.
- Backups: the Velero opt-in annotation `backup.velero.io/backup-volumes: <volume-name>` on a pod, node-agent
  runs on mini03 after WP9. Staging is not backed up.
- Namespaces: `arr` for the arr stack and the torrent client (brief) with the Pod Security decision owned by
  those plans; the design doc proposes a separate `torrent` namespace labelled `privileged` because gluetun needs
  `NET_ADMIN` and `/dev/net/tun` [ASSUMED].
- No external exposure: tailnet Ingress or LoadBalancer through the Tailscale operator, as for other apps.
- Network quirks: host `victus` cannot reach the VM over its NIC; LAN access to mini03's services goes through the tailnet.
- Capacity: 4 vCPU / 8 GiB, shared with a desktop; CPU weight 25. Do not size services with large CPU requests.

## 8. Backup and restore

- **What is backed up.** Nothing of the VM itself: the VM is rebuilt from the repo (Talos config, schematic) plus
  the host role. The host LVs hold only guest filesystems.
- **mini03's data.** Volumes of pods on `data` (arr config) are covered by Velero file-system backup if the
  pod carries `backup.velero.io/backup-volumes` and the node agent runs there (WP9), stored in the MinIO on
  mini02 (and the replica on mini03's own `backups` volume once PR #71 deploys; that replica is itself the
  backup and is not backed up by Velero). `staging` is disposable and not backed up.
- **Not covered:** host Arch configuration beyond `ansible/`; the `victus_vm` local variables file; the
  libvirt NVRAM file for the guest (rebuilt automatically); LV contents when the disk fails (rebuild the node;
  restore the arr config with Velero from mini02's MinIO).
- **Restore test (executor writes, the operator performs), "rebuild mini03 from scratch":**
  1. Run WP12 A, B, C, then D only for `mini03-os` (`sudo lvremove victus512/mini03-os` and recreate it with
     `sudo lvcreate -L 64G -n mini03-os victus512`), leaving `backups` and `staging` intact.
  2. Re-run WP4 step 3 (check; the role now reports "volume group exists but a volume is missing" or checks only
     read; if it refuses, STOP and use WP12 D fully, then WP4).
  3. Repeat WP7; confirm `data` is recreated (empty) while `backups` and `staging` keep their files:
     `talosctl -n mini03 ls /var/mnt/backups` and `... /var/mnt/staging` still list their content.
  4. Restore a test namespace from Velero as in `docs/dr/talos-backups.md` and `talos/dr/velero-restore-drill.sh`
     once a mini03 app exists. [UNVERIFIED until the first arr app is deployed]
- **Disk-lost case.** If the NVMe dies, the replica is gone too; the primary on mini02 remains. Re-do WP3 and WP4
  on the new disk after the operator updates the pinned serial (D10).

## 9. Security

- **Exposure.** The VM has no inbound exposure from the internet. It gets a LAN address (DHCP) and a tailnet
  address (untagged; the tailnet policy `hosts` alias mini03 decides what may reach it; the deploy workflow's `tag:ci` may
  reach ports 50000 and 6443 only [verified `docs/dr/talos-deploy.md`]).
- **Authentication.** The Talos API uses mutual TLS with the client certificate in the talosconfig. There is no
  SSH on Talos. The Kubernetes API is reached over the cluster endpoint with certificates.
- **Least privilege on the host.** libvirt runs QEMU as `libvirt-qemu`; the LVs are owned by root and handed
  through libvirt; the role never touches the 1 TB disk, never changes host networking in `direct` mode, never
  resizes volumes, and the destructive switch is OFF by default and applies only to a blank disk.
  macvtap isolates the VM from the host over `eno1` (a feature).
- **No GPU passthrough, no USB passthrough.** The domain defines none.
- **Secure Boot.** The domain disables Secure Boot (`firmware` features: `secure-boot` no, `enrolled-keys` no)
  and the mini03 ISO is the plain image (the pins have no Secure Boot ISO for mini03; `fetch-assets.sh` offers
  `iso-secureboot` only for mini01 and mini02) [verified repo]. Accepted risk: record in the PR.
- **Disk encryption:** deferred cluster-wide (`talos/patches/common.yaml`). The VM's disks are plain LVs on the host.
- **Pods on mini03:** each owning plan sets runAsNonRoot, drops capabilities, read-only root where possible; the
  smoke pod above does so.
- **Host Tailscale** stays up; separate device from the VM.

## 10. Operations

**Upgrade.** Talos version bump = a PR changing `talos/versions.env` (and the mini03 pins via
`talos/refresh-pins.sh`), then the `talos-deploy` workflow with `scope: talos-upgrade`, the operator approving; order
control plane, mini02, mini03 [`docs/dr/talos-deploy.md`]. `talosctl -n mini03 upgrade --image $(bash
talos/fetch-assets.sh mini03 installer-ref) --wait` is the manual equivalent. The installer image comes from
the node's own schematic (never `latest`). Host side: `pacman -Syu` on victus is the operator's own routine; reboot
only when the node can be offline (WP11 shows the effect). A libvirt or qemu upgrade needs a VM stop/start to
take effect.

**Health checks.** `kubectl get nodes`; `talosctl -n mini03 health`; `virsh -c qemu:///system list --all`;
`sudo lvs victus512`; `kubectl top nodes`; node-agent pod; Tailscale device online.

**Logs.** Console: `virsh -c qemu:///system console mini03`. Talos: `talosctl -n mini03 dmesg | tail -50`,
`talosctl -n mini03 logs kubelet`. Host: `journalctl -u libvirtd --since "1 hour ago"`, `sudo less
/var/log/libvirt/qemu/mini03.log`.

**Resource watch.** After one week, record `kubectl top nodes` for mini03 and on victus `free -h`, to decide
D3 (6 GiB enough?). Free space in the guest's volumes: `talosctl -n mini03 get volumestatus`.

### Failure modes and fixes

| Symptom | Where to look | Likely cause | Fix |
|---|---|---|---|
| VM console shows no address / "waiting for network" | `virsh domiflist mini03`; console; router lease list | No DHCP lease: wrong NIC name, NIC is Wi-Fi, no reservation, macvtap on a NIC that is down | `ip -br link` for the wired NIC name and set `victus_vm_nic`; make sure the cable is up; re-run the role and restart the VM (`virsh destroy`, `virsh start`); check the router sees the MAC |
| VM has an address but `talosctl --insecure` times out from the host victus | n/a | macvtap: the host cannot reach the guest | run `talosctl` from the Mac, not from victus |
| Node never appears in `kubectl get nodes`; console says it cannot reach the endpoint | console log; `talosctl -n <mini03-ip> dmesg --insecure` | The VM cannot resolve or reach the control plane endpoint (`mini01`): no DNS for the short name, firewall, mini01 off the LAN | on the VM's network, resolve the name: `talosctl -n <mini03-ip> --insecure ...` not possible; test from another LAN machine `getent hosts mini01`; set the endpoint in the untracked `talos/local/cluster.local.env`, re-render and re-apply (maintenance mode accepts `apply-config --insecure` again) |
| Boots to a UEFI shell / "no bootable device" | console | OVMF with Secure Boot on, the ISO not attached, or the install disk empty and ISO missing | verify `victus_vm_install_iso` is set and readable by `libvirt-qemu`; `virsh dumpxml mini03 | grep -A3 cdrom`; the XML has Secure Boot off (`virsh dumpxml mini03 | grep -i secure`) |
| Install fails: "no disk matches the selector" | `talosctl get disks --insecure` | the install selector `< 100GB` matches nothing: the OS LV is not 64 GiB or the disks use another bus | compare sizes; fix `victus_vm_lv_os_gib` (cannot resize: WP12 D) or edit the selector in a PR |
| `backups` or `staging` volume missing / pending | `talosctl get volumestatus`, `talosctl get disks` | the size band does not match (e.g. a different LV size) or the install disk was also matched | check each disk's size; the bands are 130 to 145 GB and 290 to 320 GB decimal; fix in `talos/patches/volumes-mini03.yaml` (PR) and re-apply |
| node `NotReady` | `kubectl describe node mini03`; `talosctl -n mini03 logs kubelet`; flannel pod logs | CNI not up on the node, tailnet unreachable, clock skew, resource starvation | check `kube-flannel` pod on mini03; check time (`talosctl get timestatus`); check the VM's CPU is not starved (`top` on the host) |
| Pods on mini03 cannot talk to pods elsewhere | WP10 step 3 and 4 | MTU too large for the underlay, or the node's addresses unreachable from the other nodes (Tailscale device offline) | ensure mini03 is online on the tailnet; compare the MTU of mini03 with the others; if different, fix in a PR (Talos network config) |
| Node drops when the operator plays a game | `kubectl get nodes`, `uptime` on victus | CPU/memory contention (weight 25), or a sleep | expected: it recovers; if it flaps, lower `victus_vm_vcpus` to 2 or raise `victus_vm_slice_cpu_weight`; do not pin the VM to specific CPUs without the operator |
| victus suspended: node and services gone | `journalctl -b -u victus-vm-awake` and `systemctl status victus-vm-awake.service` | the keep-awake inhibitor is not running, or the desktop environment overrides it (a manual suspend from the menu ignores `--mode=block` for `sleep` only if the user chooses to) | `sudo systemctl restart victus-vm-awake.service`; check `systemd-inhibit --list`; disable sleep in the desktop power settings; for lid close use `HandleLidSwitch=ignore` in logind (host change, the operator decides) |
| `ansible-playbook` fails at "Assert exactly one disk" | the playbook output | the disk is not the pinned one (disk replaced) or not present | D10: update the serial in the local vars file (`victus_vm_disk_serial`) |
| `ansible-playbook` fails at "Refusing to touch" | output | the disk is not blank or something is mounted | re-do WP3 |
| `ansible-playbook` cannot connect / become fails | output | stale `ansible_host`, wrong become password | WP4 step 2; use `--ask-become-pass` |
| Node object stuck after a rebuild with a `-1` tailnet device | Tailscale admin console | old device was not deleted | delete the old device, `talosctl apply-config` again |
| `kubectl get node` shows two InternalIP kinds | `kubectl get nodes -o wide` | D9 mismatch | see D9 |
| Domain XML change did not apply | `virsh dumpxml` | a stop and start is needed | `virsh shutdown` then `virsh start` |
| `kube-system/csi-smb-node`, `kube-flannel` do not appear on mini03 | `kubectl get ds -A` | node not yet Ready or a taint they do not tolerate | they tolerate everything (verified); wait for Ready |

## 11. Acceptance checklist and report format

**Acceptance (The operator sees all of this):**

- [ ] `virsh -c qemu:///system list --all` shows `mini03 running`, and `dominfo` says `Autostart: enable`.
- [ ] `sudo vgs victus512` shows three volumes of 64, 128, 283 GiB and about 1.9 GiB free.
- [ ] `kubectl get nodes` shows mini01, mini02 and `mini03` (Ready, role none), nothing else changed.
- [ ] Labels and taint as in section 0; `talosctl -n mini03 get volumestatus` shows the three volumes.
- [ ] Smoke pod ran on mini03 and the negative test stayed Pending; namespace removed.
- [ ] `kubectl -n velero get ds node-agent` shows 3 of 3 ready.
- [ ] Cross-node traffic works; MTU consistent; time synced.
- [ ] Host reboot brings the VM and node back by itself; sleep is blocked by the inhibitor.
- [ ] Root disk of victus below 70%; the old MinIO and its env file are gone; the recovery folder is `root:root`, `go-rwx`.
- [ ] The host Tailscale is still `Running`.
- [ ] No serial, MAC, IP or full tailnet name is in the repository (guards all `OK`).

**Report format after each work package:**

```
WP<n>: done|blocked|needs decision
PR: <url or none>
Guards: all OK | <which failed>
Verified: <commands run and the key lines of output, no addresses/serials>
Differences from the plan: <what looked different and what you did>
Needs from the operator: <exact next action or decision id>
```

## 12. Open questions and UNVERIFIED items

1. Whether the Velero chart version in use has `nodeAgent.tolerations` (WP9 step 2 confirms with `helm show values`).
2. Which InternalIP kind mini03 should have (D9) and the resulting flannel/Tailscale MTU values.
3. Whether the Talos `VolumeConfig`/`UserVolumeConfig` selectors match the real virtio disks and the install disk
   selector `< 100GB` (confirmed only in WP7 step 3 and 7).
4. Whether the victus self-hosted runner is still registered (affects what a merge of #49 triggers).
5. Whether the inventory's `ansible_host` for victus is current, and whether `vault_become_password_victus` exists
   in the encrypted vault (WP4 steps 2 and CRED table).
6. Arch package names (`qemu-base`, `edk2-ovmf`, `dnsmasq`) at the time of the run.
7. Where the operator keeps the `talosconfig` and the `TALOSCONFIG` setting; `talos/local/cluster.local.env`.
8. The upstream Talos documentation has moved to https://docs.siderolabs.com/talos; there is no KVM-specific guide,
   so libvirt behaviour with Talos is proven only by this plan's WP7.
9. macvtap host-to-guest isolation and the tailnet relay behaviour (WP10 step 6) were not re-tested here.
10. `/dev/net/tun` on the node (WP10 step 7): the torrent plan depends on it.
11. Decision D10 (serial in the role defaults) and the README lines that repeat part of it: owned by PR #49.
12. The PR #71 backup-replica manifests were not read in full for this plan; the interface in section 2.2 is
    [ASSUMED].
