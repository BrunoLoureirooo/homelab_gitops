# Homelab cluster: target shape and implementation brief

Written 2026-10-10. Audience: any agent (Claude Code, Cowork) working on the
homelab. Read this together with this repo (`main`): `docs/dr/mini02-talos.md` is
the detailed mini02 storage/hardware runbook and wins on hardware facts; this brief
wins on **service scope**, which was revised after the original storage plan was
written. The roadmap and build order live in `.planning/ROADMAP.md`.

## 1. Ground rules for agents

- **Learning is the priority.** Follow real-infrastructure patterns (storage
  tiers, capability-based placement, GitOps, restore drills) even where a
  homelab could cut corners.
- **Everything is declared in the repo.** Host state goes in Ansible, cluster
  workloads go in ArgoCD (app-of-apps under `argocd/apps/`). Nothing is
  hand-applied without being written back to git.
- **One PR per step, each from a fresh branch off `origin/main`. Never merge
  without the operator's sign-off.**
- The repo is **public**. Secrets are SealedSecrets (k8s) or Ansible Vault
  (`group_vars/all/vault.yml`). CI rejects raw `Secret` objects and
  unreviewed ArgoCD auto-sync; respect both guardrails.
- Prefer Helm charts (Immich and Vaultwarden use `bjw-s/app-template`) over raw
  manifests. PVCs, CNPG clusters and Ingresses stay raw on purpose.
- Every workload gets resource **requests and limits**. mini01's RAM is the
  binding constraint.
- Access is **Tailscale only**. No router port forwards, no public exposure.
  Ingress goes through the Tailscale operator.
- Bulk file traffic between machines uses the plain **LAN**, not Tailscale.

## 2. Machines and roles

| | mini01 | mini02 (not yet joined) | victus |
|---|---|---|---|
| Hardware | Fujitsu Q556/2, i5-6500 4c, **12 GB**, Intel HD 530 (Quick Sync) | Fujitsu Q910, i3-2120T 2c/4t, **8 GB** | HP Victus laptop, 16 cores, 32 GB, RTX 3050 Ti |
| OS | Debian 13 | Debian (to install) | Arch Linux |
| Disks | 477 GB NVMe (TopoLVM, fast tier); Toshiba 320 GB HDD for movies (pending burn-in; machine takes only **one** SATA drive) | 2× 1 TB 2.5" **SMR** in mdadm RAID1 (bought; waiting on optical-bay caddy and USB adapters) | 238 GB + 931 GB NVMe, LUKS + LVM |
| k3s role | **server / control plane** (SQLite today) | agent, tainted (opt-in only); becomes a server in Phase 2 | agent, tainted `tier=mobile` (live today) |
| Purpose | **processing**: all user-facing apps, control plane, ArgoCD and operators, kiosk monitor | **backend storage only**: Samba shares, MinIO, later Prometheus. No user-facing apps | **GPU and bursty work**: downloads/torrenting, *arr apps, Immich ML, second backup copy, Uptime Kuma. Portable, so not always present |

Notes:
- mini01 is the control plane and holds the kiosk monitor. Earlier
  conversation suggested mini02 for both; the repo and the plan say mini01,
  and that stands unless the operator says otherwise.
- mini04 (Debian 13) is a standalone display host outside the cluster: `cage` + Chromium kiosk via
  `ansible/mini04.yml` (`roles/kiosk`), no k3s.
- k3s version skew: victus runs v1.36.4 while mini01 runs v1.36.3. Agents must
  not be newer than the server, so bump mini01.
- mini01 has an unsolved NVMe enumeration problem at power-on (see the plan).
  Assume mini01 can be down for tens of minutes after a power cut.

Node labels (to add): `hardware/quicksync=true` (mini01), `hardware/gpu=nvidia`
(victus), `storage/raid=true` (mini02). Special nodes are tainted, and
workloads opt in with a toleration plus affinity.

## 3. Storage tiers

| Tier | Where | Holds |
|---|---|---|
| **fast** | mini01 NVMe, TopoLVM `topolvm-fast` | every database and app state |
| **bulk** | mini01 Toshiba 320 GB, single disk | replaceable media: movies and shows |
| **safe** | mini02 RAID1, per-app SMB shares via `csi-driver-smb` | irreplaceable data: Immich originals, music, Paperless originals, personal files, MinIO backups, Prometheus |
| scratch | victus disk | download staging, replaceable |

- SMB, not NFS, so each app gets its own service account and password
  (SealedSecret). Samba runs on the **host**, outside k3s. Nothing goes in
  `/etc/fstab` on consumers; the CSI driver mounts the shares.
- SMR rules on mini02: ext4 on mdadm with a write-intent bitmap. No databases,
  no torrents, no swap. Sequential write-once data only. Schedule imports and
  backups off-hours.

## 4. Service catalogue (target)

Status key: **LIVE** = running today · **NOW** = build next, no mini02 needed ·
**MINI02** = blocked on mini02 hardware · **LATER** = deliberately deferred.

| Service | Node | Data | Est. RAM | Status |
|---|---|---|---|---|
| k3s server, traefik, CoreDNS | mini01 | — | ~1.5 GB | LIVE |
| ArgoCD | mini01 | fast | ~1 GB | committed; verify it is installed and syncing |
| cert-manager, TopoLVM, tailscale-operator, sealed-secrets, cnpg, metrics-server | mini01 | — | ~0.7 GB | LIVE (cnpg via Immich) |
| Immich (server, Valkey, CNPG Postgres) | mini01 | DB/thumbs fast; originals → safe (MINI02) | ~2 GB | LIVE |
| Immich machine learning (CUDA) | victus | — | ~3 GB on victus | NOW (needs NVIDIA device plugin; set `IMMICH_MACHINE_LEARNING_URL`) |
| Vaultwarden | mini01 | fast | <0.1 GB | LIVE |
| cp-reserva-bot + web UI | mini01 | fast | small | LIVE (not in Velero yet; fix) |
| Velero | mini01 | — | ~0.2 GB | LIVE |
| MinIO (backup copy) | victus `/srv/backup` | victus LUKS | small | LIVE |
| MinIO (primary backups) | mini02 | safe | small | MINI02 |
| **Jellyfin** (movies, shows, music), replaces Plex | mini01 (Quick Sync, `/dev/dri`) | config/DB/transcode fast; movies bulk; music safe (MINI02) | ~1 GB | NOW (movies first, music when mini02 lands) |
| qBittorrent + gluetun (VPN sidecar) | victus | scratch | ~0.5 GB | NOW: bring the existing Docker setup into the repo |
| Prowlarr, Sonarr, Radarr, Lidarr | victus | config fast-ish on victus; imports go over LAN | ~1 GB | NOW (Lidarr's target is the music share, MINI02) |
| **Paperless-ngx** (+ Redis, DB) | mini01 | DB fast; originals on NVMe now, moved to safe when mini02 lands | ~1.5 GB | NOW |
| **Actual Budget** | mini01 | fast, backed up | ~0.1 GB | NOW |
| **AdGuard Home** (chosen over Pi-hole: single YAML config, built-in DoH/DoT upstreams) | mini01 | fast | ~0.1 GB | NOW: serve as Tailscale DNS, with a fallback resolver so mini01 being down doesn't kill DNS |
| **Uptime Kuma** | **victus** (compromise: off mini01, can't be off-cluster) | victus | ~0.1 GB | NOW: alerts must go via an **external** channel (Telegram or public ntfy.sh), never a self-hosted one |
| Homepage (service dashboard) | mini01 | — | ~0.1 GB | optional, low priority |
| Samba with per-app shares | mini02 host | safe | — | MINI02 |
| Prometheus | mini02 (final) | safe, short retention, 60 s scrape | ~1 GB | LATER |
| Grafana | mini01 | fast | ~0.2 GB | LATER |
| Kiosk (`cage` + browser in kiosk mode, unprivileged user, read-only anonymous Grafana) | mini01 host, via Ansible | — | ~0.5 GB | LATER (after Grafana) |
| Stalwart mail | Hetzner CX22 (outside the cluster) | — | — | separate project |

**Removed from scope:** Plex (retired, not migrated), Navidrome (Jellyfin with
the Finamp phone app covers music), Karakeep, Linkding.

**Undecided:** the PS4 games share. No storage for it today. If it happens,
first check which SMB version the PS4 homebrew client needs; SMB1 must be
isolated from the other shares.

mini01 RAM budget after the NOW items: roughly 9–10 GB of 12. Measure with
`kubectl top` before and after each step. Grafana and the kiosk add about
0.7 GB later. Prometheus never goes on mini01 long-term.

## 5. Backups

- Velero with two storage locations: victus MinIO (live today) plus mini02
  MinIO (MINI02). Order: add first, remove nothing; prove it with a restore
  test from mini02 alone before relying on it.
- Add the `cp-reserva-bot` namespace to the Velero schedule now. Every new
  app (Paperless, Actual, AdGuard config, Jellyfin config) must be covered by
  a schedule when it is added.
- victus `lv-backup` (100 GB) will need growing as the photo library grows.
- Known gaps: no offsite copy; no UPS (recommended for both minis).

## 6. Build order

Moved: the roadmap now lives in `.planning/ROADMAP.md` (phases 1-6).
Each step is still its own PR from a fresh branch off `origin/main`.

## 7. Open decisions (ask the operator; don't guess)

1. **How the victus *arr apps write movies and shows onto mini01's
   Toshiba.** Option A: a `media` Samba share on mini01 (write for the *arr
   accounts, read-only for Jellyfin), which matches the share pattern.
   Option B: run Sonarr and Radarr on mini01 and mount the victus download
   directory instead.
2. **VPN provider for gluetun:** the plan says ProtonVPN; Mullvad was
   mentioned earlier.
3. **The PS4 games share:** whether it happens, and on which disk.
4. Personal files on mini02: through an app, or one human Samba share as a
   deliberate exception (open item from the plan).
