# Plan: the arr stack (Sonarr, Radarr, Prowlarr, Bazarr) on mini03

Audience: a local language model working on this repository for the operator. Follow it literally, one work
package (WP) at a time. Where it says STOP, stop and report to the operator; do not decide for him.

Written 2026-10-25. Branch for this plan: `docs/plan-arr-stack`. Nothing in this document has been
deployed or applied; every manifest below is a proposal that the work packages turn into PRs.

## 0. Purpose, scope, non-goals, definition of done

### Purpose

Run the four Servarr media-management applications as software deployments on the planned worker
VM `mini03`, so that:

- Sonarr (TV) and Radarr (movies) manage the Jellyfin library that lives on mini01's two Toshiba disks;
- Prowlarr is the central place that feeds Sonarr and Radarr, and Bazarr adds subtitles to the same library;
- the apps talk to the download client (qBittorrent, written by the torrent-gluetun plan) and tell Jellyfin to rescan;
- each app has its own tailnet-only web address, its configuration is backed up, and every credential is sealed or kept in the operator's password manager.

### SCOPE LIMIT (read this first)

This plan covers **INFRASTRUCTURE ONLY**: deployment, storage, networking, credentials, backups, and how the
apps connect to each other, to Jellyfin and to the download client.

It deliberately does **not** cover, research or list: indexers, trackers, release groups, or any source
of media. The operator configures all of that himself, in the applications' own web UIs. If an executor is tempted to
"help" by adding sources, search providers or content lists anywhere (manifests, notes, PR text, commit
messages), it must not. Bazarr subtitle **providers** are likewise only touched at infrastructure level
(section 7, WP8: where the credentials live and what network access is needed); choosing providers is the operator's.

### Non-goals

- No Lidarr, Readarr, Jellyseerr/request app, FlareSolverr or any other companion. (Later plans.)
- No changes to Jellyfin's deployment, to the NAS, to the torrent client or to mini03 itself (their own plans).
- No SSO/OIDC. The apps use their own forms login (section 6). Authentik is a separate plan.
- No Postgres: each app keeps its default SQLite database in its config volume (decision D9).
- No live cluster change by the executor, ever (section 1).

### Definition of done (checklist)

- [ ] WP0 audit report delivered and every `[ASSUMED]` interface confirmed or corrected.
- [ ] Library share pod `library-share` runs on mini01 and exports the two disks, writable only by the account `arrimport`.
- [ ] Namespace `arr` exists; PVCs `sonarr-config`, `radarr-config`, `prowlarr-config`, `bazarr-config` are Bound on mini03 (`topolvm-fast`).
- [ ] Sonarr, Radarr, Prowlarr, Bazarr run on mini03, image pinned by digest, explicit resources, health OK.
- [ ] The library volumes `/library/disk1` and `/library/disk2` and the staging volume `/downloads` are mounted in the importing apps with the same paths everywhere.
- [ ] A test import copies a file from `/downloads` to `/library/diskN` as uid 1000, with the source removed or left as intended, and Jellyfin shows it after the automatic rescan.
- [ ] Each app is reachable on the tailnet at `https://sonarr`, `radarr`, `prowlarr`, `bazarr` (short names; full names never committed) and demands a login.
- [ ] Prowlarr is linked to Sonarr and Radarr; Sonarr and Radarr use the download client; Bazarr is linked to Sonarr and Radarr.
- [ ] Velero schedule `arr-nightly` runs and a restore test (section 8) has been done by the operator.
- [ ] All 20 guards pass; the BACKLOG row for the arr stack is updated.

## 1. Rules for the executor

1. **PR-only.** You change files in the repository and open pull requests. The operator merges and syncs Argo apps
   himself in the Argo web UI. Never push to `main`, never force-push, never merge, never delete a branch.
2. **The cluster is read-only for you.** Allowed: `get`, `describe`, `logs`, `top`, and `exec ... -- <read-only
   command>` (for example `df`, `ls`, `stat`, `cat` of non-secret files). Always pass `--context admin@<cluster>`.
   Forbidden: `apply`, `create`, `delete`, `patch`, `edit`, `scale`, `rollout`, `replace`, `label`, `annotate`,
   `drain`, `cordon`, `taint`, any `talosctl` write, any `argocd app sync`, any `velero create`. Never suggest
   `kubectl patch/apply` to the operator as a fix: changes go through a PR and an Argo sync.
3. **No secrets.** Never print, decode or paste a secret value. Never run `get secret -o yaml/json/jsonpath`.
   `describe secret` (key names only) is fine. API keys, passwords and tokens never enter the repo in clear text,
   a PR description, a log or a chat. Only the operator creates sealed files (section 6), with values he generates.
   Do not run `cat` on `/config/config.xml` or Bazarr's `config.yaml`: they contain the API key.
4. **No host details in files.** Do not write IPv4 addresses or CIDRs, MAC addresses, disk serial numbers,
   `/dev/disk/by-id` names or any `*.ts.net` name. Use placeholders such as `<node-ip>`, `<tailnet-name>`.
   The guard `check-no-host-details.sh` rejects them.
5. **Draft PRs, one concern per PR.** Branch from current `origin/main`: `git fetch origin && git switch -c
   <branch> origin/main`. Open every PR as a **draft**. Commit message ends with the line
   `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; PR descriptions end with the line
   `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
6. **Guards.** Before every commit run `bash .github/scripts/run-all-guards.sh`. All 20 lines must start with `OK`.
   Never edit a guard to make it pass; if one fails and you cannot fix your own file, STOP.
7. **Generated files.** After changing any `talos/apps-src/*.yaml`, run `talos/render-apps.sh --force` and commit
   the generated `talos/apps/*.yaml` too. Every Application needs one line in
   `talos/test/empty-cluster-expectations.txt`.
8. **StorageClass.** The cluster's only class is `topolvm-fast`, not marked default. Every PVC you write must set
   `storageClassName: topolvm-fast` (the ghcr-app template's PVC omits it: known gap, do not copy that part).
9. **Explicit resources.** Every container sets `resources.requests` and `resources.limits` for cpu and memory.
10. **Images pinned by digest**, tag kept in a comment, never `latest`.
11. **STOP conditions.** Stop and report (format in section 11) if: a precondition of a WP is false; a command's output
    differs from the "expected" in a way not covered by a troubleshooting row; a guard fails; a decision in
    section 5 that the WP depends on is unanswered; you would have to write a value only the operator can supply; you
    would have to touch a file outside the WP's list; a command prints something that looks like a secret.
12. **Never decide a the operator decision.** Section 5 lists them. Where a default is recommended, you may use it only if
    the operator has said "use the defaults" in writing in the task you were given; otherwise ask.
13. If reality differs from this plan, trust what you see, write the difference in your report and ask.
14. **Scope limit** (section 0) applies to everything you write.

## 2. Prerequisites and dependencies

Each row: what is needed, the read-only command that proves it, and what to do if not.

| # | Needs | Proof (read-only) | Expected | If not |
|---|---|---|---|---|
| P1 | Node `mini03` exists and is Ready (planned VM; PRs #49, #52, #71 on 2026-10-25) | `kubectl --context admin@<cluster> get node mini03` | one row, `Ready` | WRITE the PRs of WP1-WP6 anyway, but mark them "do not sync until mini03 is Ready" in the PR text. The operator syncs `arr` only after P1 is true. |
| P2 | mini03 labels/taint as designed: taint `node-role.homeserver/tier=mobile:NoSchedule` `[ASSUMED]` from `docs/dr/mini03.md` on branch `talos/victus-vm` | `kubectl --context admin@<cluster> get node mini03 -o jsonpath='{.spec.taints}'` | contains key `node-role.homeserver/tier` | If the taint differs, change the toleration in section 7 accordingly and say so in the report. |
| P3 | mini03 has Talos user volumes `data` (`/var/mnt/data`, for local-path PVCs) and `staging` (`/var/mnt/staging`, 283 GiB) `[ASSUMED]` | After P1: `kubectl --context admin@<cluster> get pv` shows nothing for staging yet; check Talos config in `talos/patches/volumes-mini03.yaml` (branch `talos/victus-vm` or main once merged) | files define `data` and `staging` | STOP and ask the operator. |
| P4 | Storage class `topolvm-fast` | `kubectl --context admin@<cluster> get sc` | `topolvm-fast ... rancher.io/local-path ... WaitForFirstConsumer` | STOP. |
| P5 | `csi-driver-smb` runs and tolerates the mini03 taint | `kubectl --context admin@<cluster> -n kube-system get ds csi-smb-node -o jsonpath='{.spec.template.spec.tolerations}'` | `[{"operator":"Exists"}]` (verified 2026-10-25) | If it is not tolerating, STOP: node plugin would not run on mini03 and the SMB volumes cannot mount. |
| P6 | Jellyfin runs on mini01 with the two disks | `kubectl --context admin@<cluster> -n homeserver get deploy jellyfin` | `1/1` | STOP. |
| P7 | Download client Service `qbittorrent` in namespace `arr`, port 8080 (written by the torrent-gluetun plan) `[ASSUMED]` | `kubectl --context admin@<cluster> -n arr get svc qbittorrent` | port `8080/TCP` | The arr stack can be deployed without it, but section 7 WP9 (linking) cannot be finished. Continue with WP1-WP8 and report. |
| P8 | Staging volume claim `staging` in namespace `arr`, mounted by qBittorrent at `/downloads`, owned by the torrent-gluetun plan `[ASSUMED]` | `kubectl --context admin@<cluster> -n arr get pvc staging` | `Bound` (or not yet, if mini03 is not up) | See WP2 step 4: the plan contains a conditional manifest. Do not create it twice: ask the operator which PR owns it (decision D6). |
| P9 | Namespace `arr` pod-security level compatible with these pods | `kubectl --context admin@<cluster> get ns arr --show-labels` | none or any (the pods here need only the baseline level) | If the torrent plan labels `arr` privileged, our pods still run. Fine. |
| P10 | Sealed Secrets controller and the committed certificate | `ls argocd/sealed-secrets/pub-cert.pem` | file exists | STOP. |
| P11 | Velero node agent reaches mini03 | `kubectl --context admin@<cluster> -n velero get ds node-agent -o jsonpath='{.spec.template.spec.tolerations}'` | contains the mini03 taint key | Fixed in WP7 (adds `nodeAgent.tolerations` to `talos/values/velero.yaml`). Today the output is empty (verified 2026-10-25: the DaemonSet runs only on mini01 and mini02). |

### What depends on this service

- Nothing else is blocked on it. Soft links: Homepage (a tile per app, using the API keys of section 6) and Monitoring (scrape/blackbox targets `sonarr.arr.svc:8989` etc.) `[ASSUMED]` plans written elsewhere.
- The torrent-gluetun plan is the other half: both live in namespace `arr` and share the staging volume.

## 3. Facts about this service

Marks: `[verified <url>]` = read in the official source on 2026-10-25; `[UNVERIFIED]` = not confirmed, with how to confirm.

### 3.1 Images

Image family: LinuxServer.io (`lscr.io/linuxserver/<app>`, mirrored at `ghcr.io/linuxserver/<app>`), because it is
the family the Servarr wiki's own examples use and its pages document every variable below
`[verified https://docs.linuxserver.io/images/docker-sonarr/]`. (Alternative: hotio, decision D4.)
The template script `docs/templates/ghcr-app/new-app.sh` resolves digests only on `ghcr.io`; since the same images
are at `ghcr.io/linuxserver/...`, the **digest lookup works** and is done with the read-only query below.

| App | Image reference to pin | Version tag found (newest stable release in the maintainers' release list on 2026-10-25) | Digest resolved 2026-10-25 (re-resolve before use) |
|---|---|---|---|
| Sonarr | `ghcr.io/linuxserver/sonarr` | `4.0.20.3014-ls329` | `sha256:44b06045a98bc1f237b9ffefc4b28dab64cb29305e4a2a94875ae93b5224e4cc` |
| Radarr | `ghcr.io/linuxserver/radarr` | `6.4.4.10685-ls323` | `sha256:fc0ae3c50f8128b97e84381903ec8d6845c3a569641cb7117c124376cccb57c1` |
| Prowlarr | `ghcr.io/linuxserver/prowlarr` | `2.6.5.5623-ls165` | `sha256:b3b00047ed20f6ce2b16780145cb6a0acb51c9e28ea6aa6f5dcd33c7034f1797` |
| Bazarr | `ghcr.io/linuxserver/bazarr` | `v1.6.2-ls369` | `sha256:946dc8c5bb5331418eac60050cf40a63cb8f66ac039841dda493870e3559799c` |

Tags found via `gh api "repos/linuxserver/docker-<app>/releases?per_page=100"` (first tag starting with a digit or `v`);
the digests were resolved from `ghcr.io` with the query below. The executor re-runs the query in WP0 and, if a newer
stable release exists, asks the operator before bumping (default: use these). Do **not** use the maintainers' `develop`,
`nightly` or `development` tags.

Digest lookup (read-only registry query; save as a scratch file OUTSIDE the repository, for example `/tmp/arr-digest.sh`,
and run with `bash /tmp/arr-digest.sh sonarr 4.0.20.3014-ls329`):

```bash
#!/usr/bin/env bash
# usage: arr-digest.sh <linuxserver-repo-name> <tag>
set -euo pipefail
repo="linuxserver/$1"; tag="$2"
tok="$(curl -fsS "https://ghcr.io/token?scope=repository:${repo}:pull" | jq -r .token)"
curl -fsSI -H "Authorization: Bearer ${tok}" \
  -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
  "https://ghcr.io/v2/${repo}/manifests/${tag}" | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}'
```

Expected: one line `sha256:<64 hex>`. Empty output means the tag does not exist: stop and report.
The image reference in manifests is `ghcr.io/linuxserver/<app>@sha256:<digest> # <tag>` (the registry mirror gives the
same digest as `lscr.io`; if the operator prefers `lscr.io`, say so in the PR and he decides). The tags carry an architecture
manifest list; the node is amd64, so the index digest is correct.

### 3.2 Ports, data paths, variables

| | Sonarr | Radarr | Prowlarr | Bazarr |
|---|---|---|---|---|
| Web port | 8989 | 7878 | 9696 | 6767 |
| Config volume | `/config` | `/config` | `/config` | `/config` |
| Other documented volumes | `/tv`, `/downloads` | `/movies`, `/downloads` | none | `/movies`, `/tv` |
| `PUID`/`PGID`/`TZ`/`UMASK` | yes | yes | yes | yes |
| Docs | `[verified https://docs.linuxserver.io/images/docker-sonarr/]` | `[verified https://docs.linuxserver.io/images/docker-radarr/]` | `[verified https://docs.linuxserver.io/images/docker-prowlarr/]` | `[verified https://docs.linuxserver.io/images/docker-bazarr/]` |

The image pages' `/tv`, `/movies`, `/downloads` volume names are only examples; the Servarr wiki says to ignore them
and use consistent paths in all containers `[verified https://github.com/Servarr/Wiki/blob/master/docker-guide.md]`.
This plan uses `/library/disk1`, `/library/disk2` and `/downloads` identically in every pod.

Servarr settings by environment variable `[verified https://github.com/Servarr/Wiki/blob/master/sonarr/environment-variables.md]`:
pattern `SONARR__<NAMESPACE>__<ITEM>`; relevant names are `SONARR__AUTH__APIKEY`, `SONARR__AUTH__METHOD`,
`SONARR__AUTH__REQUIRED`, `SONARR__AUTH__TRUSTCGNATIPADDRESSES`, `SONARR__SERVER__PORT`, `SONARR__SERVER__URLBASE`.
Variables override `config.xml`; the app must be restarted after a change; names are case-sensitive.
Prowlarr uses the same pattern with prefix `PROWLARR__` (`PROWLARR__AUTH__APIKEY`, `..._METHOD`, `..._REQUIRED`)
`[verified https://github.com/Servarr/Wiki/blob/master/prowlarr/environment-variables.md]`.
Radarr: the wiki has an equivalent page (`radarr/environment-variables.md`); the names `RADARR__AUTH__APIKEY`,
`RADARR__AUTH__METHOD`, `RADARR__AUTH__REQUIRED` follow the same rule `[UNVERIFIED for Radarr specifically: WP0
step 9 greps that page]`.
Accepted values `[verified https://github.com/Servarr/Wiki/blob/master/sonarr/settings.md]`: method `Basic`, `Forms`,
`External` (`None` is not selectable for new installs and is treated as Forms in v5); required `Enabled` or
`DisabledForLocalAddresses`. Use `Forms` and `Enabled`. The wiki records a high-severity bypass (CVE-2026-30975) of
`DisabledForLocalAddresses` behind a proxy that spoofs `X-Forwarded-For`; with `Enabled` it does not apply, which is
why this plan never uses `DisabledForLocalAddresses`.

Bazarr has **no documented environment variable for its API key or login** `[UNVERIFIED: confirm at
https://wiki.bazarr.media/ or the Bazarr settings UI]`; its key and login are set in the UI (section 6).

### 3.3 Health endpoints

- Sonarr/Radarr/Prowlarr expose `GET /ping` (JSON status) without login `[UNVERIFIED: not found in the wiki pages
  read; confirm with the check in WP3 step 8]`. Manifests therefore use a **tcpSocket probe** (certain), and the plan adds
  the `/ping` check as a manual verification.
- Bazarr: tcpSocket on 6767 (an HTTP health URL is `[UNVERIFIED]`).
- LinuxServer images document no HEALTHCHECK `[verified, Sonarr page: "Health check: not documented"]`.

### 3.4 Image runtime behaviour

- The images use s6 and, by default, **start as root and drop to `PUID`/`PGID`** `[verified docs.linuxserver.io]`. So the container needs
  the default capabilities (chown, setuid, setgid, dac_override). Therefore these pods do NOT `drop: [ALL]`
  and do NOT set `allowPrivilegeEscalation: false`; they run at the Pod Security **baseline** level. Decision D5 covers
  trying the documented non-root mode later.
- Non-root mode exists: set `user: <uid>:<gid>`, `PUID`/`PGID` have no effect, `/run` must be a tmpfs owned by the
  user, permissions of mounts are your job `[verified https://docs.linuxserver.io/misc/non-root/]`. Whether it is
  supported for each of the four images is `[UNVERIFIED]` ("each image's readme notes whether non-root is supported").
- Read-only root filesystem is documented as supported for the images `[verified, image pages]` but needs the extra tmpfs
  mounts from the maintainers' read-only guide; not used in the first iteration.
- The apps update themselves only through image replacement; the maintainers advise against in-container updates
  `[verified, Bazarr page]`. Upgrade = bump the digest (section 10).

### 3.5 Resource needs

From `docs/dr/mini03.md` (branch `talos/victus-vm`): "Sonarr, Radarr and Prowlarr about 300 MB each". Bazarr's
subtitle processing can spike. Values chosen are in section 4.

### 3.6 Upgrade and migration notes

- Servarr databases migrate forward on start and cannot be downgraded: take an in-app backup first (section 8), then upgrade.
- Sonarr 4 to 5 and Radarr 5 to 6 style major jumps appear in release notes; read the project's release notes in the PR
  before changing a major version `[UNVERIFIED: release notes not read]`.

### 3.7 Servarr behaviours this design relies on (all `[verified https://github.com/Servarr/Wiki/blob/master/sonarr/settings.md]` unless noted)

- Hardlinks and atomic moves need the same filesystem and mounts; otherwise Sonarr "will fall back and copy the file then
  delete from the source" (moves) or copy (torrent, left for seeding).
- Torrent downloads: "Completed files are left in their original location to allow you to seed the file"; Sonarr
  hardlinks if possible or copies.
- Media Management has "Skip Free Space Check" and "Minimum Free Space" ("prevent import if it would leave less than this
  amount of disk space available"), and the root folder list shows each folder's free space.
- Remote Path Mappings are a "dumb find and replace" for when the application and the download client do not see the
  same paths; not needed when both mount the same path.
- Backups: Settings > General > Backups; folder relative to the appdata folder; default interval 7 days, default retention 28 days.
- `Authentication Required: Enabled` is recommended.

## 4. Architecture and placement

### 4.1 The central design problem and decision

Downloads finish on mini03's staging volume (`/var/mnt/staging`, 283 GiB, its own virtual disk). The library lives
on mini01's two physical disks (`/var/mnt/media` = disk1, `/var/mnt/media2` = disk2), which only mini01 can mount.
Sonarr and Radarr must (a) read the finished file, (b) write it into the library with the right name, (c) later see the
library to detect upgrades and missing episodes, and (d) tell Jellyfin.

Facts that shape every option:

- **Hardlinks are impossible** between mini03 and mini01 (different machines, different filesystems), also impossible between staging
  and any other volume. The import is always a **copy** over the network. For torrents the source stays (it is still
  seeding); the staging copy is removed later by the torrent client's seeding limits or by the arr "Remove Completed"
  option. So every title temporarily occupies space on staging AND on the library disk.
- **Atomic (instant) moves are impossible** for the same reason: the move degrades to copy + delete. While a copy is in
  progress the library folder contains a partial file. Jellyfin must therefore be told to rescan only AFTER the import
  finishes (the arr apps do that, section 4.5), and Jellyfin's real-time library monitor should stay off for these folders
  (The operator's setting in the Jellyfin UI; D8).
- The library disks are **independent filesystems with no redundancy** and are not backed up by Velero (see `talos/manifests/jellyfin/deployment.yaml`).
  The arr apps will WRITE there, so the blast radius of a bug or a wrong click is real: limit what they can write.
- The library is not on the NAS, so a plain SMB/CSI share from the NAS (option a) does not help.

Options evaluated:

| Option | How | For | Against | Verdict |
|---|---|---|---|---|
| (a) SMB/CSI share from the NAS | arr mounts a `samba-nas` share (pattern `immich-library-smb`) | existing pattern | The library is NOT on the NAS (decision 2026-10-19). Would need a second copy of the library on mini02 `tank/nas` (256G quota, too small) and Jellyfin re-pointed. | Rejected. |
| (b) SMB export of the Toshiba disks from a small pod on mini01, mounted on mini03 with `csi-driver-smb` | New pod `library-share` (Samba, hostPath rw on both disks) in `homeserver` on mini01; static PVs in `arr`; arr pods mount `/library/disk1`, `/library/disk2` | Reuses two things already running and proven (the pinned Samba image of `samba-nas`, the csi-driver-smb static-PV pattern); arr apps stay on mini03 as already decided; Jellyfin keeps its read-only hostPath mounts untouched; a dedicated account `arrimport` (uid 1000) makes the write access explicit and revocable; no new software class. | Every import crosses the node network (SMB over the cluster network, which today runs over the tailnet: speed to be measured, WP5). SMB semantics: no hardlinks, `nobrl` locking off, case/permission mapping through mount options. Extra pod on mini01 (small). | **RECOMMENDED.** |
| (b2) NFS instead of SMB | NFS server pod on mini01 | Better POSIX semantics | Talos has no `nfsd` kernel server module and a user-space NFS server needs privileges and more moving parts; nothing in the repo uses NFS; `[UNVERIFIED]` on Talos. | Rejected. |
| (c) Importer pods on mini01 with hostPath, only the download client on mini03 | Sonarr/Radarr run on mini01 next to the library | Library access is local and atomic within each disk | Contradicts the placement decision (mini01 is at 45 percent memory with limits already at 122 percent, 4 cores shared with Jellyfin and Immich). It does NOT remove the network hop: the apps would still need the finished file from mini03's staging volume (an SMB/NFS mount in the other direction), so the same problem moves rather than disappears. hostPath writes by apps with a UI on a privileged namespace. | Rejected. |
| (d) A copy Job | Sonarr/Radarr "import" to a local folder on mini03, a CronJob/Job copies to mini01 | No SMB mount in the app pods | Sonarr/Radarr must see the FINAL library folder to track files, upgrade, rename and detect missing episodes; a handoff folder breaks all of that, and a Job needs its own scheduling, failure handling and cleanup. Also the arr apps believe the file is "imported" before it is. | Rejected. |

**Chosen design (b):**

```
 mini01 (Talos, 4 cores, 12 GiB)                              mini03 (Talos VM on victus, 4 vCPU, 8 GiB)
 ┌──────────────────────────────────────┐                     ┌─────────────────────────────────────────────┐
 │ ns homeserver (privileged)           │   SMB 445           │ ns arr                                      │
 │  Jellyfin  (hostPath ro disk1+disk2) │◀── csi-driver-smb ──│  sonarr   prowlarr   radarr   bazarr        │
 │  library-share (Samba, hostPath rw   │    static PVs       │    │ /config (PVC topolvm-fast, local-path) │
 │   disk1=/var/mnt/media               │    arr-library-     │    │ /library/disk1  /library/disk2 (SMB)   │
 │   disk2=/var/mnt/media2)             │    disk1/disk2      │    │ /downloads (PVC staging, local PV)     │
 └──────────────────────────────────────┘                     │  qbittorrent+gluetun [torrent plan]         │
        ▲  Jellyfin API (HTTP 8096, in cluster)               │    /downloads  = /var/mnt/staging (283 GiB) │
        └─────────────────────────────────────────────────────┤  Ingress x4 (tailscale)  http: sonarr:8989  │
                                                              └─────────────────────────────────────────────┘
```

### 4.2 Same paths everywhere (so no remote path mapping)

| Path in every pod that has it | Backing | Pods |
|---|---|---|
| `/library/disk1` | SMB share `disk1` = mini01 `/var/mnt/media` | sonarr, radarr, bazarr |
| `/library/disk2` | SMB share `disk2` = mini01 `/var/mnt/media2` | sonarr, radarr, bazarr |
| `/downloads` | PVC `staging` (local PV on mini03 `/var/mnt/staging`) | sonarr, radarr, qbittorrent `[ASSUMED]` |
| `/config` | PVC `<app>-config` (`topolvm-fast`, local-path on mini03 `/var/mnt/data`) | each app |

Prowlarr mounts only `/config`. Because the download client mounts the same volume at the same `/downloads` path
(`[ASSUMED]` from the torrent plan; WP0 confirms), the path the client reports is valid inside Sonarr/Radarr and
**no Remote Path Mapping is needed**. If the torrent plan mounts it elsewhere (say `/data/torrents`), add in
Sonarr and Radarr (Settings > Download Clients > Remote Path Mappings): Host `qbittorrent`, Remote Path `<path in the
client>`, Local Path `/downloads` (the wiki calls this a dumb find-and-replace, verified).

### 4.3 Permissions (uid 1000)

- Jellyfin runs as uid/gid 1000 and reads the library read-only. The Samba pod's account `arrimport` is mapped to uid 1000
  (`UID_arrimport=1000`), so new files on the disks are owned by 1000, readable by Jellyfin.
- Mount options on the arr side (`uid=1000,gid=1000,file_mode=0664,dir_mode=0775`) make the CIFS mount present files as
  1000:1000 mode 664/775 to the arr containers (they run with PUID/PGID 1000, UMASK 002, as the Servarr wiki recommends:
  "folder permissions 775 and files 664, a umask of 002" `[verified docker-guide.md]`).
- Existing files on the disks may be owned by another uid (copied in as root). Then Sonarr could not rename or delete them.
  WP0 step 6 measures it. If any exist, STOP and ask the operator (D3) whether to `chown` them (a one-off Job run by
  the operator, not part of this plan).
- Staging: the torrent client creates files there; the arr containers run as 1000:1000 with `fsGroup: 1000`
  so they can read, delete (copy source removal) and write. `[UNVERIFIED: that kubelet applies fsGroup to a `local` volume; WP5 step 3 checks `ls -ld /downloads` as uid 1000. Fallback: a one-shot root Job by the operator or `chmod`, see troubleshooting.]`
- Sonarr/Radarr "Set Permissions" (chmod after import) stays OFF (the default). CIFS mounts do not need it.

### 4.4 The two-disk split rule and free space

Rule (from Jellyfin's layout): **every title (a movie folder or a whole series folder with all its seasons) lives entirely on one
disk.** Sonarr and Radarr satisfy this naturally if each app has TWO root folders and every title is added with
exactly one root folder:

- Sonarr root folders: `/library/disk1/Shows` and `/library/disk2/Shows`.
- Radarr root folders: `/library/disk1/Movies` and `/library/disk2/Movies`.
  (Folder names `Movies`/`Shows` follow Jellyfin naming per the task; WP0 step 5 lists what actually exists on the disks
  and D3 fixes the names, because the Jellyfin deployment comment mentions older names such as `Films`.)

The apps have no automatic disk balancing. The operating rule for the operator: when adding a title choose the root folder
whose disk has more free space (Settings > Media Management lists free space per root folder; System > Status > Disk
Space shows all). Never use the "Move files" action to move a series between root folders unless the whole folder is
moving (the app moves the whole folder). Free-space protection:

- In Sonarr and Radarr, Settings > Media Management: set **Minimum Free Space** to 20480 MB (20 GiB) `[verified setting exists, value is the operator's: D3]`
  so an import never fills a disk. Leave "Skip Free Space Check" OFF. On a CIFS mount the free space is the share's filesystem,
  correct because each share is a whole XFS filesystem.
- Read-only check anytime: `kubectl --context admin@<cluster> -n arr exec deploy/sonarr -- df -h /library/disk1 /library/disk2 /downloads`.
- Staging (283 GiB) must hold downloads + seeding copies; the torrent plan's seeding limits protect it. The arr side adds:
  Settings > Download Clients > "Completed Download Handling > Remove Completed" ON (removes the download from the client after it
  is imported AND its seeding goal is met) `[UNVERIFIED wording: confirm in the UI]`.

### 4.5 Telling Jellyfin to rescan

Primary: in Sonarr and in Radarr, Settings > Connect > Add > "Emby / Jellyfin" (the connection type is named for both)
`[UNVERIFIED name in the current UI; the operator will see it]`, with:

- Host `jellyfin.homeserver.svc.cluster.local`, Port `8096`, Use SSL off (in-cluster plain HTTP; Jellyfin's Service is `jellyfin` port 8096, from `talos/manifests/jellyfin/service.yaml`).
- API Key: a Jellyfin API key (create in Jellyfin: Dashboard > Advanced > API Keys > "+" , app name `arr`) `[UNVERIFIED path: wording
  varies by Jellyfin version, 10.10.7 is deployed]`.
- Triggers: On Import, On Upgrade, On Rename, On Series/Movie Delete (and "On Movie Added/Series Add" if offered).
- "Update Library" ON.

Fallback, and how to test the key from any pod with curl (read-only effect: triggers a scan):
`curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Authorization: MediaBrowser Token="<API_KEY>"' http://jellyfin.homeserver.svc.cluster.local:8096/Library/Refresh`
expected `204` `[UNVERIFIED: endpoint and header form from memory of Jellyfin's API; confirm against
https://api.jellyfin.org/ (`POST /Library/Refresh`) in WP0]`. The API key is typed in the UI, never committed.
The executor does NOT run this command (it would need the key). The operator may.

### 4.6 Resources (requests and limits) and node capacity

Read-only measurements on 2026-10-25 (`kubectl --context admin@<cluster> top nodes`):

```
mini01   740m   18%   5077Mi   45%
mini02   125m    3%   1193Mi   16%
```
and `describe node mini01`: requests cpu 2263m (57 percent), memory 5285Mi (47 percent); LIMITS cpu 9400m (237 percent),
memory 13707Mi (122 percent). mini01 therefore cannot take the arr apps, and the new `library-share` pod is kept tiny.
mini03 is not in the cluster yet; the design figures are 4 vCPU and 8 GiB RAM, Talos idle about 1 GB, qBittorrent plus gluetun about
1 GB `[ASSUMED]`, MinIO replica about 0.5 GB `[ASSUMED]` (all from `docs/dr/mini03.md`). Remaining for the arr stack: about 5 GiB.
Re-check with `kubectl top nodes` once mini03 is up (WP0 step 2).

| Container | CPU request | CPU limit | Memory request | Memory limit | Why |
|---|---|---|---|---|---|
| sonarr | 100m | 1 | 384Mi | 1Gi | idle about 300 MB; library scans and metadata refresh spike |
| radarr | 100m | 1 | 384Mi | 1Gi | same |
| prowlarr | 50m | 500m | 192Mi | 512Mi | light |
| bazarr | 100m | 1 | 256Mi | 768Mi | subtitle search and (optional) sync spikes |
| library-share (mini01) | 50m | 1 | 64Mi | 256Mi | smbd, I/O-bound; limit protects the other 8 pods on mini01 |

Sum of arr memory limits 3.25 GiB, requests about 1.2 GiB. The `arr` namespace has no LimitRange today; the explicit
values are mandatory anyway (rule 9). `homeserver` has one (default cpu 500m, memory max 8Gi): `library-share` sets its own.

### 4.7 Placement and namespaces

- Namespace `arr` (fixed by the brief): all four apps, shared with qBittorrent. Pod Security: our pods meet **baseline**; the
  Talos cluster enforces baseline by default, so no label is needed. If the torrent-gluetun plan labels `arr` privileged for gluetun,
  our pods are unaffected (D7).
- Pinning: `nodeSelector: kubernetes.io/hostname: mini03` plus the toleration for mini03's taint `[ASSUMED]`.
- Library share pod: namespace `homeserver` (already `privileged`, hostPath is used there), pinned to mini01.
  No new namespace is invented for it.

## 5. Decisions for the operator

The executor STOPS at any WP that depends on an unanswered decision (column "Blocks").

| ID | Question | Options and trade-offs | Recommended default | If decided otherwise | Blocks |
|---|---|---|---|---|---|
| D1 | How do finished downloads reach the library? | (b) SMB export from a pod on mini01 (recommended); (c) importers on mini01 (strains mini01, still needs a hop); (d) copy Job (breaks arr tracking). See 4.1. | (b) | (c): the whole plan is rewritten (apps on mini01, hostPath); say so and stop. | everything |
| D2 | Scope of the writable export | A: two shares, whole disks (`disk1`, `disk2`): simplest, flexible, any folder (anime, etc.) can be a root folder; the arr account could delete anything on the disks if misused. B: only subfolders (`Movies`, `Shows` on each disk) as four shares: the apps cannot touch anything else; more PVs and mounts; adding a new category later needs a PR. | A, with Radarr/Sonarr "Recycle Bin" configured (D3) | B: WP1 creates four shares and WP2 four PVs (`disk1-movies` ...); paths become `/library/disk1-movies` etc. | WP1, WP2 |
| D3 | Root-folder names, disk use, existing files | Which folders on each disk are the arr roots (`Movies`, `Shows` per the Jellyfin naming in the task) vs the older names mentioned in the Jellyfin manifest (`Films`, `anime`, ...). Whether Radarr/Sonarr should adopt (import) the existing library or only manage new titles. Minimum free space (20 GiB). Whether to chown existing root-owned files (operator-run job). Recycle bin on/off: with it, deleted files accumulate on the disk; without it deletion is permanent. | `Movies` and `Shows` on both disks; new titles only (do not adopt); min free 20 GiB; recycle bin OFF (permanent delete) because disk space is limited and the originals are not backed up anyway: The operator confirms | Folder names are placed in the init container (WP1) and in the notes of WP9; nothing else changes. | WP1 (init dirs), WP9 |
| D4 | Image family | LinuxServer.io (recommended: documented, PUID/PGID/UMASK, same images as the wiki's examples); hotio (`ghcr.io/hotio/<app>`, also s6, different tag scheme, `[UNVERIFIED]` here); official upstream images exist for some apps `[UNVERIFIED]`. | LinuxServer.io | Re-do section 3 facts for the other family; ask before WP3. | WP3, WP4 |
| D5 | Root-start vs non-root hardening | Root-start with PUID/PGID drop (documented default, baseline pod security) vs `runAsUser: 1000` non-root with tmpfs `/run` (documented generic, per-image support `[UNVERIFIED]`, can break). | Root-start now; optional hardening WP10 later | WP10 turns on non-root after a trial. | WP10 |
| D6 | Who owns the staging claim | The torrent-gluetun plan `[ASSUMED]` owns PV `arr-staging` and PVC `staging`; this plan assumes it exists. Or this plan creates it (WP2 step 4) and the torrent plan only references it. Exactly one PR may create it, or Argo reports a duplicate. | Torrent plan owns it | If this plan owns it: do WP2 step 4 and tell the torrent plan's executor through the operator. | WP2 |
| D7 | Pod-security level of `arr` | baseline (no label; recommended for our pods) vs privileged (if gluetun needs it, the torrent plan decides). | Whatever the torrent plan sets; this plan adds no label | none | WP2 |
| D8 | Jellyfin library monitoring | Real-time monitoring ON can see partial copied files during an import; OFF relies on the arr "Update Library" notification and the scheduled scan. | OFF for the library folders, notification ON | If ON, expect transient partial items; test with a large copy (WP5). | WP9 |
| D9 | Database | SQLite in each app's config volume (default; simplest; backed up by the app and by Velero); Postgres per app via CNPG (more robust for big libraries; more moving parts). | SQLite | A separate plan. | none |
| D10 | Credentials model for the API keys | Pre-generated keys, sealed, injected by env (`<APP>__AUTH__APIKEY`): deterministic, reproducible after a rebuild, Prowlarr/Bazarr can be wired without hunting for keys. Or let each app generate its key at first start and the operator copies it from the UI (Settings > General); nothing to seal, but a rebuilt app gets a new key and everything linked must be re-linked. | Pre-generated and sealed (section 6) | Skip the `*-secrets` files and the `envFrom` blocks; keys are read in the UI. | WP2, WP3 |
| D11 | Tailnet host names | `sonarr`, `radarr`, `prowlarr`, `bazarr`. A stale device with the same name in the Tailscale admin console makes the new one register as `sonarr-1`: delete stale devices first. | those four | Change `tls.hosts` in WP6. | WP6 |
| D12 | Samba account | New dedicated account `arrimport` (recommended, revocable, visible in logs) vs reuse `homelab` from `samba-nas-credentials` (a decision about per-share accounts is pending for the NAS). | new `arrimport` | Reuse requires the sealed secret to live in `nas`, and the library share would accept the NAS password: not recommended. | WP1 |
| D13 | Time zone | `TZ` value for the apps (log timestamps, schedules). | `Etc/UTC` unless the operator names one | one string in each Deployment | WP3, WP4 |
| D14 | Backup cadence | In-app backup every 1 day, keep 14 days; Velero `arr-nightly` at 03:45 UTC with 30 days TTL. | as stated | edit numbers | WP7 |
| D15 | Bazarr in this plan | included (recommended, small). | included | skip WP4's Bazarr parts and WP8 | WP4, WP8 |

## 6. Credentials and secret handling

Principles: no value in the repo except as SealedSecret ciphertext; generation commands never echo; the operator
keeps every credential in his password manager (Vaultwarden). Secret objects live in `talos/sealed-secrets/` (SealedSecret
objects only), each listed in that directory's `kustomization.yaml`, delivered by the auto-sync app
`talos-sealed-secrets` (prune OFF).

### 6.1 Inventory

| # | Credential | What it is | Created by / how | Secret name (namespace) | Keys | Sealed file | How the app receives it |
|---|---|---|---|---|---|---|---|
| C1 | Library share account `arrimport` | SMB account (uid 1000) used by the Samba pod and by the CSI mounts | The operator: `openssl rand -base64 24 \| tr -d '\n' \| pbcopy` (clipboard only), then paste into Vaultwarden | `library-share-credentials` (`homeserver`) | `username` (value `arrimport`), `password` | `talos/sealed-secrets/library-share-credentials.yaml` | Samba pod: env `ACCOUNT_arrimport` from key `password`; CSI: `nodeStageSecretRef` reads keys `username` and `password` |
| C2 | Sonarr API key | 32 hex chars; authenticates every client of Sonarr (Prowlarr, Bazarr, Homepage) | The operator: `openssl rand -hex 16 \| tr -d '\n' \| pbcopy` | `sonarr-secrets` (`arr`) | `SONARR__AUTH__APIKEY` | `talos/sealed-secrets/sonarr-secrets.yaml` | env via `envFrom` (variable name is the exact Servarr name, verified) |
| C3 | Radarr API key | same | same | `radarr-secrets` (`arr`) | `RADARR__AUTH__APIKEY` | `talos/sealed-secrets/radarr-secrets.yaml` | env via `envFrom` |
| C4 | Prowlarr API key | same | same | `prowlarr-secrets` (`arr`) | `PROWLARR__AUTH__APIKEY` | `talos/sealed-secrets/prowlarr-secrets.yaml` | env via `envFrom` |
| C5 | Login of each of the 4 web UIs | username + password for Forms login | The operator at first visit (6.3) | none (stored hashed in the app's database in `/config`) | | | typed in the UI |
| C6 | Bazarr API key | generated by Bazarr at first start | Bazarr; read by the operator in the UI: Settings > General > Security > API Key `[UNVERIFIED path]` | none | | | used only by clients of Bazarr (for example Homepage) |
| C7 | Jellyfin API key for the arr apps | created in Jellyfin (Dashboard > Advanced > API Keys, name `arr`) | The operator | none (entered into Sonarr and Radarr connection settings, stored in their databases) | | | UI field |
| C8 | qBittorrent web login | `[ASSUMED]` created by the torrent-gluetun plan (its own secret) | the torrent plan | `[ASSUMED]` | | | typed into Sonarr/Radarr Download Client form by the operator |
| C9 | Subtitle provider logins | Bazarr provider accounts (infra note only) | The operator | none (stored in Bazarr's `config.yaml` inside the PVC, plaintext) | | | typed in the Bazarr UI; protected by the PVC, not exposed, covered by Velero |

If D10 is "read keys from the UI", C2-C4 disappear.

### 6.2 Generate and seal (The operator does this; the executor only writes the instructions into the PR)

Run in the operator's own terminal at the repository root. Nothing is printed. Replace `<app>` and `<APP>`.

```bash
# 1. generate (clipboard only) and store the value in Vaultwarden RIGHT NOW (it is not recoverable except from the cluster later)
openssl rand -hex 16 | tr -d '\n' | pbcopy

# 2. seal it for namespace arr
pbpaste | kubectl create secret generic <app>-secrets -n arr \
    --from-file=<APP>__AUTH__APIKEY=/dev/stdin --dry-run=client -o json |
  KUBECONFIG=/dev/null kubeseal --cert argocd/sealed-secrets/pub-cert.pem --format yaml \
    > talos/sealed-secrets/<app>-secrets.yaml

# 3. clear the clipboard
printf '' | pbcopy
```

Do it three times: (`sonarr`, `SONARR`), (`radarr`, `RADARR`), (`prowlarr`, `PROWLARR`). The library share account:

```bash
openssl rand -base64 24 | tr -d '\n' | pbcopy           # store in Vaultwarden first
pbpaste | kubectl create secret generic library-share-credentials -n homeserver \
    --from-literal=username=arrimport --from-file=password=/dev/stdin --dry-run=client -o json |
  KUBECONFIG=/dev/null kubeseal --cert argocd/sealed-secrets/pub-cert.pem --format yaml \
    > talos/sealed-secrets/library-share-credentials.yaml
printf '' | pbcopy
```

Then list each new file under `resources:` in `talos/sealed-secrets/kustomization.yaml` and add a header comment line
for it. A SealedSecret is bound to its name and namespace (default strict scope), so the `-n` above must be exactly
`arr` / `homeserver`. (Pattern of `docs/dr/talos-backups.md`, "Sealing the credentials"; helper
`docs/templates/ghcr-app/seal-secret.sh` creates secrets in `homeserver` only and must NOT be used for the `arr` ones.)

### 6.3 First login ("password discovery")

- **Sonarr, Radarr, Prowlarr**: the Deployments set `<APP>__AUTH__METHOD=Forms` and `<APP>__AUTH__REQUIRED=Enabled`. On the
  first visit through the tailnet address the app shows a screen to create the administrator username and password
  (or, on older builds, a page under Settings > General > Security) `[UNVERIFIED which of the two for these versions: The operator
  sees it; if neither appears, open Settings > General > Security]`. The operator chooses a username and a generated password
  and stores both in Vaultwarden. There is no default password and none in any log.
- **Bazarr**: first visit shows the setup wizard / Settings > General > Security where the operator enables authentication
  (Forms) and sets username and password `[UNVERIFIED exact UI]`. Until the operator does this, Bazarr has no login; since it is
  only on the tailnet this is acceptable for minutes, not days: WP8 makes it the very first step.
- **Never** leave an app at "Authentication: None / Not required".

### 6.4 Retrieval later (clipboard only)

```bash
kubectl --context admin@<cluster> -n arr get secret sonarr-secrets \
  -o jsonpath='{.data.SONARR__AUTH__APIKEY}' | base64 -d | pbcopy
```
(and `radarr-secrets` / `RADARR__AUTH__APIKEY`, `prowlarr-secrets` / `PROWLARR__AUTH__APIKEY`; the library password:
`-n homeserver get secret library-share-credentials -o jsonpath='{.data.password}'`). The UI login passwords are only in Vaultwarden
(and, hashed, in the app database).

### 6.5 What breaks if lost, rotation

| Credential | If lost | Rotation |
|---|---|---|
| C1 | Imports fail ("access denied" / mount error), apps still start, library untouched | New value, reseal (delete old file and its kustomization line first), merge, then `kubectl rollout restart` is done by the operator through an Argo sync of `library-share` and `arr` (pods must re-mount; the operator deletes the arr pods in Argo UI) |
| C2-C4 | The sealed copy is the source of truth; if the cluster loses it, other apps' links break (Prowlarr, Bazarr, Homepage). Recoverable from Vaultwarden. | New key, reseal, sync the app, then update every consumer (Prowlarr > Settings > Apps; Bazarr > Settings > Sonarr/Radarr) |
| C5 | Login locked out | recovery below |
| C6 | read again in the UI | Bazarr UI regenerate |
| C7 | Jellyfin notifications fail (library is not refreshed; files are still imported) | create new key in Jellyfin, update Sonarr and Radarr connection |

### 6.6 Lost admin password recovery (Sonarr/Radarr/Prowlarr)

Order of preference, each by PR or UI, never by `kubectl patch`:

1. **Restore from the app's own backup**: Velero restore of `/config` from before the change (section 8), or the in-app backup zip
   restored through System > Backup > Restore, which restores a database with the old login. Needs a login, so only useful if another
   path gets you in.
2. **Temporary external authentication through a PR**: change `<APP>__AUTH__METHOD` to `External` in the Deployment, merge, Argo sync. `External`
   means the app performs no authentication of its own `[verified settings.md]`; the app is still only reachable on the tailnet. Open
   Settings > General > Security, set Authentication to Forms with a new username and password, save. Then revert the env var in a second PR
   and sync. Because the env override wins over `config.xml`, the revert is mandatory, otherwise the app stays unauthenticated.
   `[UNVERIFIED: whether Settings > Security is editable while the env var is set; if not, use option 3.]`
3. **Reset in the database** by a one-off pod written and run by the operator (not part of this plan): scale the app to zero in Argo, mount the
   PVC, remove the user row from the SQLite database or the `AuthenticationMethod` entry in `config.xml` (see the Servarr FAQ
   `https://wiki.servarr.com/sonarr/faq`, not retrievable in this session: `[UNVERIFIED]`).

Bazarr: same options 1 and 3 (login in `config/config.yaml` under `/config`).

## 7. Work packages

General: every WP starts with `git fetch origin && git switch -c <branch> origin/main`, ends with `bash .github/scripts/run-all-guards.sh`
(all 20 `OK`), a commit with the Co-Authored-By line, `git push -u origin <branch>`, and a DRAFT PR
(`gh pr create --draft --title "..." --body-file <file outside the repo>`). PR bodies end with the 🤖 line. Order: WP0, WP1, WP2, WP3, WP4,
WP5 (the operator), WP6, WP7, WP8 (the operator), WP9 (the operator), WP10 (optional), WP11 (docs).
WP1-WP4 and WP6, WP7 can be written in parallel PRs but MERGE in order; WP3 and WP4 edit the same
`kustomization.yaml` and the second must rebase.

### WP0 - Read-only audit (no files changed; output is a report)

Goal: confirm every `[ASSUMED]` and measure before anything is written. Branch: none. Preconditions: none.

1. Repository state. `git fetch origin && git log --oneline -5 origin/main`, `gh pr list --state all --limit 40`. Look for merged PRs for mini03
   (#49, #52, #71), the torrent plan, and any file named `talos/manifests/arr*`, `talos/manifests/library-share*`, `docs/plans/torrent-gluetun.md`.
   Expected today: mini03 PRs draft, no arr directory. Differences: report.
2. Cluster. `kubectl --context admin@<cluster> get nodes`, `top nodes`, `get node mini03 -o jsonpath='{.spec.taints}'` (fails if absent: report).
3. Namespace. `kubectl --context admin@<cluster> get ns arr --show-labels` (NotFound is fine). Check `talos/manifests/namespaces/namespaces.yaml` for an `arr` entry.
4. Staging and torrent client. `kubectl --context admin@<cluster> -n arr get svc,pvc,deploy 2>&1`. Read the torrent plan (`docs/plans/torrent-gluetun.md` on its branch/PR) for: Service name and port, the PVC name, the mount path of the downloads volume, who creates the namespace. Record in the report. Compare with section 4.2.
5. Library layout (read-only exec into Jellyfin, which mounts both disks):
   `kubectl --context admin@<cluster> -n homeserver exec deploy/jellyfin -- ls -la /media/disk1 /media/disk2`
   and `... -- df -h /media/disk1 /media/disk2`. Expected: top-level folders (the manifest comment names `Films`, `Absolutely Anything`, `anime`, `Captures` on disk1; `TopGear`, `The.Grand.Tour` on disk2) and free space per disk. Report names and free space. This answers D3.
6. Ownership: `... -- sh -c 'find /media/disk1 /media/disk2 -maxdepth 2 ! -uid 1000 | head -20'`. Expected: empty. Anything listed: report (see 4.3).
7. Samba image pin: `grep SAMBA_IMAGE talos/storage/pins.env` must equal the digest used in WP1 (it is `docker.io/servercontainers/samba:smbd-only-a3.24.1-s4.23.8-r0@sha256:03bdd347...`). Use whatever `pins.env` says if it changed.
8. Image tags: re-run the digest query of 3.1 for the four tags; check for newer stable releases with `gh api "repos/linuxserver/docker-sonarr/releases?per_page=30" --jq '[.[].tag_name]'` (and radarr, prowlarr, bazarr). Report newer tags; do not switch silently.
9. Radarr variable names: `gh api repos/Servarr/Wiki/contents/radarr/environment-variables.md --jq .content | base64 -d | grep -n AUTH`. Expected `RADARR__AUTH__APIKEY`, `..._METHOD`, `..._REQUIRED`. Also `grep -n -i "ping" ` on the Servarr wiki clone (not required).
10. Velero: `kubectl --context admin@<cluster> -n velero get schedules` (names), `kubectl --context admin@<cluster> -n velero get ds node-agent -o jsonpath='{.spec.template.spec.tolerations}'`. Read `talos/values/velero.yaml` for the `schedules:` map.
11. Argo: `kubectl --context admin@<cluster> -n argocd get applications.argoproj.io | head -40` to see app names `arr`, `library-share` are free.
12. Jellyfin API: read https://api.jellyfin.org/ for `Library/Refresh` and the auth header form; record. This resolves 4.5 `[UNVERIFIED]`.

Verification: the report lists every item with `confirmed` or `differs: ...`. Rollback: none. STOP point: STOP and send the report to the operator; wait for the D-answers (D1-D3, D6, D7 at least) before WP1.

### WP1 - Library share on mini01 (Samba export of the two disks)

Goal: a small pod on mini01 that exports `disk1` and `disk2` to the cluster, writable by account `arrimport`, and creates the root folders. Branch `arr/wp1-library-share`.
Preconditions: WP0 report accepted; D1 = (b), D2, D3, D12 answered. The operator has sealed `library-share-credentials` (6.2) or will do it as step 5.

Files created: `talos/manifests/library-share/deployment.yaml`, `service.yaml`, `kustomization.yaml`, `talos/apps-src/library-share.yaml`, generated `talos/apps/library-share.yaml`; one line appended to `talos/test/empty-cluster-expectations.txt`. Files edited by the operator: `talos/sealed-secrets/library-share-credentials.yaml` (new), `talos/sealed-secrets/kustomization.yaml`.

1. Create `talos/manifests/library-share/deployment.yaml` (WHY: Samba is the one remote-file server that already runs in this cluster with the pinned image; hostPath rw is needed; `homeserver` is already privileged for hostPath). Assuming D2 = A and D3 = `Movies`/`Shows`:

```yaml
# SMB export of mini01's two Toshiba disks for the arr apps on mini03. The arr apps import finished
# downloads into the Jellyfin library through this share (plan docs/plans/arr-stack.md). Jellyfin keeps
# its own read-only hostPath mounts; only this pod writes. Cluster-internal only: no hostPort, no
# tailnet Service. The disks have NO redundancy and are NOT backed up by Velero.
# Image: same pin as talos/manifests/samba-nas (talos/storage/pins.env SAMBA_IMAGE).
apiVersion: apps/v1
kind: Deployment
metadata:
  name: library-share
  namespace: homeserver
  labels:
    app.kubernetes.io/name: library-share
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: library-share
  template:
    metadata:
      labels:
        app.kubernetes.io/name: library-share
    spec:
      nodeSelector:
        kubernetes.io/hostname: mini01
      initContainers:
        - name: root-dirs
          image: docker.io/library/busybox:1.37
          command:
            - sh
            - -c
            - |
              set -eu
              for d in disk1 disk2; do
                for f in Movies Shows; do
                  mkdir -p "/shares/$d/$f"
                  chown 1000:1000 "/shares/$d/$f"
                done
              done
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits: { cpu: 100m, memory: 32Mi }
          volumeMounts:
            - { name: disk1, mountPath: /shares/disk1 }
            - { name: disk2, mountPath: /shares/disk2 }
      containers:
        - name: samba
          image: docker.io/servercontainers/samba:smbd-only-a3.24.1-s4.23.8-r0@sha256:03bdd347ddb54577e5be499ca98c456e5f36d7d80c33819f46849ec2413b7b04
          env:
            - name: ACCOUNT_arrimport
              valueFrom:
                secretKeyRef:
                  name: library-share-credentials
                  key: password
            - name: UID_arrimport
              value: "1000"
            - name: SAMBA_VOLUME_CONFIG_disk1
              value: "[disk1]; path=/shares/disk1; valid users = arrimport; guest ok = no; read only = no; browseable = yes; create mask = 0664; directory mask = 0775"
            - name: SAMBA_VOLUME_CONFIG_disk2
              value: "[disk2]; path=/shares/disk2; valid users = arrimport; guest ok = no; read only = no; browseable = yes; create mask = 0664; directory mask = 0775"
          ports:
            - name: smb
              containerPort: 445
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { cpu: "1", memory: 256Mi }
          readinessProbe:
            tcpSocket: { port: smb }
            periodSeconds: 10
          livenessProbe:
            tcpSocket: { port: smb }
            initialDelaySeconds: 20
            periodSeconds: 30
          volumeMounts:
            - { name: disk1, mountPath: /shares/disk1 }
            - { name: disk2, mountPath: /shares/disk2 }
      volumes:
        - name: disk1
          hostPath:
            path: /var/mnt/media # Talos user volume u-media (first Toshiba, xfs), same disk Jellyfin mounts at /media/disk1
            type: Directory
        - name: disk2
          hostPath:
            path: /var/mnt/media2 # Talos user volume u-media2 (second Toshiba, xfs), Jellyfin /media/disk2
            type: Directory
```

   If D3 gives other folder names, change only the `for f in ...` list. If D2 = B, replace the two shares by four whose `path=` is `/shares/diskN/Movies` or `/shares/diskN/Shows`, named `disk1-movies`, `disk1-shows`, `disk2-movies`, `disk2-shows`.
   `[UNVERIFIED]`: `create mask`/`directory mask` accepted inside `SAMBA_VOLUME_CONFIG_*` with this image (the existing shares use `;`-separated Samba parameters, so it should); WP5 step 2 proves permissions. A mismatch is a Samba parse error in the pod log: remove the two mask clauses (the mount options set the presented mode).

2. Create `talos/manifests/library-share/service.yaml`:

```yaml
# Cluster-internal only; the CSI driver on mini03 mounts //library-share.homeserver.svc.cluster.local/<share>.
apiVersion: v1
kind: Service
metadata:
  name: library-share
  namespace: homeserver
  labels:
    app.kubernetes.io/name: library-share
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: library-share
  ports:
    - name: smb
      port: 445
      targetPort: smb
```

3. Create `talos/manifests/library-share/kustomization.yaml`:

```yaml
# SMB export of the Jellyfin library disks for the arr apps (plan docs/plans/arr-stack.md).
# The Secret library-share-credentials (keys username, password) is a SealedSecret in
# talos/sealed-secrets/, sealed by the operator; without it the pod stays in CreateContainerConfigError.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: homeserver
resources:
  - deployment.yaml
  - service.yaml
```

4. Create `talos/apps-src/library-share.yaml` (manual sync, like `jellyfin`):

```yaml
# Talos-only Application. Manual sync on purpose: it gives write access to the library disks.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: library-share
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/BrunoLoureirooo/homelab_gitops
    targetRevision: main
    path: talos/manifests/library-share
  destination:
    server: https://kubernetes.default.svc
    namespace: homeserver
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
```

5. Append to `talos/test/empty-cluster-expectations.txt`:
   `library-share            *       *       # manual sync; SMB export of mini01's library disks, needs the sealed library-share-credentials Secret`
   Run `talos/render-apps.sh --force`; `git status` must show `talos/apps/library-share.yaml` as new. Expected: no other generated change. If other files change, STOP.
6. Sealed secret: the PR description tells the operator to run the C1 commands of 6.2 on the PR branch and push the sealed file and the kustomization line; the executor does not.
7. Run guards, commit, push, open the draft PR.

PR title: "library-share: SMB export of the library disks for the arr apps". Body: purpose; "the operator after merge: 1) make sure the sealed secret `library-share-credentials` is merged (auto-synced by `talos-sealed-secrets`); 2) in Argo sync `library-share`; 3) watch the pod: `kubectl --context admin@<cluster> -n homeserver get pod -l app.kubernetes.io/name=library-share` becomes `1/1 Running` and its init container `root-dirs` completed; 4) no change to Jellyfin."

Verification (read-only, after the operator syncs): `kubectl --context admin@<cluster> -n homeserver get pods -l app.kubernetes.io/name=library-share -o wide` expect `1/1 Running`, node mini01; `... logs deploy/library-share --tail=30` expect smbd startup lines and no `invalid` messages; `... exec deploy/library-share -- ls -ld /shares/disk1/Movies /shares/disk2/Shows` expect owner `1000 1000`; `... exec -n homeserver deploy/jellyfin -- ls -ld /media/disk1/Movies` expect same dir visible read-only.
Rollback: The operator deletes/prunes the Argo app `library-share` (nothing else uses it yet); created folders are empty and may stay. The disks are not otherwise changed.
STOP point: after the PR is opened. Wait for "WP1 synced and verified".

### WP2 - Namespace, library volumes, staging claim, secrets references

Goal: namespace `arr`, the two SMB PVs/PVCs, (conditionally) the staging claim, and the Argo app `arr` skeleton. Branch `arr/wp2-storage`.
Preconditions: WP1 synced; D6, D7 answered; P1-P5.

Files: `talos/manifests/arr/kustomization.yaml`, `talos/manifests/arr/library-smb.yaml`, optionally `talos/manifests/arr/staging.yaml`, `talos/apps-src/arr.yaml`, generated `talos/apps/arr.yaml`, a line in `talos/test/empty-cluster-expectations.txt`, and an `arr` entry in `talos/manifests/namespaces/namespaces.yaml` only if absent (WP0 step 3).

1. Namespace (WHY: the app also uses `CreateNamespace=true`, but the Talos baseline is applied through the `namespaces` app; duplicates across apps are a conflict, so first check). If `arr` is NOT in `talos/manifests/namespaces/namespaces.yaml`, append:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: arr
```
   (no label: baseline is enforced cluster-wide; D7). If it is present (torrent plan merged first), do nothing and say so.
2. `talos/manifests/arr/library-smb.yaml` (WHY: static PVs over the share, the pattern of `talos/overlays/immich-infra/library-smb.yaml`; Retain means deleting a claim never deletes library files):

```yaml
# The two Jellyfin library disks, served by the library-share pod on mini01 (talos/manifests/library-share),
# as static csi-driver-smb volumes for the arr apps. Mount options present every file as 1000:1000,
# modes 664/775 (Servarr wiki: umask 002 with a shared group). nobrl: no byte-range locks over SMB.
# Retain: deleting a claim never deletes files. capacity is nominal (the CSI driver does not enforce it).
apiVersion: v1
kind: PersistentVolume
metadata:
  name: arr-library-disk1
spec:
  capacity:
    storage: 1Ti
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions:
    - dir_mode=0775
    - file_mode=0664
    - uid=1000
    - gid=1000
    - vers=3.1.1
    - nobrl
  csi:
    driver: smb.csi.k8s.io
    volumeHandle: mini01-library-share#disk1#arr-library-disk1
    volumeAttributes:
      source: //library-share.homeserver.svc.cluster.local/disk1
    nodeStageSecretRef:
      name: library-share-credentials
      namespace: homeserver
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: arr-library-disk2
spec:
  capacity:
    storage: 1Ti
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions:
    - dir_mode=0775
    - file_mode=0664
    - uid=1000
    - gid=1000
    - vers=3.1.1
    - nobrl
  csi:
    driver: smb.csi.k8s.io
    volumeHandle: mini01-library-share#disk2#arr-library-disk2
    volumeAttributes:
      source: //library-share.homeserver.svc.cluster.local/disk2
    nodeStageSecretRef:
      name: library-share-credentials
      namespace: homeserver
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: library-disk1
  namespace: arr
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  volumeName: arr-library-disk1
  resources:
    requests:
      storage: 1Ti
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: library-disk2
  namespace: arr
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  volumeName: arr-library-disk2
  resources:
    requests:
      storage: 1Ti
```
   (D2 = B: four PVs/PVCs instead, with `source: //library-share.homeserver.svc.cluster.local/disk1-movies` etc.)
3. Check the duplicates guard: nothing else may define PVs with these names (`grep -rn arr-library talos`).
4. Staging claim, ONLY if D6 says this plan owns it. Else skip and write "staging: owned by the torrent plan" in the PR. `talos/manifests/arr/staging.yaml`:

```yaml
# Torrent staging on mini03's own 283 GiB virtual disk (Talos user volume `staging`, /var/mnt/staging).
# Shared by qBittorrent and the arr importers (same node). Not backed up (disposable). Capacity nominal.
apiVersion: v1
kind: PersistentVolume
metadata:
  name: arr-staging
spec:
  capacity:
    storage: 283Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  local:
    path: /var/mnt/staging
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: [mini03]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: staging
  namespace: arr
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ""
  volumeName: arr-staging
  resources:
    requests:
      storage: 283Gi
```
   (RWO is per node: several pods on mini03 may mount it.) Whichever plan creates it, the name `staging` in `arr` must not be defined twice.
5. `talos/manifests/arr/kustomization.yaml`:

```yaml
# The arr stack on mini03 (plan docs/plans/arr-stack.md). Sealed Secrets sonarr-secrets, radarr-secrets,
# prowlarr-secrets live in talos/sealed-secrets/ (namespace arr).
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: arr
resources:
  - library-smb.yaml
  # - staging.yaml   # only if this plan owns the staging claim (decision D6)
```
   Careful: PVs are cluster-scoped; the `namespace:` transformer ignores them, and the PVCs carry their own namespace. Fine.
6. `talos/apps-src/arr.yaml`:

```yaml
# Talos-only Application for the arr stack. Manual sync on purpose. Pods are pinned to mini03.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: arr
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/BrunoLoureirooo/homelab_gitops
    targetRevision: main
    path: talos/manifests/arr
  destination:
    server: https://kubernetes.default.svc
    namespace: arr
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
```
   Expectations line: `arr                      *       *       # manual sync; arr apps pinned to mini03, need the sealed *-secrets and the library-share pod`.
7. `talos/render-apps.sh --force`, guards, commit, PR.

PR title "arr: namespace, library volumes over SMB, app skeleton". After merge, the operator: sync `namespaces` if it changed; sync `arr` only after mini03 is Ready (PVs and PVCs exist; the claims stay `Bound` without pods; `topolvm-fast` claims come in WP3).
Verification (after sync): `kubectl --context admin@<cluster> get pv arr-library-disk1 arr-library-disk2` expect `Bound` (PV shows `Bound` only once its claim exists: expect `Bound` to `arr/library-disk1`); `get pvc -n arr` expect `library-disk1 Bound ... 1Ti RWX`.
Rollback: delete the Argo app `arr` (PV reclaim `Retain` leaves the PVs `Released`; `library-share` data untouched).
STOP point after PR.

### WP3 - Sonarr and Radarr

Goal: Deployments, config PVCs, Services. Branch `arr/wp3-sonarr-radarr`. Preconditions: WP2 merged and synced; D4, D10, D13 answered; the operator has sealed C2, C3 (6.2) and merged them (otherwise pods stay in `CreateContainerConfigError`, which is intended).

Resolve the digests (3.1) and substitute `<DIGEST>`; the value must be 64 hex characters.

1. `talos/manifests/arr/sonarr.yaml`:

```yaml
# Sonarr (TV). Pinned to mini03. Image ghcr.io/linuxserver/sonarr 4.0.20.3014-ls329 (digest below).
# Starts as root and drops to PUID/PGID 1000 (the image's documented mode); hence no drop-ALL here.
# SQLite database in /config; /library/disk1 and /library/disk2 are the Jellyfin library disks over SMB
# (WP1/WP2); /downloads is the torrent staging volume shared with qBittorrent. Same paths in every pod.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sonarr-config
  namespace: arr
  labels:
    app.kubernetes.io/name: sonarr
spec:
  storageClassName: topolvm-fast
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sonarr
  namespace: arr
  labels:
    app.kubernetes.io/name: sonarr
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: sonarr
  template:
    metadata:
      labels:
        app.kubernetes.io/name: sonarr
      annotations:
        backup.velero.io/backup-volumes: config # Velero opt-in file-system backup (schedule arr-nightly)
    spec:
      automountServiceAccountToken: false # the app never calls the Kubernetes API
      nodeSelector:
        kubernetes.io/hostname: mini03
      tolerations:
        - key: node-role.homeserver/tier
          operator: Equal
          value: mobile
          effect: NoSchedule
      securityContext:
        fsGroup: 1000
      containers:
        - name: sonarr
          image: ghcr.io/linuxserver/sonarr@sha256:<DIGEST> # 4.0.20.3014-ls329
          ports:
            - name: http
              containerPort: 8989
          envFrom:
            - secretRef:
                name: sonarr-secrets # SONARR__AUTH__APIKEY
          env:
            - { name: PUID, value: "1000" }
            - { name: PGID, value: "1000" }
            - { name: UMASK, value: "002" }
            - { name: TZ, value: "Etc/UTC" } # D13
            - { name: SONARR__AUTH__METHOD, value: "Forms" }
            - { name: SONARR__AUTH__REQUIRED, value: "Enabled" }
          resources:
            requests: { cpu: 100m, memory: 384Mi }
            limits: { cpu: "1", memory: 1Gi }
          readinessProbe:
            tcpSocket: { port: http }
            periodSeconds: 10
          livenessProbe:
            tcpSocket: { port: http }
            initialDelaySeconds: 60
            periodSeconds: 30
          volumeMounts:
            - { name: config, mountPath: /config }
            - { name: library-disk1, mountPath: /library/disk1 }
            - { name: library-disk2, mountPath: /library/disk2 }
            - { name: downloads, mountPath: /downloads }
      volumes:
        - name: config
          persistentVolumeClaim: { claimName: sonarr-config }
        - name: library-disk1
          persistentVolumeClaim: { claimName: library-disk1 }
        - name: library-disk2
          persistentVolumeClaim: { claimName: library-disk2 }
        - name: downloads
          persistentVolumeClaim: { claimName: staging }
---
apiVersion: v1
kind: Service
metadata:
  name: sonarr
  namespace: arr
  labels:
    app.kubernetes.io/name: sonarr
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: sonarr
  ports:
    - name: http
      port: 8989
      targetPort: http
```

2. `talos/manifests/arr/radarr.yaml`: the same file with these substitutions everywhere: `sonarr` -> `radarr`, `SONARR__` -> `RADARR__`, port `8989` -> `7878`, image `ghcr.io/linuxserver/radarr@sha256:<RADARR DIGEST> # 6.4.4.10685-ls323`. Write it out in full (no includes). The mount list is identical (Radarr also imports from `/downloads` into `/library/diskN`).
3. Append to `talos/manifests/arr/kustomization.yaml` resources: `sonarr.yaml`, `radarr.yaml`.
4. Notes the PR must carry: (a) the tcpSocket probes are used because `/ping` is `[UNVERIFIED]`; (b) `backup.velero.io/backup-volumes: config` names the volume `config`; (c) mini03's taint assumption (P2).
5. Guards (the check for `latest`, raw secrets and apps), commit, PR "arr: Sonarr and Radarr on mini03".

After merge, the operator: confirm the sealed secrets synced (`kubectl --context admin@<cluster> -n arr describe secret sonarr-secrets` shows key names only), sync `arr`.
Verification (executor, read-only, after the sync):
- `kubectl --context admin@<cluster> -n arr get pods -o wide` expect `sonarr-...  1/1 Running  ... mini03`, same for radarr.
- `kubectl --context admin@<cluster> -n arr exec deploy/sonarr -- sh -c 'id; ls -ld /config /downloads /library/disk1 /library/disk2; df -h /library/disk1 /library/disk2 /downloads'` expect directories visible; free space of disk1/disk2 matches WP0 step 5; `/downloads` writable by uid 1000 (`[UNVERIFIED]` fsGroup effect: if `ls -ld /downloads` shows owner root and mode 755, write `needs decision` and report; fix is the operator's, see troubleshooting row 4).
- Test write permission without touching media: `kubectl --context admin@<cluster> -n arr exec deploy/sonarr -- sh -c 'su-exec abc touch /library/disk1/Shows/.arr-write-test 2>&1 || s6-setuidgid abc touch /library/disk1/Shows/.arr-write-test; ls -l /library/disk1/Shows/.arr-write-test; rm /library/disk1/Shows/.arr-write-test'` `[UNVERIFIED tool name: the lsio images use s6-setuidgid or the user 'abc'; if neither exists, skip and rely on WP5]`. (This creates and removes one empty file; permitted as an `exec` check by the operator's rules only because it is a test file. If in doubt, leave it to the operator in WP5.)
- `kubectl --context admin@<cluster> -n arr exec deploy/sonarr -- wget -qO- http://127.0.0.1:8989/ping` expect JSON `{"status":"OK"}` (`[UNVERIFIED]`; if it 404s write down the real response).
Rollback: The operator deletes the two Deployments by removing the files from the kustomization in a PR (PVCs stay; Retain). The config PVs persist; delete PVs only deliberately.
STOP point after PR.

### WP4 - Prowlarr and Bazarr

Branch `arr/wp4-prowlarr-bazarr`. Preconditions: WP3 merged; D15 answered; C4 sealed.

1. `talos/manifests/arr/prowlarr.yaml`: PVC `prowlarr-config` (`topolvm-fast`, 1Gi), Deployment `prowlarr`, Service `prowlarr` port 9696. Based on the Sonarr file with these differences: image `ghcr.io/linuxserver/prowlarr@sha256:<DIGEST> # 2.6.5.5623-ls165`; secret `prowlarr-secrets`; env `PROWLARR__AUTH__METHOD=Forms`, `PROWLARR__AUTH__REQUIRED=Enabled`; port 9696; resources `requests {cpu: 50m, memory: 192Mi}`, `limits {cpu: 500m, memory: 512Mi}`; volume mounts: only `/config` (no library, no downloads, no `volumes` for them). Write the file out in full.
2. `talos/manifests/arr/bazarr.yaml` (skip if D15 = no): PVC `bazarr-config` (1Gi), Deployment `bazarr`, Service `bazarr` port 6767. Image `ghcr.io/linuxserver/bazarr@sha256:<DIGEST> # v1.6.2-ls369`. NO `envFrom` (no secret; its login is set in the UI). Env: `PUID`, `PGID`, `UMASK=002`, `TZ`. Resources `requests {100m, 256Mi}`, `limits {cpu "1", memory 768Mi}`. Mounts: `/config`, `/library/disk1`, `/library/disk2` (read-write: Bazarr writes subtitle files next to the videos). No downloads mount. Probes tcpSocket on `http` (6767). Annotation `backup.velero.io/backup-volumes: config`. Toleration and nodeSelector as Sonarr.
3. Add both files to `kustomization.yaml`; guards; PR "arr: Prowlarr and Bazarr on mini03".
After merge the operator syncs `arr`.
Verification: `kubectl --context admin@<cluster> -n arr get pods` all four `1/1 Running` on mini03; `kubectl --context admin@<cluster> top pods -n arr` (record values); `kubectl --context admin@<cluster> top node mini03` (record, compare with 4.6).
Rollback: as WP3. STOP point after PR.

### WP5 - Network and permission proof (The operator and the executor, no repository change)

Goal: measure the SMB path before anyone relies on it. No PR; a report.

1. Executor (read-only): confirm `kubectl --context admin@<cluster> get pv,pvc -A | grep -E 'arr-library|library-disk|staging'` all Bound.
2. The operator, in his terminal (these write a test file; the executor must not run them): a throughput and permission test through the Sonarr pod.
   `kubectl --context admin@<cluster> -n arr exec deploy/sonarr -- sh -c 'dd if=/dev/zero of=/downloads/speedtest.bin bs=1M count=2048 status=none && time cp /downloads/speedtest.bin /library/disk1/Shows/speedtest.bin && ls -ln /library/disk1/Shows/speedtest.bin && rm /library/disk1/Shows/speedtest.bin /downloads/speedtest.bin'`
   Expected: `ls -ln` shows owner `1000 1000`, mode `-rw-rw-r--`; the `cp` time gives MB/s. Write it down. Acceptable: above about 15 MB/s (a 10 GiB film in about 11 minutes). If below, see troubleshooting row 2; report.
3. The operator: on mini01, the same file seen by Jellyfin: during step 2 run (before `rm`) `kubectl --context admin@<cluster> -n homeserver exec deploy/jellyfin -- ls -ln /media/disk1/Shows/speedtest.bin` expect owner 1000, readable. Remove the file afterwards (the command above does).
4. The operator, partial-file check (D8): start a large copy and in a second terminal list the destination folder to see whether the app/`cp` writes under a temporary name: informational only (Sonarr's behaviour `[UNVERIFIED]`).
STOP point: report numbers; if the rate is unacceptable or ownership is wrong, STOP; do not proceed to WP6 until the operator says so.

### WP6 - Tailnet ingress for each app

Branch `arr/wp6-ingress`. Preconditions: WP4 synced; the four apps are healthy; D11 answered.

1. `talos/manifests/arr/ingress.yaml` (pattern of `talos/manifests/jellyfin/ingress.yaml`; the short name comes from `tls.hosts`, the full tailnet name is never committed):

```yaml
# Tailnet-only web access for the arr apps through the Tailscale operator. Short names only; the full
# tailnet name is a host detail and is not committed. A stale device with the same name makes the new
# one register as <name>-1: delete stale devices in the Tailscale admin console first.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: sonarr
  namespace: arr
  labels:
    app.kubernetes.io/name: sonarr
spec:
  ingressClassName: tailscale
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: sonarr
                port:
                  number: 8989
  tls:
    - hosts:
        - sonarr
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: radarr
  namespace: arr
  labels:
    app.kubernetes.io/name: radarr
spec:
  ingressClassName: tailscale
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: radarr
                port:
                  number: 7878
  tls:
    - hosts:
        - radarr
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prowlarr
  namespace: arr
  labels:
    app.kubernetes.io/name: prowlarr
spec:
  ingressClassName: tailscale
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: prowlarr
                port:
                  number: 9696
  tls:
    - hosts:
        - prowlarr
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: bazarr
  namespace: arr
  labels:
    app.kubernetes.io/name: bazarr
spec:
  ingressClassName: tailscale
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: bazarr
                port:
                  number: 6767
  tls:
    - hosts:
        - bazarr
```
2. Add `ingress.yaml` to `kustomization.yaml`; guards (host-detail guard must stay `OK`); PR "arr: tailnet ingress for the four apps".
3. The operator after merge: delete stale `sonarr`/`radarr`/`prowlarr`/`bazarr` devices in the Tailscale admin console if present; sync `arr`; then complete WP8 immediately (Bazarr has no login until he sets it).
Verification: `kubectl --context admin@<cluster> -n arr get ingress` shows four ingresses with ADDRESS filled after a minute; `kubectl --context admin@<cluster> -n tailscale get pods` shows `ts-sonarr-*`, `ts-radarr-*`, `ts-prowlarr-*`, `ts-bazarr-*` Running; the operator opens `https://sonarr` etc. on a tailnet device and gets the login/first-run page.
Rollback: remove `ingress.yaml` from the kustomization (Argo prune of the app on next sync) and delete the stale devices.
STOP point after PR.

### WP7 - Backups: Velero schedule, node agent on mini03

Branch `arr/wp7-velero`. Preconditions: WP4 merged; P11 result; D14.

1. Edit `talos/values/velero.yaml` (NOT `argocd/values/velero.yaml`; read the header comments first): in the existing `schedules:` map add a sibling key (maps merge in Helm; do not touch `homeserver-nightly`):

```yaml
  arr-nightly:
    schedule: "45 3 * * *" # daily 03:45 UTC, after cp-reserva-bot-nightly (03:30)
    template:
      ttl: "720h0m0s"
      includedNamespaces:
        - arr
```
   and a top-level block for the node agent so it runs on mini03 (the base chart values set only resources for it; adding tolerations merges):

```yaml
nodeAgent:
  tolerations:
    - key: node-role.homeserver/tier
      operator: Equal
      value: mobile
      effect: NoSchedule
```
   (If `talos/values/velero.yaml` already has a `nodeAgent:` key or PR #71 added tolerations, merge into it, do not duplicate.) Do NOT set `defaultVolumesToFsBackup`: the volumes are opted in by the pod annotation `backup.velero.io/backup-volumes: config`, which excludes the SMB library volumes and staging. WHY: otherwise Velero would try to read the multi-hundred-GiB library over SMB.
2. Run the guards; PR "velero: nightly arr schedule and node agent on mini03". The operator syncs `velero` after mini03 is Ready; then `kubectl --context admin@<cluster> -n velero get ds node-agent` shows 3 pods and `get schedules` lists `arr-nightly`.
3. In-app backups (the operator, UI; also in WP9): Settings > General > Backups: interval 1 day, retention 14 days (verified setting exists, values D14).
Verification (after the first run): `kubectl --context admin@<cluster> -n velero get backups | grep arr` expect `Completed`; `kubectl --context admin@<cluster> -n velero describe backup <arr backup name> | grep -i -A5 "Pod Volume"` expect four volumes (`config` of each app) `Completed`, no library volumes.
Rollback: revert the PR.
STOP point after PR. The operator performs the restore test of section 8 once.

### WP8 - Bazarr and app lock-down (the operator, UI; copy-paste list)

Do this right after WP6. The operator:
1. Open `https://bazarr`; in Settings > General > Security set Authentication to Forms and a username/password (store in Vaultwarden) `[UNVERIFIED exact label]`. Save, restart if asked.
2. Open `https://sonarr`, `https://radarr`, `https://prowlarr`: create the administrator login on the first-run screen (6.3). Store in Vaultwarden.
3. In each of Sonarr, Radarr and Prowlarr: Settings > General > Security: confirm Authentication = Forms and Authentication Required = Enabled (they come from the environment variables).
4. Settings > General > Backups (each app): interval 1 day, retention 14 days.
5. Settings > General > Analytics: turn off sending anonymous usage data if desired.
6. Subtitle providers in Bazarr (Settings > Providers) are chosen and entered by the operator. Infrastructure facts only: they need outbound HTTPS from the pod (the cluster has full egress), credentials are stored in `/config/config/config.yaml` on the PVC (plaintext inside the volume, not in git), Velero `arr-nightly` backs them up. This plan does not list providers.

### WP9 - First-run configuration and linking (the operator, UI; the order matters)

Order and the exact values (every host is a cluster-internal Service name, no tailnet involved):

1. **Media Management in Sonarr** (Settings > Media Management):
   - Rename Episodes ON; Standard Episode Format `{Series Title} - S{season:00}E{episode:00} - {Episode Title}`; Series Folder `{Series Title} ({Series Year})`; Season Folder `Season {season:00}` (Jellyfin naming) `[UNVERIFIED tokens: copy from the in-UI token list if any differs]`.
   - Importing: leave "Use Hardlinks instead of Copy" at its default (it falls back to copy across filesystems, verified); "Import Extra Files" ON for subtitles.
   - Minimum Free Space 20480 MB (D3). Skip Free Space Check OFF. Set Permissions OFF.
   - Root Folders: add `/library/disk1/Shows` and `/library/disk2/Shows`. The UI shows free space for each: compare with `df` output of WP0.
2. **Media Management in Radarr**: Movie Folder `{Movie Title} ({Release Year})`, Standard Movie Format `{Movie Title} ({Release Year})`; Minimum Free Space 20480; root folders `/library/disk1/Movies` and `/library/disk2/Movies`. Same other settings.
3. **Download client** in Sonarr and Radarr: Settings > Download Clients > Add > qBittorrent. Host `qbittorrent`, Port `8080`, Use SSL off, username/password from the torrent plan `[ASSUMED]` (Vaultwarden), Category `tv` (Sonarr) and `movies` (Radarr), Test must say success. `[ASSUMED]` host and port from the torrent plan. Enable "Remove Completed" under Completed Download Handling when the seeding rules are decided. If the test fails with a host-header or CSRF message from qBittorrent, that is the client's own web-UI setting (troubleshooting row 7).
4. **Jellyfin connection** (4.5): Jellyfin > Dashboard > Advanced > API Keys > "+" name `arr`, copy once into Vaultwarden; Sonarr and Radarr > Settings > Connect > Add "Emby / Jellyfin": host `jellyfin.homeserver.svc.cluster.local`, port 8096, SSL off, API key, triggers as in 4.5, Update Library ON, Test. Also set Jellyfin library path(s) to include the new roots: Dashboard > Libraries: Movies library must include `/media/disk1/Movies` and `/media/disk2/Movies`; Shows: `/media/disk1/Shows` and `/media/disk2/Shows` (Jellyfin sees the same folders under different paths, which is why the apps use Jellyfin's API and not paths).
5. **Prowlarr to Sonarr and Radarr**: Prowlarr > Settings > Apps > Add > Sonarr: Prowlarr Server `http://prowlarr:9696`, Sonarr Server `http://sonarr:8989`, API Key = Sonarr's (clipboard command 6.4), Sync Level "Full Sync" (The operator's choice), Test. Repeat for Radarr (`http://radarr:7878`). The sources Prowlarr serves are configured in its UI by the operator (out of scope).
6. **Bazarr to Sonarr and Radarr**: Bazarr > Settings > Sonarr: Address `sonarr`, Port `8989`, API Key, Base URL empty, SSL off, Test. Settings > Radarr: `radarr` / `7878`. Path mappings: none needed (same `/library/...` paths everywhere); if Bazarr lists a path warning, compare the path Sonarr reports with Bazarr's mount.
7. **Smoke test**: in Sonarr add one series that is already in the library root of disk2 (or test with one small title) with root folder chosen deliberately, search/import manually; confirm: file lands under the chosen disk; Jellyfin shows it within a minute; ownership 1000; staging copy remains until the client removes it (expected, seeding).
8. **qBittorrent categories**: Sonarr and Radarr rely on the categories above; the torrent plan owns the client's save paths (`/downloads/...`).

### WP10 - Optional hardening (non-root), after everything works

Branch `arr/wp10-nonroot`. Preconditions: D5 = yes; backups taken (section 8).
Trial one app at a time, starting with Prowlarr (no library mounts): in its Deployment add `securityContext: {runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000}` at pod level and `allowPrivilegeEscalation: false`, `capabilities: {drop: [ALL]}` at container level, remove `PUID`/`PGID` (no effect), add `volumes: - name: run, emptyDir: {medium: Memory}` mounted at `/run` (documented requirement: `/run` owned by the user; the emptyDir owner follows `fsGroup`; `[UNVERIFIED]` for the exact ownership, maintainers use `/run:uid=1000,gid=1000,exec`). If `/config` is owned by a different uid from the first run (the previous root-start run chowned it to 1000, so it should be 1000) the app starts; otherwise STOP. If the pod crashloops, revert; this is why it is optional. Read-only root filesystem: same trial, later.

### WP11 - Docs

Branch `arr/wp11-docs`. Update `docs/BACKLOG.md` row "Sonarr and the arr stack" to state, create `docs/dr/arr-restore.md` containing section 8's restore test verbatim, and one row in `docs/dr/talos-backups.md` listing `arr-nightly` if that file has a schedule table. Guards, PR "docs: arr stack state and restore test".

## 8. Backup and restore

| What | Mechanism | Frequency / retention | Not covered |
|---|---|---|---|
| Config of Sonarr, Radarr, Prowlarr, Bazarr (`/config`: databases, `config.xml`/`config.yaml`, in-app backups, cover images) | Velero file-system backup (kopia), opt-in by the pod annotation `backup.velero.io/backup-volumes: config`, schedule `arr-nightly` | daily 03:45 UTC, 720h, to MinIO on mini02 (second copy on mini03 is PR #71) | the library disks (no backup exists, separate topic), staging (disposable), the SMB mounts |
| Each app's database, consistently | The app's own backup (Settings > General > Backups, a zip in `/config/Backups` or the configured folder, interval 1 day, 14 days) | daily | n/a |
| Manual export | Each app: System > Backup > "Backup Now" then download the zip; store in Vaultwarden attachments or on the NAS `backups` share | before every upgrade | |
| Sealed secrets | git (ciphertext) + Vaultwarden (values) | | |

Why two layers: the apps keep live SQLite databases. Velero copies the files while the app may write; a copy can be
inconsistent. The app's own zip is consistent and is itself inside `/config`, so Velero preserves it. A restore therefore prefers
the in-app zip (inside the restored `/config`) over the live database file. `[UNVERIFIED: whether a kopia copy of a quiet SQLite DB restores cleanly; the restore test below answers it.]`
Cover images (`MediaCover`) can reach a few GB for a large library and make backups bigger; that is accepted (they are re-downloadable); if it becomes a problem, mount an `emptyDir` over `/config/MediaCover` (The operator decision, not now).

### Restore test (The operator performs, once after WP7; the executor writes this into `docs/dr/arr-restore.md`)

Goal: prove a Velero backup of `arr` restores a usable Sonarr config, without touching the live app.

1. `kubectl --context admin@<cluster> -n velero get backups | grep arr` and note a Completed backup name `<B>`.
2. Restore into a scratch namespace, excluding things that would clash with the live objects (ingresses, PVs of the library, secrets are restored with the namespace; the Sonarr pod is scaled to zero right after):
   `velero restore create arr-test --from-backup <B> --include-namespaces arr --namespace-mappings arr:arr-restore-test --exclude-resources ingresses.networking.k8s.io,persistentvolumes --restore-volumes`
   (run on the operator's machine with the `velero` CLI pointed at the cluster; not an executor command).
3. In the scratch namespace the restored Deployments reference `library-disk1/2` PVCs and `staging`, which do not exist there: the pods stay `Pending`. That is intended; only the restored PVC data matters. Check `kubectl --context admin@<cluster> -n arr-restore-test get pvc` shows `sonarr-config` Bound with data restored (`velero restore describe arr-test --details` lists the pod volume restore `Completed`).
4. Inspect without starting the app: create a one-off pod in the scratch namespace that mounts `sonarr-config` read-only and lists `/config` (The operator writes this by hand): expect `sonarr.db`, `config.xml`, `Backups/`. Do not print `config.xml`.
5. Clean up: `kubectl --context admin@<cluster> delete ns arr-restore-test` and `velero restore delete arr-test` (the operator). The Retain policy leaves the scratch PV `Released`: delete it deliberately.
6. A real disaster restore: restore namespace `arr` from the backup into the same namespace after deleting the Argo app's workloads, then verify login and library listing; if the database does not open, restore the newest in-app zip with System > Backup > Restore.

## 9. Security

- **Exposure**: tailnet only, via the Tailscale operator Ingress per app (WP6). Services are ClusterIP. No hostPort, no public exposure. The library share is a ClusterIP Service, not on the tailnet.
- **Authentication**: Forms login with `Authentication Required: Enabled` for Sonarr/Radarr/Prowlarr (set by env, so it cannot be turned off by mistake in the UI); Bazarr login set in WP8. `DisabledForLocalAddresses` is not used (the wiki documents a bypass CVE for it behind proxies, and Tailscale ingress traffic looks local; `TRUSTCGNATIPADDRESSES` is left at its default `false`).
- **API keys**: per-app sealed Secrets; each pod only receives its own key.
- **Least privilege**: dedicated SMB account `arrimport` instead of the NAS account; the share exists only in-cluster; apps mount the library read-write because Sonarr/Radarr/Bazarr must write; decision D2 can narrow it to `Movies`/`Shows`. Jellyfin remains read-only. Prowlarr has no library or download mounts. Bazarr has no download mount.
- **Pod security**: baseline-compatible, no hostPath, no privileged, no host network, default ServiceAccount token not needed: `automountServiceAccountToken: false` is set in every arr pod spec (the apps never call the Kubernetes API); WP3 step 2 and WP4 copy it from the Sonarr file. Root-start with PUID drop is the documented compromise (D5); WP10 hardens.
- **Network**: flannel in this cluster is not known to enforce NetworkPolicy `[UNVERIFIED]`; none are written. Egress is open (the apps need metadata sites; Bazarr needs provider sites).
- **Data at risk**: the writable mount on the library disks. Mitigations: Recycle bin OFF vs ON is D3; no backup exists for the library: any accidental delete is permanent. The operator should keep "Unmonitor instead of delete" as habit.
- **Secrets in clear**: Bazarr provider credentials sit in plaintext in its PVC (and in the Velero backup in MinIO). Acceptable for a tailnet-only homelab; noted.

## 10. Operations

### Upgrade procedure (bump the digest in a PR)

1. The operator takes an in-app backup in each app (System > Backup > Backup Now) or confirms last night's `arr-nightly` is Completed.
2. Executor: pick the new tag (maintainers' release list, stable tags only), resolve the digest with the query in 3.1, edit the image line and the tag comment in `talos/manifests/arr/<app>.yaml`, one app per PR, read the project's release notes for breaking changes and quote them in the PR.
3. Guards, draft PR. The operator merges, syncs `arr` in Argo, watches the pod, opens the UI, checks System > Status shows no new errors and that the Jellyfin connection Test passes.
4. Downgrade: not supported by the databases. Rollback = revert the PR AND restore `/config` from the backup (section 8).
5. Cadence: monthly or on security advisories (the Servarr wiki lists advisories in the settings pages).

### Health checks (read-only)

- `kubectl --context admin@<cluster> -n arr get pods -o wide` all `1/1 Running`, node mini03.
- `kubectl --context admin@<cluster> -n arr top pods` against the limits in 4.6.
- `kubectl --context admin@<cluster> -n arr exec deploy/sonarr -- df -h /library/disk1 /library/disk2 /downloads`.
- In each app: System > Status (health warnings list unreachable download client, root folder missing, free space).
- Logs: `kubectl --context admin@<cluster> -n arr logs deploy/sonarr --tail=100` (the app also keeps logs in `/config/logs`).

### Troubleshooting

| # | Symptom | Where to look | Likely cause | Fix |
|---|---|---|---|---|
| 1 | Pod `Pending`, event "node(s) had untolerated taint" | `kubectl describe pod -n arr <pod>` | the toleration does not match mini03's taint (P2), or mini03 not Ready | correct the toleration key/value in a PR; wait for P1 |
| 2 | Import very slow or times out | `time cp` in WP5; node network | SMB over the cluster network (tailnet) is slow; relayed path | measure; the operator investigates direct tailnet paths (see `pod-udp-snat` app); fall back to scheduling big imports at night |
| 3 | Pod `ContainerCreating` for a long time, event `MountVolume.MountDevice failed` for `library-disk1` | `describe pod`, `kubectl -n kube-system logs ds/csi-smb-node -c smb` | wrong share name, credentials secret missing or wrong, library-share not running, mini03 cannot reach `library-share.homeserver.svc` (DNS from the CSI pod) | check `library-share` pod; `describe secret library-share-credentials -n homeserver` shows keys `username`,`password`; verify PV `source` |
| 4 | Sonarr cannot write to `/downloads` or library: "Access to the path is denied" | `ls -ld` in the pod | staging directory owned by root and `fsGroup` not applied to the `local` volume; or files on disk owned by a different uid | staging: The operator runs a one-time chown Job on mini03 (not in this plan) or the torrent plan creates the folders as 1000; library: WP0 step 6 and D3 |
| 5 | Import says "No files found" or "Import failed, path does not exist" | Activity > Queue message | download client reports a path that is not mounted at the same place in the arr pod | align the mount path or add a Remote Path Mapping (4.2) |
| 6 | Jellyfin does not show new files | Sonarr Settings > Connect > Test; Jellyfin Dashboard > Scheduled tasks | wrong Jellyfin API key or host; library folders not added to Jellyfin libraries; D8 | re-create key, check host `jellyfin.homeserver.svc.cluster.local:8096`, add the folders in Jellyfin |
| 7 | Test of qBittorrent fails: forbidden / unauthorized / host header | Sonarr log | qBittorrent web UI rejects the Host header or CSRF check, or wrong login (the torrent plan owns its settings) | tell the operator; the fix is in qBittorrent options (host header validation / allowed domains) `[UNVERIFIED]` |
| 8 | "Disk space" warning or imports blocked | System > Status | free space below Minimum Free Space on the chosen disk | choose the other root folder for new titles; delete or move content; staging: lower seeding limits |
| 9 | App restarts in a loop, log mentions `config.xml` or database corruption | `logs --previous` | a bad restore, or the PVC node is not mini03 | restore from the in-app zip or Velero (section 8) |
| 10 | `https://sonarr` shows nothing | `kubectl -n tailscale get pods` ts-sonarr; Tailscale admin console | stale device name (`sonarr-1`), proxy not running | delete stale devices; check Ingress ADDRESS |
| 11 | Velero backup shows `PartiallyFailed` for arr | `velero backup describe --details` | node-agent not on mini03 (taint) | WP7 tolerations |
| 12 | Prowlarr/Bazarr Test cannot connect to Sonarr | the pod log | wrong key, or used the tailnet name instead of the Service name | use `http://sonarr:8989` and the key from 6.4 |
| 13 | After rotating the Samba password imports fail | mount events | pods keep the old mount | The operator deletes the arr pods in the Argo UI so they re-mount |

## 11. Acceptance checklist and report format

### Acceptance (The operator sees all of this working)

- [ ] `kubectl --context admin@<cluster> -n arr get pods` shows sonarr, radarr, prowlarr, bazarr `1/1 Running` on mini03; `library-share` runs on mini01.
- [ ] `https://sonarr`, `https://radarr`, `https://prowlarr`, `https://bazarr` open from a tailnet device and require a login.
- [ ] Sonarr and Radarr list four root folders with the free space of each disk.
- [ ] Prowlarr > Settings > Apps shows Sonarr and Radarr with a green test; Bazarr's Sonarr/Radarr tests are green; the qBittorrent test is green in both.
- [ ] A test title imports from `/downloads` to the chosen disk, owned by uid 1000, and appears in Jellyfin without a manual scan; the other disk is untouched.
- [ ] The measured SMB throughput is recorded in the WP5 report.
- [ ] `arr-nightly` has a Completed backup; the restore test (section 8) has been done once.
- [ ] No secret, address or tailnet name is in the repository; 20 of 20 guards `OK`.
- [ ] BACKLOG updated.

### Report format (after every WP)

```
WP<n>: done | blocked | needs decision
PR: <url or none>
Guards: 20/20 OK | list of failures
Verified: <commands run and what they showed, no secret values>
Differences from the plan: <or none>
Needs from the operator: <decisions, sealed files, Argo syncs, UI steps>
```

## 12. Open questions and UNVERIFIED items

1. mini03 does not exist yet; taint key/value, node name, volumes `data` and `staging` are `[ASSUMED]` from `docs/dr/mini03.md` (branch `talos/victus-vm`). Confirm in WP0.
2. Torrent plan interfaces `[ASSUMED]`: Service `qbittorrent.arr.svc:8080`, claim `staging` in `arr`, mount path `/downloads`, qBittorrent login handling, who creates namespace `arr`, its pod-security label.
3. Radarr environment variable names (`RADARR__AUTH__*`): by rule only; WP0 step 9.
4. `/ping` health endpoint of Sonarr/Radarr/Prowlarr and an HTTP health path for Bazarr: not found in the sources read; tcpSocket probes used.
5. Whether kubelet applies `fsGroup` to the `local` staging volume; fallback in troubleshooting row 4.
6. Whether the lsio images run correctly non-root (WP10) and read-only.
7. Exact first-run screens (admin creation, Bazarr security page), the connection type name "Emby / Jellyfin" in the current Sonarr/Radarr, the "Remove Completed" wording.
8. Jellyfin API: endpoint `/Library/Refresh` and the `Authorization: MediaBrowser Token="..."` header form; the API-key menu path in Jellyfin 10.10.7.
9. Whether Sonarr/Radarr write imports under a temporary name during the copy (affects partial files seen by Jellyfin, D8).
10. Real SMB throughput between mini03 and mini01; flannel runs over the tailnet today (node addresses are tailnet addresses).
11. Whether the Servarr FAQ's password-reset procedure applies (the wiki FAQ page was not retrievable from this session; only the GitHub copies of the wiki pages for settings, environment variables and the Docker guide were read).
12. Bazarr API key/login: no environment variable known; subtitle providers are the operator's.
13. Release notes for the pinned major versions were not read (3.6).
14. NetworkPolicy enforcement by the CNI.
15. `create mask`/`directory mask` clauses inside `SAMBA_VOLUME_CONFIG_*` with the pinned Samba image.
16. Contradiction between the brief and the repo to note: the brief says the library folders follow `Movies/` and `Shows/`; `talos/manifests/jellyfin/deployment.yaml` comments name older folders (`Films`, `anime`, ...). `docs/dr/mini03.md` proposes the same SMB export ("mini01 exports /var/mnt/media and /var/mnt/media2") and puts qBittorrent/gluetun possibly in a separate namespace `torrent` with the arr apps in `arr`, whereas the brief puts both in `arr`: this plan follows the brief and lists the question as D7.
