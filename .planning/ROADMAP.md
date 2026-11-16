# Roadmap: Homelab

## Overview
Make the homelab rebuildable and growing: a golden image so any Debian node stands up fast, then the service build-out on mini01/victus, then mini02 as the storage backend, then an HA control plane. This file is the single roadmap; it absorbs the old "Build order" (docs/homelab-brief.md section 6) and the old "Roadmap" (a plan doc since removed). Architecture and ground rules stay in docs/homelab-brief.md.

Rules: each step is its own PR from a fresh branch off `origin/main`; never merged without the operator's sign-off.

## Phases

- [ ] **Phase 1: Bare metal to mini01** - encrypted preseed install (Ventoy), CI proof, Ansible bare-node fixes, DR fixes (CNPG operator, Postgres backup, Sealed Secrets key, Velero), runbook and a coverage ledger proving nothing on mini01 is uncovered
- [ ] **Phase 1.1 (INSERTED): MagicDNS instead of a hard-coded Tailscale IP** - `tls-san`, `ansible_host`, victus join; own spec at `phases/01.1-magicdns-tls-san/01.1-SPEC.md`
- [ ] **Phase 2: Services on current hardware** - Jellyfin, download stack, Immich ML, Uptime Kuma, Actual/AdGuard, Paperless (no mini02 needed)
- [ ] **Phase 3: mini02 and storage tiers** - mini02 joins; MinIO + second Velero location, Samba shares, SMB CSI, music, Immich originals, RAID drill
- [ ] **Phase 4: Observability** - Prometheus on mini02, Grafana on mini01, then the kiosk
- [ ] **Phase 5: HA control plane** - SSD in mini02, SQLite to embedded etcd, three servers
- [ ] **Phase 6: Stateful failover** - CNPG Postgres replica on mini02, second CoreDNS, reschedulable apps

Already done (old build order steps 1-3 and parts of 4): baseline recorded; mini01 k3s v1.36.4; `cp-reserva-bot` Velero schedule; Vaultwarden and Immich volume backups; Toshiba media disk provisioned by Ansible and mounted at `/srv/media`; Phase 0 bench work (drive tests) for the Toshiba.

## Phase Details

### Phase 1: Bare metal to mini01
**Goal**: A bare UEFI machine becomes a faithful mini01 from this repo: encrypted preseed install, bare-node-ready Ansible, rebuildable GitOps with proven-restorable backups, and a coverage ledger with zero uncovered items. The real disk swap is performed later on request. See `phases/01-golden-image/01-SPEC.md`.
**Depends on**: Nothing (first phase)
**Requirements**: IMG-01, IMG-02, IMG-03, IMG-04, IMG-05, IMG-06
**Success Criteria** (what must be TRUE):
  1. CI installs the preseed in QEMU (disk, passphrase, password injected at run time), reaches the LUKS unlock prompt, unlocks over SSH, and a negative control fails.
  2. The same preseed reinstalls over an existing LUKS disk and an existing plain-LVM `vg0` disk.
  3. Ansible runs against the built VM twice (second run `changed=0`), and every `ansible/**` change is a proven no-op on live mini01.
  4. The CNPG operator is declared, Immich Postgres is backed up with a working scratch restore, the Sealed Secrets key restore is verified, and a Vaultwarden Velero restore drill has completed.
  5. `docs/rebuild-node.md` and `docs/mini01-coverage.md` exist; the ledger check finds no UNCOVERED rows.
  6. No secret or host detail exists in the repo, CI logs or artifacts.
**Plans**: TBD

### Phase 1.1 (INSERTED): MagicDNS instead of a hard-coded Tailscale IP
**Goal**: mini01's control-plane address is a name, not the literal IP: `tls-san` accepts the MagicDNS name, and `ansible_host`, kubeconfig and the victus join use it, so a rebuilt node with a new Tailscale IP keeps working. See `phases/01.1-magicdns-tls-san/01.1-SPEC.md`.
**Depends on**: Phase 1
**Requirements**: TBD
**Success Criteria** (what must be TRUE):
  1. The certificate SAN lists the IP and the name; no literal IP remains in `ansible/`.
  2. `control-node.yml`, `argocd-bootstrap.yml` and the victus agent work through the name.
**Plans**: TBD

### Phase 2: Services on current hardware
**Goal**: The user-facing services that do not need mini02 are running from the repo.
**Depends on**: Nothing (can run in parallel with Phase 1)
**Requirements**: TBD
**Success Criteria** (what must be TRUE):
  1. Jellyfin on mini01 with Quick Sync serves movies from the Toshiba; Plex retired.
  2. victus download stack (qBittorrent + gluetun, Prowlarr, Sonarr, Radarr, Lidarr) is in the repo with a `tier=mobile` toleration.
  3. Immich ML runs on the victus GPU; Uptime Kuma on victus with external alerting.
  4. Actual Budget, AdGuard Home and Paperless-ngx are deployed and covered by a Velero schedule.
**Plans**: TBD
Open decisions first: how victus *arr apps write to mini01's Toshiba (Samba `media` share vs run Sonarr/Radarr on mini01); VPN provider (ProtonVPN vs Mullvad).

### Phase 3: mini02 and storage tiers
**Goal**: mini02 is a tainted storage-backend node holding the irreplaceable data and a second backup copy.
**Depends on**: mini02 hardware ready (caddy, adapters); benefits from Phase 1
**Requirements**: TBD
**Success Criteria** (what must be TRUE):
  1. Both 1 TB drives burned in; mini02 installed (RAID1 + LVM by hand, asserted by Ansible), joined, tainted and labelled.
  2. MinIO on mini02 plus a second Velero location; a restore test from mini02 alone passes.
  3. Samba per-app shares, SMB CSI driver and SealedSecrets on mini01 working.
  4. Music share (Jellyfin read-only, Lidarr write) live; Paperless originals moved; Immich originals moved only after the restore test passes.
  5. First RAID rebuild drill done.
**Plans**: TBD

### Phase 4: Observability
**Goal**: Cluster and host metrics are collected and viewable, including on the kiosk monitor.
**Depends on**: Phase 3
**Requirements**: TBD
**Success Criteria** (what must be TRUE):
  1. Prometheus on mini02, Grafana on mini01 (anonymous read-only, tailnet only).
  2. Kiosk dashboard displays on mini01's monitor (untested on hardware).
**Plans**: TBD

### Phase 5: HA control plane
**Goal**: The control plane survives losing any one node.
**Depends on**: Phase 3; an SSD in mini02 (OS + etcd; mSATA slot or USB 3 SSD)
**Requirements**: TBD
**Success Criteria** (what must be TRUE):
  1. k3s converted from SQLite to embedded etcd (`--cluster-init`).
  2. Three servers (mini01, mini02, victus); caveat: victus is a laptop, so quorum needs both minis when it is away. A Raspberry Pi with an SSD is the cleaner long-term third member.
**Plans**: TBD

### Phase 6: Stateful failover
**Goal**: Immich and Vaultwarden can fail over to mini02.
**Depends on**: Phase 5
**Requirements**: TBD
**Success Criteria** (what must be TRUE):
  1. CNPG Postgres for Immich with `instances: 2` (primary mini01, replica mini02 SSD), automatic failover; VectorChord image verified on mini02's CPU (AVX2).
  2. Second CoreDNS replica on mini02 and Tailscale ingress proxies able to run there.
  3. Immich and Vaultwarden can reschedule to mini02; Jellyfin stays pinned to mini01 (Quick Sync).
**Plans**: TBD

## Backlog and open items (from the old plan)

Cross-cutting, not tied to a phase yet:
- Disaster recovery gaps: Immich Postgres backup (no CNPG backup, `immich-pg-1` has no Velero annotation); Sealed Secrets private key storage; Tailscale identity/IP hard-coded (<mini01-tailnet-ip>); CI runner registered by hand; k3s SQLite DB not backed up; Vaultwarden restore drill; clean up duplicate weekly Velero schedules.
- mini01 NVMe power-on enumeration problem: BIOS Fast Boot / POST delay, newer BIOS for D3403-U1x; test the 256 GB SN530 in mini01 over 10-15 restarts before any migration.
- UPS for mini01 and mini02 (protects the RAID, avoids triggering the NVMe problem); offsite backup copy.
- victus staging/backup volume layout and growing `lv-backup` (100 GB, the only off-machine copy of the photos).
- mini02 hardware: measure optical drive (9.5 mm?), slot-in vs tray, connector, pick caddy and cable (test with a 320 GB drive first); does the Q910 have an mSATA slot; optional 16 GB RAM; CPU upgrade only if needed (i5-3470T is the safe one).
- Open decisions: personal files on mini02 (frontend app vs one human Samba share); PS4 games share (check SMB version, isolate SMB1).
