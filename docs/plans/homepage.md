# Plan: Homepage (dashboard for every service)

Audience: a local language model working on this repository for the operator. Follow it literally, one work
package at a time. Where it says STOP, stop and report to the operator; do not decide for him.

Written 2026-10-25. Service list: `docs/BACKLOG.md` (row "Homepage", status Planned). Model for tone:
`docs/plans/nas-completion.md`.

Marks used below: `[verified <url>]` = read in the official documentation on the date above.
`[UNVERIFIED]` = not confirmed; the text says how to confirm. `[ASSUMED]` = depends on a sibling plan
that is written in parallel (arr-stack, torrent-gluetun, paperless, monitoring, authentik,
actual-budget); the interface is guessed and must be checked with the command given when that service
exists.

## 0. Purpose, scope, non-goals, definition of done

**Purpose.** One page on the tailnet that links to every service of the homelab and shows live numbers
(playing streams, photo counts, DNS queries blocked, Argo sync state, node CPU and memory, download
speed, and so on).

**Scope.**
- Homepage (gethomepage.dev) as one Deployment in namespace `homeserver` on mini01, config as YAML in
  ConfigMaps generated from files in this repo, widget credentials as sealed Secrets, read-only
  Kubernetes access, a tailnet-only Ingress.
- Work is split into packages. WP1 delivers an empty-ish dashboard with only the services that exist today.
  Every later service gets its own small package that adds its tile, its widget and its sealed key.

**Non-goals.**
- No public exposure. No login proxy in front of it (an optional login is WP9, behind a decision).
- No change to the other services (their API keys are created by the operator in their own UIs).
- Homepage does not replace monitoring (`monitoring` plan) or backups.
- No Docker socket integration (this is Kubernetes).

**Definition of done** (tick every item):
- [ ] WP0 audit report delivered.
- [ ] WP1 merged and synced: dashboard opens at the tailnet URL, tiles for today's services, Kubernetes
      node widget shows CPU and memory.
- [ ] WP2 merged and synced: live widgets for Jellyfin, Immich, AdGuard Home (and Argo CD if D4 = yes).
- [ ] One package per later service merged when that service exists (WP3 to WP8), or explicitly deferred by the operator.
- [ ] `docs/BACKLOG.md` row updated (in the WP1 PR: status Partway; in the last package: Done).
- [ ] All guards green on every PR; no clear-text secret and no full tailnet name in the repo.
- [ ] Acceptance checklist (section 11) done by the operator.

## 1. Rules for the executor (read every time)

1. You change files in the repository and open pull requests. **Nothing else.** the operator merges PRs and syncs
   Argo apps himself in the Argo web UI. Never change the live cluster.
2. Cluster access is **read-only**: `get`, `describe`, `logs`, `top`, `exec ... -- <read-only command>`.
   Always `--context admin@<cluster>`. Forbidden: `apply`, `create`, `delete`, `patch`, `edit`, `scale`,
   `rollout`, `replace`, `label`, `annotate`, `drain`, `cordon`, `taint`, `argocd app sync`.
3. **Never print or decode secret values.** No `get secret -o yaml/json/jsonpath`. `describe secret` shows
   key names only and is allowed. If any command prints a secret, stop and tell the operator.
4. **No secrets in the repo in clear text.** Sealed values only (`kubeseal` with
   `argocd/sealed-secrets/pub-cert.pem`). The operator types secret values himself (hidden prompt); you never see them.
5. **No host details in any committed file** (guard `check-no-host-details.sh`): no IPv4 or CIDR, no MAC, no
   disk serial, no `/dev/disk/by-id` name, no full tailnet host name (the `<tailnet-domain>` suffix). Use
   placeholders in the plan and in commit messages and PR text. Section 4.3 says how the manifests still
   work without writing the name.
6. One concern per PR. Branch from current `origin/main`: `git fetch origin && git switch -c <branch> origin/main`.
   Open **draft** PRs. Never push to `main`, never force-push, never merge, never delete a branch.
7. Before every commit run `bash .github/scripts/run-all-guards.sh`; all 20 must print OK. Never edit a
   guard to make it pass. If one fails, fix your file or STOP.
8. After changing `talos/apps-src/*.yaml` run `talos/render-apps.sh --force` and commit `talos/apps/`.
   Every Application needs a line in `talos/test/empty-cluster-expectations.txt`.
9. Commit message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. PR description ends with
   `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
10. Never use the tag `latest`. Pin the image by digest.
11. Every PVC in this cluster needs `storageClassName: topolvm-fast` (not needed here: Homepage has no PVC).
12. Every container in namespace `homeserver` must set explicit `resources` (requests and limits); the
    LimitRange defaults CPU limits to 500m.
13. **STOP conditions.** Stop and report (do not improvise) when: a guard fails and you cannot fix it in your
    own file; a read-only command shows something different from what this plan expects and the plan does
    not say what to do; a package depends on a decision in section 5 that the operator has not answered; a
    `[ASSUMED]` interface does not match reality; a secret value appears anywhere.
14. **Never decide a the operator decision** (section 5). Use the recommended default only to write a draft, and say
    in the PR which default you used.
15. If something does not match what you see, trust what you see, write the difference in your report, ask.

## 2. Prerequisites and dependencies

### 2.1 Needed for WP1 (all exist today)

| Need | Read-only proof | If not ready |
|---|---|---|
| Argo CD running | `kubectl --context admin@<cluster> -n argocd get deploy argocd-server` shows 1/1 | STOP |
| Tailscale operator and IngressClass | `kubectl --context admin@<cluster> get ingressclass` lists `tailscale` | STOP |
| Metrics API (for the node widget) | `kubectl --context admin@<cluster> get apiservice v1beta1.metrics.k8s.io` shows AVAILABLE `True` (checked 2026-10-25: True) | STOP; the Kubernetes widget would stay empty |
| Sealed Secrets controller + certificate | `test -f argocd/sealed-secrets/pub-cert.pem && echo ok` prints `ok`; `kubectl --context admin@<cluster> -n kube-system get pods \| grep -i sealed` (or in the namespace where it runs) is Running | STOP |
| `kubeseal` and `jq` on the operator's Mac | The operator runs `command -v kubeseal jq` | The operator installs them |
| Existing services to link | `kubectl --context admin@<cluster> get ingress -A` lists immich, jellyfin, vaultwarden (homeserver), adguard-ui (adguard), argocd (argocd) | STOP and report which is missing |
| Tailnet device name `homepage` free | The operator looks in the Tailscale admin console, Machines: no stale `homepage` device (a stale one makes the new device register as `homepage-1`, see the comment in `talos/manifests/jellyfin/ingress.yaml`) | The operator deletes the stale device first |

### 2.2 Needed for later packages

| Package | Needs | Proof |
|---|---|---|
| WP2 | API keys created by the operator in Jellyfin, Immich, AdGuard Home (section 6) | The operator confirms; the executor cannot check values |
| WP2 (Argo widget) | Decision D4 and a read-only Argo account (WP2 step 6) | STOP if D4 unanswered |
| WP3 | arr stack deployed (plan `arr-stack`) in namespace `arr` | `kubectl --context admin@<cluster> -n arr get svc` lists sonarr, radarr, prowlarr, bazarr `[ASSUMED]` |
| WP4 | torrent client deployed (plan `torrent-gluetun`) in `arr` | `kubectl --context admin@<cluster> -n arr get svc` lists the client `[ASSUMED]` |
| WP5 | Paperless (plan `paperless`) in `paperless` | `kubectl --context admin@<cluster> -n paperless get svc` `[ASSUMED]` |
| WP6 | Grafana (plan `monitoring`) in `monitoring` | `kubectl --context admin@<cluster> -n monitoring get svc` `[ASSUMED]` |
| WP7 | Authentik (plan `authentik`) in `authentik` | `kubectl --context admin@<cluster> -n authentik get svc` `[ASSUMED]` |
| WP8 | Actual Budget in `homeserver` | `kubectl --context admin@<cluster> -n homeserver get svc` `[ASSUMED]` |
| WP9 | Decision D6; for OIDC, WP7 done | see WP9 |

Each of WP3 to WP8: if the service is not running, the package is **blocked**; report "blocked" and do
nothing. Do not put a tile for a service that does not exist (it would show a red error).

### 2.3 What depends on Homepage

Nothing. It only reads. Removing it never breaks another service.

## 3. Facts about Homepage

All facts below are `[verified]` on 2026-10-25 unless marked otherwise.

| Fact | Value | Source |
|---|---|---|
| Image | `ghcr.io/gethomepage/homepage` | [verified https://gethomepage.dev/installation/k8s/] |
| Current release | `v2.7.0`, released 23 October (2026) | [verified https://github.com/gethomepage/homepage/releases] |
| Tag to use | `v2.7.0` (the docs examples use `latest`; do not). That the registry tag is spelled exactly `v2.7.0` is `[UNVERIFIED]`: `new-app.sh` resolving it in WP1 step 2 is the proof; if it fails, list tags on the GHCR package page and use the one matching release 2.7.0 | |
| Port | 3000 (container), probe path `/api/healthcheck` | [verified https://gethomepage.dev/installation/k8s/] |
| Config directory | `/app/config` (files `settings.yaml`, `services.yaml`, `widgets.yaml`, `bookmarks.yaml`, `kubernetes.yaml`, `docker.yaml`, optional `custom.css`, `custom.js`); log directory `/app/config/logs` | [verified https://gethomepage.dev/installation/k8s/] |
| User | The Kubernetes example runs `runAsNonRoot`, uid/gid 1000, capabilities dropped, seccomp RuntimeDefault | [verified https://gethomepage.dev/installation/k8s/] |
| Allowed hosts | `HOMEPAGE_ALLOWED_HOSTS`: comma separated, no spaces, entries may carry a port; `localhost:3000` and `127.0.0.1:3000` are always allowed; `*` disables the check (do NOT); if you see host validation errors, read the logs and add the host exactly as logged; `/api/auth/*` and `/auth/*` are exempt | [verified https://gethomepage.dev/installation/] |
| Secrets in config | `HOMEPAGE_VAR_<NAME>` replaces the text `{{HOMEPAGE_VAR_<NAME>}}` in config files; `HOMEPAGE_FILE_<NAME>` must point to a file whose content replaces `{{HOMEPAGE_FILE_<NAME>}}` | [verified https://gethomepage.dev/installation/docker/] |
| YAML rules | Spaces not tabs; quote strings with special characters, especially API keys | [verified https://gethomepage.dev/configs/] |
| Built-in login (v2.0+) | Optional. `HOMEPAGE_AUTH_ENABLED=true`, `HOMEPAGE_AUTH_SECRET` (random, at least 32 characters), `HOMEPAGE_EXTERNAL_URL` (absolute URL), then either `HOMEPAGE_AUTH_PASSWORD` or the OIDC trio `HOMEPAGE_OIDC_ISSUER`, `HOMEPAGE_OIDC_CLIENT_ID`, `HOMEPAGE_OIDC_CLIENT_SECRET` (optional `HOMEPAGE_OIDC_NAME`, `HOMEPAGE_OIDC_SCOPE`, `HOMEPAGE_OIDC_AUTO_LOGIN`); OIDC callback `https://<host>/api/auth/callback/homepage-oidc`; with auth on, every page and API route needs a session except `/api/healthcheck` and `/api/config/custom.css`; no rate limiting for password attempts | [verified https://gethomepage.dev/installation/] |
| Kubernetes mode | `kubernetes.yaml`: `mode: disabled \| default \| cluster` (`cluster` = use the pod's service account); optional discovery flags `ingress`, `traefik`, `gateway`. Needs Kubernetes 1.19+ and a Metrics service | [verified https://gethomepage.dev/configs/kubernetes/] |
| RBAC the docs list | ClusterRole `homepage`, verbs `get`, `list` only: core `namespaces`, `pods`, `nodes`; `extensions` and `networking.k8s.io` `ingresses`; `traefik.io` `ingressroutes`; `gateway.networking.k8s.io` `httproutes`, `gateways`; `metrics.k8s.io` `nodes`, `pods`. ClusterRoleBinding to ServiceAccount `homepage` | [verified https://gethomepage.dev/installation/k8s/] |
| Per-service pod stats | In `services.yaml` a service may carry `namespace`, `app` (label selector `app.kubernetes.io/name=<app>`) and `podSelector`; only CPU and memory are shown | [verified https://gethomepage.dev/configs/kubernetes/] |
| Service keys | `href`, `icon`, `description`, `siteMonitor` (HTTP HEAD/GET, shows response time), `ping` (ICMP, IPv4 only; do not use), `showStats` | [verified https://gethomepage.dev/configs/services/] |
| Layout | `settings.yaml` `layout:` per group: `style: row`, `columns`, `header`, `tab`, `initiallyCollapsed`; `headerStyle`, `cardStyle`, `maxGroupColumns` | [verified https://gethomepage.dev/configs/settings/] |
| Resource need | Not documented by the project. The plan sizes it from the Kubernetes example plus the node's real usage (section 4.4) | `[UNVERIFIED]`: confirm with `kubectl --context admin@<cluster> top pod -n homeserver` after WP1 |
| Writable root filesystem | The upstream example does not set `readOnlyRootFilesystem`; whether Next.js needs to write inside the image is not documented. The plan keeps the root filesystem writable | `[UNVERIFIED]`; the operator may later try `true` in a separate PR |
| State | None. No database, no PVC. All configuration is the YAML files; there is no admin account | [verified https://gethomepage.dev/installation/k8s/] (the example has no volume besides the config and logs) |

Upgrade notes: v2.0.0 was the last release with a "Breaking Changes" section; v2.5.0, v2.6.0 and v2.7.0
have none. `[verified https://github.com/gethomepage/homepage/releases]`. Still read the release notes of
the target version before every bump (section 10.1).

### 3.1 Widget facts (verified one by one)

Fields each widget needs, from the official widget pages:

| Widget `type` | Required fields | Optional fields worth knowing | Source |
|---|---|---|---|
| `jellyfin` | `url`, `key` | `version: 2` for Jellyfin 10.12 and newer (default 1), `enableBlocks`, `enableNowPlaying` (default true), `enableUser`, `enableMediaControl` (default true; set `false`, a dashboard should not control playback) | https://gethomepage.dev/widgets/services/jellyfin/ |
| `immich` | `url`, `key` | `version: 2` for Immich 1.118 and newer; key needs the `server.statistics` permission; fields `users photos videos storage` | https://gethomepage.dev/widgets/services/immich/ |
| `adguard` | `url`, `username`, `password` (same as the web login) | fields `queries blocked filtered latency` | https://gethomepage.dev/widgets/services/adguard-home/ |
| `sonarr` | `url`, `key` | `enableQueue` | https://gethomepage.dev/widgets/services/sonarr/ |
| `radarr` | `url`, `key` | `enableQueue`; fields `wanted missing queued movies` | https://gethomepage.dev/widgets/services/radarr/ |
| `prowlarr` | `url`, `key` | fields `numberOfGrabs numberOfQueries numberOfFailGrabs numberOfFailQueries` | https://gethomepage.dev/widgets/services/prowlarr/ |
| `bazarr` | `url`, `key` | fields `missingEpisodes missingMovies` | https://gethomepage.dev/widgets/services/bazarr/ |
| `qbittorrent` | `url` plus either `username`+`password` or `key` (API key needs qBittorrent 5.2.0 or newer) | `enableLeechProgress`, `enableLeechSize`; fields `leech download seed upload` | https://gethomepage.dev/widgets/services/qbittorrent/ |
| `paperlessngx` | `url` plus either `username`+`password` or `key` (a token; if both are given the token wins) | fields `total inbox` | https://gethomepage.dev/widgets/services/paperlessngx/ |
| `grafana` | `url`, `username`, `password` | `version: 2` for Grafana newer than 10.4, `alerts: alertmanager`; fields `dashboards datasources totalalerts alertstriggered` | https://gethomepage.dev/widgets/services/grafana/ |
| `authentik` | `url`, `key` | `version: 2` for Authentik 2025.8.0 or newer | https://gethomepage.dev/widgets/services/authentik/ |
| `argocd` | `url`, `key` (token of a dedicated read-only account; the docs call a personal bearer token "not recommended") | fields `apps synced outOfSync healthy progressing degraded suspended missing`, at most four | https://gethomepage.dev/widgets/services/argocd/ |
| `kubernetes` (info widget in `widgets.yaml`) | none (uses `kubernetes.yaml`) | `cluster` and `nodes` blocks with `show cpu memory showLabel label` | https://gethomepage.dev/widgets/info/kubernetes/ |
| Vaultwarden | **no widget exists** (the docs page returned 404) `[verified absence 2026-10-25]` | use `siteMonitor` | |
| Actual Budget | **no widget exists** (the docs page returned 404) `[verified absence 2026-10-25]` | use `siteMonitor` | |
| NAS (Samba) | no widget, and not HTTP; tile only | description text | |

Where fields are not labelled "required" in the docs, the table lists the ones shown in the docs example.

## 4. Architecture and placement

### 4.1 Where

- Namespace `homeserver` (fixed by the brief), node **mini01** via `nodeSelector: kubernetes.io/hostname: mini01`.
- Why mini01: it already hosts the other `homeserver` web apps and the Tailscale proxy pods; Homepage has
  no state, so the node does not matter for data. mini02 is cordoned on purpose; mini03 does not exist yet.
  Read-only check on 2026-10-25 (`kubectl --context admin@<cluster> top nodes`):
  mini01 740m CPU (18%), 5077Mi memory (45%); mini02 125m (3%), 1193Mi (16%). mini01 has 12 GiB RAM;
  Homepage's ~128 MiB request is about 1% of it. Pinning to mini01 keeps the dashboard up when the
  planned mini03 VM is down.
- If mini01's memory later passes ~80%, re-evaluate with the operator (Homepage may move to mini03 with a
  `nodeSelector` change; that is a one-line PR).

### 4.2 Diagram

```
 the operator's browser (on the tailnet)
        |  https://homepage.<tailnet-domain>
        v
 Tailscale proxy pod (namespace tailscale, created by the Ingress)
        |  http :3000   (Host header = the tailnet name -> must be in HOMEPAGE_ALLOWED_HOSTS)
        v
 Service homepage (ClusterIP :3000)  ->  Pod homepage (homeserver, mini01)
                                          |  reads: ConfigMap homepage-config (YAML files)
                                          |  reads: Secret homepage-secrets, homepage-<service>-secrets (env)
                                          |  Kubernetes API via ServiceAccount homepage (get/list only)
                                          |  widget calls over plain HTTP to in-cluster Service DNS names:
                                          v
   jellyfin.homeserver:8096   immich-server.homeserver:2283   adguard-web.adguard:3000
   argocd-server.argocd:80    sonarr/radarr/... .arr    grafana.monitoring    ...
```

### 4.3 Links versus widgets, and the tailnet name

- **Widget URLs** (`widget.url`) use **in-cluster Service DNS names**: `http://<service>.<namespace>.svc.cluster.local:<port>`.
  The pod calls the services directly, never through the tailnet, so there are no certificate problems:
  these are plain HTTP, inside the cluster, on ports the Services already expose. (Certificates only
  appear if someone wrongly puts an `https://` tailnet URL in a widget; see troubleshooting.)
- **Tile links** (`href`) open in the operator's browser, so they must be the **tailnet** URLs
  (`https://<short-name>.<tailnet-domain>`). The full name is a host detail the guard rejects, so the
  config files contain `https://jellyfin.{{HOMEPAGE_VAR_TAILNET}}` and the sealed Secret supplies
  `HOMEPAGE_VAR_TAILNET=<tailnet-domain>` (the part after the short name, for example the tailnet name
  plus its `.ts.net` suffix; the operator knows it, the executor never writes it). The text replacement
  happens in the config file text, so a variable in the middle of a URL works `[verified]` by the
  docs sentence "`HOMEPAGE_VAR_XXX` replaces `{{HOMEPAGE_VAR_XXX}}`"; WP1 verification proves it in practice.
- **Allowed hosts** also need the full name: the sealed key `HOMEPAGE_ALLOWED_HOSTS` holds
  `homepage.<tailnet-domain>` (The operator types it at sealing time). Nothing in a plain file contains the name.
- Tailnet short names today (Ingress `tls.hosts` / device names): `jellyfin`, `immich`, `vaultwarden`,
  `argocd`, `adguard-ui` (the AdGuard Ingress device is named after the Ingress, the DNS service is
  `adguard`), `nas` (Samba, not HTTP). Confirm with
  `kubectl --context admin@<cluster> get ingress -A` (the ADDRESS column shows the full names: **do not
  copy them into any file**; only read the short part).

### 4.4 Resources

```
requests: cpu 50m,  memory 128Mi
limits:   cpu 300m, memory 384Mi
```
Reasoning: Homepage is a Next.js server that mostly idles and answers a few API proxy calls per page
view; the upstream example sets no limits `[UNVERIFIED sizing]`. 300m CPU lets a page render quickly
without hurting Jellyfin on the 4-core node (Jellyfin transcodes in software; see the memory note on
Jellyfin limits). 384Mi leaves headroom for Next.js; if the pod is OOM-killed (`kubectl ... describe pod`
shows `OOMKilled`), raise the limit to 512Mi in a PR.

## 5. Decisions for the operator

The executor STOPS at any package that depends on an unanswered decision.

| Id | Question | Options and trade-offs | Recommended default | If decided otherwise |
|---|---|---|---|---|
| D1 | Dashboard tailnet name | `homepage` (default, short) or another short name | `homepage` | Change `tls.hosts`, the allowed-hosts sealed value and the OIDC redirect URI together |
| D2 | One sealed Secret or one per service | (a) one Secret `homepage-secrets` holding every key: re-sealing needs all values again each time; (b) a core Secret plus `homepage-<service>-secrets` per service: adding a service is one new sealed file, nothing else is re-typed | (b) | (a) makes every later package ask the operator to retype all earlier values |
| D3 | Dedicated API users | Create a separate, least-privilege account or key for Homepage in each app (more steps, safer) or reuse an admin key (fewer steps) | Dedicated where the app supports it (Jellyfin API key is per-app anyway; Immich key with only `server.statistics`; Argo `readonly` account; Authentik user with the two view permissions); for AdGuard Home only one user exists, so the admin login is reused | An admin credential in Homepage means a leaked Homepage Secret is a full admin leak of that app |
| D4 | Show Argo CD sync state widget | Yes: needs a read-only Argo account, which changes Argo's own configuration (a separate PR outside this plan, location `[UNVERIFIED]`); No: tile with `siteMonitor` only | No for the first pass (tile only), add later | If Yes: WP2 step 6 becomes active and STOPs until the operator approves the Argo change |
| D5 | Kubernetes pod-stat badges per tile (`namespace`/`app` keys) and the cluster info widget | Cluster/node widget only (recommended, cheap) or also per-pod CPU/memory on tiles (more API calls, needs `pods` list, already granted) | Node widget in WP1; per-tile pod stats left out | Add `namespace`/`app` keys to tiles in one follow-up PR |
| D6 | Login in front of Homepage | (a) none: reachable by anyone on the tailnet (the tailnet itself is the boundary); (b) Homepage's own password login (`HOMEPAGE_AUTH_PASSWORD`); (c) OIDC with Authentik (needs WP7 and Authentik running); (d) Authentik forward-auth proxy (not feasible with the Tailscale Ingress, section 9.3) | (a) until Authentik exists, then (c) | WP9 implements (b) or (c). Note: the tile hrefs and widget data are not secret, but the page reveals which services exist and the names of the groups |
| D7 | Bookmarks | Keep a small bookmarks row (router admin etc.) or none | None | Add `bookmarks.yaml` content later; never put an IP in it (use a sealed variable) |
| D8 | Group names | Media, Photos and Files, Security, Infrastructure, Finance, Admin (from the request) | As listed | Rename in `services.yaml` and `settings.yaml` layout together |

## 6. Credentials and secret handling

**Important correction to the usual pattern:** Homepage has **no admin password and no first-login
account**. There is nothing to "discover". Everything below is either (a) a value Homepage needs to talk to
other apps, or (b) optional login credentials (WP9). If the operator asks "what is the Homepage password": there is
none (unless WP9 is done); open the URL and the dashboard is shown.

### 6.1 Core Secret (WP1)

| Item | Detail |
|---|---|
| Secret | `homepage-secrets`, namespace `homeserver` |
| Sealed file | `talos/sealed-secrets/homepage-secrets.yaml` (listed in `talos/sealed-secrets/kustomization.yaml`) |
| Keys | `HOMEPAGE_ALLOWED_HOSTS` = `homepage.<tailnet-domain>`; `HOMEPAGE_VAR_TAILNET` = `<tailnet-domain>` |
| Created by | The operator, with `docs/templates/ghcr-app/seal-secret.sh homepage HOMEPAGE_ALLOWED_HOSTS HOMEPAGE_VAR_TAILNET` (hidden prompts). The operator knows the tailnet domain (visible in the Tailscale admin console under DNS). No generation command: these are names, not random values |
| Reaches the app as | environment variables of the same name (`envFrom`) |
| Sensitivity | Low (host names), but must not be committed in clear |
| Retrieve later | `kubectl --context admin@<cluster> -n homeserver get secret homepage-secrets -o jsonpath='{.data.HOMEPAGE_ALLOWED_HOSTS}' \| base64 -d \| pbcopy` (the operator, own terminal; clipboard only) |
| If lost | The dashboard answers "Host validation failed" and tiles have no links. Re-seal (delete the sealed file and its kustomization line, run the script again) |
| Rotation | Not applicable; change only when the tailnet name or D1 changes |

### 6.2 Widget credentials inventory

One Secret per service (D2 = b): `homepage-<service>-secrets`, namespace `homeserver`, sealed file
`talos/sealed-secrets/homepage-<service>-secrets.yaml`, created with
`docs/templates/ghcr-app/seal-secret.sh homepage-<service> KEY...` (the script appends `-secrets`).
Every key is an environment variable and is referenced in config as `{{KEY}}` (so every key name starts with
`HOMEPAGE_VAR_`). The Deployment loads each with `envFrom ... optional: true`, so a package can merge before
The operator has sealed the next one (the tile shows a widget error until then).

Generating a value: none of these are generated by the operator with a command; each is created inside the
target application (UI path in the table), copied to the clipboard there, and pasted into the hidden
prompt of the seal script. After pasting, the operator also stores the value in Vaultwarden. If a value ever lands
in a chat or log, revoke it in the application and re-seal.

| # | Widget (package) | Credential | Created by the operator at (exact UI path) | Sealed Secret / key | Env var in Homepage (and config placeholder) | What the widget shows |
|---|---|---|---|---|---|---|
| 1 | Jellyfin (WP2) | API key | Jellyfin web UI > Administration > Dashboard > Advanced > API Keys > "+" , App name `Homepage` [verified https://gethomepage.dev/widgets/services/jellyfin/] | `homepage-jellyfin-secrets` / `HOMEPAGE_VAR_JELLYFIN_KEY` | `HOMEPAGE_VAR_JELLYFIN_KEY` (`{{HOMEPAGE_VAR_JELLYFIN_KEY}}`) | Active streams, now playing |
| 2 | Immich (WP2) | API key with permission `server.statistics` | Immich web UI > Account Settings > API Keys > New API Key (tick only `server.statistics`; if Immich says the key is too weak for statistics, use a key of the admin user, and record that in the report) [verified https://gethomepage.dev/widgets/services/immich/] | `homepage-immich-secrets` / `HOMEPAGE_VAR_IMMICH_KEY` | `HOMEPAGE_VAR_IMMICH_KEY` | Users, photos, videos, storage |
| 3 | AdGuard Home (WP2) | The web login (username and password; AdGuard has one user) [verified https://gethomepage.dev/widgets/services/adguard-home/] | Already exists: the admin account. The operator gets the password from Vaultwarden (it is also in sealed Secret `adguard-admin`, namespace `adguard`, key `password`; to copy it: `kubectl --context admin@<cluster> -n adguard get secret adguard-admin -o jsonpath='{.data.password}' \| base64 -d \| pbcopy`) | `homepage-adguard-secrets` / `HOMEPAGE_VAR_ADGUARD_USERNAME`, `HOMEPAGE_VAR_ADGUARD_PASSWORD` | same names | Queries, blocked, filtered, latency |
| 4 | Argo CD (WP2, only if D4 = yes) | API token of a local read-only account | Argo web UI > Settings > Accounts > account `readonly` > Tokens > Generate New. The account must first exist with capability `apiKey` and role `role:readonly` (docs give Helm values `accounts.readonly: apiKey` and `g, readonly, role:readonly`; where this repo configures Argo is `[UNVERIFIED]`: `kubectl --context admin@<cluster> -n argocd get cm argocd-cm -o yaml` shows the current `accounts.*` keys) [verified https://gethomepage.dev/widgets/services/argocd/] | `homepage-argocd-secrets` / `HOMEPAGE_VAR_ARGOCD_KEY` | `HOMEPAGE_VAR_ARGOCD_KEY` | Apps, synced, out of sync, healthy (max four fields) |
| 5 | Sonarr (WP3) | API key | Sonarr web UI > Settings > General > Security > API Key [verified https://gethomepage.dev/widgets/services/sonarr/] | `homepage-sonarr-secrets` / `HOMEPAGE_VAR_SONARR_KEY` | same | Wanted, queued, series |
| 6 | Radarr (WP3) | API key | Radarr > Settings > General > API Key [verified https://gethomepage.dev/widgets/services/radarr/] | `homepage-radarr-secrets` / `HOMEPAGE_VAR_RADARR_KEY` | same | Wanted, missing, queued, movies |
| 7 | Prowlarr (WP3) | API key | Prowlarr > Settings > General > API Key [verified https://gethomepage.dev/widgets/services/prowlarr/] | `homepage-prowlarr-secrets` / `HOMEPAGE_VAR_PROWLARR_KEY` | same | Grabs, queries, failures |
| 8 | Bazarr (WP3) | API key | Bazarr > Settings > General > API Key [verified https://gethomepage.dev/widgets/services/bazarr/] | `homepage-bazarr-secrets` / `HOMEPAGE_VAR_BAZARR_KEY` | same | Missing episodes and movies (subtitles) |
| 9 | qBittorrent (WP4) | WebUI username + password (or, from qBittorrent 5.2.0, an API key under Options > WebUI > Authentication > API Key) [verified https://gethomepage.dev/widgets/services/qbittorrent/] | The WebUI account of the torrent client; created per the `torrent-gluetun` plan `[ASSUMED]`. If that plan keeps qBittorrent's "bypass authentication for clients in whitelisted subnets" off, Homepage needs the login | `homepage-qbittorrent-secrets` / `HOMEPAGE_VAR_QBITTORRENT_USERNAME`, `HOMEPAGE_VAR_QBITTORRENT_PASSWORD` | same | Download and upload speed, leech and seed counts |
| 10 | Paperless-ngx (WP5) | API token (or username+password; the token wins if both) | Paperless web UI > top-right user menu > My Profile > API Auth Token (circular-arrow icon generates it) `[UNVERIFIED path: the Homepage docs only link to https://docs.paperless-ngx.com/api/#authorization; confirm in the UI]` | `homepage-paperless-secrets` / `HOMEPAGE_VAR_PAPERLESS_KEY` | same | Total documents, inbox count |
| 11 | Grafana (WP6) | Username and password (the widget supports no token) [verified https://gethomepage.dev/widgets/services/grafana/] | Grafana > Administration > Users and access > Users > New user, name `homepage`, role Viewer `[UNVERIFIED role sufficiency: the dashboards/datasources counts may need Viewer or Editor; if the widget shows 403, raise the role to Editor and note it]` | `homepage-grafana-secrets` / `HOMEPAGE_VAR_GRAFANA_USERNAME`, `HOMEPAGE_VAR_GRAFANA_PASSWORD` | same | Dashboards, datasources, alerts |
| 12 | Authentik (WP7) | API token of a user holding global permissions "authentik Core: Can view User" and "authentik Events: Can view Event" [verified https://gethomepage.dev/widgets/services/authentik/] | Authentik Admin interface > Directory > Tokens and App passwords > Create, Intent `API Token`, user = a dedicated service user `homepage` with those two permissions | `homepage-authentik-secrets` / `HOMEPAGE_VAR_AUTHENTIK_KEY` | same | Users, logins in the last 24 h, failed logins |
| 13 | Vaultwarden, Actual Budget, NAS | none (no widget exists) | | | | tile with link and `siteMonitor` only |

### 6.3 Optional login credentials (WP9, decision D6)

| Item | Detail |
|---|---|
| Secret | `homepage-auth-secrets`, namespace `homeserver`, sealed file `talos/sealed-secrets/homepage-auth-secrets.yaml` |
| Keys (password login, D6 = b) | `HOMEPAGE_AUTH_ENABLED` = `true`; `HOMEPAGE_AUTH_SECRET` = random string, at least 32 characters; `HOMEPAGE_EXTERNAL_URL` = `https://homepage.<tailnet-domain>`; `HOMEPAGE_AUTH_PASSWORD` = strong password |
| Keys (OIDC, D6 = c) | the first three above, plus `HOMEPAGE_OIDC_ISSUER`, `HOMEPAGE_OIDC_CLIENT_ID`, `HOMEPAGE_OIDC_CLIENT_SECRET`; no `HOMEPAGE_AUTH_PASSWORD` |
| Generation (the operator, no echo) | `openssl rand -base64 32 \| pbcopy` for `HOMEPAGE_AUTH_SECRET` and for the password (paste into the hidden prompt, then store in Vaultwarden) |
| Password discovery | The password is the one the operator chose; it appears nowhere else. Retrieve: `kubectl --context admin@<cluster> -n homeserver get secret homepage-auth-secrets -o jsonpath='{.data.HOMEPAGE_AUTH_PASSWORD}' \| base64 -d \| pbcopy` |
| Lost password recovery | Delete the sealed file and its kustomization line, re-run `seal-secret.sh homepage-auth HOMEPAGE_AUTH_ENABLED HOMEPAGE_AUTH_SECRET HOMEPAGE_EXTERNAL_URL HOMEPAGE_AUTH_PASSWORD` with a new password, PR, merge, sync `talos-sealed-secrets`, then the operator restarts the pod (section 10.5). There is no data to lose: sessions simply end |
| If locked out entirely | Remove the package WP9 (revert the PR): the dashboard is open again |
| Rotation | Same as recovery; changing `HOMEPAGE_AUTH_SECRET` logs everybody out |

### 6.4 How the operator retrieves any widget credential later

`kubectl --context admin@<cluster> -n homeserver get secret homepage-<service>-secrets -o jsonpath='{.data.<KEY>}' | base64 -d | pbcopy`
(own terminal, clipboard only, never on screen). Better: it is in Vaultwarden.

### 6.5 What breaks if a widget credential is lost or revoked

Only that tile's live numbers (an error text such as "API Error", HTTP 401/403). The link still works.
Fix: create a new key in the app, delete the sealed file and its kustomization line, re-seal, PR, sync
`talos-sealed-secrets`, restart the Homepage pod (env vars are read at start).

## 7. Work packages

General: every package is one branch, one draft PR. After each package the executor writes the report of
section 11. Branch names are given. All paths are relative to the repository root.

### WP0: read-only audit

Goal: confirm the facts this plan relies on, change nothing.
Branch: none (no files). Report only.

Steps (run each; compare with "expected"; on a difference write it down, STOP only where stated):
1. `git fetch origin && git status -sb` : on a clean tree. Expected: nothing to commit.
2. `kubectl --context admin@<cluster> top nodes` : mini01 and mini02 listed. Record numbers. STOP if mini01 memory is above 85% (tell the operator).
3. `kubectl --context admin@<cluster> get ns homeserver --show-labels` : label `pod-security.kubernetes.io/enforce=privileged`.
4. `kubectl --context admin@<cluster> -n homeserver get limitrange default-limits -o yaml` : default CPU limit 500m (this is why explicit resources are mandatory).
5. `kubectl --context admin@<cluster> get ingress -A` : immich, jellyfin, vaultwarden, adguard-ui, argocd present. Record the **short** device names only.
6. `kubectl --context admin@<cluster> get svc -A | grep -E "jellyfin|immich-server|adguard-web|argocd-server|vaultwarden"` : record names, namespaces, ports. Expected (2026-10-25): `jellyfin.homeserver:8096`, `immich-server.homeserver:2283`, `adguard-web.adguard:3000`, `argocd-server.argocd:80,443`, `vaultwarden.homeserver:80`. If a port differs, use the real one everywhere below.
7. `kubectl --context admin@<cluster> -n argocd get cm argocd-cmd-params-cm -o jsonpath='{.data.server\.insecure}'` : expected `true` (so `http://argocd-server.argocd.svc.cluster.local:80` answers plain HTTP). If not `true`, the Argo widget URL must use port 443 with HTTPS and the certificate would fail: mark D4 "blocked" and tell the operator.
8. `kubectl --context admin@<cluster> -n argocd get networkpolicy argocd-server -o yaml` : check that ingress is allowed from other namespaces (the Helm default allows any source on the server ports). If it restricts sources, WP2's Argo widget needs a NetworkPolicy change: STOP for that widget only.
9. `kubectl --context admin@<cluster> get apiservice v1beta1.metrics.k8s.io` : AVAILABLE True.
10. `kubectl --context admin@<cluster> -n homeserver get deploy jellyfin -o jsonpath='{.spec.template.spec.containers[0].image}'` and `... get deploy immich-server ...` : record the versions to decide the widget `version:` field (Jellyfin 10.12 or newer -> `version: 2`; Immich 1.118 or newer -> `version: 2`). The tag is printed as a digest plus comment in the manifests; read the comment in `talos/manifests/jellyfin/deployment.yaml` if the live image shows only a digest.
11. `ls talos/manifests talos/apps-src talos/sealed-secrets` : confirm there is no `homepage` yet.
12. `cat .github/scripts/check-no-host-details.sh | head -70` : confirm the rules in section 1 rule 5.
13. `gh pr list --state all --search homepage` : no conflicting PR.
14. `docs/BACKLOG.md` row "Homepage" is `Planned`.

STOP point: deliver the audit as the WP0 report (numbers, differences, the decisions D1 to D8 listed for the operator).

### WP1: the dashboard with today's services

Goal: a working Homepage with tiles for the services that exist now and a node CPU/memory widget; no widget credentials yet except the core Secret.
Branch: `feat/homepage-core`.
Preconditions: WP0 done; D1, D2, D8 answered (defaults accepted counts as answered only if the operator said so).

**Step 1: create the branch.**
`git fetch origin && git switch -c feat/homepage-core origin/main`

**Step 2: generate the scaffold and pin the image.**
WHY: the template script resolves the digest and writes the Argo Application plus the expectation line.
`docs/templates/ghcr-app/new-app.sh homepage ghcr.io/gethomepage/homepage:v2.7.0 3000`
Expected output: `resolved ghcr.io/gethomepage/homepage:v2.7.0 to sha256:<64 hex>`. Write that digest down.
If it says it could not resolve: list the tags on https://github.com/gethomepage/homepage/pkgs/container/homepage, pick the one for release 2.7.0, retry. If still failing STOP.
Then delete files this app does not use:
`rm talos/manifests/homepage/pvc.yaml`

**Step 3: `talos/manifests/homepage/deployment.yaml`** (overwrite the generated file; keep the digest you got in step 2 in place of `<DIGEST>`):

```yaml
# Homepage dashboard on mini01. Stateless: config comes from the generated ConfigMap homepage-config,
# widget credentials from sealed Secrets (env vars). Pin the image by digest; the tag stays in the comment.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: homepage
  labels:
    app.kubernetes.io/name: homepage
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: homepage
  template:
    metadata:
      labels:
        app.kubernetes.io/name: homepage
    spec:
      serviceAccountName: homepage
      automountServiceAccountToken: true # needed for kubernetes.yaml mode: cluster
      enableServiceLinks: false          # many services in the namespace; keeps the environment small
      nodeSelector:
        kubernetes.io/hostname: mini01
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: homepage
          image: ghcr.io/gethomepage/homepage@sha256:<DIGEST> # v2.7.0
          ports:
            - name: http
              containerPort: 3000
          # HOMEPAGE_ALLOWED_HOSTS and HOMEPAGE_VAR_TAILNET live in the sealed Secret homepage-secrets.
          # Every widget package adds one more optional block below (optional: true lets a package
          # merge before the operator has sealed its key).
          envFrom:
            - secretRef:
                name: homepage-secrets
            # --- widget secrets, one block per package (keep alphabetical) ---
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 300m
              memory: 384Mi
          # The Host header of a kubelet probe is the pod IP, which is not in HOMEPAGE_ALLOWED_HOSTS.
          # "localhost:3000" is always allowed (docs), so the probes send that Host header.
          readinessProbe:
            httpGet:
              path: /api/healthcheck
              port: http
              httpHeaders:
                - name: Host
                  value: localhost:3000
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /api/healthcheck
              port: http
              httpHeaders:
                - name: Host
                  value: localhost:3000
            initialDelaySeconds: 30
            periodSeconds: 30
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
            # readOnlyRootFilesystem is left off: [UNVERIFIED] whether Next.js writes inside the image.
          volumeMounts:
            - name: config
              mountPath: /app/config/settings.yaml
              subPath: settings.yaml
            - name: config
              mountPath: /app/config/services.yaml
              subPath: services.yaml
            - name: config
              mountPath: /app/config/widgets.yaml
              subPath: widgets.yaml
            - name: config
              mountPath: /app/config/bookmarks.yaml
              subPath: bookmarks.yaml
            - name: config
              mountPath: /app/config/kubernetes.yaml
              subPath: kubernetes.yaml
            - name: config
              mountPath: /app/config/docker.yaml
              subPath: docker.yaml
            - name: logs
              mountPath: /app/config/logs
      volumes:
        - name: config
          configMap:
            name: homepage-config # kustomize rewrites this to the hashed generated name
        - name: logs
          emptyDir: {}
```
Note: the probe `Host: localhost:3000` trick is `[UNVERIFIED]`. The upstream example instead sets `HOMEPAGE_ALLOWED_HOSTS` to `$(MY_POD_IP):3000,...` for the probe `[verified https://gethomepage.dev/installation/k8s/]`. If the pod never becomes Ready (pod events show probe failures), replace both probes with `tcpSocket: {port: http}` (same periods) and report it to the operator.

**Step 4: `talos/manifests/homepage/service.yaml`** (overwrite):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: homepage
  labels:
    app.kubernetes.io/name: homepage
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: homepage
  ports:
    - name: http
      port: 3000
      targetPort: http
```

**Step 5: `talos/manifests/homepage/ingress.yaml`** (overwrite; follows `talos/manifests/jellyfin/ingress.yaml`):
```yaml
# Homepage on the tailnet only, served by the Tailscale operator. The hostname comes from tls.hosts
# (`homepage`); the full tailnet name is a host detail and is not committed. A stale `homepage` device in
# the tailnet makes the new one register as `homepage-1`: delete the stale device first.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: homepage
  labels:
    app.kubernetes.io/name: homepage
spec:
  ingressClassName: tailscale
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: homepage
                port:
                  number: 3000
  tls:
    - hosts:
        - homepage
```

**Step 6: `talos/manifests/homepage/rbac.yaml`** (new). Least privilege: the docs' rules minus the Traefik and Gateway API resources this cluster does not run. Ingress discovery is off (D5), but the `ingresses` rule is kept because the docs list it as required for the Kubernetes integration `[UNVERIFIED]` whether Homepage errors without it; it exposes only host names of Ingresses to the pod.
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: homepage
  labels:
    app.kubernetes.io/name: homepage
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: homepage
  labels:
    app.kubernetes.io/name: homepage
rules:
  - apiGroups: [""]
    resources: ["namespaces", "pods", "nodes"]
    verbs: ["get", "list"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list"]
  - apiGroups: ["metrics.k8s.io"]
    resources: ["nodes", "pods"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: homepage
  labels:
    app.kubernetes.io/name: homepage
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: homepage
subjects:
  - kind: ServiceAccount
    name: homepage
    namespace: homeserver
```
No `secrets`, no write verbs, no `configmaps`.

**Step 7: config files under `talos/manifests/homepage/config/`** (new directory).

`settings.yaml`:
```yaml
title: Homelab
headerStyle: clean
cardStyle: hairline
maxGroupColumns: 3
disableIndexing: true   # keep search engines away (also nothing is public)
layout:
  Media:
    style: row
    columns: 3
  Photos and Files:
    style: row
    columns: 3
  Security:
    style: row
    columns: 3
  Infrastructure:
    style: row
    columns: 3
  Finance:
    style: row
    columns: 2
  Admin:
    style: row
    columns: 3
```
(Group names must equal the group names in `services.yaml`. Groups that have no service yet are simply not drawn.)

`services.yaml` for WP1 (today's services). `{{HOMEPAGE_VAR_TAILNET}}` is the sealed suffix (section 4.3). Icons are names from the Dashboard Icons set that Homepage bundles; if an icon does not render, remove the `icon:` line (it is cosmetic):
```yaml
- Media:
    - Jellyfin:
        icon: jellyfin.png
        href: https://jellyfin.{{HOMEPAGE_VAR_TAILNET}}
        description: Movies and series
        siteMonitor: http://jellyfin.homeserver.svc.cluster.local:8096
- Photos and Files:
    - Immich:
        icon: immich.png
        href: https://immich.{{HOMEPAGE_VAR_TAILNET}}
        description: Photos
        siteMonitor: http://immich-server.homeserver.svc.cluster.local:2283
    - NAS:
        icon: samba.png
        description: Files on the tailnet (SMB share named nas; open it in the file manager, there is no web page)
- Security:
    - Vaultwarden:
        icon: vaultwarden.png
        href: https://vaultwarden.{{HOMEPAGE_VAR_TAILNET}}
        description: Passwords
        siteMonitor: http://vaultwarden.homeserver.svc.cluster.local:80
    - AdGuard Home:
        icon: adguard-home.png
        href: https://adguard-ui.{{HOMEPAGE_VAR_TAILNET}}
        description: DNS filtering
        siteMonitor: http://adguard-web.adguard.svc.cluster.local:3000
- Infrastructure:
    - Argo CD:
        icon: argo-cd.png
        href: https://argocd.{{HOMEPAGE_VAR_TAILNET}}
        description: GitOps sync
        siteMonitor: http://argocd-server.argocd.svc.cluster.local:80
```
The NAS tile has no `href`: whether Homepage accepts that is `[UNVERIFIED]`; if the Homepage log reports an error for it, remove the NAS tile and report.

`widgets.yaml` (top bar):
```yaml
- kubernetes:
    cluster:
      show: false
    nodes:
      show: true
      cpu: true
      memory: true
      showLabel: true
- datetime:
    text_size: xl
    format:
      timeStyle: short
      dateStyle: medium
```

`kubernetes.yaml`:
```yaml
mode: cluster
```

`bookmarks.yaml` and `docker.yaml` (Homepage tolerates empty files; an empty list/mapping is the safe form):
```yaml
[]
```
for `bookmarks.yaml`, and
```yaml
{}
```
for `docker.yaml` (docker integration is not used).

**Step 8: `talos/manifests/homepage/kustomization.yaml`** (overwrite the generated one):
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: homeserver
resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
  - rbac.yaml
configMapGenerator:
  - name: homepage-config
    files:
      - config/settings.yaml
      - config/services.yaml
      - config/widgets.yaml
      - config/bookmarks.yaml
      - config/kubernetes.yaml
      - config/docker.yaml
```
WHY a generator: the name gets a content hash, so any config change rolls the pod automatically (a ConfigMap mounted with `subPath` is never refreshed in a running pod). `namespace: homeserver` applies to the ServiceAccount and ClusterRoleBinding subject? It does NOT rewrite a ClusterRoleBinding subject namespace for a ServiceAccount unless the ServiceAccount is in the same kustomization (it is), so kustomize rewrites it; verify in step 10.

**Step 9: Argo app and expectation line.**
Check `talos/apps-src/homepage.yaml` (written by the script): `path: talos/manifests/homepage`, destination namespace `homeserver`, manual sync (no `automated`). If the script wrote `automated`, remove it. Then:
`talos/render-apps.sh --force`
Check the last line of `talos/test/empty-cluster-expectations.txt` is `homepage  *  *  # ...`; if the script wrote no comment, add `# manual sync; needs its sealed secret`. Commit `talos/apps/homepage.yaml` too.

**Step 10: render and read the output locally (no cluster).**
`kubectl kustomize talos/manifests/homepage > /tmp/homepage-render.yaml && grep -n "kind:\|name: homepage" /tmp/homepage-render.yaml | head -40`
Expected: ConfigMap `homepage-config-<hash>`, Deployment referencing that name, ClusterRoleBinding subject namespace `homeserver`. (`kubectl kustomize` is client-side; it does not touch the cluster.) Also run a YAML parse of the config: `for f in talos/manifests/homepage/config/*.yaml; do python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "$f" && echo "ok $f"; done` — the `{{...}}` text inside quoted URLs is fine; if the YAML parser complains about a file, quote the offending value.

**Step 11: wire the sealed Secret list.** Do not seal anything yourself. Add to `talos/sealed-secrets/kustomization.yaml` nothing now: the file is created by the operator's script (it appends its own line). In the PR description the operator's commands (below) are listed. To keep the PR mergeable without the sealed file, `homepage-secrets` is **required** (not optional) in the Deployment; the pod stays Pending/CreateContainerConfigError until the operator seals and syncs, which is intended. Because the Argo app is manual sync, the operator syncs after sealing.

**Step 12: docs.** Edit `docs/BACKLOG.md`: row Homepage -> `Partway`, note `Plan: docs/plans/homepage.md`.

**Step 13: guards and commit.**
`bash .github/scripts/run-all-guards.sh` (20 OK). Commit message `homepage: dashboard with today's services` + the Co-Authored-By line.

**The operator's steps (copy-paste list, PR description):**
1. In the Tailscale admin console remove any stale `homepage` device.
2. Seal the core secret (hidden prompts; type `homepage.<tailnet-domain>` for the first value and `<tailnet-domain>` for the second):
   `docs/templates/ghcr-app/seal-secret.sh homepage HOMEPAGE_ALLOWED_HOSTS HOMEPAGE_VAR_TAILNET`
   Commit and push the new `talos/sealed-secrets/homepage-secrets.yaml` and the changed `talos/sealed-secrets/kustomization.yaml` onto this PR branch (or ask the executor to commit them).
3. Merge the PR.
4. Argo: wait for `talos-sealed-secrets` (auto-sync) to be Synced; check with `kubectl --context admin@<cluster> -n homeserver describe secret homepage-secrets` (shows the two key names, never values).
5. Argo: sync `homepage`. Watch it become Healthy.
6. Open `https://homepage.<tailnet-domain>` on a tailnet device.

Verification (read-only):
- `kubectl --context admin@<cluster> -n homeserver get deploy,pod -l app.kubernetes.io/name=homepage` : 1/1 Running.
- `kubectl --context admin@<cluster> -n homeserver logs deploy/homepage --tail=50` : no lines containing `error` or `Host validation failed`; a startup line from Next.js.
- `kubectl --context admin@<cluster> get ingress -n homeserver homepage` : ADDRESS filled (do not copy it).
- `kubectl --context admin@<cluster> auth can-i list pods --as=system:serviceaccount:homeserver:homepage` : `yes` (impersonation is a read-only check); `... auth can-i get secrets --as=system:serviceaccount:homeserver:homepage -A` : `no`; `... auth can-i delete pods --as=system:serviceaccount:homeserver:homepage` : `no`.
- In the browser: tiles in groups Media, Photos and Files, Security, Infrastructure; the tile links open the real services (this proves `HOMEPAGE_VAR_TAILNET`); node CPU and memory widget shows mini01 and mini02.
- `kubectl --context admin@<cluster> top pod -n homeserver -l app.kubernetes.io/name=homepage` : record real usage in the report (confirms the `[UNVERIFIED]` sizing).

Rollback: revert the PR; the operator syncs `homepage` (Argo does not prune because manual sync; he deletes the app resources in the Argo UI). The sealed Secret may stay. Nothing else depends on Homepage.

PR title: `homepage: dashboard with today's services` (the umbrella plan PR is titled "docs: implementation plan for Homepage").
PR description: what the PR adds, "Needs the operator before sync: the 6 steps above", decisions used (D1 `homepage`, D2 per-service secrets, D8 group names), and the generated-file note.

STOP point: after the PR is opened, stop. WP2 needs the dashboard running and the operator's API keys.

### WP2: live widgets for services that exist today

Goal: Jellyfin, Immich, AdGuard Home (and Argo CD if D4 = yes) show live numbers.
Branch: `feat/homepage-widgets-core`.
Preconditions: WP1 synced and the dashboard opens (The operator confirms); the operator has created the credentials of section 6.2 rows 1 to 3 and has them in the clipboard/Vaultwarden. WP2 can be done widget by widget; a widget whose key the operator has not created yet is left out and reported.

**Step 1.** `git fetch origin && git switch -c feat/homepage-widgets-core origin/main` (after WP1 is merged).

**Step 2: determine widget versions** (from the WP0 audit): Jellyfin `version: 2` if 10.12 or newer; Immich `version: 2` if 1.118 or newer. If unsure, STOP and ask the operator for the version shown in the app's About page.

**Step 3: edit `talos/manifests/homepage/config/services.yaml`**: add a `widget:` block to the existing tiles (keep everything else).

Jellyfin:
```yaml
    - Jellyfin:
        icon: jellyfin.png
        href: https://jellyfin.{{HOMEPAGE_VAR_TAILNET}}
        description: Movies and series
        widget:
          type: jellyfin
          url: http://jellyfin.homeserver.svc.cluster.local:8096
          key: "{{HOMEPAGE_VAR_JELLYFIN_KEY}}"
          version: 2
          enableBlocks: true
          enableNowPlaying: true
          enableMediaControl: false
```
Immich:
```yaml
    - Immich:
        icon: immich.png
        href: https://immich.{{HOMEPAGE_VAR_TAILNET}}
        description: Photos
        widget:
          type: immich
          url: http://immich-server.homeserver.svc.cluster.local:2283
          key: "{{HOMEPAGE_VAR_IMMICH_KEY}}"
          version: 2
```
AdGuard Home:
```yaml
    - AdGuard Home:
        icon: adguard-home.png
        href: https://adguard-ui.{{HOMEPAGE_VAR_TAILNET}}
        description: DNS filtering
        widget:
          type: adguard
          url: http://adguard-web.adguard.svc.cluster.local:3000
          username: "{{HOMEPAGE_VAR_ADGUARD_USERNAME}}"
          password: "{{HOMEPAGE_VAR_ADGUARD_PASSWORD}}"
```
When a tile has a `widget`, the `siteMonitor` line may stay; remove it if the tile looks crowded.

**Step 4: edit `talos/manifests/homepage/deployment.yaml`**: under `envFrom`, after the marker comment, add (one block per widget in this PR):
```yaml
            - secretRef:
                name: homepage-adguard-secrets
                optional: true
            - secretRef:
                name: homepage-immich-secrets
                optional: true
            - secretRef:
                name: homepage-jellyfin-secrets
                optional: true
```
**Step 5: guards, render, commit.** `talos/render-apps.sh --force` is needed only if `talos/apps-src` changed (it did not). Run `kubectl kustomize talos/manifests/homepage >/dev/null && echo ok`, then the guards.

**Step 6 (only if D4 = yes): Argo CD widget.** First STOP: the read-only Argo account is an Argo configuration change. Report to the operator: "the account `readonly` with capability `apiKey` and policy `g, readonly, role:readonly` must be added to Argo's configuration (Helm values `configs.cm.accounts.readonly: apiKey` and `configs.rbac.policy.csv`), in whatever file this repo uses to install Argo; I could not find it / I found it at <path>". Do not edit Argo's configuration inside this PR. After the operator's separate change and token, add:
```yaml
    - Argo CD:
        icon: argo-cd.png
        href: https://argocd.{{HOMEPAGE_VAR_TAILNET}}
        description: GitOps sync
        widget:
          type: argocd
          url: http://argocd-server.argocd.svc.cluster.local:80
          key: "{{HOMEPAGE_VAR_ARGOCD_KEY}}"
          fields: ["apps", "synced", "outOfSync", "healthy"]
```
and the `envFrom` block for `homepage-argocd-secrets`.

**The operator's steps (PR description):**
1. Create the three credentials (section 6.2, rows 1 to 3).
2. Seal one Secret per service (hidden prompts, paste each value):
   `docs/templates/ghcr-app/seal-secret.sh homepage-jellyfin HOMEPAGE_VAR_JELLYFIN_KEY`
   `docs/templates/ghcr-app/seal-secret.sh homepage-immich HOMEPAGE_VAR_IMMICH_KEY`
   `docs/templates/ghcr-app/seal-secret.sh homepage-adguard HOMEPAGE_VAR_ADGUARD_USERNAME HOMEPAGE_VAR_ADGUARD_PASSWORD`
   Commit the three new files and the changed `talos/sealed-secrets/kustomization.yaml` to the PR.
3. Merge. Wait for `talos-sealed-secrets` Synced. Sync `homepage` (the Deployment changes, so the pod restarts and reads the new variables).

Verification:
- `kubectl --context admin@<cluster> -n homeserver describe secret homepage-jellyfin-secrets homepage-immich-secrets homepage-adguard-secrets` : key names present.
- `kubectl --context admin@<cluster> -n homeserver logs deploy/homepage --tail=80` : no `401`, `403`, `ECONNREFUSED` for the widgets.
- Browser: Jellyfin tile shows stream counts, Immich shows user/photo/video counts, AdGuard shows queries and blocked.
Rollback: revert the PR. STOP point: report which widgets work.

### WP3: arr stack (Sonarr, Radarr, Prowlarr, Bazarr)

Goal: tiles and widgets for the four arr apps. Branch `feat/homepage-arr`.
Preconditions: section 2.2; `[ASSUMED]` Service names `sonarr`, `radarr`, `prowlarr`, `bazarr` in namespace `arr`, ports 8989, 7878, 9696, 6767 (the apps' defaults) and tailnet short names equal to the app names. Confirm with `kubectl --context admin@<cluster> -n arr get svc` and `kubectl --context admin@<cluster> get ingress -n arr`. Use the real values if they differ; STOP if the services are missing.

Add to `services.yaml`:
```yaml
- Media:
    # (existing Jellyfin tile stays; this block continues the same group in the same file, see note)
    - Sonarr:
        icon: sonarr.png
        href: https://sonarr.{{HOMEPAGE_VAR_TAILNET}}
        description: Series
        widget:
          type: sonarr
          url: http://sonarr.arr.svc.cluster.local:8989
          key: "{{HOMEPAGE_VAR_SONARR_KEY}}"
          enableQueue: true
    - Radarr:
        icon: radarr.png
        href: https://radarr.{{HOMEPAGE_VAR_TAILNET}}
        description: Movies
        widget:
          type: radarr
          url: http://radarr.arr.svc.cluster.local:7878
          key: "{{HOMEPAGE_VAR_RADARR_KEY}}"
          enableQueue: true
    - Prowlarr:
        icon: prowlarr.png
        href: https://prowlarr.{{HOMEPAGE_VAR_TAILNET}}
        description: Indexers
        widget:
          type: prowlarr
          url: http://prowlarr.arr.svc.cluster.local:9696
          key: "{{HOMEPAGE_VAR_PROWLARR_KEY}}"
    - Bazarr:
        icon: bazarr.png
        href: https://bazarr.{{HOMEPAGE_VAR_TAILNET}}
        description: Subtitles
        widget:
          type: bazarr
          url: http://bazarr.arr.svc.cluster.local:6767
          key: "{{HOMEPAGE_VAR_BAZARR_KEY}}"
```
NOTE for the executor: a group name must appear **once** in `services.yaml`. Do not add a second `- Media:` list; add these four tiles as additional list items **inside** the existing `- Media:` list. Same rule in every later package.

Deployment: four optional `envFrom` blocks (`homepage-sonarr-secrets`, `homepage-radarr-secrets`, `homepage-prowlarr-secrets`, `homepage-bazarr-secrets`).
The operator seals: `seal-secret.sh homepage-sonarr HOMEPAGE_VAR_SONARR_KEY` (and radarr, prowlarr, bazarr likewise), after reading each key at Settings > General (section 6.2). Merge, wait for `talos-sealed-secrets`, sync `homepage`.
Verification: logs without 401; tiles show queue/wanted counts. Rollback: revert. STOP.

### WP4: torrent client

Goal: download/upload speed tile. Branch `feat/homepage-torrent`.
Preconditions: torrent client running in `arr` `[ASSUMED]` as Service `qbittorrent`, WebUI port 8080 (the client shares a pod with gluetun, so the Service exists on that pod); confirm with `kubectl --context admin@<cluster> -n arr get svc`. If the plan chose another client (for example Transmission or Deluge), STOP: that widget's fields are not covered here.
Tile in the `Media` group (inside the existing list):
```yaml
    - qBittorrent:
        icon: qbittorrent.png
        href: https://qbittorrent.{{HOMEPAGE_VAR_TAILNET}}
        description: Downloads (through the VPN)
        widget:
          type: qbittorrent
          url: http://qbittorrent.arr.svc.cluster.local:8080
          username: "{{HOMEPAGE_VAR_QBITTORRENT_USERNAME}}"
          password: "{{HOMEPAGE_VAR_QBITTORRENT_PASSWORD}}"
          enableLeechProgress: true
```
Deployment: optional envFrom `homepage-qbittorrent-secrets`. The operator seals: `seal-secret.sh homepage-qbittorrent HOMEPAGE_VAR_QBITTORRENT_USERNAME HOMEPAGE_VAR_QBITTORRENT_PASSWORD`. Merge, wait, sync.
Verification: tile shows speeds. If it shows an error, see troubleshooting (qBittorrent can reject requests whose Host or Referer header does not match: `[UNVERIFIED]` the docs page does not mention it; the symptom would be HTTP 401/403 despite correct credentials; report to the operator, who may need to disable "Enable Host header validation" in qBittorrent Options > WebUI, a security trade-off he decides).
Rollback: revert. STOP.

### WP5: Paperless-ngx

Branch `feat/homepage-paperless`. Preconditions: `[ASSUMED]` Service `paperless` (or the chart's webserver Service) in namespace `paperless`, port 8000; confirm with `kubectl --context admin@<cluster> -n paperless get svc`.
Tile in group `Photos and Files`:
```yaml
    - Paperless-ngx:
        icon: paperless-ngx.png
        href: https://paperless.{{HOMEPAGE_VAR_TAILNET}}
        description: Documents
        widget:
          type: paperlessngx
          url: http://paperless.paperless.svc.cluster.local:8000
          key: "{{HOMEPAGE_VAR_PAPERLESS_KEY}}"
```
Optional envFrom `homepage-paperless-secrets`. The operator seals: `seal-secret.sh homepage-paperless HOMEPAGE_VAR_PAPERLESS_KEY`. Merge, wait, sync. Verification: total documents and inbox count appear. Rollback: revert. STOP.

### WP6: Grafana (monitoring)

Branch `feat/homepage-grafana`. Preconditions: `[ASSUMED]` Service `grafana` in `monitoring`, port 80 (the Grafana Helm chart default) or 3000; confirm with `kubectl --context admin@<cluster> -n monitoring get svc`. Decide `version` from Grafana's version (newer than 10.4 -> `version: 2`).
Tile in group `Infrastructure`:
```yaml
    - Grafana:
        icon: grafana.png
        href: https://grafana.{{HOMEPAGE_VAR_TAILNET}}
        description: Metrics and dashboards
        widget:
          type: grafana
          version: 2
          url: http://grafana.monitoring.svc.cluster.local:80
          username: "{{HOMEPAGE_VAR_GRAFANA_USERNAME}}"
          password: "{{HOMEPAGE_VAR_GRAFANA_PASSWORD}}"
```
Optional envFrom `homepage-grafana-secrets`. The operator seals `seal-secret.sh homepage-grafana HOMEPAGE_VAR_GRAFANA_USERNAME HOMEPAGE_VAR_GRAFANA_PASSWORD`. If monitoring also provides an Alertmanager the dashboard should use, add `alerts: alertmanager` only if the operator asks. Rollback: revert. STOP.

### WP7: Authentik

Branch `feat/homepage-authentik`. Preconditions: `[ASSUMED]` Service `authentik-server` in `authentik`, port 80; confirm with `kubectl --context admin@<cluster> -n authentik get svc`. Authentik 2025.8.0 or newer -> `version: 2`.
Tile in group `Security`:
```yaml
    - Authentik:
        icon: authentik.png
        href: https://authentik.{{HOMEPAGE_VAR_TAILNET}}
        description: Single sign-on
        widget:
          type: authentik
          version: 2
          url: http://authentik-server.authentik.svc.cluster.local:80
          key: "{{HOMEPAGE_VAR_AUTHENTIK_KEY}}"
```
Optional envFrom `homepage-authentik-secrets`. The operator: create service user `homepage` with the two view permissions, create the token (row 12), `seal-secret.sh homepage-authentik HOMEPAGE_VAR_AUTHENTIK_KEY`. Rollback: revert. STOP.

### WP8: Actual Budget (tile only)

Branch `feat/homepage-actual`. No widget exists. Precondition `[ASSUMED]`: Service `actual-budget` in `homeserver`, port 5006; confirm with `kubectl --context admin@<cluster> -n homeserver get svc`.
Tile in a new group `Finance` (create it; `settings.yaml` already has its layout entry):
```yaml
- Finance:
    - Actual Budget:
        icon: actual-budget.png
        href: https://actual.{{HOMEPAGE_VAR_TAILNET}}
        description: Budget
        siteMonitor: http://actual-budget.homeserver.svc.cluster.local:5006
```
No Secret needed. Rollback: revert. STOP.

### WP9: login in front of Homepage (only if D6 = b or c)

Goal: Homepage asks for a login. Branch `feat/homepage-login`. STOP unless the operator answered D6. For (c) also needs WP7 and a working Authentik.

Steps:
1. Add to `deployment.yaml` `envFrom` (after the marker): `homepage-auth-secrets`, **required** (not optional, a login that silently disappears is worse than a pod that does not start).
2. The operator seals:
   - (b): `seal-secret.sh homepage-auth HOMEPAGE_AUTH_ENABLED HOMEPAGE_AUTH_SECRET HOMEPAGE_EXTERNAL_URL HOMEPAGE_AUTH_PASSWORD` (values: `true`, `openssl rand -base64 32 | pbcopy` result, `https://homepage.<tailnet-domain>`, a strong password).
   - (c): `seal-secret.sh homepage-auth HOMEPAGE_AUTH_ENABLED HOMEPAGE_AUTH_SECRET HOMEPAGE_EXTERNAL_URL HOMEPAGE_OIDC_ISSUER HOMEPAGE_OIDC_CLIENT_ID HOMEPAGE_OIDC_CLIENT_SECRET`. In Authentik first: Applications > Create with Provider (OAuth2/OpenID), redirect URI `https://homepage.<tailnet-domain>/api/auth/callback/homepage-oidc` (strict), scopes openid email profile; copy the client id and secret and the issuer URL shown on the provider page. Restrict who may use the application with an Authentik policy/group: Homepage applies no claim checks of its own `[verified https://gethomepage.dev/installation/]`.
3. Health probes keep working because `/api/healthcheck` needs no session `[verified]`.
4. Verification: opening the URL redirects to the sign-in page; after login the dashboard appears; `kubectl ... logs deploy/homepage` shows `warn` lines for failed attempts only.
Rollback: revert the PR (the dashboard opens again).

## 8. Backup and restore

| What | Covered by | Notes |
|---|---|---|
| Dashboard configuration (YAML) | Git (this repo) | The source of truth; a restore is `git` plus an Argo sync |
| Widget credentials | Sealed files in git (ciphertext) + Vaultwarden (values) | The sealed-secrets controller key is backed up per `docs/dr/talos-backups.md`; if that key is lost the sealed files cannot be decrypted and the operator re-seals from Vaultwarden |
| Pod data | nothing to back up: no PVC, no database. The only runtime writes are logs in an emptyDir | Do NOT add the Velero opt-in annotation `backup.velero.io/backup-volumes` |
| Namespace objects | Velero schedule `homeserver-nightly` (daily 10:00 UTC) covers resource manifests of namespace `homeserver` | Resource YAML only; recreating from git is equivalent |

Restore test (the executor writes this into the WP1 PR description; the operator performs it once):
1. Note the dashboard layout (screenshot).
2. In the Argo UI, delete the `homepage` Deployment resource only (Argo will show OutOfSync), then sync `homepage`.
3. Expected: the pod returns Running within a minute, same tiles and numbers; no login or data loss.
4. Full-loss test (optional): delete the namespace objects of `homepage` in Argo, sync again from git, confirm the ClusterRole/Binding return and the dashboard works. The sealed Secrets are re-created by `talos-sealed-secrets` (prune is off, so they were never deleted).

## 9. Security

### 9.1 Exposure
- Tailnet only (Tailscale Ingress). No public hostname, no port on the node, `disableIndexing: true`.
- Anyone on the tailnet can open the dashboard (no login by default, D6). What an intruder on the tailnet would see: service names, links, and whatever the widgets display (counts, now-playing titles, queue contents). Widgets never reveal the API keys (they are used server-side; Homepage proxies the calls).
- Homepage holds API credentials for other apps. A compromise of the Homepage pod = those credentials. Mitigation: dedicated and least-privilege keys (D3), env-only (no file in git), cluster-internal calls only.
- Do not set `HOMEPAGE_ALLOWED_HOSTS=*`.

### 9.2 Least privilege
- ServiceAccount `homepage` with a ClusterRole of `get` and `list` on namespaces, pods, nodes, ingresses and the metrics API only. No secrets, no ConfigMaps, no write verbs. The token is mounted because `mode: cluster` needs it.
- Pod: `runAsNonRoot`, uid/gid 1000, `allowPrivilegeEscalation: false`, all capabilities dropped, seccomp `RuntimeDefault`. Root filesystem writable `[UNVERIFIED]` (see section 3). No hostPath, no host network, no Docker socket.
- Namespace `homeserver` is `privileged` for other apps; Homepage does not need it.
- No NetworkPolicy exists for `homeserver`; a possible future hardening (allow egress only to the widget targets) is out of scope.

### 9.3 If the operator wants a login later
- Preferred: Homepage's own login (WP9). Option (b) a shared password (no rate limiting `[verified]`; acceptable on a tailnet); option (c) OIDC with Authentik, native in Homepage v2 `[verified https://gethomepage.dev/installation/]`.
- Authentik forward-auth (proxy provider in front of Homepage): **`[UNVERIFIED]` and probably not feasible** with the Tailscale operator Ingress, because the Ingress terminates TLS and forwards straight to the Service; there is no ingress controller with an `auth_request`/forward-auth hook to call the Authentik outpost. Making it work would need an additional reverse proxy (for example Authentik's own proxy outpost placed in front, with the Tailscale Ingress pointing at the outpost). That is a new component and a separate plan; recommend native OIDC instead.
- Tailscale ACLs can also restrict which tailnet devices reach the `homepage` device; that is a Tailscale admin console change by the operator (not in this repo).

## 10. Operations

### 10.1 Upgrade procedure (one PR)
1. Read the release notes for the target version at https://github.com/gethomepage/homepage/releases (look for "Breaking Changes" and for changes to the widgets in use).
2. Resolve the digest of the new tag: `docs/templates/ghcr-app/new-app.sh` only creates new apps, so use the same registry query it uses, by hand (read-only): get a token `curl -fsS "https://ghcr.io/token?scope=repository:gethomepage/homepage:pull" | jq -r .token`, then `curl -fsSI -H "Authorization: Bearer <that token>" -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" https://ghcr.io/v2/gethomepage/homepage/manifests/<new-tag>` and read the `docker-content-digest` header.
3. Edit `talos/manifests/homepage/deployment.yaml`: new digest and new tag comment. Run the guards, open a draft PR "homepage: bump to <tag>".
4. The operator merges and syncs `homepage`. Verify with section 10.2. Rollback: revert the PR and sync.

### 10.2 Health and logs (read-only)
- `kubectl --context admin@<cluster> -n homeserver get pod -l app.kubernetes.io/name=homepage`
- `kubectl --context admin@<cluster> -n homeserver logs deploy/homepage --tail=100` : the Homepage log shows config (YAML) errors, widget errors and host validation errors; **this is the validation tool**.
- Configuration check before merging (no cluster): section WP1 step 10 (`kubectl kustomize` plus the YAML parse).
- `kubectl --context admin@<cluster> -n homeserver top pod -l app.kubernetes.io/name=homepage`
- Health endpoint: `/api/healthcheck` (used by the probes).

### 10.3 Adding a service later (one PR)
1. Confirm the service runs and read its Service name, namespace, port: `kubectl --context admin@<cluster> get svc -A | grep <name>` and its tailnet short name: `kubectl --context admin@<cluster> get ingress -A`.
2. Edit `talos/manifests/homepage/config/services.yaml`: add one tile inside the right existing group (copy the closest tile from WP2 to WP8). Widget URL = `http://<svc>.<ns>.svc.cluster.local:<port>`; link = `https://<short>.{{HOMEPAGE_VAR_TAILNET}}`; credentials = `"{{HOMEPAGE_VAR_<SERVICE>_<FIELD>}}"`.
3. If the widget needs a credential: add an optional `envFrom` block for `homepage-<service>-secrets` in `deployment.yaml`; the operator seals it with `docs/templates/ghcr-app/seal-secret.sh homepage-<service> HOMEPAGE_VAR_<SERVICE>_<FIELD>`.
4. `kubectl kustomize talos/manifests/homepage >/dev/null` ; guards ; draft PR. Because the ConfigMap name has a content hash, the pod restarts by itself when the operator syncs `homepage`.
5. Add a row to section 6.2 of this plan in the same PR (what the credential is, where it is created).

### 10.4 Resource watch
`kubectl --context admin@<cluster> top nodes` (mini01 memory below ~80%); `... top pod -n homeserver`. Raise limits only by PR.

### 10.5 Restarting the pod (env var changes)
Environment variables are read at start. After a Secret changes, the pod must restart: The operator deletes the `homepage` pod in the Argo UI (Deployment recreates it), or changes nothing in git and uses Argo's "Restart" action on the Deployment. (The executor cannot do it.)

### 10.6 Troubleshooting

| Symptom | Where to look | Likely cause | Fix |
|---|---|---|---|
| Browser shows an error mentioning host validation, or the log says "Host validation failed" | `kubectl --context admin@<cluster> -n homeserver logs deploy/homepage --tail=50` | The host in the address bar is not in `HOMEPAGE_ALLOWED_HOSTS` (typo, different device name such as `homepage-1`, or a port needed) | The log prints the host exactly; the operator re-seals `homepage-secrets` with the exact string (comma separated, no spaces). Never use `*`. If the device is `homepage-1`, remove the stale device in Tailscale and recreate the Ingress, or put that name into the allowed hosts instead |
| Pod Running but never Ready; events show probe failures | `kubectl --context admin@<cluster> -n homeserver describe pod -l app.kubernetes.io/name=homepage` | Probe Host header rejected | Use the `tcpSocket` fallback (WP1 step 3 note) |
| Pod in `CreateContainerConfigError` | `describe pod` events: secret `homepage-secrets` not found | The sealed Secret was not synced yet | Wait for `talos-sealed-secrets` Synced; check `kubectl ... describe secret homepage-secrets` |
| Tile links go to `https://jellyfin.{{HOMEPAGE_VAR_TAILNET}}` literally | Browser status bar | `HOMEPAGE_VAR_TAILNET` missing from the Secret or pod not restarted | Check key names with `describe secret`; restart the pod |
| A tile has a red error / "API Error" | Homepage log line naming the service | Wrong URL (service name, namespace or port), service down | `kubectl ... get svc -n <ns>`; fix the `url` in `services.yaml` |
| Widget shows HTTP 401 or 403 | Log line with the status | Wrong or revoked key, a key with too few permissions (Immich needs `server.statistics`; Authentik user needs the two view permissions; Grafana user role) | Recreate the credential in the app, re-seal (section 6.5), restart the pod |
| Widget empty with no error, numbers all zero | Browser | Wrong `version:` (Jellyfin 2, Immich 2, Grafana 2, Authentik 2) | Set the right version per section 3.1 |
| "certificate" / "self signed" / `fetch failed` errors on a widget | Log | A widget `url` uses `https://` (for example the tailnet name or Argo port 443) | Use the in-cluster plain-HTTP Service URL (`http://...svc.cluster.local:<port>`); Argo works over HTTP because `server.insecure` is `true` |
| Argo widget fails while the tile works | Log | No Argo token, token expired, NetworkPolicy of `argocd-server` | Section 6.2 row 4; WP0 step 8 |
| Node widget empty | Log, `kubectl --context admin@<cluster> top nodes` | Metrics API down, or RBAC missing | `get apiservice v1beta1.metrics.k8s.io`; `auth can-i list nodes.metrics.k8s.io --as=system:serviceaccount:homeserver:homepage` |
| Config change not visible | Pod name/age | The Argo app was not synced, or YAML error (page shows an error banner / log shows a parse error) | Sync `homepage`; fix YAML indentation (spaces only; quote values with special characters) |
| Page unreachable from the tailnet | `kubectl --context admin@<cluster> get ingress -n homeserver homepage`, Tailscale admin console | Device not created, `homepage-1` stale-device clash | Remove the stale device; wait for the proxy pod in namespace `tailscale` |
| OOMKilled | `describe pod` | Limit too low | Raise memory limit to 512Mi by PR |

## 11. Acceptance checklist and report format

The operator sees, at the end:
- [ ] `https://homepage.<tailnet-domain>` opens on the phone and the laptop (tailnet connected), and does not open off the tailnet.
- [ ] Groups Media, Photos and Files, Security, Infrastructure (and Finance once Actual Budget exists) are drawn; every tile link opens the right service.
- [ ] Node widget shows mini01 and mini02 CPU and memory.
- [ ] Jellyfin, Immich and AdGuard Home widgets show live numbers.
- [ ] Each later service tile appears with working numbers (arr, qBittorrent, Paperless, Grafana, Authentik).
- [ ] `kubectl --context admin@<cluster> -n homeserver logs deploy/homepage --tail=100` has no errors.
- [ ] `kubectl --context admin@<cluster> auth can-i get secrets --as=system:serviceaccount:homeserver:homepage -A` prints `no`.
- [ ] No clear-text secret and no full tailnet name anywhere in the repo (guards green).
- [ ] All widget credentials are stored in Vaultwarden.
- [ ] `docs/BACKLOG.md` says Done.

Report after each package (copy this block):
```
WP<n>: done | blocked | needs decision
PR: <url>
Guards: 20/20 OK | list of failures
Verified: <commands run and results, no secret values>
Differences from the plan: <or "none">
Needs from the operator: <steps, keys to seal, decisions>
```

## 12. Open questions and UNVERIFIED items

1. Whether the registry tag is exactly `v2.7.0` (resolved by `new-app.sh`).
2. Whether the probe with `Host: localhost:3000` is accepted (fallback: `tcpSocket`).
3. Whether the Next.js image tolerates `readOnlyRootFilesystem: true`.
4. Whether a tile without `href` (the NAS tile) is accepted.
5. Whether Homepage needs the `ingresses` RBAC rule when Ingress discovery is off.
6. Resource sizing (50m/128Mi request, 300m/384Mi limit): confirm with `top pod` after WP1.
7. Immich: whether a key with only `server.statistics` is enough on the installed version.
8. Paperless token UI path; Grafana minimum role for the widget; qBittorrent host header behaviour.
9. Where this repo configures Argo CD (for the read-only `readonly` account, D4).
10. Authentik forward-auth with the Tailscale Ingress: believed infeasible; native OIDC recommended.
11. Interfaces assumed from sibling plans: Services `sonarr`, `radarr`, `prowlarr`, `bazarr`, `qbittorrent` (namespace `arr`; ports 8989, 7878, 9696, 6767, 8080), `paperless` (namespace `paperless`, port 8000), `grafana` (namespace `monitoring`, port 80), `authentik-server` (namespace `authentik`, port 80), `actual-budget` (namespace `homeserver`, port 5006), and tailnet short names equal to the app names.
12. Whether the AdGuard username is `admin` or another name: The operator knows; the executor never reads it.
