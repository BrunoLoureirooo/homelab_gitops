# Plan: qBittorrent behind gluetun (VPN kill switch) on mini03

Audience: a local language model working on this repository for the operator. Follow it literally, one work
package (WP) at a time. Where it says STOP, stop and report to the operator; do not decide for him.

Written 2026-10-25. Status of the world on that date: mini03 does not exist yet (VM still in draft PRs
#49, #52, #71), the arr stack is a separate plan, nothing of this plan is deployed.

Facts are marked `[verified <url>]` (read in official documentation or from the official registry on
2026-10-25), `[ASSUMED]` (an interface another plan must provide) or `[UNVERIFIED]` (could not be
confirmed; the text says how the executor confirms it).

## 0. Purpose, scope, non-goals, definition of done

**SCOPE LIMIT (read first).** This plan is INFRASTRUCTURE ONLY: how a torrent client is deployed, how its
network is locked to a VPN, where its files and configuration live, how its credentials are sealed, how it
is backed up and monitored. It does NOT cover, and the executor must NOT research, add, suggest or write
down: trackers, torrent sites, indexers, magnet links, or any source of media, or what to download. The operator
decides that himself, in the application's own web UI, after this plan is finished. If a step seems to need
such a thing, STOP and ask the operator.

**Purpose.** Run the qBittorrent download client in namespace `arr` on node `mini03`, with ALL of its network
traffic leaving only through a VPN tunnel run by gluetun in the same pod, with a working inbound port
(provider port forwarding), downloads staged on mini03's 283 GiB `staging` volume, and its WebUI reachable
(a) by the arr apps in the cluster at `qbittorrent.arr.svc` port 8080 `[ASSUMED interface for the arr-stack
plan]` and (b) by the operator on the tailnet.

**Non-goals.** The arr apps themselves (arr-stack plan). Building the mini03 VM (mini03-vm plan). The second
backup copy on mini03 (backup-replica plan). Choosing media sources. Moving finished media into the Jellyfin
library on mini01 (arr-stack plan). Backing up the downloads (they are disposable).

**Definition of done** (all must be true; Section 11 has the long form):

- [ ] Decisions D1 to D8 (Section 5) answered by the operator and recorded in the PR descriptions.
- [ ] A test pod proved `/dev/net/tun` and `NET_ADMIN` work on mini03 and the result is written down (WP2).
- [ ] Namespace `arr` exists with the Pod Security label decided in D4 (WP3).
- [ ] Sealed Secrets `gluetun-vpn` and `qbittorrent-webui` committed (WP4, WP6).
- [ ] Pod `qbittorrent` (init `fix-perms`, sidecar `gluetun`, container `qbittorrent`) Running 2/2 on mini03,
      pinned by image digest (WP5).
- [ ] Leak tests pass: public IP seen from inside the pod differs from the operator's own; with the tunnel down
      nothing leaves; DNS goes through the tunnel (Section 7, WP7).
- [ ] The forwarded port is set in qBittorrent automatically and shows as "connectable" (WP7).
- [ ] Permanent WebUI password set, stored in the operator's password manager and in the sealed Secret (WP6).
- [ ] Tailnet WebUI reachable (WP8). Disk-space guard CronJob works (WP9). Backup schedule covers `arr` (WP10).
- [ ] `docs/plans/torrent-gluetun.md` open questions (Section 12) answered or still listed.

## 1. Rules for the executor

1. You change files in the repository and open pull requests. Nothing else. The operator merges PRs and syncs Argo CD
   apps himself in the Argo web UI.
2. Cluster access is READ-ONLY and always with `--context admin@<cluster>`: `get`, `describe`, `logs`, `top`,
   and `exec ... -- <read-only command>` only where a step says so. Forbidden: `apply`, `create`, `delete`,
   `patch`, `edit`, `scale`, `rollout`, `replace`, `label`, `annotate`, `drain`, `cordon`, `taint`, any
   `talosctl apply-config/upgrade/reset`, any `argocd app sync`. Never suggest a live `kubectl patch/apply`
   to the operator either: every change goes through a PR and an Argo sync.
3. NEVER print or decode secret values. Forbidden: `get secret -o yaml/json/jsonpath`. `describe secret`
   (key names only) is allowed. If any command prints something that looks like a key, token or password,
   STOP and tell the operator without repeating it.
4. Secrets enter the repo only as SealedSecret objects in `talos/sealed-secrets/`, sealed by the operator (he types
   the values). You never receive a value. Use placeholders such as `<paste from password manager>`.
5. Do NOT write IPv4 addresses, MAC addresses, disk serials, `/dev/disk/by-id` names, or any host name ending
   in `.ts.net` into any committed file (guard `check-no-host-details.sh`). That includes the pod and
   service network ranges (they are 10.x ranges and are rejected). Section 4.4 explains how this plan
   delivers the one setting that needs them (a sealed key).
6. One concern per pull request, branch from current `origin/main`:
   `git fetch origin && git switch -c <branch> origin/main`. Open PRs as DRAFTS. Never push to `main`, never
   force-push, never merge, never delete a branch. Commit messages end with the line
   `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; PR descriptions end with the line
   `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
7. Before every commit run `bash .github/scripts/run-all-guards.sh`. Every line must start with `OK` (20
   checks). Never edit a guard to make it pass. If one fails, fix your file or STOP.
8. After changing `talos/apps-src/*.yaml` run `talos/render-apps.sh --force` and commit the generated
   `talos/apps/<app>.yaml` (and anything else it regenerates). Every Application needs one line in
   `talos/test/empty-cluster-expectations.txt`.
9. Never use image tags `latest`. Pin every image by digest (`image: repo:tag@sha256:...`), Section 3.3.
10. EVERY PVC sets `storageClassName: topolvm-fast` (the cluster's only StorageClass, not the default; the
    `docs/templates/ghcr-app` PVC template lacks it, do not copy that gap).
11. EVERY container, including init containers, sets explicit `resources` (requests and limits).
12. STOP conditions: a decision in Section 5 is unanswered and a package depends on it; a read-only check in a
    precondition fails; a guard fails and the fix is not obvious; `mini03` does not exist as a Node; any
    command output differs from "expected" in a way the plan does not explain; anything would require a
    live cluster change. Report to the operator in the format of Section 11 and wait.
13. Never decide a the operator decision. Never pick a VPN provider, region, or hostname for him.
14. If the repo or the cluster differs from this plan, trust what you see, write the difference down in the
    report ("Differences from the plan"), and ask.
15. Out-of-scope content (Section 0) is never researched or written.

## 2. Prerequisites and dependencies

Run these read-only checks in WP1 and put the output in the report.

| Needs | Proof (read-only) | If not ready |
|---|---|---|
| mini03 is a Node, Ready, with the taint `node-role.homeserver/tier=mobile:NoSchedule` and the xfs volume `staging` | `kubectl --context admin@<cluster> get node mini03 -o wide` and `kubectl --context admin@<cluster> get node mini03 -o jsonpath='{.spec.taints}'` and `talosctl`-free check: later WP5 pod mounts `/var/mnt/staging` | STOP. WP1 to WP3 can still be written; WP2 (tun probe) and everything after cannot be deployed. mini03 is built by the mini03-vm plan (PRs #49, #52, #71) |
| Namespace `arr` creation is coordinated with the arr-stack plan `[ASSUMED]` | `git grep -n "name: arr" -- talos/manifests/namespaces` | If the line already exists (arr-stack merged first), do not add it again, only check its labels (D4) |
| Sealed Secrets controller works | `kubectl --context admin@<cluster> -n kube-system get pods` (look for sealed-secrets) and `... get sealedsecrets -A` | STOP, ask the operator |
| Tailscale operator works | `kubectl --context admin@<cluster> -n tailscale get pods` shows `operator-*` Running | STOP |
| StorageClass `topolvm-fast` exists | `kubectl --context admin@<cluster> get storageclass` | STOP |
| Velero is healthy (for WP10) | `kubectl --context admin@<cluster> -n velero get pods` and `... get backupstoragelocations -n velero` shows `Available` | Skip WP10, report |
| The operator has a paid VPN subscription that supports port forwarding (decision D1) | He tells you | STOP at WP4 |
| The operator's password manager (Vaultwarden on the tailnet) is usable | He tells you | Not blocking |

Depends on this service: the arr-stack plan (`qbittorrent.arr.svc:8080`, categories, the shared staging
path `/data`), the monitoring plan (alerts on this pod and CronJob), the backup-replica plan (Velero schedule
and node agent toleration on mini03, WP10 here must be coordinated with it).

Interfaces this plan ASSUMES from sibling plans (`[ASSUMED]`, confirm in WP1 by reading `docs/plans/` on
`origin/main` if those plans have been merged; otherwise ask the operator):

- Namespace `arr` is the one namespace for arr apps and the torrent client.
- The arr apps mount the same hostPath `/var/mnt/staging` at the container path `/data` (so paths such as
  `/data/torrents/tv` mean the same thing in qBittorrent and in the arr apps, no remote path mapping).
- Download categories: `tv` (Sonarr), `movies` (Radarr), `music` (Lidarr), as folders below
  `/data/torrents/`.
- The arr apps authenticate to qBittorrent with a username and password (they enter it in their UI); this
  plan stores that password in the sealed Secret `qbittorrent-webui` (keys `username`, `password`).

## 3. Facts about this service

### 3.1 Images and versions

| Piece | Image | Version found 2026-10-25 | Source |
|---|---|---|---|
| gluetun (VPN client) | `ghcr.io/qdm12/gluetun` (also `qmcgaw/gluetun` on Docker Hub; the README says the image names stay the same after the repository moved to `github.com/passteque/gluetun`) | `v3.41.3` (released 2026-07-30). Registry index digest on 2026-10-25: `sha256:fa19cc76b2af13d57a8d3dc3066f2ada061b1c761b8aecf989b3877c0486e027` (cross-check yours against this) | [verified https://github.com/passteque/gluetun/releases] [verified registry query `ghcr.io/v2/qdm12/gluetun/manifests/v3.41.3`] |
| qBittorrent | `ghcr.io/linuxserver/qbittorrent` (the same image as `lscr.io/linuxserver/qbittorrent`; the tag `latest` means stable with libtorrent v2, the tag `libtorrentv1` is v1) | upstream qBittorrent `5.3.0` released 2026-10-20; image tag `5.3.0` exists, index digest on 2026-10-25: `sha256:75ecbb1c89ab7b0a21c4bde40b4820e4f1649d2d56d83b91913422155e8d2a5f` (cross-check) | [verified https://docs.linuxserver.io/images/docker-qbittorrent/] [verified https://github.com/qbittorrent/qBittorrent/releases] [verified registry query `ghcr.io/v2/linuxserver/qbittorrent/manifests/5.3.0`] |

The tag `5.3.0` of the linuxserver image is a floating tag inside the 5.3.0 release (linuxserver rebuilds
weekly, so its digest changes); that is why the digest is pinned. Both images are `linux/amd64` capable
(mini03 is amd64).

### 3.2 gluetun facts (all from the official wiki, https://github.com/qdm12/gluetun-wiki)

- Kubernetes: needs the `NET_ADMIN` capability on the gluetun container; use `strategy: Recreate`
  because IP rules are shared across the whole pod and abrupt exits leave rules behind (error
  `adding IPv6 rule: ...: file exists`); a `postStart` hook deleting old rules is the documented fix.
  [verified https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/kubernetes.md]
- `/dev/net/tun` must be available to the container (Docker examples use `--device /dev/net/tun`).
  [verified https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/protonvpn.md] Whether Talos plus
  containerd allows it to a non-privileged container is NOT known: WP2 tests it `[UNVERIFIED]` until then.
- Firewall variables: `FIREWALL_INPUT_PORTS` = "ports to allow through the default interface" (the wiki says
  it seems needed for Kubernetes sidecars); `FIREWALL_OUTBOUND_SUBNETS` = "subnets that Gluetun and the
  containers sharing its network stack are allowed to access" (adds firewall AND routing; must not overlap
  the VPN tunnel range); `FIREWALL_VPN_INPUT_PORTS` = ports allowed from the VPN server side.
  [verified https://github.com/qdm12/gluetun-wiki/blob/main/setup/options/firewall.md]
- Port forwarding native providers: Private Internet Access, ProtonVPN, Perfect Privacy, PrivateVPN.
  Surfshark is NOT in that list (and its provider page does not mention port forwarding): no port forwarding
  through gluetun with Surfshark. [verified https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md]
  Enable with `VPN_PORT_FORWARDING=on`. Hooks: `VPN_PORT_FORWARDING_UP_COMMAND` /
  `VPN_PORT_FORWARDING_DOWN_COMMAND`; placeholders `{{PORT}}` (first forwarded port), `{{PORTS}}`,
  `{{VPN_INTERFACE}}` (default `tun0`). Shell syntax needs `/bin/sh -c '...'`. The file
  `/tmp/gluetun/forwarded_port` also holds the port (the wiki says it will be deprecated in v4.0.0).
  [verified same page]
- The wiki's qBittorrent example (used in this plan): UP command posts
  `json={"listen_port":{{PORT}},"current_network_interface":"{{VPN_INTERFACE}}","random_port":false,"upnp":false}`
  to `http://127.0.0.1:8080/api/v2/app/setPreferences` with `wget -O- -nv --retry-connrefused --post-data`;
  DOWN command sets `listen_port` 0 and interface `lo`. Requirements: WebUI enabled on 8080 and the WebUI
  option "Bypass authentication for clients on localhost" ticked (JSON key `bypass_local_auth`). The DOWN
  command exists because of a qBittorrent bug (the port must be re-set after a disconnect).
  [verified same page]
- Health: internal health server `HEALTH_SERVER_ADDRESS` default `127.0.0.1:9999`; gluetun restarts the VPN
  internally when its checks fail (startup check within 6 s, small check every minute, full check every 5
  minutes); the Docker `HEALTHCHECK` is `/gluetun-entrypoint healthcheck`.
  [verified https://github.com/qdm12/gluetun-wiki/blob/main/faq/healthcheck.md] The Dockerfile sets
  `HEALTH_RESTART_VPN=on`. [verified https://github.com/passteque/gluetun/blob/master/Dockerfile]
- DNS: gluetun runs its own DNS over TLS forwarder; `DNS_UPSTREAM_RESOLVERS` default `cloudflare`,
  `DNS_UPSTREAM_RESOLVER_TYPE` default `dot`, `DNS_CACHING` on. Warning: using a private DNS address "will
  leak out of the VPN tunnel". [verified https://github.com/qdm12/gluetun-wiki/blob/main/setup/options/dns.md]
- Control server (port 8000): since v3.40-era releases every route requires authentication; with none
  configured it is not usable. This plan does not use it. [verified https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/control-server.md]
- ProtonVPN provider page (variables): `VPN_SERVICE_PROVIDER=protonvpn`; WireGuard: `VPN_TYPE=wireguard`,
  `WIREGUARD_PRIVATE_KEY` (32 byte key in base64, "works for all ProtonVPN servers", obtained by generating
  a WireGuard configuration at the Proton account and copying `PrivateKey`); OpenVPN: `OPENVPN_USER`
  (an OpenVPN-specific username), `OPENVPN_PASSWORD`. Filters: `SERVER_COUNTRIES`, `SERVER_REGIONS`,
  `SERVER_CITIES`, `PORT_FORWARD_ONLY=on`, `FREE_ONLY`. Port forwarding: `VPN_PORT_FORWARDING=on`; for
  WireGuard enable the "NAT-PMP (Port Forwarding)" option when generating the configuration; for OpenVPN
  append `+pmp` to the username. ProtonVPN gives a random port. [verified https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/protonvpn.md]
- Private Internet Access provider page: `VPN_SERVICE_PROVIDER=private internet access`; OpenVPN:
  `OPENVPN_USER`, `OPENVPN_PASSWORD`; "native" WireGuard is NOT available (only a custom-provider
  workaround); WireGuard port forwarding additionally needs `VPN_PORT_FORWARDING_PROVIDER=private internet
  access`, `VPN_PORT_FORWARDING_USERNAME`, `VPN_PORT_FORWARDING_PASSWORD`; `PORT_FORWARD_ONLY=true`; the
  page warns PIA port forwarding often does not work well outside P2P applications.
  [verified https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/private-internet-access.md]
- WireGuard generic options: `WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES`, `WIREGUARD_PUBLIC_KEY`,
  `WIREGUARD_MTU`, `WIREGUARD_PERSISTENT_KEEPALIVE_INTERVAL`, `WIREGUARD_IMPLEMENTATION` (`auto`,
  `kernelspace`, `userspace`). For `protonvpn` only the private key is documented as required.
  [verified https://github.com/qdm12/gluetun-wiki/blob/main/setup/options/wireguard.md]

### 3.3 qBittorrent facts

- Image `ghcr.io/linuxserver/qbittorrent`: environment `PUID`, `PGID`, `TZ`, `WEBUI_PORT` (default 8080),
  `TORRENTING_PORT` (default 6881, applied only when set; this plan does NOT set it because the port comes
  from the VPN); volumes `/config` and `/downloads`; WebUI on 8080; "A temporary password for the `admin`
  user is printed to the container log on startup ... if you don't change it, a new password is generated
  each time the container starts." Read-only and non-root operation are supported but documented separately.
  [verified https://docs.linuxserver.io/images/docker-qbittorrent/]
- The exact log line wording is NOT given there. `[UNVERIFIED]`: upstream prints a line like
  `The WebUI administrator username is: admin` and `The WebUI administrator password was not set. A
  temporary password is provided for this session: <password>`. WP6 tells the executor to search the log for
  the words `temporary password` (case-insensitive) rather than rely on the exact text.
- WebUI API (qBittorrent 5.0 API) has `POST /api/v2/auth/login`, `POST /api/v2/app/setPreferences`,
  `/api/v2/torrents/stop` and `/api/v2/torrents/start` (5.x names; 4.x called them pause/resume), and the
  preference keys `web_ui_host_header_validation_enabled` and `bypass_local_auth`.
  [verified https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-(qBittorrent-5.0)]
- Configuration file: `/config/qBittorrent/qBittorrent.conf` (inside the `/config` volume) holds the
  password as a PBKDF2 hash (key `WebUI\Password_PBKDF2`) `[UNVERIFIED path and key name; confirm in WP6 with
  a read-only `exec ... ls /config/qBittorrent`]`.

### 3.4 Digests (how the executor resolves them)

The `docs/templates/ghcr-app/new-app.sh` resolver only handles ghcr.io images and builds a whole app; here
use the same registry query by hand (read-only, no Docker needed). Both images are on ghcr.io:

```bash
# usage: digest <owner/repo> <tag>
digest() {
  T=$(curl -s "https://ghcr.io/token?scope=repository:$1:pull" | jq -r .token)
  curl -sI -H "Authorization: Bearer $T" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://ghcr.io/v2/$1/manifests/$2" | grep -i '^docker-content-digest'
}
digest qdm12/gluetun v3.41.3
digest linuxserver/qbittorrent 5.3.0
```

Expected: one line `docker-content-digest: sha256:<64 hex>` per call. If the output is empty or the HTTP
status is not 200, STOP (wrong tag or registry change). If the digest differs from Section 3.1, that is
normal for the linuxserver image (weekly rebuild): use YOUR fresh value and write it in the report.

## 4. Architecture and placement

### 4.1 Pod design: one pod, shared network namespace

All containers of a Kubernetes pod share one network namespace. That is the whole trick: gluetun (the VPN
client) creates the tunnel interface `tun0` and firewall rules in the pod's namespace, and qBittorrent, in
the same namespace, can only use what gluetun allows. No VPN credentials or configuration are ever inside
the qBittorrent container.

```
  arr apps (arr namespace, any node)        the operator (tailnet)
        |  qbittorrent.arr.svc:8080               |
        |                                  Tailscale Ingress "qbittorrent" (tailscale ns proxy pod)
        v                                         v
 +------------------- pod "qbittorrent" on mini03 (one network namespace) -----------------+
 |  eth0 (pod IP) <--- firewall (gluetun): only input port 8080, only pod-network traffic  |
 |     |                                                                                    |
 |  [init: fix-perms]  [sidecar: gluetun]  <-- WireGuard private key (sealed Secret)        |
 |                       creates tun0, DNS 127.0.0.1:53 (DoT), health 127.0.0.1:9999        |
 |  [qbittorrent]  WebUI 8080 ; BitTorrent traffic ONLY via tun0 ; forwarded port from VPN  |
 |        mounts: /config (PVC topolvm-fast)  /data (hostPath /var/mnt/staging)             |
 +------------------------------------------------------------------------------------------+
                                  tun0 ---> VPN provider ---> internet
```

Decisions that follow from the facts:

1. **Native sidecar.** gluetun is an init container with `restartPolicy: Always` (Kubernetes native sidecar,
   stable; the cluster is v1.36). It starts first, qBittorrent starts only after gluetun's `startupProbe`
   passes (tunnel up). If gluetun cannot connect, qBittorrent never starts and nothing can leak. Fallback
   if the executor finds that native sidecars are rejected: put gluetun first in `containers:` (plain
   sidecar); the firewall still blocks leaks, only the start order is lost.
2. **Kill switch.** gluetun installs a default-deny firewall in the pod namespace at start. When the tunnel
   drops, rules stay, so traffic stays blocked even if the gluetun container crashes (the namespace outlives
   the container). That is the kill switch; Section 7 tests it.
3. **`dnsPolicy: None`** with `nameservers: [127.0.0.1]` for the whole pod, so qBittorrent resolves only via
   gluetun's local DoT forwarder (no cluster DNS, no leak). `[UNVERIFIED]` that gluetun answers on
   127.0.0.1:53; WP7 proves it with `nslookup`/`getent`.
4. **`strategy: Recreate`**, one replica, `postStart` hook not needed on first try (add it if the error
   `adding IPv6 rule ... file exists` appears, Section 10).
5. **No ServiceAccount token**: `automountServiceAccountToken: false`, dedicated ServiceAccount `qbittorrent`.

### 4.2 `/dev/net/tun` and `NET_ADMIN` on Talos, and Pod Security

- Talos' kernel supports TUN (the Tailscale system extension and the Tailscale operator's proxy pods already
  need it) `[UNVERIFIED for this node's device node and for non-privileged pods]`. A device node existing on
  the host does not mean a non-privileged container may open it: the container runtime's device allowlist
  can refuse it (the Jellyfin manifest records exactly that for `/dev/dri`: "Operation not permitted"
  until a device plugin allowed it). Three ways, tried in this order by the probe in WP2:
  - **Variant A**: `hostPath` `/dev/net/tun` (`type: CharDevice`) mounted into the gluetun container with
    `capabilities.add: [NET_ADMIN]`, not privileged. Best if it works.
  - **Variant B**: only `NET_ADMIN`, no device mount (gluetun can create the node itself with `mknod` if
    its entrypoint does so; expected to fail the open for the same allowlist reason). Control experiment.
  - **Variant C**: gluetun container `privileged: true` (qBittorrent stays unprivileged). Works almost
    certainly; costs least-privilege for the VPN container only.
  - Variant D (only if A fails and the operator rejects C): a generic device plugin DaemonSet exposing
    `/dev/net/tun` as a resource. That is a new component; STOP and ask the operator (decision D3).
- **Pod Security of `arr`.** Talos enforces the Pod Security `baseline` level cluster-wide
  (`talos/manifests/namespaces/namespaces.yaml`, first comment). `baseline` forbids `NET_ADMIN`, `hostPath`
  volumes and privileged containers, all three of which this pod needs (NET_ADMIN for gluetun, hostPath for
  `/var/mnt/staging` and `/dev/net/tun`). So `arr` needs the label `pod-security.kubernetes.io/enforce:
  privileged` (as `homeserver`, `nas`, `velero`, `tailscale` have). That is decision D4 and it also applies
  to the arr apps that share the namespace. Mitigation: only this pod's gluetun container gets the extra
  rights; everything else sets `allowPrivilegeEscalation: false`, drops all capabilities, `runAsNonRoot`
  where the image allows.

### 4.3 Placement, storage and sizing

- Node: `mini03` via `nodeSelector: kubernetes.io/hostname: mini03` AND the toleration for the node's
  taint `node-role.homeserver/tier=mobile:NoSchedule` (from `talos/nodes/mini03.yaml` on branch
  `talos/victus-vm`). Without the toleration the pod stays Pending.
- Staging data: the volume `staging` (xfs, 283 GiB, `UserVolumeConfig` in `talos/patches/volumes-mini03.yaml`)
  is mounted by Talos on the node at **`/var/mnt/staging`** (stated in that file and in `docs/dr/mini03.md`,
  branch `talos/victus-vm`). A pod reaches it with a `hostPath` volume, the same way Jellyfin uses
  `/var/mnt/media` on mini01. Mounted in the pod at `/data`. Layout inside (created by `fix-perms`):
  `/data/torrents/incomplete`, `/data/torrents/tv`, `/data/torrents/movies`, `/data/torrents/music`.
  hostPath data is NOT backed up by Velero and is deliberately disposable.
- Config: PVC `qbittorrent-config`, 1 Gi, `storageClassName: topolvm-fast`, mounted at `/config`. On mini03
  the provisioner puts it on the `data` volume at `/var/mnt/data/local-path` (about 33 GiB, shared with the
  arr apps' config). Velero can back it up with the opt-in annotation (WP10).
- Image storage: mini03's EPHEMERAL is capped at 24 GiB for all container images, both images here are
  a few hundred MB.
- Real usage today (read-only `kubectl --context admin@<cluster> top nodes`, 2026-10-25): `mini01` 1684m CPU
  (42%), 5182Mi (46%); `mini02` 122m CPU (3%), 1192Mi (16%). `mini03` does not exist yet, so its numbers
  cannot be read: it is a 4 vCPU / 8 GiB VM (`docs/dr/mini03.md`) planned to carry the arr stack (about
  300 MB each for Sonarr, Radarr, Prowlarr), MinIO (about 300 MB) and this pod (the document estimates 1 GB
  for qBittorrent plus gluetun under load). The executor repeats `top nodes` in WP1 and quotes mini03 if it
  exists.
- Resource requests/limits (all containers; reasoning: memory is what qBittorrent grows with torrent count
  and cache, CPU matters little; the VM yields CPU to the desktop's games anyway):

| Container | requests | limits | Why |
|---|---|---|---|
| `fix-perms` (init) | cpu 10m, mem 16Mi | cpu 100m, mem 64Mi | runs once, `mkdir` and `chown` |
| `gluetun` (sidecar) | cpu 50m, mem 64Mi | cpu 500m, mem 256Mi | VPN crypto and DNS forwarder; WireGuard userspace on busy links can use CPU |
| `qbittorrent` | cpu 250m, mem 512Mi | cpu 2, mem 2Gi | 4 vCPU node shared with arr apps and MinIO; 2 Gi bounds the libtorrent cache |
| `disk-guard` (CronJob) | cpu 10m, mem 16Mi | cpu 100m, mem 64Mi | a `curl` and `df` every 5 minutes |

### 4.4 The one setting that needs an address: `FIREWALL_OUTBOUND_SUBNETS`

For the arr apps (and the Tailscale proxy pod) to reach the WebUI, gluetun must know the cluster's POD
network range: `FIREWALL_OUTBOUND_SUBNETS` allows AND routes replies to it via eth0 instead of the tunnel.
Pod and service ranges are 10.x IPv4 ranges and the guard `check-no-host-details.sh` rejects any such
literal anywhere under `talos/`, `docs/` (regex: 10.x.x.x, 172.16 to 31, 192.168). So:

- The range is NOT written in any manifest. It is a KEY of the sealed Secret `gluetun-vpn`
  (`FIREWALL_OUTBOUND_SUBNETS`), consumed by `secretKeyRef`, like the other VPN settings.
- The operator (or the executor, read-only) finds the value with
  `kubectl --context admin@<cluster> get nodes -o jsonpath='{.items[*].spec.podCIDR}'`: it prints one
  per-node block per node (`/24` blocks). The cluster-wide pod network is the enclosing block (the common
  prefix, normally a `/16`; confirm with the operator or `talosctl get` only if he asks). Use the enclosing block,
  not the per-node ones, so pods on future nodes work. The value goes to the operator at sealing time; the
  executor does not paste it anywhere in the repo, chat summary or PR text. Reading it from the command
  is fine.
- Only the pod network is needed: the service network is NAT'd to pod addresses before packets reach this
  pod, and kubelet probes use `exec` (below) so no node address is needed.
- LAN subnets are deliberately NOT added: no LAN access from torrent traffic. (If the operator later wants the
  qBittorrent pod to reach something on the LAN, that is a separate decision.)

## 5. Decisions for the operator

The executor STOPS at any package that depends on an unanswered decision.

| Id | Question | Options and trade-offs | Recommended default | If decided otherwise |
|---|---|---|---|---|
| D1 | VPN provider | (a) **ProtonVPN paid plan**: port forwarding via NAT-PMP, native in gluetun, WireGuard, one key for all servers. (b) **Private Internet Access**: port forwarding native, but only OpenVPN natively (WireGuard needs a custom-provider workaround), the wiki warns PF is flaky outside P2P apps. (c) Surfshark: NO port forwarding in gluetun [verified]; only usable without an inbound port (slower, fewer peers). (d) another provider: STOP, needs its own research | (a) ProtonVPN with WireGuard | PIA: use the OpenVPN column of Section 6.2/WP5 variables. Surfshark: remove the port-forwarding variables, expect poor connectability. |
| D2 | Protocol | WireGuard (faster, lighter CPU, one 32-byte key) vs OpenVPN (user/password, works where UDP WireGuard is blocked, heavier) | WireGuard (Proton) | OpenVPN: secret keys `OPENVPN_USER`, `OPENVPN_PASSWORD` instead of `WIREGUARD_PRIVATE_KEY`; env `VPN_TYPE` removed (gluetun default is openvpn) |
| D3 | How gluetun gets `/dev/net/tun` | A: hostPath device + NET_ADMIN (least privilege, only if the WP2 probe passes), C: gluetun container `privileged: true`, D: device plugin DaemonSet (extra component) | A if probe passes, else C | Edit the securityContext/volumes of the gluetun container only (Section 7 WP5 shows both) |
| D4 | Pod Security level of `arr` | `privileged` (needed: NET_ADMIN, hostPath, maybe privileged), or splitting the torrent client into its own namespace (contradicts the fixed rule that `arr` holds both so they can share volumes) | `privileged` on `arr` | A different namespace invalidates `qbittorrent.arr.svc`; STOP and replan with the arr-stack plan |
| D5 | Server location filter | `SERVER_COUNTRIES` / `SERVER_REGIONS` (The operator chooses; one country close to him gives lower latency; the Proton servers must be P2P-capable, `PORT_FORWARD_ONLY=on` handles that) | The operator names one country | Any value; it is a plain env value `<country>` he supplies in WP5 |
| D6 | How arr apps authenticate to qBittorrent | (a) username and password entered in each arr app (stored by them); (b) in qBittorrent turn on "Bypass authentication for clients in whitelisted IP subnets" and whitelist the pod network (no password for in-cluster clients; anything running in the cluster then has full control) | (a) password | (b): set in the UI only (the value lives in the PVC, not the repo); the `qbittorrent-webui` Secret is then used only by the disk guard |
| D7 | Disk guard action | Below 20 GiB free on `/data`: (a) stop (pause) all torrents, resume by hand; (b) only alert (needs the monitoring plan); (c) both | (a) with the alert added when monitoring exists | (b): drop WP9's API call, keep only the `df` and fail the Job (visible as a failed Job) |
| D8 | Include a Velero schedule for namespace `arr` | Yes (config is small, covers qBittorrent categories, settings, and the arr apps' config too) / No (rebuild settings by hand, about 10 minutes of UI work) | Yes (WP10), coordinated with the arr-stack and backup-replica plans | Skip WP10, keep the manual export of Section 8 |

## 6. Credentials and secret handling

Principles: no value ever appears in the repo, a PR, a log or chat. The operator types values into the sealing
command (hidden prompt) or into the web UI. Sealing uses the committed certificate
`argocd/sealed-secrets/pub-cert.pem`, offline; the sealed object is committed to `talos/sealed-secrets/` and
listed in its `kustomization.yaml`; the auto-sync app `talos-sealed-secrets` (prune OFF) delivers it. A
SealedSecret is bound to name and namespace, so the namespace `arr` must exist before the object is
delivered (WP3 first).

### 6.1 Inventory

| # | Credential | What it is | Created by | Secret / key | Sealed file | How the app receives it |
|---|---|---|---|---|---|---|
| 1 | VPN WireGuard private key (D1=Proton, D2=WireGuard) | 32-byte base64 key of a Proton WireGuard configuration generated with NAT-PMP on | The operator, at the provider (6.2) | Secret `gluetun-vpn`, namespace `arr`, key `WIREGUARD_PRIVATE_KEY` | `talos/sealed-secrets/gluetun-vpn.yaml` | env var of the gluetun container via `secretKeyRef` |
| 1b | VPN username/password (only if D2=OpenVPN) | Proton: the OpenVPN-specific username (from the OpenVPN/IKEv2 page of the Proton account) with `+pmp` appended; PIA: the PIA account username and password | The operator | same Secret, keys `OPENVPN_USER`, `OPENVPN_PASSWORD` | same file | env vars |
| 1c | PIA WireGuard port-forwarding login (only if PIA and WireGuard) | `VPN_PORT_FORWARDING_USERNAME`, `VPN_PORT_FORWARDING_PASSWORD` | The operator | same Secret | same file | env vars |
| 2 | Pod network range | not a credential, but must not be written in committed plain files (guard) | Executor reads it read-only, the operator seals it (4.4) | same Secret, key `FIREWALL_OUTBOUND_SUBNETS` | same file | env var `FIREWALL_OUTBOUND_SUBNETS` |
| 3 | qBittorrent WebUI admin | user `admin` (default; can be renamed in the UI) and the permanent password the operator sets | The operator, in the UI after the first start (6.3) | Secret `qbittorrent-webui`, namespace `arr`, keys `username`, `password` | `talos/sealed-secrets/qbittorrent-webui.yaml` | the disk-guard CronJob reads it as env vars `QB_USER`, `QB_PASS`; the arr apps get it typed in by the operator |
| 4 | Temporary WebUI password | generated by qBittorrent at each start until a permanent one is set | qBittorrent | none (log only) | none | printed in the container log |
| 5 | Proton / PIA account login | The operator's own account at the provider | The operator | NOT in the cluster; his password manager only | none | n/a |
| 6 | Tailscale | the operator already owns the identity of the proxy for the Ingress | n/a | none for this app | none | n/a |

No database, no signing keys, no OIDC secrets exist for this service.

Keep the same values in the operator's password manager (Vaultwarden) under an entry "qbittorrent-vpn"
(provider key, account) and "qbittorrent-webui" (admin password).

### 6.2 What the operator creates at the provider (exact fields)

ProtonVPN, WireGuard, with port forwarding (D1=a, D2=WireGuard). Needs a paid Proton VPN plan
(port forwarding is a paid feature `[UNVERIFIED plan name; the gluetun wiki says "paid ProtonVPN subscribers"
for Moderate NAT, and the port-forwarding steps need P2P servers; the operator confirms in his account]`).

1. Sign in at the Proton account, open VPN, Downloads, "WireGuard configuration" (gluetun wiki links
   `https://account.proton.me/u/0/vpn/WireGuard` and the guide `https://protonvpn.com/support/wireguard-configurations/`).
2. Give the configuration a name, for example `homelab-qbittorrent`.
3. Platform: GNU/Linux (or the generic option the page offers). Under "Select VPN options" turn ON
   **NAT-PMP (Port Forwarding)**. [verified wiki]. Leave "VPN Accelerator" at its default.
4. Pick any server (the key works for all Proton servers [verified wiki]; gluetun picks by `SERVER_COUNTRIES`).
5. Create. The page shows a configuration text; copy ONLY the value of the line `PrivateKey = ...` straight
   into the sealing prompt (Section 7 WP4), not into a file or chat. Do not copy `Address`, `DNS`, `PublicKey`,
   `Endpoint`: gluetun's Proton integration needs only the private key [verified wiki] (it carries its own
   server list).
6. Save the config in the password manager. Proton allows a limited number of keys; one is enough. The
   config is bound to the NAT-PMP choice: if you forgot the option, generate a new configuration.

If D1=PIA (OpenVPN): the account username and password go into `OPENVPN_USER` and `OPENVPN_PASSWORD`.
Choose a PIA region (`SERVER_REGIONS`) that offers port forwarding (`PORT_FORWARD_ONLY=true`).

### 6.3 Password discovery, retrieval, loss, rotation

- **First login.** The first time qBittorrent starts with no password configured, it prints a TEMPORARY
  password for user `admin` in the container log; a new one is generated at every start until a permanent
  one is set. Read it (read-only):
  `kubectl --context admin@<cluster> -n arr logs deploy/qbittorrent -c qbittorrent | grep -i -A1 "temporary password"`.
  If the grep finds nothing, show the first 60 lines of the log and look for the words `administrator` and
  `password`; this is the point marked `[UNVERIFIED]` in 3.3. This temporary password is not a lasting secret,
  but do not paste it into chat or the PR. Then the operator opens the WebUI (WP8), logs in as `admin`, and sets the
  permanent password: Tools > Options > Web UI > Authentication > Username / Password (set a new one, at
  least 20 random characters: `openssl rand -base64 24 | pbcopy`) > Save. The hash is stored in
  `/config/qBittorrent/qBittorrent.conf` on the PVC (backed up by Velero, WP10).
- **Sealing it for the disk guard and the record** (WP6): The operator seals the same user and password into
  `qbittorrent-webui` (recipe in WP6).
- **Later retrieval:** in the operator's own terminal, clipboard only:
  `kubectl --context admin@<cluster> -n arr get secret qbittorrent-webui -o jsonpath='{.data.password}' | base64 -d | pbcopy`
  and for the VPN key
  `kubectl --context admin@<cluster> -n arr get secret gluetun-vpn -o jsonpath='{.data.WIREGUARD_PRIVATE_KEY}' | base64 -d | pbcopy`
  (the executor never runs these).
- **What breaks if lost:** the VPN key: gluetun cannot connect, the pod stays 1/2 and nothing downloads (no
  leak); regenerate at the provider and re-seal. The WebUI password: nobody can log in, the arr apps and the
  disk guard fail login (they log errors, no data lost).
- **Rotate the WebUI password:** change it in the UI, re-seal `qbittorrent-webui` (delete the old file first,
  re-run the recipe, commit), update the arr apps' download-client entries. **Rotate the VPN key:** revoke
  the old configuration at the provider after the new one works: new sealed file in a PR, the operator syncs
  `qbittorrent` and the pod restarts.
- **Lost WebUI password recovery (PR-based):** (1) PR sets `replicas: 0` for `qbittorrent` and the operator syncs.
  (2) A second small PR adds a one-shot Pod `qbittorrent-reset` in `arr` (same node selector/toleration,
  mounts the PVC `qbittorrent-config` at `/config`, command
  `sh -c 'sed -i "/WebUI.Password_PBKDF2/d" /config/qBittorrent/qBittorrent.conf && echo done'`, image the
  qBittorrent digest, explicit resources) and the operator syncs it, reads `logs` for `done`, then the PR is
  reverted. (3) PR sets `replicas: 1`; on start qBittorrent prints a new temporary password; set a permanent
  one as above and re-seal. `[UNVERIFIED]` that deleting the line is enough; the official qBittorrent
  documentation describes removing the stored hash this way, the executor reads
  `https://github.com/qbittorrent/qBittorrent/wiki` before writing the Pod.

## 7. Work packages

Order: WP1 audit, WP2 tun probe, WP3 namespace, WP4 VPN secret, WP5 the pod, WP6 first start and WebUI
secret, WP7 leak and port tests, WP8 tailnet ingress, WP9 disk guard, WP10 backup schedule. One PR each
unless stated. WP5 depends on WP2 to WP4; WP9 and WP10 depend on WP6.

### WP1: read-only audit (no PR)

Goal: confirm the prerequisites of Section 2 and the real facts the later packages use.
Branch: none. Preconditions: The operator has answered D1 and D2 (others may wait).

1. `git fetch origin && git switch --detach origin/main`. Read `docs/plans/` for sibling plans merged since
   (arr-stack, mini03-vm, backup-replica). Note any differences from `[ASSUMED]` items.
2. Read `talos/patches/volumes-mini03.yaml` and `docs/dr/mini03.md` on `origin/talos/victus-vm` (still unmerged)
   with `git show origin/talos/victus-vm:talos/patches/volumes-mini03.yaml`. Confirm the mount is
   `/var/mnt/staging`. If it differs (name or path), STOP and use the real path everywhere below.
3. Run (each read-only, `--context admin@<cluster>`):
   `get nodes -o wide`, `top nodes`, `get storageclass`, `get ns --show-labels`,
   `get nodes -o jsonpath='{.items[*].spec.podCIDR}'` (do not write the output into any file),
   `-n tailscale get pods`, `-n velero get pods`, `get sealedsecrets -A`.
   Expected: a Node `mini03` once the VM is built (otherwise report "mini03 absent"); namespace `arr`
   absent (or present with the arr-stack's label).
4. `git grep -n -i "torrent\|gluetun\|qbittorrent" -- talos docs/BACKLOG.md` to find anything already in
   the repo. Expected: only backlog and the mini03 docs.
5. Check the toleration key: `git show origin/talos/victus-vm:talos/nodes/mini03.yaml | grep -A2 taints`
   should show `node-role.homeserver/tier: mobile:NoSchedule`.

Verification: write the Section 11 report with the outputs (no secret values; do not paste the podCIDR
output into the report, say "obtained"). Rollback: none. STOP: report to the operator; wait for D3/D4/D5 answers
before WP2.

### WP2: prove `/dev/net/tun` and `NET_ADMIN` work on mini03 (one PR)

Goal: decide D3 with evidence. Branch `torrent/wp2-tun-probe`. Preconditions: WP1 shows mini03 Ready; WP3's
namespace PR is merged and synced first (the probe runs in `arr`), so do WP3 before WP2 if `arr` does not exist.
(Order note: execute WP3 then WP2.)

Files (Argo app `tun-probe`, manual sync, deleted again after the result):

1. `talos/manifests/tun-probe/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: arr
resources:
  - probe-a.yaml
  - probe-b.yaml
  - probe-c.yaml
```
2. `talos/manifests/tun-probe/probe-a.yaml` (Variant A, non-privileged, device mounted; B and C are the same
   file with the changes stated below). Replace `<GLUETUN_REF>` with `ghcr.io/qdm12/gluetun:v3.41.3@sha256:<digest from 3.4>`.
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: tun-probe-a
  labels:
    app.kubernetes.io/name: tun-probe
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: mini03
  tolerations:
    - key: node-role.homeserver/tier
      operator: Equal
      value: mobile
      effect: NoSchedule
  automountServiceAccountToken: false
  containers:
    - name: probe
      image: <GLUETUN_REF>
      command: ["/bin/sh", "-c"]
      args:
        - |
          echo "== device"; ls -l /dev/net/tun || echo NO_DEVICE_NODE
          echo "== caps"; grep Cap /proc/self/status
          echo "== create tun interface"
          if ip tuntap add dev probe0 mode tun; then echo TUN_OK; ip tuntap del dev probe0 mode tun; else echo TUN_FAILED; fi
          sleep 3600
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 100m, memory: 64Mi}
      securityContext:
        capabilities:
          add: [NET_ADMIN]
      volumeMounts:
        - {name: tun, mountPath: /dev/net/tun}
  volumes:
    - name: tun
      hostPath: {path: /dev/net/tun, type: CharDevice}
```
   `probe-b.yaml`: name `tun-probe-b`; delete `volumeMounts` and `volumes` (only `NET_ADMIN`).
   `probe-c.yaml`: name `tun-probe-c`; delete `volumeMounts`/`volumes`, replace the securityContext with
   `securityContext: {privileged: true}`.
3. `talos/apps-src/tun-probe.yaml`: copy `talos/apps-src/jellyfin.yaml`'s shape, name `tun-probe`, path
   `talos/manifests/tun-probe`, destination namespace `arr`, no automated sync. Run
   `talos/render-apps.sh --force`. Add to `talos/test/empty-cluster-expectations.txt` the line
   `tun-probe               *       *       # manual sync; temporary probe, removed after WP2`.
4. Guards, commit, push, draft PR "WP2: probe /dev/net/tun on mini03 (temporary)".

PR description: what the three pods test; the operator steps after merge: Argo CD UI, app `tun-probe`, Sync; wait
a minute; tell the executor "synced". The executor then reads (read-only):
`kubectl --context admin@<cluster> -n arr logs tun-probe-a` (and `-b`, `-c`).

Expected outputs and what they mean:
- `TUN_OK` in A: use Variant A (D3=A). `TUN_FAILED` in A and `TUN_OK` in C: use Variant C unless the operator
  prefers D (stop and ask). If B shows `TUN_OK`, even simpler: no device volume, NET_ADMIN only (record it).
- `NO_DEVICE_NODE` in all: the node has no `/dev/net/tun`; in A the pod may fail to start with a hostPath
  type error (`describe pod` shows it). Report; it is a mini03 image problem for the mini03-vm plan
  (tun module/extension), STOP.
- A pod stuck Pending: toleration or nodeSelector wrong or mini03 missing; `describe pod` events.

Cleanup: second PR "WP2b: remove tun-probe" deleting the three files, the app source, the generated app,
the expectations line; the operator syncs `tun-probe` (prune) or deletes the app in the Argo UI. Record the result
in the final PR of WP5 (the choice).
Rollback: delete the app. STOP: wait for the operator's confirmation of D3.

### WP3: namespace `arr` with the Pod Security label (one PR, may be shared with arr-stack)

Goal: namespace exists, label per D4. Branch `torrent/wp3-namespace`. Preconditions: D4 answered.

1. `git grep -n "name: arr$" -- talos/manifests/namespaces`. If it exists, only check the label and STOP
   if it is not `privileged` (tell the operator, it breaks this pod).
2. Append to `talos/manifests/namespaces/namespaces.yaml` (keep the file's comment style):
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: arr
  labels:
    pod-security.kubernetes.io/enforce: privileged # qBittorrent pod: gluetun needs NET_ADMIN and the tun device, staging is a hostPath
```
3. Guards, commit, draft PR "arr: namespace with the privileged Pod Security label".
   The `namespaces` app is in the automatic order; the operator merges and syncs `namespaces` in Argo.
Verification (after sync): `kubectl --context admin@<cluster> get ns arr --show-labels` shows the label.
Rollback: revert the PR (namespace deletion only if empty). STOP.

### WP4: seal the VPN credentials (The operator does the sealing; executor prepares the PR)

Goal: Secret `gluetun-vpn` in `arr`. Branch `torrent/wp4-vpn-secret`. Preconditions: D1, D2 answered; WP3
synced; the operator has the provider key (6.2). The executor does not see values.

Copy-paste list for the operator (from the repository root, `kubeseal` and `jq` installed; the pod range value is
`<the enclosing pod network range from WP1>`; he can read it with the command in 4.4):

```bash
read -rsp "WIREGUARD_PRIVATE_KEY: " K; echo
read -rp  "FIREWALL_OUTBOUND_SUBNETS (pod network, CIDR): " S
jq -n --arg k "$K" --arg s "$S" '{apiVersion:"v1",kind:"Secret",
   metadata:{name:"gluetun-vpn",namespace:"arr"},type:"Opaque",
   data:{WIREGUARD_PRIVATE_KEY:($k|@base64),FIREWALL_OUTBOUND_SUBNETS:($s|@base64)}}' |
 KUBECONFIG=/dev/null kubeseal --cert argocd/sealed-secrets/pub-cert.pem --format yaml \
   > talos/sealed-secrets/gluetun-vpn.yaml
unset K S
grep -c 'kind: SealedSecret' talos/sealed-secrets/gluetun-vpn.yaml   # expect 1
```
For OpenVPN (D2) replace the data keys by `OPENVPN_USER` and `OPENVPN_PASSWORD` (and the PIA WireGuard
login keys if needed). Provider typed into a hidden prompt; nothing echoes. Then: add the line
`  - gluetun-vpn.yaml` to the `resources:` list of `talos/sealed-secrets/kustomization.yaml` and add a
comment line in the header there: `#   gluetun-vpn.yaml   arr/gluetun-vpn   WIREGUARD_PRIVATE_KEY, FIREWALL_OUTBOUND_SUBNETS`.
(The guard `check-backups-06.sh` requires every file in the directory to be a SealedSecret and be listed.)

Executor: after the operator commits the file on the branch (or hands it over), run the guards, push, draft PR
"arr: sealed VPN credentials for gluetun". Do NOT open the file contents in chat (ciphertext is safe in
git, but there is no reason to print it).
The operator after merge: nothing to sync by hand (`talos-sealed-secrets` auto-syncs). Verify (read-only):
`kubectl --context admin@<cluster> -n arr describe secret gluetun-vpn` shows the two keys (names and
sizes only). If the SealedSecret reports `no key could decrypt` (`describe sealedsecret`), the certificate
or namespace is wrong: STOP.
Rollback: delete the sealed file and its kustomization line in a PR. STOP.

### WP5: the pod (Argo app `qbittorrent`) (one PR)

Goal: deploy qBittorrent + gluetun. Branch `torrent/wp5-pod`. Preconditions: WP2 result (D3), WP3 and WP4
synced, D1 to D5 answered, digests from 3.4 resolved today.

Files (all under `talos/manifests/qbittorrent/`; namespace `arr` is set by the kustomization and the
Argo destination):

1. `kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: arr
resources:
  - serviceaccount.yaml
  - pvc.yaml
  - deployment.yaml
  - service.yaml
```
2. `serviceaccount.yaml`:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: qbittorrent
automountServiceAccountToken: false
```
3. `pvc.yaml`:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: qbittorrent-config
  labels:
    app.kubernetes.io/name: qbittorrent
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: topolvm-fast
  resources:
    requests:
      storage: 1Gi
```
4. `service.yaml` (the in-cluster address the arr apps use, `qbittorrent.arr.svc:8080`):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: qbittorrent
  labels:
    app.kubernetes.io/name: qbittorrent
spec:
  selector:
    app.kubernetes.io/name: qbittorrent
  ports:
    - {name: http, port: 8080, targetPort: http, protocol: TCP}
```
5. `deployment.yaml`. Replace `<GLUETUN_REF>` and `<QBIT_REF>` with `repo:tag@sha256:...` from 3.4;
   `<COUNTRY>` with the operator's D5 answer (a plain value, not secret). Keep the comments (the next person needs
   them). This is the Variant C form for gluetun; for Variant A (D3) apply the two edits listed after it.
```yaml
# qBittorrent behind gluetun. One pod = one network namespace: gluetun (native sidecar) owns the tunnel and
# the firewall, qBittorrent can only use what gluetun allows (kill switch). Docs: docs/plans/torrent-gluetun.md
# Pod Security: namespace `arr` is `privileged` (NET_ADMIN, tun device, hostPath).
# gluetun: https://github.com/qdm12/gluetun-wiki   qBittorrent image: https://docs.linuxserver.io/images/docker-qbittorrent/
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qbittorrent
  labels:
    app.kubernetes.io/name: qbittorrent
spec:
  replicas: 1
  strategy:
    type: Recreate # IP rules are pod-wide; a rolling update would run two gluetuns in one namespace's rules (gluetun wiki, Kubernetes page)
  selector:
    matchLabels:
      app.kubernetes.io/name: qbittorrent
  template:
    metadata:
      labels:
        app.kubernetes.io/name: qbittorrent
      annotations:
        backup.velero.io/backup-volumes: config # Velero file-system backup of the config PVC only (WP10); /data is a hostPath and not backed up
    spec:
      serviceAccountName: qbittorrent
      automountServiceAccountToken: false
      nodeSelector:
        kubernetes.io/hostname: mini03
      tolerations:
        - key: node-role.homeserver/tier
          operator: Equal
          value: mobile
          effect: NoSchedule
      # All name resolution goes through gluetun's local DNS-over-TLS forwarder, never the cluster DNS.
      dnsPolicy: None
      dnsConfig:
        nameservers: ["127.0.0.1"]
        options:
          - {name: ndots, value: "1"}
      terminationGracePeriodSeconds: 60
      initContainers:
        - name: fix-perms # one-shot: create the download folders owned by the qBittorrent user (uid/gid 1000)
          image: <QBIT_REF>
          command: ["/bin/sh", "-c"]
          args:
            - |
              mkdir -p /data/torrents/incomplete /data/torrents/tv /data/torrents/movies /data/torrents/music
              chown 1000:1000 /data /data/torrents /data/torrents/incomplete /data/torrents/tv /data/torrents/movies /data/torrents/music
              chmod 775 /data/torrents /data/torrents/incomplete /data/torrents/tv /data/torrents/movies /data/torrents/music
              echo fix-perms done
          resources:
            requests: {cpu: 10m, memory: 16Mi}
            limits: {cpu: 100m, memory: 64Mi}
          securityContext:
            runAsUser: 0
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
              add: [CHOWN, FOWNER, DAC_OVERRIDE]
          volumeMounts:
            - {name: data, mountPath: /data}
        - name: gluetun # native sidecar: starts first and keeps running; qbittorrent starts after its startupProbe passes
          image: <GLUETUN_REF>
          restartPolicy: Always
          env:
            - {name: VPN_SERVICE_PROVIDER, value: protonvpn} # D1; for PIA: "private internet access" (and VPN_TYPE below removed, OPENVPN_* keys from the Secret)
            - {name: VPN_TYPE, value: wireguard}             # D2
            - {name: SERVER_COUNTRIES, value: "<COUNTRY>"}   # D5
            - {name: PORT_FORWARD_ONLY, value: "on"}         # only P2P / port-forwarding servers
            - {name: VPN_PORT_FORWARDING, value: "on"}
            - name: VPN_PORT_FORWARDING_UP_COMMAND
              value: |-
                /bin/sh -c 'wget -O- -nv --retry-connrefused --post-data "json={\"listen_port\":{{PORT}},\"current_network_interface\":\"{{VPN_INTERFACE}}\",\"random_port\":false,\"upnp\":false}" http://127.0.0.1:8080/api/v2/app/setPreferences'
            - name: VPN_PORT_FORWARDING_DOWN_COMMAND
              value: |-
                /bin/sh -c 'wget -O- -nv --retry-connrefused --post-data "json={\"listen_port\":0,\"current_network_interface\":\"lo\"}" http://127.0.0.1:8080/api/v2/app/setPreferences'
            - {name: FIREWALL_INPUT_PORTS, value: "8080"}    # WebUI reachable on eth0; everything else inbound stays blocked
            - {name: DNS_UPSTREAM_RESOLVER_TYPE, value: dot} # explicit: the documented default, DNS over TLS through the tunnel
            - {name: DNS_UPSTREAM_RESOLVERS, value: cloudflare}
            - {name: HEALTH_RESTART_VPN, value: "on"}
            - {name: TZ, value: Europe/Lisbon}               # [ASSUMED] the operator's time zone; change if wrong
            - name: WIREGUARD_PRIVATE_KEY
              valueFrom: {secretKeyRef: {name: gluetun-vpn, key: WIREGUARD_PRIVATE_KEY}}
            - name: FIREWALL_OUTBOUND_SUBNETS # the pod network range, sealed on purpose (guard rejects IP literals), see plan 4.4
              valueFrom: {secretKeyRef: {name: gluetun-vpn, key: FIREWALL_OUTBOUND_SUBNETS}}
          resources:
            requests: {cpu: 50m, memory: 64Mi}
            limits: {cpu: 500m, memory: 256Mi}
          securityContext: # Variant C (D3): privileged. For Variant A replace by the block under "Variant A" in plan WP5
            privileged: true
          startupProbe: # the tunnel is up and the health check passes; up to about 3 minutes
            exec: {command: ["/gluetun-entrypoint", "healthcheck"]}
            periodSeconds: 5
            failureThreshold: 36
            timeoutSeconds: 5
          livenessProbe: # gluetun restarts the VPN by itself; this only restarts the container if it is stuck
            exec: {command: ["/gluetun-entrypoint", "healthcheck"]}
            periodSeconds: 30
            failureThreshold: 6
            timeoutSeconds: 5
          volumeMounts:
            - {name: gluetun-state, mountPath: /gluetun}
      containers:
        - name: qbittorrent
          image: <QBIT_REF>
          ports:
            - {name: http, containerPort: 8080}
          env:
            - {name: PUID, value: "1000"}
            - {name: PGID, value: "1000"}
            - {name: TZ, value: Europe/Lisbon}
            - {name: WEBUI_PORT, value: "8080"}
            # TORRENTING_PORT is deliberately NOT set: the listening port is the one forwarded by the VPN and
            # is written into qBittorrent by gluetun's VPN_PORT_FORWARDING_UP_COMMAND.
          resources:
            requests: {cpu: 250m, memory: 512Mi}
            limits: {cpu: "2", memory: 2Gi}
          securityContext: # the linuxserver image starts as root (s6) and drops to PUID/PGID, so it needs these four
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
              add: [CHOWN, SETUID, SETGID, DAC_OVERRIDE, FOWNER]
          readinessProbe: # exec, not httpGet: kubelet probes come from the node and the node range is not allowed by the firewall
            exec:
              command: ["/bin/sh", "-c", "curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8080/"]
            periodSeconds: 10
            timeoutSeconds: 6
          livenessProbe: # fails (container restarted) if the WebUI is dead OR gluetun's health server reports the tunnel unhealthy
            exec:
              command: ["/bin/sh", "-c", "curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8080/ && curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:9999/"]
            initialDelaySeconds: 60
            periodSeconds: 30
            timeoutSeconds: 12
            failureThreshold: 4
          volumeMounts:
            - {name: config, mountPath: /config}
            - {name: data, mountPath: /data}
      volumes:
        - name: config
          persistentVolumeClaim: {claimName: qbittorrent-config}
        - name: data
          hostPath: {path: /var/mnt/staging, type: Directory} # mini03's `staging` volume (talos/patches/volumes-mini03.yaml)
        - name: gluetun-state
          emptyDir: {}
```
   **Variant A edits** (D3=A, probe passed): in the gluetun container replace the `securityContext` by
```yaml
          securityContext:
            capabilities:
              add: [NET_ADMIN]
```
   and add under gluetun `volumeMounts` `- {name: tun, mountPath: /dev/net/tun}` and under `volumes`
   `- name: tun` / `hostPath: {path: /dev/net/tun, type: CharDevice}`.
   Notes the executor must keep honest: (1) qBittorrent's liveness probe needs `curl` inside the image
   (the linuxserver image ships it `[UNVERIFIED]`; WP5 verification checks with `exec ... -- which curl`);
   if absent use `wget -q -O /dev/null` (check `which wget`). (2) The gluetun health server on port 9999
   returning a non-2xx status when unhealthy is `[UNVERIFIED]` beyond the wiki (it says the Docker healthcheck
   "queries the health server and exits 0 if healthy"); verify in WP7 by reading the status code when the
   tunnel is up (expect 200). If the plain GET gives a different success code, adapt the probe, do not
   guess. (3) The `/gluetun` emptyDir keeps gluetun's server list and PIA port state across container
   restarts but not pod restarts (fine).

6. `talos/apps-src/qbittorrent.yaml` (shape of `talos/apps-src/samba-nas.yaml`):
```yaml
# qBittorrent behind gluetun for mini03 (docs/plans/torrent-gluetun.md). Manual sync: it needs the sealed
# Secret gluetun-vpn and the mini03 node. Namespace `arr` is created by the `namespaces` app.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: qbittorrent
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/BrunoLoureirooo/homelab_gitops
    targetRevision: main
    path: talos/manifests/qbittorrent
  destination:
    server: https://kubernetes.default.svc
    namespace: arr
```
   (no `CreateNamespace`: `namespaces` owns `arr`). Run `talos/render-apps.sh --force`; add to
   `talos/test/empty-cluster-expectations.txt`:
   `qbittorrent             *       *       # manual sync; needs the mini03 node, the arr namespace and the sealed gluetun-vpn Secret`.
7. Validate without a cluster: `kubectl kustomize talos/manifests/qbittorrent` renders; (if available)
   `kubectl --context admin@<cluster> apply --dry-run=server -k talos/manifests/qbittorrent` is a LIVE API call,
   do NOT run it. Use `kubectl kustomize ... | kubeconform` only if installed.
8. Guards, commit, draft PR "arr: qBittorrent behind gluetun on mini03".

PR description: the WP2 result, decisions D1 to D5, image digests with tags, the sentence "the pod range is
in the sealed Secret", and the operator's steps after merge:
1. Argo CD UI, app `qbittorrent`, review the diff, Sync. 2. Watch the pod go `Init:0/2` then `2/2`.
3. If it stays in Init, check the gluetun log (executor's WP5 verification). Do not continue to WP6 until
`2/2`.

Verification (read-only, after the operator syncs):
- `kubectl --context admin@<cluster> -n arr get pods -o wide`: `qbittorrent-...` `2/2 Running` (the native
  sidecar counts as a running container) on `mini03`.
- `kubectl --context admin@<cluster> -n arr logs deploy/qbittorrent -c gluetun | tail -40`: lines about
  the VPN connecting, the public IP, `port forwarded is <number>` (exact wording `[UNVERIFIED]`; look for
  "port forward"), the health server running; no `ERROR` about tun.
- `... -c fix-perms`: `fix-perms done`.
- `... -n arr describe pod <pod>` shows no Events errors.
Expected differences to report: tun errors (go back to D3), `permission denied` writing `/data`
(ownership; `fix-perms` log), `Pending` (toleration/nodeSelector/mini03 absent), image pull errors.
Rollback: revert the PR; in Argo delete the app (prune) or set `replicas: 0` via a PR. Data in `/data`
remains on the node (disposable); the PVC remains (reclaim Retain).
STOP: report; wait.

### WP6: first start, permanent password, sealed WebUI secret, qBittorrent settings

Goal: password set, settings in place. Branch `torrent/wp6-webui-secret`. Preconditions: WP5 `2/2`.

Steps for the executor (read-only): get the temporary password hint:
`kubectl --context admin@<cluster> -n arr logs deploy/qbittorrent -c qbittorrent | grep -i "temporary password"`
and confirm the log line wording for Section 12 (report the wording WITHOUT the password: replace the value
with `<redacted>`). Also `exec` checks: `kubectl --context admin@<cluster> -n arr exec deploy/qbittorrent -c qbittorrent -- ls /config/qBittorrent` (expect `qBittorrent.conf`) and
`... -- which curl`.

Copy-paste list for the operator (UI steps, in this order; each is Tools > Options in the qBittorrent WebUI,
reached in WP8 on the tailnet or temporarily via `kubectl --context admin@<cluster> -n arr port-forward
deploy/qbittorrent 8080:8080` from his own terminal and `http://localhost:8080`; `port-forward` is
read-only for the cluster, and the firewall allows it because the traffic arrives on eth0 port 8080):

1. Log in as `admin` with the temporary password from the log.
2. Web UI tab > Authentication: new Username (keep `admin` or choose) and a new Password (generate with
   `openssl rand -base64 24 | pbcopy`; paste it into the field and into the password manager). Tick
   "Bypass authentication for clients on localhost" (this is required for gluetun's port hook, which runs
   inside the same pod; it does not open anything to the network). Do NOT tick the subnet whitelist unless
   D6=b.
3. Web UI tab > "Enable Host header validation": either untick it or put `*` into "Server domains". Reason:
   the arr apps call `qbittorrent.arr.svc` and the Tailscale Ingress passes the tailnet name as Host header;
   a mismatching Host header is rejected. The tailnet name is not committed anywhere; it lives only in this
   UI setting. Keep "Enable Cross-Site Request Forgery (CSRF) protection" ON.
4. Downloads tab: "Default Save Path" `/data/torrents`; tick "Keep incomplete torrents in" and set
   `/data/torrents/incomplete`; "Default Torrent Management Mode": Automatic; tick "Delete .torrent files
   afterwards" off (leave default).
5. Left list > categories (the Categories box in the main window, right click > "Add category"):
   `tv` with save path `/data/torrents/tv`; `movies` with `/data/torrents/movies`; `music` with
   `/data/torrents/music`. (Names `[ASSUMED]` to match the arr-stack plan.)
6. Connection tab: untick "Use UPnP / NAT-PMP port forwarding from my router" (the VPN hook manages the
   port); leave "Port used for incoming connections" alone (gluetun overwrites it).
7. Advanced tab: leave "Network interface" empty at first; the hook sets it to `tun0` (check after WP7).
8. Click Save.

Then the operator seals the WebUI credentials (recipe like WP4, namespace `arr`, name `qbittorrent-webui`):
```bash
read -rp  "qBittorrent user: " U
read -rsp "qBittorrent password: " P; echo
jq -n --arg u "$U" --arg p "$P" '{apiVersion:"v1",kind:"Secret",
   metadata:{name:"qbittorrent-webui",namespace:"arr"},type:"Opaque",
   data:{username:($u|@base64),password:($p|@base64)}}' |
 KUBECONFIG=/dev/null kubeseal --cert argocd/sealed-secrets/pub-cert.pem --format yaml \
   > talos/sealed-secrets/qbittorrent-webui.yaml
unset U P
grep -c 'kind: SealedSecret' talos/sealed-secrets/qbittorrent-webui.yaml   # expect 1
```
plus the kustomization line and header comment (as in WP4:
`#   qbittorrent-webui.yaml   arr/qbittorrent-webui   username, password`). Executor: guards, draft PR
"arr: sealed qBittorrent WebUI credentials". The operator then enters `http://qbittorrent.arr.svc:8080`, the user
and the password in each arr app's download-client form (arr-stack plan; host `qbittorrent.arr.svc`, port
`8080`, no TLS, category `tv`/`movies`/`music`).

Verification: after the settings, `kubectl --context admin@<cluster> -n arr logs deploy/qbittorrent -c qbittorrent | tail`
shows no auth errors; the Secret `qbittorrent-webui` has the two keys (`describe secret`).
Rollback: the settings are in the PVC (re-doable); delete the sealed file via PR. STOP.

### WP7: leak tests, DNS test, forwarded-port test (read-only; the operator runs the kill-switch test)

Goal: prove the design. No PR. All commands use `-n arr` and the pod's name via `deploy/qbittorrent`.

Executor, read-only:
1. Public IP seen from inside (through the tunnel):
   `kubectl --context admin@<cluster> -n arr exec deploy/qbittorrent -c qbittorrent -- curl -s --max-time 15 https://api.ipify.org`
   Expected: one IP address (do not write it into any file or report; say "obtained"). It must differ from
   the operator's home public address. The operator compares on his own machine: `curl -s https://api.ipify.org` and the
   two values must be different (and the exit should be in the country chosen in D5). If equal: STOP, leak.
2. DNS path: `... exec deploy/qbittorrent -c qbittorrent -- cat /etc/resolv.conf` expects only the loopback
   nameserver; `... -- getent hosts example.com` returns an answer. Also in the gluetun log `dns` lines show
   the DoT upstream. If resolution fails, STOP (the loopback DNS assumption is wrong, 4.1 point 3).
3. Interface check: `... exec deploy/qbittorrent -c qbittorrent -- cat /proc/net/dev` lists `tun0` (or the WireGuard
   interface name gluetun uses; the hook receives it as `{{VPN_INTERFACE}}`) next to `eth0` and `lo`.
4. Forwarded port: `... exec deploy/qbittorrent -c gluetun -- cat /tmp/gluetun/forwarded_port` prints one
   number (wiki-documented file, [verified]). Compare with qBittorrent's setting:
   `... exec deploy/qbittorrent -c qbittorrent -- curl -s http://127.0.0.1:8080/api/v2/app/preferences` (works
   thanks to localhost bypass) and read `listen_port`, which must equal the forwarded number, and
   `current_network_interface` must equal the tunnel interface. Look at it with `| grep -o '"listen_port":[0-9]*'`.
   If not equal: Section 10 row "no forwarded port" / "port not set".
5. Health endpoint status (for the probe, WP5 note 2):
   `... exec deploy/qbittorrent -c qbittorrent -- curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9999/` expect `200`.

The operator, in his own terminal (these change pod state, they are his tests, not the executor's):
6. Kill-switch test. First confirm the baseline (step 1 works). Then take the tunnel down inside the pod:
   `kubectl --context admin@<cluster> -n arr exec deploy/qbittorrent -c gluetun -- sh -c 'ip link set <tunnel-interface> down'`
   (use the interface name from step 3). Immediately run step 1's `curl ... api.ipify.org` again: expected
   result is a timeout or failure, never an address. Also try `curl -s --max-time 5 http://example.com` (any
   plain site): must fail too. gluetun then restarts the VPN by itself within about a minute (health check,
   [verified faq]); after that step 1 works again and the log shows the reconnect.
7. Restart-order test: The operator deletes the pod in the Argo CD UI (pod > Delete): the new pod must show `Init` until the tunnel
   is up, and qBittorrent must not start earlier (observe with `get pods -w`).
8. Inbound reachability of the forwarded port from outside (optional, the operator only): use the provider's or
   any port-check website with the VPN exit address and the forwarded port while qBittorrent has an active
   torrent; or in qBittorrent's status bar, the connection indicator should be green (connectable). No site
   names are recommended here.

Expected failures to know: the first `curl` can fail for up to a minute after a pod start (tunnel
connecting); the port hook may need a few retries (wget `--retry-connrefused`).
Rollback: none. STOP: report all outputs as "OK/not OK" without addresses.

### WP8: tailnet access to the WebUI (one PR)

Goal: The operator opens qBittorrent on the tailnet as `qbittorrent`. Branch `torrent/wp8-ingress`. Preconditions: WP6 done
(the WebUI has a password; never expose the temporary-password state).

1. Create `talos/manifests/qbittorrent/ingress.yaml` and add it to the kustomization `resources:`:
```yaml
# qBittorrent WebUI on the tailnet only (Tailscale operator). The hostname comes from tls.hosts; the full
# tailnet name is a host detail and is not committed. Needs the WebUI Host header validation relaxed (plan WP6).
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: qbittorrent
  labels:
    app.kubernetes.io/name: qbittorrent
spec:
  ingressClassName: tailscale
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: qbittorrent
                port:
                  number: 8080
  tls:
    - hosts:
        - qbittorrent
```
2. `kubectl kustomize talos/manifests/qbittorrent` renders; `talos/render-apps.sh --force` (no app change
   expected, run anyway); guards; draft PR "arr: qBittorrent WebUI on the tailnet".
The operator after merge: sync app `qbittorrent` in Argo. In the Tailscale admin console delete any stale
`qbittorrent` device first (otherwise the new one registers as `qbittorrent-1`, as noted in the Jellyfin
Ingress). Open `https://qbittorrent.<tailnet-name>` (name taken from his Tailscale console).
Verification (read-only): `kubectl --context admin@<cluster> -n arr get ingress` shows an address;
`-n tailscale get pods` shows a new `ts-qbittorrent-*` pod. The proxy pod reaches the WebUI because
its source is in the pod network that `FIREWALL_OUTBOUND_SUBNETS` allows. If the page does not load, see
Section 10 ("WebUI unreachable from the tailnet").
Rollback: revert the PR (the Ingress is removed on sync). STOP.

### WP9: disk-space guard (one PR)

Goal: below 20 GiB free on `/data`, pause all torrents so the 283 GiB volume never fills (D7=a).
Branch `torrent/wp9-disk-guard`. Preconditions: WP6 (credentials), D7.

1. Create `talos/manifests/qbittorrent/disk-guard.yaml` and list it in the kustomization:
```yaml
# Every 5 minutes: if less than 20 GiB are free on the staging volume, stop (pause) ALL torrents through the
# qBittorrent API so the volume cannot fill up. Resuming is manual (WebUI: select all > Start).
apiVersion: batch/v1
kind: CronJob
metadata:
  name: qbittorrent-disk-guard
  labels:
    app.kubernetes.io/name: qbittorrent-disk-guard
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 0
      activeDeadlineSeconds: 120
      template:
        spec:
          restartPolicy: Never
          automountServiceAccountToken: false
          nodeSelector:
            kubernetes.io/hostname: mini03
          tolerations:
            - key: node-role.homeserver/tier
              operator: Equal
              value: mobile
              effect: NoSchedule
          containers:
            - name: guard
              image: <QBIT_REF> # same digest as the Deployment: it has curl, df and awk
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -eu
                  min_kib=$((20 * 1024 * 1024))
                  avail_kib=$(df -Pk /data | awk 'NR==2 {print $4}')
                  echo "free KiB on /data: $avail_kib (limit $min_kib)"
                  if [ "$avail_kib" -ge "$min_kib" ]; then echo "ok"; exit 0; fi
                  echo "LOW DISK: stopping all torrents"
                  base=http://qbittorrent.arr.svc:8080
                  curl -fsS -c /tmp/cj -H "Referer: $base" \
                    --data-urlencode "username=$QB_USER" --data-urlencode "password=$QB_PASS" \
                    "$base/api/v2/auth/login" | grep -q "Ok."
                  curl -fsS -b /tmp/cj -H "Referer: $base" --data "hashes=all" "$base/api/v2/torrents/stop"
                  echo "stopped"
                  exit 1 # fail the Job so the low disk is visible (and alertable)
              env:
                - name: QB_USER
                  valueFrom: {secretKeyRef: {name: qbittorrent-webui, key: username}}
                - name: QB_PASS
                  valueFrom: {secretKeyRef: {name: qbittorrent-webui, key: password}}
              resources:
                requests: {cpu: 10m, memory: 16Mi}
                limits: {cpu: 100m, memory: 64Mi}
              securityContext:
                runAsUser: 1000
                runAsGroup: 1000
                runAsNonRoot: true
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: [ALL]
              volumeMounts:
                - {name: data, mountPath: /data, readOnly: true}
                - {name: tmp, mountPath: /tmp}
          volumes:
            - name: data
              hostPath: {path: /var/mnt/staging, type: Directory}
            - name: tmp
              emptyDir: {}
```
   Caveats to write in the PR: the guard depends on the WebUI Host header relaxation (WP6 step 3) and on the
   firewall allowing the CronJob pod (pod network). The low-disk path exits 1 on purpose. `df` in a
   running pod on a hostPath reports the whole xfs filesystem. `torrents/stop` is the qBittorrent 5.x name
   [verified]; if the image ever downgrades to 4.x it is `torrents/pause`.
2. Guards, draft PR "arr: qBittorrent disk-space guard". After merge the operator syncs `qbittorrent`.
Verification: next run: `kubectl --context admin@<cluster> -n arr get cronjob,jobs` and
`kubectl --context admin@<cluster> -n arr logs job/<latest>` shows `ok` and the free KiB figure. Safe test
of the low path (The operator-approved PR only): temporarily change `min_kib` to a huge number in a test PR; the
job must log `stopped` and fail; torrents are then resumed in the UI; revert the PR. Do not do this without
telling the operator that it pauses his torrents.
Rollback: revert the PR. STOP.

### WP10: backup schedule for `arr` (one PR, coordinate with the arr-stack / backup-replica plans)

Goal: the config PVC is covered. Branch `torrent/wp10-velero`. Preconditions: D8=yes, WP5 synced, Velero healthy.
Facts read from the repo: Velero's schedules only cover namespace `homeserver` (`homeserver-nightly`, daily
in `talos/values/velero.yaml`) and `cp-reserva-bot`; volumes are opt-in per pod with the annotation
`backup.velero.io/backup-volumes: <volume-name>` (the Deployment above carries it for volume `config`);
the Velero server runs on mini02 and the node agent DaemonSet must run on mini03 to read its volumes, but
mini03 has a taint, so the node agent needs a toleration.

1. First check whether the arr-stack or backup-replica PRs already added an `arr` schedule or the node
   agent toleration: `git grep -n "arr-nightly\|node-role.homeserver/tier" -- talos/values`. Do not duplicate.
2. In `talos/values/velero.yaml` (the Talos override; do NOT edit `argocd/values/velero.yaml`, the live k3s
   cluster reads it) add under `schedules:` (Helm merges maps) and add a `nodeAgent` block:
```yaml
schedules:
  arr-nightly:
    schedule: "40 10 * * *" # daily, 10:40 UTC, after homeserver-nightly
    template:
      ttl: "720h0m0s"
      includedNamespaces:
        - arr

nodeAgent:
  tolerations:
    - key: node-role.homeserver/tier
      operator: Equal
      value: mobile
      effect: NoSchedule
```
   (Keep the file's existing `schedules:` key: add `arr-nightly` beside `homeserver-nightly` instead of
   creating a second `schedules:` key; YAML forbids duplicate keys. Check the final file renders:
   `yq '.schedules, .nodeAgent' talos/values/velero.yaml`.)
3. Guards, draft PR "velero: nightly schedule for the arr namespace and node agent on mini03".
The operator after merge: sync `velero` in Argo; a node-agent pod appears on mini03.
Verification (read-only): `kubectl --context admin@<cluster> -n velero get schedules` lists `arr-nightly`;
after the next run `get backups -n velero` shows a `Completed` backup, and
`kubectl --context admin@<cluster> -n velero get podvolumebackups` lists the `config` volume.
Rollback: revert the PR. STOP.

## 8. Backup and restore

What is covered:

| Data | Mechanism | Notes |
|---|---|---|
| qBittorrent configuration, categories, WebUI hash, torrent resume data (PVC `qbittorrent-config`, volume `config`) | Velero schedule `arr-nightly` with the pod annotation `backup.velero.io/backup-volumes: config` (WP10), stored in MinIO on mini02 (second copy on mini03 once the backup-replica plan exists) | Small (well below 1 Gi) |
| VPN key and WebUI credentials | Sealed Secrets in git (ciphertext) plus the operator's password manager | The sealed-secrets private key itself is backed up by the existing process (`docs/dr/talos-backups.md`) |
| Manifests | git | |
| Downloads and incomplete files in `/data` (hostPath `/var/mnt/staging`) | NOT backed up on purpose | Re-downloadable; finished media is imported elsewhere by the arr stack |
| Provider account | Provider | |

Manual export (when Velero is off, D8 = no): The operator, in the WebUI, Tools > Options > "Export" does not exist
for all settings; instead rely on the PVC copy: `kubectl --context admin@<cluster> -n arr exec deploy/qbittorrent -c qbittorrent -- tar -C /config -cf - qBittorrent | tar -xf - -C ~/qbit-config-backup`
into a folder OUTSIDE the repository (it contains the password hash and session data).

**Restore test** (the executor writes the test PR, the operator performs it; never during a download you care about):
1. The operator notes the category list and the permanent password works (login succeeds).
2. PR "qbittorrent: restore test": sets `replicas: 0` for `qbittorrent`. The operator syncs. Then the operator deletes the
   PVC `qbittorrent-config` in the Argo CD UI (the config is gone; this is the test).
3. The operator restores the PVC from the latest `arr-nightly` backup. The executor first reads
   `docs/dr/talos-backups.md` for the project's restore procedure and writes the exact commands into the PR
   description; if that document has none for PVCs with opt-in file-system backups, STOP and ask the operator.
4. PR sets `replicas: 1` back. Expected: qBittorrent starts, the same permanent password works, the three
   categories exist.
Rollback: the PVC reclaim policy is Retain; the old volume directory remains on the node.

## 9. Security

- **Exposure:** the WebUI only on the tailnet (Ingress `tailscale`) and in the cluster; nothing is exposed
  to the public internet. Inbound BitTorrent traffic arrives only through the provider's forwarded port on
  the tunnel (gluetun opens it itself; `FIREWALL_VPN_INPUT_PORTS` is not needed with native Proton port
  forwarding `[UNVERIFIED]`; WP7 step 8 confirms connectability, add `FIREWALL_VPN_INPUT_PORTS` only if it
  shows not connectable and the log says the port is blocked).
- **Authentication:** WebUI password (6.3); localhost bypass is only for the sidecar in the same pod; CSRF
  protection stays on; host header validation relaxed (reachable only inside the cluster and tailnet).
- **Kill switch:** gluetun's default-deny firewall in the pod namespace; replies only to the pod network
  range; no LAN range allowed (4.4). The pod's only route to the internet is the tunnel.
- **Least privilege:** the qBittorrent container drops ALL capabilities and adds back only the five that
  the linuxserver s6 startup needs (switching to PUID/PGID); `allowPrivilegeEscalation: false`; no
  ServiceAccount token. gluetun: `NET_ADMIN` only (Variant A) or `privileged` (Variant C, decision D3) but
  it holds the VPN key and runs as root; the namespace `arr` is `privileged` (D4). Hardening later:
  `readOnlyRootFilesystem` for qBittorrent and `runAsUser 1000` are supported by the image per the
  linuxserver docs but need extra tmpfs mounts `[UNVERIFIED]`; try in a separate PR after everything works.
- **Network policy:** the CNI is flannel (`kube-flannel` DaemonSet), which does not enforce NetworkPolicy;
  do not rely on one. Other pods in the cluster can reach port 8080 and must authenticate.
- **Supply chain:** images pinned by digest; bump through PRs (Section 10).
- **Data at rest:** staging is an unencrypted xfs volume on victus' NVMe; the config PVC holds a password hash.
  Disposable torrent data is the stated trade-off.

## 10. Operations

**Upgrade (qBittorrent or gluetun).** PR "qbittorrent: bump <image> to <tag>": get the new tag from the
project's release page, resolve its digest (3.4), change the `image:` line in `deployment.yaml` (and
`disk-guard.yaml`, same digest), keep the old tag in a comment, guards, draft PR. Read the gluetun release
notes for breaking changes before a minor bump (the control server authentication changed in an earlier
release; this plan does not use it). The operator syncs `qbittorrent` in Argo; the Recreate strategy restarts the
pod (a minute of downtime; torrents resume). Verify with WP7 steps 1 and 4 again. Rollback: revert the PR
(the previous digest). qBittorrent major jumps (4.x to 5.x) can migrate the config one-way: the Velero
backup of the PVC is the way back.

**Health checks.** Pod `2/2` Ready; gluetun log tail; `describe pod` events; the disk-guard CronJob last
success: `kubectl --context admin@<cluster> -n arr get cronjob,jobs`; Velero `arr-nightly` last backup.

**Logs.** `kubectl --context admin@<cluster> -n arr logs deploy/qbittorrent -c gluetun --tail=100`,
`-c qbittorrent`, `-c fix-perms`; previous crashed container: add `--previous`.

**Resource watch.** `kubectl --context admin@<cluster> top pod -n arr --containers` (metrics-server is
deployed) and `top nodes`; qBittorrent memory near the 2 Gi limit means too many torrents/cache: lower the
"Disk cache" in Options > Advanced or raise the limit in a PR. Monitoring plan `[ASSUMED]`: alerts on pod
restarts of `arr/qbittorrent`, failed Jobs of `qbittorrent-disk-guard`, and free space of the node
filesystem backing `/var/mnt/staging`.

**Troubleshooting**

| Symptom | Where to look | Likely cause | Fix |
|---|---|---|---|
| Pod `Pending` | `describe pod`, Events | mini03 absent or not Ready; missing toleration for the `mobile` taint; the PVC cannot bind (storage class) | Fix the toleration/selector in the Deployment; check `get pvc -n arr` has `storageClassName: topolvm-fast`; wait for mini03 |
| Pod `Init:0/2` or `Init:1/2` forever, gluetun not ready | `logs -c gluetun` | Tunnel does not come up: wrong or missing `WIREGUARD_PRIVATE_KEY`; the key was generated without NAT-PMP; filter `SERVER_COUNTRIES` has no P2P server (with `PORT_FORWARD_ONLY=on`); provider limits; UDP blocked | Read the log's last error. Key problems: regenerate and re-seal (WP4). Filter: change `<COUNTRY>` by PR. Blocked UDP: switch to OpenVPN TCP (D2) |
| gluetun log: `/dev/net/tun` or `operation not permitted`, `TUN` errors | `logs -c gluetun` | The container may not open the device | Back to D3: Variant C (privileged) or the device plugin; redo the WP2 probe on the real node |
| gluetun log `adding IPv6 rule ... file exists` | `logs -c gluetun` | Stale rules in the pod namespace after an abrupt restart | Strategy is already `Recreate`; delete the pod in the Argo UI; if repeated add the documented `lifecycle.postStart` that runs `ip rule del table 51820 || true` and `ip -6 rule del table 51820 || true` [verified kubernetes wiki page] |
| Tunnel up but no forwarded port | `logs -c gluetun` for "port forward"; `cat /tmp/gluetun/forwarded_port` | Config generated without NAT-PMP; non-P2P server; `VPN_PORT_FORWARDING` not `on`; (OpenVPN) `+pmp` missing in the username; (PIA WireGuard) missing PF username/password | Fix per 6.2; confirm `PORT_FORWARD_ONLY=on`; re-seal if the key must be regenerated |
| Forwarded port exists but qBittorrent shows not connectable / the port in the UI differs | `exec ... curl .../api/v2/app/preferences` (WP7 step 4); gluetun log shows the hook output | The hook ran before the WebUI was up and all retries failed, or the localhost bypass is not ticked (hook gets `Forbidden`), or the port is blocked in the firewall | Tick "Bypass authentication for clients on localhost" (WP6); delete the pod to re-run the hook; if still blocked add `FIREWALL_VPN_INPUT_PORTS` with the port only after the operator approves (the port changes per session on Proton, so prefer the hook) |
| WebUI unreachable from the arr apps (timeout) | `kubectl --context admin@<cluster> -n arr get endpoints qbittorrent`; from an arr pod `exec ... curl -m5 http://qbittorrent.arr.svc:8080` | Pod not Ready (readiness probe failing: no `curl`; WebUI down); `FIREWALL_INPUT_PORTS` lacks 8080; `FIREWALL_OUTBOUND_SUBNETS` does not contain the pod network or has a typo (replies go into the tunnel); arr pod on a node range outside the sealed value | Check the Endpoints list; check the gluetun log for dropped packets with `FIREWALL_IPTABLES_LOG_LEVEL`-style debug only if needed; correct the sealed key (re-seal, WP4) |
| WebUI answers `Unauthorized` or a blank page via the service or tailnet name | `curl -i` response text; qBittorrent log | Host header validation rejects the hostname (WP6 step 3) | Set "Server domains" to `*` or untick validation, Save |
| Arr app says "authentication failed" | arr app's test button | Password changed or typed wrong; or D6=b whitelist not set | Re-enter (6.3); recover password if lost |
| Torrents stalled after the VPN reconnects (up/down switching) | gluetun log (reconnect lines), `preferences` `listen_port` and `current_network_interface` | The qBittorrent bug the wiki mentions: bound to the old interface or port after a reconnect; the DOWN command must have set interface `lo` and the UP command the new port | Check both hook commands are set exactly as in WP5 (quotes!); delete the pod in the Argo UI to reset; check that the liveness probe restarts the container on gluetun health failure |
| qBittorrent container restarting every few minutes | `describe pod` (last state, reason `Completed` or liveness failed), `logs --previous` | Liveness probe too strict (health server not returning success) or memory limit OOMKilled | Verify `curl http://127.0.0.1:9999/` status (WP7 step 5), raise `timeoutSeconds`; if OOMKilled raise the memory limit by PR |
| Disk guard Job failing | `logs job/<name>` | `LOW DISK` (expected, then free space and resume torrents); login failed (password changed); WebUI unreachable | Act on the message; re-seal the Secret if the password changed |
| `/data` permission denied in qBittorrent | `logs -c qbittorrent`, `-c fix-perms` | `fix-perms` did not run or the volume is owned by root with other modes | Re-sync after fixing the init script by PR; check the PUID/PGID are 1000 in both the init and the main container |
| Pod OOM or node pressure on mini03 | `top nodes`, `describe node mini03` | Too many torrents/arr apps for the 8 GiB VM | Lower qBittorrent limits by PR, or give the VM more RAM (mini03-vm plan, a the operator decision) |

## 11. Acceptance checklist and report format

Acceptance (The operator ticks each):

- [ ] `get pods -n arr` shows `qbittorrent-*` `2/2 Running` on `mini03`.
- [ ] Public IP from inside the pod differs from his own; its country matches D5.
- [ ] With the tunnel taken down (WP7 step 6) the in-pod `curl` fails; it recovers by itself.
- [ ] `/proc/net/dev` lists the tunnel interface; `/etc/resolv.conf` is loopback only.
- [ ] `listen_port` in qBittorrent equals `/tmp/gluetun/forwarded_port`; the status bar shows connectable.
- [ ] The WebUI works at the tailnet name `qbittorrent` with the permanent password.
- [ ] An arr app's "Test" button for the download client `qbittorrent.arr.svc:8080` succeeds (after the arr plan).
- [ ] Categories `tv`, `movies`, `music` exist with save paths under `/data/torrents`.
- [ ] `get cronjob -n arr` shows the disk guard with a recent successful run.
- [ ] `get schedules -n velero` lists `arr-nightly` with a Completed backup including the `config` volume.
- [ ] Secrets `gluetun-vpn` and `qbittorrent-webui` exist (`describe secret`); both values are in the operator's
      password manager.
- [ ] The test app `tun-probe` is removed.
- [ ] All guards OK on every merged PR.

Report format the executor uses after each package:

```
WP<n>: done | blocked | needs decision
PR: <url or none>
Guards: 20 OK | <failing guard and line>
Verified: <commands run and what they showed, no addresses, no secrets>
Differences from the plan: <what was different and what you did>
Needs from the operator: <decisions, UI steps, syncs, values to seal>
```

## 12. Open questions and UNVERIFIED items

Open questions for the operator: D1 to D8 (Section 5); his time zone (`TZ` is set to a value marked `[ASSUMED]`);
whether the arr-stack plan really mounts `/var/mnt/staging` at `/data` and uses categories `tv`, `movies`,
`music`; whether finished media import to Jellyfin needs a different layout (arr-stack plan).

UNVERIFIED (how to confirm):

1. Whether a non-privileged container with `NET_ADMIN` and a hostPath `/dev/net/tun` works on Talos
   (WP2 probe decides D3).
2. Exact wording of qBittorrent's temporary-password log line (WP6: grep for `temporary password`,
   record the real wording in the report, redacting the value).
3. Whether the linuxserver image contains `curl` (probes, WP7, disk guard) (`exec ... -- which curl`; if
   missing, switch probes to `wget -q -O /dev/null`, and the disk guard to wget with `--post-data`).
4. The HTTP status of gluetun's health server on `127.0.0.1:9999` when healthy (expected `200`; WP7 step 5).
5. That gluetun answers DNS on `127.0.0.1:53` inside the shared namespace (WP7 step 2), and that its
   `/gluetun-entrypoint healthcheck` works as an exec probe.
6. Proton plan requirement for port forwarding and the exact labels of the WireGuard generator page
   (The operator confirms in his account; `NAT-PMP (Port Forwarding)` is the label in the gluetun wiki).
7. Whether `FIREWALL_VPN_INPUT_PORTS` is unnecessary with Proton's native forwarding (WP7 step 8).
8. The path and key name of the stored WebUI password hash in `qBittorrent.conf`, and that deleting the line
   resets the password (recovery in 6.3).
9. Whether the `linuxserver/qbittorrent` image also runs read-only/non-root as the docs claim, in this
   cluster (later hardening PR).
10. The tag/digest of both images changes over time: digests in 3.1 are as of 2026-10-25.
11. The mount path `/var/mnt/staging` and the node taint are read from the UNMERGED branch
    `talos/victus-vm`; if the final mini03 PRs change them, update this plan (WP1 step 2).
12. Native-sidecar behaviour (`restartPolicy: Always` in `initContainers`) on this exact Kubernetes
    (v1.36 reported by `get nodes`): expected supported; if rejected use the fallback in 4.1.
