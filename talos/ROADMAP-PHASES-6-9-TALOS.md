# Phases 6 to 9 under Talos (plan 15-05 Task 3)

Replacement text for `### Phase 6` .. `### Phase 9` and their checklist lines in
`.planning/ROADMAP.md` on the plan branch (`plan-golden-image`, the 9-phase
numbering). It is kept here as a file because this branch is based on `main`,
whose ROADMAP still carries the older 6-phase numbering; apply it to ROADMAP.md
when this work is rebased onto the plan branch, then delete this file. Goals are
unchanged; where they run and how they are built changes.

Decided 2026-10-12 (the operator): Talos on mini01 and mini02, mini01 is the single
control plane, mini02 a worker, and the victus HOST stays Arch and is not a
cluster member.

Amended 2026-10-15 (the operator): victus also runs a Talos worker, **mini03**, as a libvirt/QEMU VM
on that Arch host, after gate G2 (see `docs/dr/mini03.md`). The host stays out
of the cluster; the VM is the cluster node and carries the arr stack, the torrent client behind a VPN
and a second copy of the backups.

## Checklist lines

- [ ] **Phase 6: mini02 and storage tiers (Talos)** - mini02 joins as a Talos worker, ZFS mirror (or the recorded fallback), MinIO + second Velero location, Samba pod, SMB CSI (or the recorded CIFS fallback), Immich originals moved after the restore test, first disk-loss drill
- [ ] **Phase 6b: mini03, the victus worker VM (Talos in libvirt)** - a Talos worker VM on the victus host after G2, repo-managed node config and domain definition, the 512 GB disk provisioned by a role that stays off until the operator wipes it (64 GiB OS, 128 GiB backup replica, 283 GiB torrent staging), arr stack, qBittorrent behind a VPN and the backup replica scheduled on it (see `docs/dr/mini03.md`)
- [ ] **Phase 7: Observability** - Prometheus on the mini02 worker, Grafana on mini01; the kiosk display needs a separate device (no desktop on Talos)
- [ ] **Phase 8: HA control plane (three control-plane nodes)** - needs a third control-plane machine; mini01 alone until then
- [ ] **Phase 9: Stateful failover** - CNPG replica on mini02, second CoreDNS, reschedulable apps; needs Phase 8 for automatic API-level failover

## Phase 6: mini02 and storage tiers (Talos)

**Goal**: mini02 is a Talos worker holding the irreplaceable data on mirrored storage and a second backup copy, built entirely from the repo.
**Depends on**: gate G2 (mini01 running on Talos); plan 15-05 decision recorded in `talos/STORAGE-DECISION.md`
**Success Criteria** (what must be TRUE):
  1. Both 1 TB drives burned in; mini02 booted from the Image Factory ISO of `talos/schematics/mini02.yaml`, joined as a labelled, tainted worker from `talos/` machine config (no hand-built RAID, no Ansible).
  2. The pool exists as decided: ZFS mirror `tank` (option 1), or one UserVolume plus a scheduled second copy (option 2) if the CI proof failed.
  3. MinIO on mini02 plus a second Velero location; a restore test from mini02 alone passes.
  4. Samba runs as a pod (`talos/manifests/samba-nas`) with per-app shares; SMB CSI works, or the recorded fallback is in place when the kernel lacks CIFS.
  5. Music share (Jellyfin read-only, Lidarr write) live; Paperless originals moved; Immich originals moved only after the restore test passes.
  6. First disk-loss drill done: pull one mirror disk, read the data, put it back, resilver.

## Phase 7: Observability

**Goal**: Cluster and node metrics are collected and viewable.
**Depends on**: Phase 6
**Success Criteria** (what must be TRUE):
  1. Prometheus on the mini02 worker, Grafana on mini01 (anonymous read-only, tailnet only).
  2. The dashboard is viewable from another device. The mini01 kiosk is dropped: Talos has no desktop, so a kiosk would be a separate small machine. Open item.

## Phase 8: HA control plane (three control-plane nodes)

**Goal**: The control plane survives losing any one node.
**Depends on**: Phase 6; a third control-plane machine (a small PC, or a Raspberry Pi with an SSD running Talos).
**Why three nodes**: etcd needs a majority. Two members tolerate zero failures: losing either one stops writes. So making mini02 a second control plane makes the cluster LESS available than one control plane. A third member is required. victus stays on Arch and is not a member. Until Phase 8, the control plane is mini01 alone, and `talosctl etcd snapshot` plus the restore drill (plan 15-06) is the recovery path.
**Success Criteria** (what must be TRUE):
  1. Three Talos control-plane nodes (mini01, mini02 and the third machine) form an etcd quorum.
  2. Losing any one of them leaves the API available; proven by a drill.

## Phase 9: Stateful failover

**Goal**: Immich and Vaultwarden can fail over to mini02.
**Depends on**: Phase 8 for automatic API-level failover. Interim, with one control plane: a CNPG replica on the mini02 worker already works (it is a data replica, not a control-plane member) and promotion works while the API is up.
**Success Criteria** (what must be TRUE):
  1. CNPG Postgres for Immich with `instances: 2` (primary mini01, replica mini02), automatic failover; VectorChord image verified on mini02's CPU (AVX2).
  2. Second CoreDNS replica on mini02 and Tailscale ingress proxies able to run there.
  3. Immich and Vaultwarden can reschedule to mini02; Jellyfin stays pinned to mini01 (Quick Sync).
