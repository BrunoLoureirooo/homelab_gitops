# mini03: the Talos worker VM on victus (arr stack, torrents behind a VPN, backup replica)

Status (2026-11-04): design only; the VM is not built. The host is ready for it: victus is out of the
cluster (k3s agent uninstalled, standalone MinIO and its data removed) and the 512 GB NVMe was wiped
on purpose by the operator, who confirmed everything on it exists elsewhere. That means P0 below (the interim
copy and the wipe) is closed. Still to do: the role's provisioning run (WP4 of `docs/plans/mini03-vm.md`),
the MAC and router reservation, the Tailscale key, and the join. Decided by the operator 2026-10-15, reworked
2026-10-19 (new role, new disk layout). Applies after gate G2 of the cutover (`talos/CUTOVER.md`),
never during it. This is the one canonical document for the node; the pieces are
`ansible/roles/victus_vm` (host side, PR #49), `talos/nodes/mini03.*`,
`talos/patches/volumes-mini03.yaml` and `talos/schematics/mini03.yaml` (guest side, this PR) and
`talos/manifests/backup-replica` (the backup replica, its own PR from `main`).

## Purpose

victus is the operator's desktop (Arch Linux, gaming, dev). A k3s agent cannot join a Talos control plane,
and the operator wants the cluster side of victus managed from this repository, so:

- the victus HOST stays on Arch, outside the cluster, as a desktop. Its own Tailscale stays on the
  tailnet permanently (it is how the desktop reaches tailnet apps);
- a Talos WORKER named **mini03** runs as a libvirt/QEMU VM on that host and is the cluster node;
- mini03 runs three things and nothing else:
  1. the arr stack: Sonarr, Radarr, Prowlarr, and later Lidarr, Bazarr and a Jellyseerr-style
     request app;
  2. qBittorrent with a gluetun VPN sidecar in the same pod (kill switch: no traffic outside the
     VPN);
  3. a second copy of the backups (a MinIO fed from mini02's MinIO by a scheduled mirror).
- the 512 GB NVMe on victus holds all of it: the VM's OS and app data, the backup replica and the
  torrent staging area.

Torrent staging lives on mini03 only, never on mini02 or the `tank` pool. Finished media is imported
into the Jellyfin library on mini01 (the two Toshiba disks) over the network.

Proxmox was considered and rejected: it replaces the host OS, which ends the desktop. libvirt/QEMU on
the existing Arch install gives the same VM for about 1.5 GB less RAM.

Earlier revisions of this document said the 512 GB disk stays unused and victus hosts no backup
machinery. Both statements are reversed: the disk is the VM's storage, and victus holds the second
copy of the backups (the primary copy stays on mini02).

## What the repository manages

| Layer | Where it lives |
|---|---|
| The 512 GB disk (LVM) and the VM (CPU, RAM, disks, NIC, autostart) | `ansible/roles/victus_vm`, applied by the victus playbook, run by the operator with sudo |
| Talos in the VM: image, node config, volumes, labels, taint | `talos/schematics/mini03.yaml`, `talos/nodes/mini03.*`, `talos/patches/volumes-mini03.yaml`, applied by the Talos deploy workflow |
| Workloads on the node | Argo CD apps from this repository, pinned to mini03 by label and taint |
| Arch, the desktop, games, dev tools | not managed here; only the small host config of `ansible/roles/host_config_victus` |

## Host disk layout (the 512 GB NVMe)

The disk is a Samsung NVMe, serial kept in the vault (`vault_victus_vm_disk_serial`), currently `nvme0n1` and holding an old Debian LVM
(`vg0`) that the operator wipes himself before anything is built. The 1 TB OS disk is never touched.

**Recommendation: one host LVM volume group `victus512` on the whole disk, three logical volumes,
each handed to the VM as a raw virtio block disk.** (The alternative, three plain partitions,
works too.)

Why LVM and not partitions or image files:

- Raw block devices passed to the VM: no filesystem on the host between the guest and the disk, no
  qcow2 or sparse-file layers, the best I/O behaviour for a torrent workload (many small random
  writes) and for MinIO.
- The guest cannot grow beyond its volume, so a runaway torrent client can only fill its own
  staging volume and never the VM's OS disk or the backups. That isolation is the main reason for
  three separate disks instead of one big one.
- LVM keeps about 1.9 GiB unallocated for a later `lvextend` (and metadata, alignment), and lets a
  volume be snapshotted or moved with the host tools. Partitions cannot do either.
- The cost is one more layer on the host (lvm2) and that the host must never mount or scan the
  volumes: they hold only guest filesystems and no host LVM, and the role asserts nothing on the
  disk is mounted.

Talos installs to disk 1 (`vda`). Disks 2 and 3 are not installed to: they become Talos
`UserVolumeConfig` xfs volumes, mounted by the guest under `/var/mnt` (`backups` and `staging`).

### The numbers (exact)

The disk is 476.9 GiB (512 GB decimal, 512,110,190,592 bytes = 488,386 MiB).

| Volume | Size | Guest disk | In the guest |
|---|---|---|---|
| `mini03-os` | 64 GiB | `vda` (install disk) | Talos system, EPHEMERAL (containerd images, logs) capped at 24 GiB, and the `data` volume (about 33 GiB) at `/var/mnt/data` for the local-path PVCs: the arr config |
| `mini03-backups` | 128 GiB | `vdb` | xfs volume `backups` at `/var/mnt/backups`: the MinIO replica |
| `mini03-staging` | 283 GiB | `vdc` | xfs volume `staging` at `/var/mnt/staging`: torrent downloads |

Arithmetic:

- 64 + 128 = 192 GiB for OS and backups; 476.9 - 192 = 284.9 GiB remain.
- The GPT takes 1 MiB at each end and LVM aligns to 4 MiB extents, so the physical volume has about
  488,380 MiB (476.9 GiB) usable.
- Staging is 283 GiB (289,792 MiB). Total allocated 65,536 + 131,072 + 289,792 = 486,400 MiB.
- 488,380 - 486,400 = 1,980 MiB, about 1.9 GiB, stays free in the volume group.
- In decimal units: 64 GiB = 68.7 GB, 128 GiB = 137.4 GB, 283 GiB = 303.9 GB.

The Talos config selects the data disks by size band (`talos/patches/volumes-mini03.yaml`): the
install disk is "smaller than 100 GB" (only `vda`), backups is 130 to 145 GB (only `vdb`), staging
is 290 to 320 GB (only `vdc`). The libvirt domain also sets the disk serials `mini03-os`,
`mini03-backups` and `mini03-staging`.

A volume cannot shrink (xfs), so these sizes are a decision, not a default. The free 1.9 GiB is
the only room to grow either data volume without a bigger disk.

## VM sizing

Proposal: **4 vCPU / 8 GiB RAM** (`victus_vm_vcpus`, `victus_vm_memory_mib`, adjustable). victus has 8
cores / 16 threads and 30 GiB RAM; measured idle on 2026-10-15: 2.7 GB used, load about 0.02.

- Talos worker idle is about 1 GB; Sonarr, Radarr and Prowlarr about 300 MB each; qBittorrent plus
  gluetun about 1 GB under load (more with a big torrent list); MinIO about 300 MB plus page cache.
  Estimated 3 to 4 GB in use, so 8 GiB leaves room for page cache, which is what makes torrent and
  MinIO I/O fast. If the node shows plenty of free memory after the first week, 6 GiB is enough.
- The VM yields to the desktop: `machine.slice` has CPU weight 25 against the user session's 100, so
  a game wins any CPU contention. No GPU is passed through; the host keeps both.
- Total taken from the desktop: 8 GiB of 30 and at most 4 of 16 threads, mostly idle.

## Networking: macvtap (direct), not a bridge

Options on the wired port `eno1`:

| | Host bridge `br0` on eno1 | macvtap (`type=direct`, mode bridge) |
|---|---|---|
| Changes host networking | Yes: eno1 becomes a bridge port, the host's address moves to `br0` | No. eno1, its address, routes and Tailscale are untouched |
| Risk when done over SSH | A mistake or a race at `networkctl reload` drops the host off the LAN and off the tailnet (Tailscale's LAN path goes through the same NIC); recovery needs a keyboard | None for the host: the VM gets its own MAC on the wire next to the host |
| VM reachable from the LAN and tailnet | Yes | Yes |
| Host reachable from the VM, VM from the host | Yes | **No**: macvtap blocks host-to-guest traffic over the same NIC |
| Works on Wi-Fi | No (also needs Ethernet) | No (also needs Ethernet) |

**Choice: macvtap.** the operator is on SSH and the tailnet to victus, and bridging a NIC remotely is the
one thing here that can cut that off. With macvtap nothing on the host changes, so it cannot. The
price is that victus itself cannot talk to mini03 over `eno1`. What that affects:

- The operator's desktop reaching an arr UI by mini03's address on the LAN: use the tailnet or the cluster
  ingress instead. Both work, because the traffic comes from another machine or from the tailnet
  interface.
- The host's Tailscale trying a direct LAN path to the VM's own Tailscale: it will fall back to a
  relayed path. Slower but working. If that ever matters, a host-side `macvlan` shim interface fixes
  it later; that is a host network change and out of scope here.
- libvirt host tooling (virsh console, the guest agent channel) is unaffected: it does not use the
  network.

`victus_vm_network_mode` keeps `bridge` (an existing bridge only, never created by the role) and `nat`
as options. NAT is not recommended: the control plane cannot reach a NATed node inbound.

The VM gets a MAC from the vault (`vault_victus_vm_mac`, never committed) and a DHCP reservation in
the router, as the other nodes do. Talos's cluster endpoint is the short name `mini01`
(`talos/cluster.env`): it must resolve from the VM through the router's DHCP DNS. Prove that before
P2; if it does not, put the address in the untracked `talos/local/cluster.local.env`.

## How the guest joins the cluster

1. Schematic `mini03`: `siderolabs/qemu-guest-agent` (libvirt shuts the VM down cleanly) and
   `siderolabs/tailscale`. The id and ISO hash are pinned in `talos/versions.env`
   (`SCHEMATIC_MINI03_ID`, `ASSET_MINI03_ISO_SHA256`); the pins are unchanged from the
   earlier victus-vm schematic because its content is identical.
2. Fetch the ISO with `talos/fetch-assets.sh mini03 iso`, set `victus_vm_install_iso` and start the VM.
   It boots into Talos maintenance mode.
3. `render.sh mini03` builds the worker config from the committed patches and the secrets bundle
   (`talos/CUTOVER.md` describes the sops flow); `talosctl apply-config --insecure` sends it to the
   VM's reserved address. The control-plane endpoint is `https://mini01:6443`. The config installs
   Talos to `vda` (`UnattendedInstallConfig`, size ceiling 100 GB) and creates the `data`, `backups`
   and `staging` volumes.
4. Add `mini03` to the Talos deploy `TALOS_NODES` variable after the control plane
   (`docs/dr/talos-deploy.md`). It is a worker only: no etcd.
5. Tailscale needs `secrets/tailscale-mini03.sops.yaml` (an auth key, made by the operator), as for the other
   nodes. The tailnet name is never committed.
6. Check the node's InternalIP is its LAN address, not the Tailscale one (`kubectl get node mini03 -o
   wide`); flannel needs the LAN path to mini01.

### Scheduling policy: label and taint

`talos/nodes/mini03.yaml` gives the node:

- label `node-role.homeserver/tier=mobile` and label `node-role.homeserver/pool=media-backup`;
- taint `node-role.homeserver/tier=mobile:NoSchedule`.

Only the pods listed above carry `nodeSelector: kubernetes.io/hostname: mini03` plus a toleration
for that taint. The mini02-style `node.kubernetes.io/unschedulable` toleration is not needed: mini02
is cordoned, mini03 is tainted, and a taint is the right tool for a node that should accept a defined
set of workloads. DaemonSets that must run there (Velero node agent, csi-driver-smb node plugin,
tailscale proxies) tolerate the taint explicitly; see below.

### Velero node agent on mini03

Velero backs up pod volumes through its node-agent DaemonSet, which runs on every node
(`talos/values/velero.yaml` pins only the server to mini02). mini03's volumes (arr config on
`data`) are backed up like any other, so the node agent must tolerate the taint:
add `nodeAgent.tolerations` with `node-role.homeserver/tier=mobile:NoSchedule` to the Velero values in a
later PR, once the node exists, and opt the arr config volumes in with the
`backup.velero.io/backup-volumes` annotation, as the other apps do. The torrent staging volume is NOT
backed up (it is disposable and large). The replica's own data is not backed up by Velero (it is
itself the backup).

## The second copy of the backups

Primary backup target: MinIO on mini02 over the ZFS dataset `tank/backups`
(`talos/manifests/backup-target`), buckets `velero-backups` (which already holds the Immich library
through Velero's file-system backup of the `immich-server` volume `data`), `litestream` and
`immich-pg`, each with its scoped user.

**Design: a MinIO on mini03 over the `backups` volume plus a scheduled `mc mirror` CronJob from
mini02's MinIO.** Manifests are in `talos/manifests/backup-replica` (own PR, not deployed until the node
exists):

- `Deployment/minio-replica` in namespace `velero`, pinned to mini03, hostPath
  `/var/mnt/backups`, same Chainguard image pin as the primary. Service `velero-backup-replica`.
- `CronJob/backup-replica-mirror`, daily, pinned to mini03: for each of the three buckets runs
  `mc mirror --remove --overwrite SOURCE/bucket REPLICA/bucket`, but first checks the replica's size
  against a budget and refuses to run (non-zero exit, so the failure is visible) when the replica
  is over 80% of the volume.
- Scoped users, the same pattern as the rest of the backup tooling (see `talos/dr/minio/setup-users.sh`):
  a **read-only** user on mini02's MinIO for the three buckets (the mirror can never delete or alter the
  primary), and a read-write user on the replica for the same three buckets. The replica's root pair is
  sealed too. All four credentials are sealed secrets that the operator creates; the manifests only name them
  (see `talos/manifests/backup-replica/README.md`). Plaintext never touches the repository.

The mirror runs at 13:00 UTC, after the 10:00 UTC `homeserver-nightly` Velero schedule and the 02:30
Postgres base backup. `--remove` keeps the replica equal to the primary, including Velero's own
deletions at TTL expiry, so retention is whatever the primary retains. A replica that deletes what
the primary deletes does not protect against a mistaken deletion on the primary for longer than one
day. If that matters, drop `--remove` (the replica then grows without bound; see the sizing).

### Size math: does it fit 128 GiB (137 GB)?

| | Size | Note |
|---|---|---|
| `velero-backups` today | about 55 GB | measured: the nightly carries about 55 GB for `immich-server` `data`, i.e. the whole library, plus small volumes |
| `litestream` | under 1 GB | the Vaultwarden SQLite replica |
| `immich-pg` | about 2 to 5 GB | WAL archive plus a base backup retained 14 days (estimate; check `mc du`) |
| Total today | about 60 GB | 44% of 137 GB |

- Velero keeps a deduplicating Kopia repository: a nightly backup of an append-mostly photo library
  adds only the new and changed blobs, so 30 days of retention (TTL `720h`) cost the changed data,
  not 30 copies. The replica mirrors the repository as it is.
- Growth is dominated by new photos. At an assumed 3 GB a month the replica reaches 80% (about 110
  GB, so 50 GB above today) in about 16 months; at 6 GB a month, about 8 months. Measure the real
  rate from the first three months of `mc du` readings before trusting either number.
- Mirror overwrite churn is transient: objects are written whole, so allow a few GB above the steady
  size while a run is in flight.

**When it needs attention:**

- 80% of the volume (about 110 GB, 102 GiB): the mirror job exits non-zero before copying and the failed
  Job is the alert. Decide then: prune old Velero backups and the `immich-pg` retention on the primary,
  stop mirroring a bucket that is no longer worth a second copy, or move the replica to a bigger disk.
- 90% (about 123 GB): treat as an incident; MinIO and xfs degrade near full.
- Growing the volume is not a real remedy on this disk: only about 1.9 GiB is free in the volume group
  and xfs cannot shrink the staging volume. The honest answers are pruning or a bigger disk.

### Restore from the replica

Losing mini02 (or the `tank` pool) must not mean losing the backups.

1. Run Velero against the replica: add a second `BackupStorageLocation` named `replica`
   (`s3Url` = `http://velero-backup-replica.velero.svc.cluster.local:9000`, the replica's scoped `velero`
   credentials) and `velero backup get` syncs the backups from the replica's bucket. If mini02 itself is
   gone and Velero's server ran there, reinstall Velero on mini01 or mini03 pointing at the replica, then
   `velero restore create --from-backup NAME` (the drill script `talos/dr/velero-restore-drill.sh`
   restores into a scratch namespace first).
2. For the databases: Vaultwarden restores from the `litestream` bucket (init container) and Postgres
   from the `immich-pg` WAL archive; point those at the replica's service name and its credentials.
3. If MinIO on mini03 is also lost with the host, the data directory `/var/mnt/backups` is a plain MinIO
   directory on the `mini03-backups` volume: attach the LV to any MinIO and it serves the same
   buckets.
4. Rebuilding mini02's primary from the replica is the reverse mirror: `mc mirror REPLICA/bucket
   PRIMARY/bucket` using the replica's read user and the primary's write user.

### Restore drill from the replica

`talos/dr/replica-restore-drill.sh` proves the replica is usable without touching production. Run it from
the repository root with the cluster reachable (needs `kubectl`, `mc`, `curl`):

```
bash talos/dr/replica-restore-drill.sh --check                       # looks only
bash talos/dr/replica-restore-drill.sh --live admin@<cluster>       # the drill
```

It does two things. (A) Compares each replica bucket with the primary (objects and bytes; the replica may
trail by 10% because the mirror runs once a day) and checks every Velero backup older than 26 hours is on the
replica. (B) Restores the Vaultwarden database from the replica's `litestream` bucket into an empty volume in
a scratch namespace `replica-drill` (on mini03), runs `PRAGMA integrity_check` and counts the tables. It
prints `DRILL PASS` or `DRILL FAIL`, then deletes the scratch namespace. The primary is only read.

It does not run `velero restore` from the replica: the replica holds backups with the same names as the
primary, so Velero would skip them and the restore would read the primary. A full Velero restore from the
replica is only meaningful when the primary is gone (step 1 above).

## gluetun and qBittorrent on Talos

The qBittorrent pod has two containers in one pod: `gluetun` (the VPN client and firewall) and
`qbittorrent`. They share the pod's network namespace, so qBittorrent sees only gluetun's tunnel.

### `/dev/net/tun` (early proof of concept, P4 step 1)

gluetun needs a tun device and `NET_ADMIN`. The facts to verify first, on the real node:

- Talos's kernel has TUN built in (the Tailscale extension depends on it), so the device node should
  exist on the host. **Not yet checked:** whether `/dev/net/tun` appears in the host's `/dev`
  (a one-line `talosctl ls /dev/net` shows it).
- A normal pod does not get it: containerd's default device list has no tun and the device cgroup
  would deny it. Two ways to give it to one pod:
  1. A **privileged** gluetun container, or one with `NET_ADMIN` plus a `hostPath` volume of type
     `CharDevice` on `/dev/net/tun`. Simplest, and needs the namespace labelled
     `pod-security.kubernetes.io/enforce: privileged` (Talos enforces baseline cluster-wide, which forbids
     both privileged and `NET_ADMIN`). Put qBittorrent and gluetun alone in their own namespace `torrent` with that label (like `velero`
     and `tailscale` have), and keep the arr apps in `arr` at the default baseline level. The blast radius
     is then the one pod.
  2. A **device plugin** (for example squat's generic-device-plugin exposing `squat.ai/tun`): the pod
     asks for the resource and gets the device, with only `NET_ADMIN` added. Tighter, at the cost of one
     more DaemonSet that must tolerate the mini03 taint.
  Start with option 1 to prove the path works; move to option 2 only if the privileged label bothers you.
- Also verify the netfilter modules gluetun's iptables needs (the cluster CNI already uses
  netfilter, so they are likely present) and that its image's `iptables` works against Talos's kernel.

If neither works on Talos, the fallback is a VPN-routing pod network (a Tailscale exit node or a router-level VPN
for the VM's address) at the cost of the in-pod kill switch. That is a design change, not a tuning, and is
why this is the first step of P4.

### Kill switch and firewall

- gluetun's own firewall is on (`FIREWALL=on`, the default): everything not through the tunnel is dropped,
  except the pod's own cluster traffic allowed explicitly with `FIREWALL_OUTBOUND_SUBNETS` (the
  pod and service CIDRs, so the arr apps can reach the qBittorrent web UI and Prowlarr can reach the
  indexers through their own path) and `FIREWALL_INPUT_PORTS` for the web UI port only.
- Defence in depth: qBittorrent is bound to the tunnel interface (`Network Interface = tun0`), so it
  cannot send on another interface even if the firewall were off.
- A `NetworkPolicy` for the pod: egress only to the cluster and to the VPN endpoint's address, ingress only from the arr
  pods. (Only effective if the CNI enforces NetworkPolicy; check with the cluster's CNI.)
- DNS comes from gluetun (DNS over TLS inside the tunnel), not the node's resolver.
- Verification (P4): from the qBittorrent container `curl` the public address through the tunnel and confirm it is the VPN's; then
  stop the gluetun tunnel (kill its VPN process or block the endpoint) and confirm qBittorrent
  gets no connectivity at all (no fallback to the home address).
- Forwarded port: gluetun can request one from providers that support it; qBittorrent's listening port is updated
  from it by a small `VPN_PORT_FORWARDING_UP_COMMAND` hook. Provider-dependent.

### VPN credentials

The provider is **not decided yet**. gluetun supports the major ones (OpenVPN or WireGuard); the pod reads
the credentials from a sealed secret `gluetun-vpn` in the `torrent` namespace that the operator creates, with these
placeholder keys: `VPN_SERVICE_PROVIDER`, `VPN_TYPE`, and for WireGuard `WIREGUARD_PRIVATE_KEY` and
`WIREGUARD_ADDRESSES` (or for OpenVPN `OPENVPN_USER` and `OPENVPN_PASSWORD`), plus `SERVER_COUNTRIES`.
Nothing real is committed; neither the provider name nor any account detail belongs in this repository.

## The arr stack: placement and storage

- Sonarr, Radarr, Prowlarr (and later Lidarr, Bazarr, a Jellyseerr-style app) run as ordinary Deployments in
  namespace `arr` (baseline pod security, no privileges, no hostPath), pinned to mini03 with the toleration.
  qBittorrent and gluetun run in namespace `torrent`.
- **Config volumes** (the SQLite databases): PVCs from the existing `topolvm-fast` class, which is
  `rancher.io/local-path` here and stores under `/var/mnt/data/local-path` on whichever node the pod is on. On
  mini03 that is the `data` volume on the 64 GiB OS disk. They are opted into Velero's file-system backup, so
  they land on mini02's MinIO and on the replica. They are small (hundreds of MB).
- **Downloads**: the `staging` volume. Pods in two namespaces share the one volume, and a PVC is namespaced, so
  there are two local PersistentVolumes (`local` volume type on `/var/mnt/staging`, node-affine to mini03,
  one per namespace, each on a subdirectory) or, simpler, the arr apps and qBittorrent in one namespace if
  the privileged label is acceptable for all of them. Either way every application sees the same path
  (`/downloads`), so remote path mapping is not needed. To settle in P4.
- **Import path to the Jellyfin library on mini01**: see below.

### Importing into the Jellyfin library on mini01 (SMB)

The Jellyfin library is on mini01's two Toshiba disks (hostPaths `/var/mnt/media` and `/var/mnt/media2`; the
move there is being done separately and is not touched here). mini03 is a different machine, so Sonarr and
Radarr import over the network.

**Simplest option, recommended: SMB, reusing the pattern already in the cluster.** A small Samba pod on
mini01 exports `/var/mnt/media` and `/var/mnt/media2` (same image pin as `talos/manifests/samba-nas`, hostPath
volumes, in a namespace labelled privileged like `nas`), with one account, read-write only for the arr import user. The arr pods mount
the shares through `csi-driver-smb` (already installed, plugin on every node; its node plugin must
tolerate the mini03 taint), as PersistentVolumes and PVCs like `immich-library-smb`. Jellyfin keeps its
hostPath mounts read-only; only the arr apps can write through SMB.

Alternatives, for the record: NFS (needs an NFS server pod and kernel server support that has not been checked on
Talos), or running Sonarr and Radarr on mini01 next to the library (against the decision). SMB needs nothing
new. **The operator to confirm the import path choice.**

### No hardlinks: the space consequence

Radarr and Sonarr normally import a finished torrent by **hardlinking** it into the library, so the file exists
once on disk while it seeds. A hardlink cannot cross filesystems, let alone machines: staging is on mini03's
`staging` volume, the library is on mini01's disks. So every import is a **copy**, and
the file exists twice until the torrent is removed from staging:

- once in `staging` (still seeding, or waiting to be cleaned up) and once in the library;
- the library is on 2 x 320 GB disks, so media is written there exactly once per import (the copy), never twice;
- staging holds only what is still seeding or not yet imported: set a seeding limit in qBittorrent (for example
  ratio 1.0 or 7 days, then **delete the files**), and Sonarr/Radarr's "remove completed" so the staging volume
  does not keep every file forever;
- budget: the 283 GiB staging volume is the working set of simultaneous downloads plus the seeding tail.
  At a typical season of 20 to 40 GB and a movie of 5 to 20 GB, about ten to twenty items fit at once. Keep a
  qBittorrent "free space" pause threshold at about 20 GiB so a full volume pauses the client instead of
  breaking imports;
- the import itself is a network copy (SMB over the LAN): it takes as long as the file size divided by the
  link, but nothing waits on it besides the arr app.

Torrenting is the source of the final media: the library on mini01 is what Jellyfin plays, and staging is
disposable.

## Desktop effects to accept

- The VM needs the machine awake and on AC; the role holds a sleep and lid-switch inhibitor while it runs. A
  suspended machine drops the node, and with it the arr stack, the torrents and the second backup copy.
- Rebooting victus into another OS takes the node offline.
- The VM's autostart brings it back after a host reboot; the guest agent shuts it down cleanly.
- Games and the desktop win CPU contention (weight 25), so torrent hashing slows while you play. That is
  intended.

## Phased plan

Each phase has a check and a way back. Nothing below runs before gate G2.

### P0. Prerequisites (before anything on victus is built)

1. The Jellyfin move to mini01's Toshiba disks is finished and checked (separate work, not touched here).
2. **Interim second copy** of the backups and the library on victus's `/home` (about 473 GB free), taken
   while the 512 GB disk is still full of Debian: `mc mirror` of the three buckets from mini02's MinIO to a
   directory under `/home`, and a plain read-only copy of the Immich library from its share (about 55 GB).
   About 60 GB for the buckets plus about 55 GB for the plain copy, so under 120 GB of the 473 GB.
   This copy is the safety net while the disks are rebuilt, and stays until P3 is verified.
3. The operator wipes the 512 GB disk by hand (steps in `ansible/README.md`, "Wipe the 512 GB disk"): this is the
   only point of no return, and it happens after step 2 is verified.
- Verify: the interim copy's object count and total size match the source (`mc du`, `mc diff`); the library
  copy's file count and size match.
- Rollback: none needed before the wipe; the old disk is untouched until the operator wipes it.

### P1. Host (libvirt, volumes, VM definition)

Run by the operator with sudo, `ansible-playbook victus.yml --check --diff` first, then for real with
`victus_vm_enabled: true` and, for this run only, `victus_vm_disk_provision: true` (set back to false
afterwards). The role installs libvirt/QEMU/OVMF/lvm2, builds the volume group and three volumes on the blank
disk (refusing anything else), and defines the domain `mini03` without starting it.
- Verify: `lsblk` shows the three volumes, `vgs victus512` shows 1.9 GiB free, `virsh -c qemu:///system dominfo
  mini03` shows a defined, shut-off domain; the host's SSH and tailnet access never blinked (the role changed no
  networking). A second run changes nothing (idempotence).
- Rollback: `virsh undefine mini03`, then `lvremove` and `vgremove victus512` by hand (this destroys only the
  new, empty volumes). Set `victus_vm_enabled` back to false.

### P2. Talos node join

Fetch the ISO, set `victus_vm_install_iso`, set `victus_vm_start: true` for one run (or
`virsh start mini03`), render and apply `mini03`, add it to `TALOS_NODES`.
- Verify: `kubectl get node mini03` is Ready with the label and taint; `talosctl get volumestatus` on the node
  shows `data`, `backups` and `staging` mounted; the InternalIP is the LAN address; the cluster still sees mini01
  and mini02 unchanged.
- Rollback: `kubectl drain mini03 --ignore-daemonsets && kubectl delete node mini03`, `virsh destroy mini03`;
  mini01 and mini02 are unaffected because a worker is never part of etcd.

### P3. Backup replica

Sync the `backup-replica` app after the operator has created the scoped users and sealed the four credentials
(`talos/manifests/backup-replica/README.md`). Run the mirror once by hand
(`kubectl -n velero create job --from=cronjob/backup-replica-mirror first-mirror`).
- Verify: `mc du` of each replica bucket matches the primary's; run `talos/dr/velero-restore-drill.sh` against
  the replica location into a scratch namespace; the job's size check reports under 80%. Only then delete the
  interim copy on victus `/home` from P0.
- Rollback: delete the CronJob and the Deployment (the primary is untouched, the mirror only reads it); the
  interim copy from P0 is still there until this phase is verified.

### P4. arr stack and gluetun

Order: (1) the tun proof of concept (a throwaway pod on mini03 that opens `/dev/net/tun`); (2) gluetun plus
qBittorrent, with the kill-switch tests above; (3) Prowlarr, Sonarr, Radarr, then the later apps. Config on the
OS volume, downloads on staging.
- Verify: the public address from the qBittorrent pod is the VPN's; the kill-switch test (tunnel down means no
  traffic) passes; the arr apps reach qBittorrent and Prowlarr; a test torrent of a public-domain file
  downloads into staging.
- Rollback: delete the `arr` namespace's apps (their config PVCs hold nothing irreplaceable; Velero has them);
  mini03 keeps serving the backup replica.

### P5. Import path and the Jellyfin library

Deploy the Samba pod on mini01 for the two library disks, the SMB PVs on mini03, and the arr root folders. Import one
item end to end.
- Verify: an import produces the file in the library through SMB with the right owner; Jellyfin sees and plays it
  after a library scan; staging is cleaned when the seeding limit is reached; the read-write account cannot be used
  from outside the arr pods.
- Rollback: remove the Samba app and the SMB volumes; imported files stay in the library (it is just files on the
  Toshiba disks). Jellyfin is unaffected, because it never depended on SMB.

## Unresolved, needs the operator

- **VPN provider** and its credentials (sealed secret `gluetun-vpn`, placeholders only).
- **Import path**: SMB (recommended) vs NFS vs moving the arr apps to mini01.
- **Networking**: macvtap (recommended, host cannot reach the VM over `eno1`) vs bridging `eno1`.
- Whether the mirror should delete on the replica what the primary deletes (`--remove`, as proposed), or keep
  everything and grow.
- The VM's MAC and the router reservation; the short-name resolution of `mini01` from the VM.

## Unrun

Everything. No VM has been defined, no disk touched, no gluetun test done. What was checked offline:
`render.sh mini03 --ci` and `talosctl validate --mode metal` pass (talosctl v1.14.2), renders are deterministic, the
domain XML renders for the three network modes and is well-formed, and the disk-state decision of the Ansible role
passes its 12 offline scenarios. Not tested: that Talos's disk selector matches the real virtio disks as intended,
booting the VM, joining the cluster, the taint behaviour, `/dev/net/tun` in a pod, and anything about the backup
replica.
