# Plan: Authentik (single sign-on) for the homelab

Audience: a local language model working on this repository for the operator. Follow it literally, one work
package (WP) at a time. Where it says STOP, stop and report to the operator; do not decide for him.

Written 2026-10-25. Research done the same day against the official documentation (links in the text,
marked `[verified <url>]`). Anything not confirmed is marked `[UNVERIFIED]` with the way to confirm it.
The service list lives in `docs/BACKLOG.md` (Authentik: Planned).

## 0. Purpose, scope, non-goals, definition of done

**Purpose.** Run Authentik, a self-hosted identity provider, on the Talos cluster so that the operator can log in
to several homelab apps with one account (OpenID Connect, "OIDC"), with the Authentik login protected
by a strong password and a second factor.

**In scope.**

- Namespace `authentik`; a CloudNativePG (CNPG) PostgreSQL cluster `authentik-pg` with backups to MinIO;
  the official Helm chart (server + worker); a tailnet-only Ingress; sealed secrets.
- The first administrator (`akadmin`), a daily-use admin user, a break-glass path, recovery commands.
- Integrations, each as its own separate package: Immich, Jellyfin, Paperless-ngx, Grafana, Actual Budget,
  Argo CD, Vaultwarden (assessed, recommended NOT to enable), and apps without OIDC (proxy outpost).
- Optional: declaring the Authentik configuration as blueprints (files in git, sealed because they carry
  host names).
- A restore drill for the database.

**Non-goals.**

- No public internet exposure (tailnet only, like every other app).
- No email/SMTP setup, no LDAP outpost, no Authentik "social login" with Google/GitHub.
- No migration of existing local accounts away; local logins stay until the operator removes them himself.
- No change to any live cluster object by the executor (see rules).
- Not touching Homepage (it has no login).

**Definition of done** (every box must be ticked by evidence, not by assumption):

- [ ] WP1 audit report delivered and the operator answered the blocking decisions (section 5).
- [ ] Namespace `authentik` exists with the Pod Security labels from this plan.
- [ ] Sealed secrets `authentik-secrets` and `authentik-pg-s3` exist in `talos/sealed-secrets/` and are
      listed in its `kustomization.yaml`.
- [ ] App `authentik-infra` synced: `authentik-pg` is healthy, a base backup exists in MinIO.
- [ ] App `authentik` synced: `authentik-server` and `authentik-worker` are Running and Ready.
- [ ] the operator logs in at `https://authentik.<tailnet>.ts.net/` as `akadmin`, created his daily user, enrolled
      a second factor, and tested the break-glass procedure.
- [ ] At least one app (Immich first) signs in through Authentik AND its local login still works.
- [ ] A database restore drill succeeded (section 8).
- [ ] `docs/BACKLOG.md` marks Authentik "Partway"/"Done" in the PR that finishes it.

## 1. Rules for the executor

1. You change files in the repository and open pull requests. **Nothing else.** the operator merges PRs and syncs
   Argo apps himself in the Argo web UI. Never change the live cluster.
2. Allowed cluster access is **read-only**: `get`, `describe`, `logs`, `top`, and `exec ... -- <read-only
   command>`. Always pass `--context admin@<cluster>`. Forbidden: `apply`, `create`, `delete`, `patch`,
   `edit`, `scale`, `rollout`, `replace`, `label`, `annotate`, `drain`, `cordon`, `taint`, `talosctl`
   changes, `argocd app sync`, and any `kubectl exec` that changes state (for example `ak changepassword`,
   `ak create_recovery_key`, `ak shell` writes). Those are in operator-only lists below.
3. **Never print or decode secret values.** No `get secret -o yaml/json/jsonpath`. `describe secret` is fine
   (it shows key names only). If any command prints a secret, stop and tell the operator.
4. **No host details in committed files**: no IPv4 addresses, MAC addresses, disk serials,
   `/dev/disk/by-id` names, and no host name ending in `.ts.net`. Use placeholders (`<tailnet>`,
   `<node-ip>`). Settings that need the full tailnet host name (Authentik URL, OIDC redirect URIs) are
   delivered only through **sealed Secret keys** (section 6) or typed by the operator in a web UI.
5. One concern per PR. Branch from current `origin/main`:
   `git fetch origin && git switch -c <branch> origin/main`. PRs are **drafts**. Never push to `main`,
   never force-push, never merge, never delete a branch.
6. Before every commit run `bash .github/scripts/run-all-guards.sh`; all 20 lines must say `OK`. Never edit a
   guard to make it pass. If one fails, fix your file or stop and report.
7. After adding or changing `talos/apps-src/*.yaml` run `talos/render-apps.sh --force` and commit both the
   source and the generated `talos/apps/<app>.yaml`. Every Application also needs a line in
   `talos/test/empty-cluster-expectations.txt`.
8. Commit messages end with the line `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. PR
   descriptions end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
9. Every PVC and CNPG storage block must set `storageClassName`/`storageClass: topolvm-fast` (the cluster has
   exactly one class and it is not the default). Every container must set explicit `resources`.
10. Images are pinned by tag AND digest, never `latest`. How to get a digest: section 7, WP4 step 1.
11. **STOP conditions**: a command output differs from the expected one in a way this plan does not cover; a
    guard fails twice; a decision in section 5 that the package depends on is unanswered; you are about
    to type a secret, a full tailnet name or an IP address into a file; the cluster state contradicts a
    precondition.
12. **Never decide a the operator decision** (section 5). Use the recommended default only if the plan says "default
    if the operator does not answer"; otherwise ask.
13. The lock-out rule (applies to every integration package): SSO is enabled for **one app at a time**; the
    app's local login stays enabled; the operator verifies SSO in a private browser window while an existing
    session is still open; only after ALL planned apps work does the operator (not the executor) decide to remove a
    local login, and the break-glass admin is never removed.
14. Report after each package in the format of section 11.

## 2. Prerequisites and dependencies

Run each command (read-only); if the result differs, do what the last column says.

| # | Needs | Proof command | Expected | If not |
|---|---|---|---|---|
| P1 | CNPG operator running | `kubectl --context admin@<cluster> -n cnpg-system get deploy` | one deployment `cnpg-controller-manager` with READY `1/1` | STOP; the app `cnpg-operator` must be synced by the operator first |
| P2 | CNPG CRDs | `kubectl --context admin@<cluster> get crd clusters.postgresql.cnpg.io scheduledbackups.postgresql.cnpg.io` | both listed | same as P1 |
| P3 | Tailscale operator | `kubectl --context admin@<cluster> -n tailscale get deploy operator` | `1/1` | STOP; Ingress would not work |
| P4 | StorageClass | `kubectl --context admin@<cluster> get sc` | exactly `topolvm-fast` | STOP, report the list |
| P5 | Sealed secrets controller + the committed certificate | `ls argocd/sealed-secrets/pub-cert.pem` and `kubectl --context admin@<cluster> -n kube-system get pods \| grep -i sealed` | file exists, controller Running | STOP |
| P6 | MinIO (Velero backup target) reachable in cluster | `kubectl --context admin@<cluster> -n velero get deploy minio` and `kubectl --context admin@<cluster> -n velero get svc velero-backup-target` | Deployment `1/1` (runs on mini02), Service exists, port 9000 | STOP; backups cannot be set up |
| P7 | PriorityClass `hs-interactive` | `kubectl --context admin@<cluster> get pc hs-interactive` | exists (value 500) | omit `priorityClassName` and report |
| P8 | Node capacity | `kubectl --context admin@<cluster> top nodes` | see section 4 | if mini01 memory is above 75 percent, STOP and ask the operator (decision D2) |
| P9 | Tools on the executor's machine | `helm version`, `yq --version`, `kubeseal --version`, `jq --version` | all present | report which is missing (`crane`/`skopeo` are NOT installed on the machine where this plan was written; use the curl recipe in WP4) |
| P10 | MinIO bucket `authentik-pg` and a scoped user | The operator step (WP2); the executor cannot check bucket contents read-only | The operator confirms | STOP at WP3 until the operator confirms |

**What depends on Authentik** (do not start these before WP6 is accepted): the integration packages
WP8 to WP14. `[ASSUMED]` interfaces of sibling plans, to be checked when those plans land:

- Paperless plan: namespace `paperless`, Deployment/Service `paperless`, port 8000, configured through
  environment variables from a Secret I call `paperless-secrets` `[ASSUMED]`.
- Monitoring plan: namespace `monitoring`, Grafana Service `grafana` port 80 (kube-prometheus-stack style)
  `[ASSUMED]`; Grafana receives its settings from the chart's `grafana.ini` plus a secret for the client secret.
- Actual Budget plan: namespace `homeserver`, Service `actual-budget` port 5006 `[ASSUMED]`.
- Homepage: nothing to integrate.

## 3. Facts about this service

### 3.1 Image, chart, versions

- Image: `ghcr.io/goauthentik/server` (the chart default `global.image.repository`; the same image runs
  server and worker with different arguments). `[verified https://raw.githubusercontent.com/goauthentik/helm/main/charts/authentik/values.yaml]`
- Newest stable release on 2026-10-25: **2026.8.5** (published 2026-10-21); also maintained: 2026.5.8
  (published 2026-10-21). `[verified https://api.github.com/repos/goauthentik/authentik/releases]`
  Contradiction to flag: the documentation site labels 2026.8 "pre-release" while GitHub marks the
  2026.8.x releases as normal releases. Decision D1 (section 5).
- Helm chart: repository `https://charts.goauthentik.io`, chart `authentik`, chart version equals app
  version: `version: 2026.8.5`, `appVersion: 2026.8.5`. Its dependencies are the Bitnami `postgresql`
  subchart (disabled by default, NOT used here) and `authentik-remote-cluster` (creates the ServiceAccount
  and RBAC). `[verified https://raw.githubusercontent.com/goauthentik/helm/main/charts/authentik/Chart.yaml]`
- Checked by rendering the chart locally (`helm template`, chart 2026.8.5, values in WP4): Service
  `authentik-server` listens on port 80 (to container port 9000, name `http`) and 443 (to 9443);
  Deployments are `authentik-server` (container `server`) and `authentik-worker` (container `worker`);
  `authentik.existingSecret.secretName` is injected into BOTH as `envFrom: secretRef`; probes use
  `/-/health/live/` and `/-/health/ready/` on port `http`; metrics port 9300; the ClusterRole created by the
  chart only allows `list` on CustomResourceDefinitions, plus a namespaced Role for managed outposts.
  The executor repeats this render in WP4 (step 2) and STOPs on any difference.
- The documented install is the Helm chart; the bundled PostgreSQL is only for demo, production should use
  an external database such as CloudNativePG. `[verified https://docs.goauthentik.io/install-config/install/kubernetes/]`
- The chart creates no file storage by default (`global.volumes`/`volumeMounts`, or S3). Not needed here:
  only uploaded icons/backgrounds would need it. `[verified same page]`

### 3.2 Redis: NOT needed

Since release 2025.10 Authentik does not use Redis at all (caching, tasks, embedded outpost sessions and
WebSockets moved to PostgreSQL). Redis settings were removed and can be deleted. **Verified.**
`[verified https://docs.goauthentik.io/releases/2025.10/]` and `[verified https://goauthentik.io/blog/2025-11-13-we-removed-redis/]`.
The chart values contain no Redis keys `[verified values.yaml above]`. Consequences: no Redis pod, but
about 50 percent more PostgreSQL connections than before (so `max_connections` is raised in WP3), and when
PostgreSQL requires TLS, Authentik needs TLS 1.3 or the Extended Master Secret extension.

### 3.3 Configuration (environment variables)

All names `[verified https://docs.goauthentik.io/install-config/configuration/]`:

| Variable | Meaning | Where we set it |
|---|---|---|
| `AUTHENTIK_SECRET_KEY` | cookie signing and secret encryption key; "Changing this will invalidate active sessions" | sealed Secret `authentik-secrets` |
| `AUTHENTIK_POSTGRESQL__HOST`, `__PORT`, `__USER`, `__PASSWORD`, `__NAME` | database connection; HOST/PORT/USER/PASSWORD hot-reload | chart values (`authentik.postgresql.*`), password from the CNPG-generated Secret |
| `AUTHENTIK_POSTGRESQL__SSLMODE` | TLS use; documented default `verify-ca` | values `global.env` = `require` (CNPG's server certificate is signed by the CNPG CA, which Authentik does not have) `[UNVERIFIED that require connects; confirm in WP1/WP5 from the worker log]` |
| `AUTHENTIK_BOOTSTRAP_PASSWORD` | initial `akadmin` password; "Only read on the first startup"; stored in plain text, so the docs recommend `AUTHENTIK_BOOTSTRAP_PASSWORD_HASH`; setting both is an error | sealed Secret |
| `AUTHENTIK_BOOTSTRAP_TOKEN` | creates an API token (the value is the token key) for `akadmin`; "Only read on the first startup" | sealed Secret, OPTIONAL (default: do not set) |
| `AUTHENTIK_BOOTSTRAP_EMAIL` | email address of `akadmin`; the page states no first-start restriction for this one | sealed Secret |
| `AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS` | CIDRs from which `X-Forwarded-*` headers are trusted | sealed Secret key, only if WP5 shows it is needed (CIDRs are address literals; guard) |
| `AUTHENTIK_WEB__BASE_URL` | base URL; a bootstrap value copied into the Base URL system setting on first start | OPTIONAL sealed key; do not set unless a link in the UI shows the wrong host |

The three `BOOTSTRAP` variables are documented as being set on the worker container and cannot use the
`file://` syntax. `[verified https://docs.goauthentik.io/install-config/automated-install/]`. The chart
puts the same Secret into server and worker, which is harmless.

`AUTHENTIK_SECRET_KEY` note: for versions before 2023.6.0 the docs say it must NOT be changed after the
first install; for current versions changing it invalidates sessions. Treat it as never-rotate regardless:
see section 6 for what else may depend on it `[UNVERIFIED for encrypted fields such as stored provider
secrets and MFA devices: confirm on https://docs.goauthentik.io/ (search "secret key") before any rotation]`.

### 3.4 Ports, health, data

- Ports: 9000 (HTTP), 9443 (HTTPS, self-signed), 9300 (metrics). Health: `/-/health/live/` and
  `/-/health/ready/`; the worker probes use `ak healthcheck` (exec). `[verified values.yaml / render]`
- Data: everything is in PostgreSQL. Nothing needs a volume. Blueprints are mounted read-only from
  ConfigMaps/Secrets (WP15).
- Setup URL: the initial setup page is `/if/flow/initial-setup/` (the trailing slash is required, a missing
  slash gives "Not Found"). It exists only until the `akadmin` password is set. This is confirmed by
  community guides only, not by the official page I could read `[UNVERIFIED on the official docs; the
  executor does NOT test it, the operator sees it or not in WP6]`.
- Sizing: the Authentik documentation states hardware minimums for Docker Compose installs; I could not
  open that exact page `[UNVERIFIED: check https://docs.goauthentik.io/install-config/ "Requirements"]`. The
  numbers in section 4 are conservative homelab values to be adjusted by measuring (section 10).

### 3.5 Upgrade/migration notes

- Always upgrade one release at a time within the supported pair of releases, read the release notes
  `https://docs.goauthentik.io/releases/` first. 2025.10 breaking changes: Redis removed (extra DB
  connections), TLS 1.3/EMS needed for TLS PostgreSQL. `[verified https://docs.goauthentik.io/releases/2025.10/]`
- Migrations run automatically when the server starts; take a CNPG backup before every upgrade (section 10).

### 3.6 Recovery commands (verified)

`[verified https://docs.goauthentik.io/troubleshooting/login/]`

- Recovery link (valid N minutes, grants direct login as the user, treat the link as a password):
  `kubectl --context admin@<cluster> -n authentik exec -it deployment/authentik-worker -c worker -- ak create_recovery_key 10 akadmin`
- Reset password: `kubectl --context admin@<cluster> -n authentik exec -it deployment/authentik-server -c server -- ak changepassword akadmin`
- The page shows the login URL form `https://<authentik-host>/if/flow/default-authentication-flow/?next=%2F`.
  The recovery key command prints a link; its URL shape is not documented `[UNVERIFIED]`, use what it prints.
- Both commands are operator-only (they change state).

### 3.7 Blueprints (verified)

`[verified https://docs.goauthentik.io/customize/blueprints/ and .../blueprints/v1/structure/ and .../blueprints/export/]`

- YAML file: `version: 1`, optional `metadata` (`name` required when `metadata` present, `labels`), optional
  `context`, required `entries`. Each entry: `model` (`app.model`), `state` (`present` default, `created`,
  `must_created`, `absent`), `identifiers`, `id` (for `!KeyOf`), `attrs`, optional `conditions`, `permissions`.
  Tags documented: `!Find`, `!KeyOf`, `!Condition`, `!Context`.
- The container scans `/blueprints`; new files are discovered, changed files re-applied, and a periodic scan
  runs every 60 minutes by default.
- Helm chart: `blueprints.configMaps: []` and `blueprints.secrets: []`, "Only keys ... ending with
  `.yaml` will be discovered". A ConfigMap named `X` is mounted on the worker at
  `/blueprints/mounted/cm-X` (seen in the local render). The mount path for `secrets` is presumably
  `/blueprints/mounted/secret-X` `[UNVERIFIED: the executor renders it in WP15]`.
- Export: `ak export_blueprint` inside a worker container prints a blueprint of most objects. Write-only
  fields (an OAuth2 provider's client secret) are NOT exported; some objects are skipped for dependencies.

## 4. Architecture and placement

```
 tailnet device (browser, phone)
        |  HTTPS (valid Let's Encrypt cert, issued by the Tailscale operator's proxy)
        v
 [Tailscale ingress proxy pod, ns tailscale, device "authentik"]
        |  HTTP
        v
 Service authentik-server :80  ---> pod authentik-server (9000)  ----+
                                    pod authentik-worker (9000/9300) -+--> Service authentik-pg-rw :5432
                                                                          pod authentik-pg-1 (CNPG, PVC topolvm-fast)
                                                                              |  WAL + base backups (S3)
                                                                              v
                                          Service velero-backup-target.velero :9000 (MinIO on mini02), bucket authentik-pg
 All of the above except MinIO: namespace authentik, node mini01 (default D2).
```

- **Namespace**: `authentik` (fixed by the brief). Pod Security: `restricted` (enforce/audit/warn), like
  `adguard`. CNPG pods and the Authentik images (non-root) are expected to fit; the chart sets no
  security context by default, so WP4 sets one. If the sync reports a Pod Security violation, STOP and
  ask the operator whether to relax to `baseline` (decision D13); never relax on your own.
- **Node**: mini01 by default (D2). Real usage read on 2026-10-25 with `kubectl top nodes`:
  mini01 `740m` CPU (18 percent), `5077Mi` memory (45 percent); mini02 `125m` CPU (3 percent), `1193Mi`
  (16 percent). `kubectl describe node mini01` shows requests CPU 2263m (57 percent) and memory 5285Mi
  (47 percent), limits well above 100 percent (overcommitted by design). mini01 has 4 cores and 12 GiB.
  mini02 (7.6 GiB, cordoned, runs MinIO and Samba) has more headroom but pods there must tolerate the
  cordon, and a login service that sits on the same node as its own backup target gains nothing;
  mini03 does not exist yet.
- **Requests/limits** (all containers; the `authentik` namespace has no LimitRange, so they must be explicit):

| Container | CPU request | CPU limit | Memory request | Memory limit | Reasoning |
|---|---|---|---|---|---|
| server | 200m | 1 | 512Mi | 1Gi | Python/Go app, bursts at login; idle uses a few hundred MiB `[UNVERIFIED, measure]` |
| worker | 100m | 1 | 384Mi | 1Gi | background tasks, blueprint apply |
| authentik-pg-1 | 100m | 1 | 256Mi | 768Mi | tiny database (users, flows, events) |
| Total requests | 400m | | 1152Mi | | adds about 10 percent of mini01's CPU and 10 percent of its memory |

  After this plan, mini01 requests would be roughly 2.7 CPU (67 percent) and 6.4 GiB memory (57 percent).
  Acceptable. If the worker or server gets OOM-killed, raise the limit by 50 percent and report.
- **Storage**: only the CNPG volume: 5Gi on `topolvm-fast` (node-local, reclaim Retain). There is nothing
  else to store. Velero does not cover namespace `authentik` and does not need to (the database has its own
  backup; the CNPG volume is excluded from Velero by design in this repo's backup docs).
- **Deployment style**: Argo apps, manual sync. Two apps because Helm cannot hold the CNPG objects:
  `authentik-infra` (plain manifests: Cluster, ScheduledBackup, Ingress) and `authentik` (the chart).
  The CNPG operand image is `ghcr.io/cloudnative-pg/postgresql` major 17 (immich uses PostgreSQL 17 too).
  `[UNVERIFIED that Authentik 2026.8 supports PostgreSQL 17; the chart's bundled subchart pins 17.11 so it
  does]`.

## 5. Decisions for the operator

| Id | Question | Options and trade-offs | Recommended default | If decided otherwise |
|---|---|---|---|---|
| D1 | Which Authentik release? | (a) 2026.8.5, newest, docs call the 2026.8 line "pre-release"; (b) 2026.5.8, older line, still receiving fixes | (a) 2026.8.5 if the docs' "pre-release" label is gone when WP1 re-checks; otherwise (b) | change `targetRevision`, `global.image.tag` and digest; chart version equals app version |
| D2 | Which node? | mini01 (busy but has room, all apps there); mini02 (more room, cordoned, same node as MinIO); mini03 (not built) | mini01 | for mini02 add the cordon toleration to values and the CNPG `affinity`; STOP and re-plan storage |
| D3 | How is the first admin created? | (a) `AUTHENTIK_BOOTSTRAP_PASSWORD` (or the `_HASH` form) in the sealed Secret: no open window, password known to the operator; (b) leave it unset and open `/if/flow/initial-setup/` after the first start: first visitor on the tailnet sets the `akadmin` password, a race window | (a) with the plain `BOOTSTRAP_PASSWORD` (simpler; `_HASH` is better but needs a hash tool, see section 6) | for (b) drop the bootstrap keys; WP6 changes to the setup-page procedure and the operator must open the page immediately after the first start |
| D4 | Set `AUTHENTIK_BOOTSTRAP_TOKEN`? | creates a long-lived API token for `akadmin`; useful only for automation | do NOT set | if set, the operator deletes the token in the UI after use |
| D5 | **Network path for the back channel (blocking for WP8 to WP13)**: pods cannot resolve the tailnet name (observed 2026-10-25: DNS lookup of an existing tailnet Ingress name from the `immich-server` pod fails with `ENOTFOUND`; CoreDNS forwards to the node's resolver). OIDC clients call Authentik server-to-server (discovery, token, userinfo) | (N1) add a CoreDNS stanza forwarding the `ts.net` zone to the Tailscale MagicDNS resolver (change to the CoreDNS ConfigMap; on Talos the ConfigMap may be owned by the machine config `[UNVERIFIED]`); (N2) set the Talos nodes' nameservers to the MagicDNS resolver plus a public fallback (machine-config change, the operator runs it); (N3) per-pod `hostAliases` (chart value `global.hostAliases`, per-app equivalents) mapping the Authentik name to a tailnet address: cannot be committed (host name), so not recommended; (N4) clients whose settings allow separate endpoints (Grafana: `auth_url` browser, `token_url`/`api_url` server) use the in-cluster Service for the server-side calls | decide after the WP5 spike; leaning N2 (one place, works for every app); N4 for Grafana regardless | with no answer, STOP before any integration package; only WP2 to WP7 can proceed |
| D6 | Admin users | (a) `akadmin` is the daily user; (b) `akadmin` stays as break-glass (long password in Vaultwarden, no MFA needed but used only in emergencies) and the operator works as a second user `<operator>` with MFA | (b) | for (a) the break-glass is only the `ak` command path (still always available to the operator through kubectl) |
| D7 | Configure through the UI or blueprints in git? | UI: fast, state lives only in the database (backed up by CNPG); blueprints: reproducible but must be sealed (they contain host names), more work | UI first (WP6 to WP14); blueprints as an optional later package WP15 | skip WP15 |
| D8 | MinIO bucket and scoped user for the database backups | needs a new bucket `authentik-pg` and a user with the policy template `talos/dr/minio/policy.json.tmpl`; a the operator step | yes, same pattern as `immich-pg` | without it no backups: do not deploy `authentik-pg` (STOP at WP3) |
| D9 | Which apps get SSO and in which order | Immich, Paperless, Grafana, Actual Budget, Jellyfin (plugin, archived), Argo CD (not managed by Argo; changes via Helm), Vaultwarden (no) | Immich, Paperless, Grafana, Actual Budget; Jellyfin only if the operator accepts an archived plugin; Argo CD last or never; Vaultwarden never | the packages for skipped apps are simply not executed |
| D10 | Apps without OIDC: use a proxy outpost? | none planned today; WP14 describes the method | do not build until an app needs it | n/a |
| D11 | Argo CD SSO | Argo CD is installed by `talos/install-argocd.sh` (Helm, `dex.enabled=false`), NOT managed by itself; SSO would be a `helm upgrade` by the operator with values kept outside git; a mistake can lock the operator out of the deployment tool | skip for now | n/a |
| D12 | Pod Security level for namespace `authentik` | `restricted` (recommended) or `baseline` | `restricted` | change the label in the namespace entry |

## 6. Credentials and secret handling

How the operator seals (summary of the existing method; full text in `docs/dr/talos-backups.md`,
"Sealing the credentials"): offline, with `kubeseal --cert argocd/sealed-secrets/pub-cert.pem`; plaintext
only in memory or in a temporary file outside the repository that is deleted afterwards. The helper
`docs/templates/ghcr-app/seal-secret.sh <app> KEY...` creates `<app>-secrets` in namespace **homeserver**,
so it is NOT used as is for namespace `authentik`; use the explicit recipe below.

### 6.1 Inventory

| # | Credential | What it is | Created by / how | Secret (namespace) and key | Sealed file | How the app receives it |
|---|---|---|---|---|---|---|
| C1 | Secret key | signing/encryption key | The operator: `openssl rand -base64 60 \| tr -d '\n' \| pbcopy` (nothing printed) | `authentik-secrets` (authentik), key `AUTHENTIK_SECRET_KEY` | `talos/sealed-secrets/authentik-secrets.yaml` | `envFrom` via chart `authentik.existingSecret.secretName` |
| C2 | Database password | owner `authentik` of database `authentik` | generated by the CNPG operator, not by anyone (Secret `authentik-pg-app`, keys `username`, `password`, created by the operator `[UNVERIFIED name: CNPG names it <cluster>-app; confirm with describe in WP1/WP3]`) | `authentik-pg-app` (authentik) | none (never in git) | values `global.env` entry `AUTHENTIK_POSTGRESQL__PASSWORD` with `valueFrom.secretKeyRef` |
| C3 | Bootstrap admin password | initial `akadmin` password | The operator: `openssl rand -base64 24 \| tr -d '\n' \| pbcopy`, store in the password manager | `authentik-secrets`, key `AUTHENTIK_BOOTSTRAP_PASSWORD` | same file as C1 | `envFrom`; read only at the first start |
| C4 | Bootstrap email | login email of `akadmin` | The operator types it | `authentik-secrets`, key `AUTHENTIK_BOOTSTRAP_EMAIL` | same file | `envFrom` |
| C5 | Bootstrap token | API token for `akadmin` | NOT created (D4) | (`AUTHENTIK_BOOTSTRAP_TOKEN` if ever) | | |
| C6 | MinIO access pair for the database backup | S3 credentials of the scoped MinIO user for bucket `authentik-pg` | The operator via the MinIO admin steps (WP2) | `authentik-pg-s3` (authentik), keys `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY` | `talos/sealed-secrets/authentik-pg-s3.yaml` | CNPG `barmanObjectStore.s3Credentials` |
| C7 | OIDC client secrets (one per integration) | generated by Authentik when the operator creates the provider | Authentik UI | the client's own config: Immich stores it in its UI settings (database); Paperless in a sealed key; Grafana and Actual in a sealed key | per integration package | per package |
| C8 | Trusted proxy CIDRs (only if WP5 needs it) | not secret, but an address literal the guard rejects | The operator types it | `authentik-secrets`, key `AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS` | same file | `envFrom` |
| C9 | Break-glass admin | second local superuser | The operator in the UI (WP6) | none in the cluster; password only in the password manager | | |
| C10 | The Authentik URL and the OIDC issuer/redirect URIs | contain the full tailnet host name | typed in web UIs, or inside sealed keys | see integration packages | | |

### 6.2 Sealing recipe for `authentik-secrets` (The operator runs it; the executor writes the instruction only)

Run from the repository root in the PR branch of WP2. Values are typed with hidden input; the Secret object
exists only in the pipe.

```bash
read -rs SECRET_KEY;  echo     # paste the generated key (C1)
read -rs BOOT_PASS;   echo     # paste the generated password (C3)
read -r  BOOT_EMAIL            # your email
kubectl create secret generic authentik-secrets -n authentik \
  --from-literal=AUTHENTIK_SECRET_KEY="$SECRET_KEY" \
  --from-literal=AUTHENTIK_BOOTSTRAP_PASSWORD="$BOOT_PASS" \
  --from-literal=AUTHENTIK_BOOTSTRAP_EMAIL="$BOOT_EMAIL" \
  --dry-run=client -o json |
  KUBECONFIG=/dev/null kubeseal --cert argocd/sealed-secrets/pub-cert.pem --format yaml \
  > talos/sealed-secrets/authentik-secrets.yaml
unset SECRET_KEY BOOT_PASS BOOT_EMAIL
```

(`kubectl create ... --dry-run=client` does not contact the cluster; the same pattern is documented in
`docs/dr/talos-backups.md`.) The password-manager entries are made at generation time (`pbcopy`, paste into
the manager) BEFORE sealing, because nothing prints the values afterwards.

`authentik-pg-s3` is sealed the same way, with keys `ACCESS_KEY_ID` and `ACCESS_SECRET_KEY`, namespace
`authentik`, output `talos/sealed-secrets/authentik-pg-s3.yaml`. Then add both files to `resources:` in
`talos/sealed-secrets/kustomization.yaml` (and a comment line per file in its header, as the others have).

Sealed secrets are namespace- and name-bound: a sealed file for `authentik/authentik-secrets` decrypts only
under exactly that namespace and name.

### 6.3 Password discovery (where the first-login credential appears)

- With D3(a): the login is user `akadmin` with the password the operator generated (C3). It is in his password manager.
  Retrieval later (clipboard only, never on screen):
  `kubectl --context admin@<cluster> -n authentik get secret authentik-secrets -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_PASSWORD}' | base64 -d | pbcopy`
  Caveat: this Secret keeps the ORIGINAL bootstrap password forever. Once the operator changes the password in the UI
  the stored value is stale and harmless, but note it in the password manager ("original, changed").
- With D3(b): there is no password. The first visitor of `https://authentik.<tailnet>.ts.net/if/flow/initial-setup/`
  sets it. Risk window: from the first start of the server until the operator completes the page, any device on the
  tailnet that opens that URL can claim the administrator account. Mitigation: The operator opens the page right
  after the sync and does it immediately; if the page shows "Not Found" the account already exists or the
  default flows failed (check the worker log).
- Authentik never writes the password to a log.
- Whether the bootstrap variables apply only on the first start: password and token yes `[verified
  automated-install page]`; email: the page does not say, treat it as first start only.

### 6.4 What breaks if lost, and rotation

| Credential | If lost | Rotation |
|---|---|---|
| `AUTHENTIK_SECRET_KEY` | Authentik cannot start with a different key and decrypt stored data; with a NEW key all sessions are invalid for sure, and fields Authentik encrypted with the key (for example stored provider/outpost secrets, MFA secrets) may be unreadable `[UNVERIFIED which fields; confirm in the docs before ever rotating]` | do not rotate casually. If you must: take a CNPG backup, export blueprints, rotate in the sealed Secret, restart both Deployments, then test every integration and every MFA device. The key is kept in the password manager AND in the sealed file; losing both is a rebuild of Authentik from blueprints |
| DB password | pods fail to connect | it lives in the CNPG-managed Secret; rotate by annotating/recreating through the operator (operator-only), then restart the Deployments |
| Bootstrap password | no effect after the first start | n/a |
| `akadmin` password | recovery below | UI: User settings, change password |
| MinIO pair | database backups stop (the database keeps working); CNPG reports the failed archive | new user in MinIO, re-seal `authentik-pg-s3` |

### 6.5 Lost admin password: recovery procedure (operator-only)

1. Open a terminal with kubectl access.
2. Preferred: recovery link. `kubectl --context admin@<cluster> -n authentik exec -it deployment/authentik-worker -c worker -- ak create_recovery_key 10 akadmin`
   Open the printed link in a browser within 10 minutes (the link is as powerful as the password; do not
   paste it in chat). Then set a new password in User settings.
3. If the link does not work: `kubectl --context admin@<cluster> -n authentik exec -it deployment/authentik-server -c server -- ak changepassword akadmin`
   and type the new password. Log in at `/if/flow/default-authentication-flow/?next=%2F`.
4. Store the new password in the password manager.
5. If the pod does not start at all: logs `kubectl --context admin@<cluster> -n authentik logs deploy/authentik-server`.

### 6.6 Break-glass admin kept out of SSO

- Break-glass account = `akadmin` (D6b), a LOCAL Authentik account. It is never used to sign in to other
  apps through SSO. Apps keep their own local admin accounts (Immich admin, Paperless superuser, Grafana
  `admin`, Actual password login, Argo CD `admin`), which are the break-glass for each app.
- Authentik itself is not behind SSO (it is the provider), so a broken integration never locks the
  Authentik admin out.
- Ultimate break-glass: `kubectl exec` with the `ak` commands above. It needs only cluster access, which does not depend
  on Authentik. Argo CD, Kubernetes and Talos are never tied to Authentik in this plan (D11).

## 7. Work packages

Package order: WP1 audit; WP2 namespace + secrets + MinIO (the operator); WP3 database; WP4 Authentik app;
WP5 network path spike; WP6 first login and admins (the operator); WP7 hardening + external URL checks; WP8 to
WP14 integrations; WP15 blueprints (optional); WP16 restore drill and docs.

Commands below use `C=admin@<cluster>` shorthand only in prose; type the full `--context admin@<cluster>`.

---

### WP1: read-only audit (no PR)

**Goal.** Prove the prerequisites, re-check the version facts, and produce a report. No file is created.

Steps.

1. Run P1 to P9 of section 2. Record each output line.
2. Re-check the version: open `https://api.github.com/repos/goauthentik/helm/releases?per_page=3` (or `helm search repo`
   after `helm repo add authentik https://charts.goauthentik.io`) and
   `https://docs.goauthentik.io/releases/`. Write down the newest stable chart version and whether the
   docs still call 2026.8 "pre-release". This answers D1.
3. Read `docs/dr/minio-standalone.md` (marked SUPERSEDED), `talos/dr/minio/setup-users.sh` and `talos/dr/minio/policy.json.tmpl`; the
   MinIO now runs in cluster (`talos/manifests/backup-target`, Deployment `minio` in `velero`). Write down
   how a NEW bucket and user are created today (the script was written for the old victus MinIO and may
   not apply). If it cannot be done with the script as is, put that in the report; WP2 then gives the operator
   the generic `mc` steps.
4. Check CNPG details: `kubectl --context admin@<cluster> -n homeserver get cluster immich-pg -o jsonpath='{.status.image}'` prints the operand image of Immich;
   `kubectl --context admin@<cluster> -n homeserver describe secret immich-pg-app` (key names only) to confirm the
   generated Secret naming `<cluster>-app` with keys such as `username`, `password`. Use `describe` only.
5. Confirm the DNS problem: `kubectl --context admin@<cluster> -n homeserver exec deploy/immich-server -- getent hosts argocd.<tailnet>.ts.net`
   is not required (needs the real name); instead report "pods cannot resolve tailnet names" only if the operator
   gives you a name; otherwise copy the finding from section 5/D5 as `[ASSUMED, observed 2026-10-25]`.
6. List the Tailscale operator image: `kubectl --context admin@<cluster> -n tailscale get deploy operator -o jsonpath='{.spec.template.spec.containers[0].image}'`
   (on 2026-10-25: `tailscale/k8s-operator:v1.102.3`). Write it down for D5.
7. Check the apps this plan integrates actually exist at the time you run: `kubectl --context admin@<cluster> get ns`.
8. Find the digest recipe works (read-only registry query, no login): see WP4 step 1.

Expected: all prerequisites OK except P10 (the operator) and any sibling services not yet deployed.

Rollback: none. STOP point: deliver the report in the section 11 format and wait for answers to D1, D2, D3, D5, D8, D12.

---

### WP2: namespace, sealed secrets, MinIO bucket (PR + the operator steps)

**Goal.** Create the namespace and the two sealed secrets. Branch `feat/authentik-namespace-secrets`.

Preconditions: WP1 report accepted; D3, D8, D12 answered.

Steps.

1. **Namespace.** Edit `talos/manifests/namespaces/namespaces.yaml`: append this document after the last one.
   WHY: that app auto-syncs and owns the labelled namespaces.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: authentik
  labels:
    pod-security.kubernetes.io/enforce: restricted # D12; Authentik and CNPG run non-root, no host paths
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

   (The file's header comment says the namespaces there are those needing explicit labels; fine.) Verify with
   `kubectl kustomize talos/manifests/namespaces | grep -c "name: authentik"` which must print `1`.
2. **Instructions for the operator** go into the PR description (below): MinIO bucket, user, then sealing (6.2).
   The executor does NOT create the sealed files; it cannot know the secret values. The operator commits the two
   sealed files to the same PR branch (or hands them over).
3. When the sealed files exist: add to `talos/sealed-secrets/kustomization.yaml` under `resources:`
   `- authentik-secrets.yaml` and `- authentik-pg-s3.yaml`, and add two comment lines in the header:

```
#   authentik-secrets.yaml      authentik/authentik-secrets     AUTHENTIK_SECRET_KEY, AUTHENTIK_BOOTSTRAP_PASSWORD, AUTHENTIK_BOOTSTRAP_EMAIL
#   authentik-pg-s3.yaml        authentik/authentik-pg-s3       ACCESS_KEY_ID, ACCESS_SECRET_KEY  (MinIO user authentik-pg)
```

4. Verify: `bash .github/scripts/run-all-guards.sh` all `OK`; `grep -c "kind: SealedSecret" talos/sealed-secrets/authentik-secrets.yaml` prints `1`;
   `grep -ci "password\|secret_key" talos/sealed-secrets/authentik-secrets.yaml` may match only
   `encryptedData` key names (ciphertext), never plain text. Confirm with `grep -n "AUTHENTIK_BOOTSTRAP_PASSWORD:" talos/sealed-secrets/authentik-secrets.yaml` that the value after the colon is a long `Ag...` string.

**Steps only the operator can do (copy-paste list).**

1. Generate and store in the password manager: C1 `openssl rand -base64 60 | tr -d '\n' | pbcopy`; C3
   `openssl rand -base64 24 | tr -d '\n' | pbcopy` (one at a time, paste into the manager as new entries).
2. MinIO: create bucket `authentik-pg` and a user `authentik-pg` limited to that bucket. If
   `talos/dr/minio/setup-users.sh` still applies (WP1 step 3 says), use it; otherwise with `mc` pointed at the
   in-cluster MinIO (port-forward from the operator's machine) create the bucket, a policy copied from
   `talos/dr/minio/policy.json.tmpl` with the bucket name replaced, and the user. Write the generated access
   key and secret into the password manager.
3. Run the sealing recipe of 6.2 for `authentik-secrets` and for `authentik-pg-s3`.
4. Commit the two sealed files on the PR branch.

Rollback: revert the PR. The namespace app has prune off: if the namespace already exists, delete it by
hand only when empty (the operator).

PR title: **"feat: authentik namespace and sealed secrets"**. Description: what
was added, the the operator steps above, no values. After merge the operator syncs: nothing manual (apps `namespaces` and
`talos-sealed-secrets` auto-sync). Check: `kubectl --context admin@<cluster> get ns authentik` and
`kubectl --context admin@<cluster> -n authentik get sealedsecret` lists both, then `kubectl --context admin@<cluster> -n authentik get secret`
shows `authentik-secrets` and `authentik-pg-s3`.

STOP point: wait for the operator to confirm both Secrets exist.

---

### WP3: the database (app `authentik-infra`)

**Goal.** CNPG Cluster `authentik-pg`, daily backup, and the Ingress. Branch `feat/authentik-infra`.

Preconditions: WP2 merged and the Secrets exist; D8 done (P10).

Steps.

1. Resolve the PostgreSQL operand image. List tags (read-only) and pick the newest 17.x minimal image tag:
   `curl -s "https://ghcr.io/token?scope=repository:cloudnative-pg/postgresql:pull" | jq -r .token` gives a token; then
   `curl -s -H "Authorization: Bearer $TOKEN" https://ghcr.io/v2/cloudnative-pg/postgresql/tags/list | jq -r '.tags[]' | grep -E '^17\.[0-9]+$' | sort -V | tail -3`.
   Do not use a tag containing `-bookworm`/`-standard` unless it is the only form `[UNVERIFIED: tag naming
   of the CNPG operand images; compare with the immich cluster's `17-1.1.1` style and pick the plain
   `17.<minor>` tag]`. Then get its digest (WP4 step 1 recipe with repository `cloudnative-pg/postgresql`).
   Write `PGTAG` and `PGDIGEST` into your notes.
2. Create `talos/manifests/authentik-infra/cluster.yaml`:

```yaml
# Authentik's PostgreSQL (CloudNativePG). One instance on mini01, 5Gi on topolvm-fast.
# Backups: WAL archiving + base backups to the in-cluster MinIO, bucket authentik-pg (Secret authentik-pg-s3).
# The operator generates the Secret authentik-pg-app (keys username, password) for the owner.
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: authentik-pg
  namespace: authentik
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:<PGTAG>@sha256:<PGDIGEST>
  priorityClassName: hs-interactive
  affinity:
    nodeSelector:
      kubernetes.io/hostname: mini01 # D2
  bootstrap:
    initdb:
      database: authentik
      owner: authentik
  postgresql:
    parameters:
      max_connections: "200" # Authentik 2025.10+ uses about 50 percent more connections [UNVERIFIED sizing; measure]
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: "1"
      memory: 768Mi
  storage:
    size: 5Gi
    storageClass: topolvm-fast
  backup:
    retentionPolicy: 14d
    barmanObjectStore:
      destinationPath: s3://authentik-pg/
      endpointURL: http://velero-backup-target.velero.svc.cluster.local:9000
      s3Credentials:
        accessKeyId:
          name: authentik-pg-s3
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: authentik-pg-s3
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
      data:
        compression: gzip
```

   Replace `<PGTAG>` and `<PGDIGEST>` with the real values (a placeholder left in a committed file is a
   bug). The form `name:tag@sha256:digest` is how the existing manifests pin; if CNPG 1.25 rejects the form,
   use the digest alone `name@sha256:digest` `[UNVERIFIED]`. The operator version is 1.25 (in-tree
   `barmanObjectStore`, the same as `immich-pg`); do not use the newer plugin form.
   Check the CNPG field names against the operator's own CRD: `kubectl --context admin@<cluster> get crd clusters.postgresql.cnpg.io -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.affinity.properties}' | jq 'keys'`
   (read-only) must list `nodeSelector`.
3. Create `talos/manifests/authentik-infra/scheduled-backup.yaml`:

```yaml
# Daily base backup of authentik-pg at 03:00 UTC. CNPG cron has SIX fields (seconds first).
# immediate: false: the first backup is taken on purpose by the operator (WP3 verification).
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: authentik-pg-daily
  namespace: authentik
spec:
  schedule: "0 0 3 * * *"
  backupOwnerReference: self
  immediate: false
  cluster:
    name: authentik-pg
```

4. Create `talos/manifests/authentik-infra/ingress.yaml` (tailnet device name `authentik`; the Ingress
   belongs to this app but points at the Service the chart creates in WP4):

```yaml
# Authentik on the tailnet only (Tailscale operator), device name `authentik` from tls.hosts.
# The full name (authentik.<tailnet>.ts.net) is a host detail and is not committed.
# If a stale `authentik` device exists in the tailnet, the new one registers as `authentik-1`:
# delete the stale device in the Tailscale admin console first (same note as jellyfin).
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: authentik
  namespace: authentik
spec:
  ingressClassName: tailscale
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: authentik-server
                port:
                  number: 80
  tls:
    - hosts:
        - authentik
```

5. Create `talos/manifests/authentik-infra/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cluster.yaml
  - scheduled-backup.yaml
  - ingress.yaml
```

6. Create `talos/apps-src/authentik-infra.yaml`:

```yaml
# Authentik's database, backup schedule and tailnet Ingress (plain manifests). Manual sync.
# The Secret authentik-pg-s3 comes from talos/sealed-secrets/ (sealed); this app does not create it.
# Needs the CNPG operator (app cnpg-operator) and the Tailscale operator.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: authentik-infra
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/BrunoLoureirooo/homelab_gitops
    targetRevision: main
    path: talos/manifests/authentik-infra
  destination:
    server: https://kubernetes.default.svc
    namespace: authentik
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
```

7. Run `bash talos/render-apps.sh --force`; check `git status` shows only `talos/apps/authentik-infra.yaml`
   as new generated file (plus your sources). If other generated files change, STOP and report (the tree was
   not clean).
8. Add to `talos/test/empty-cluster-expectations.txt` (column layout as the other lines):
   `authentik-infra          *       *       # manual sync; needs the CNPG operator, the sealed authentik-pg-s3 and the Tailscale operator`
9. Verify: `kubectl kustomize talos/manifests/authentik-infra | head -5` renders; `bash .github/scripts/run-all-guards.sh` all `OK`.

Verification after the operator's sync (The operator or executor, read-only):
`kubectl --context admin@<cluster> -n authentik get cluster authentik-pg` shows `Cluster in healthy state`, 1/1 instances;
`kubectl --context admin@<cluster> -n authentik get pods -o wide` shows `authentik-pg-1` Running on mini01;
`kubectl --context admin@<cluster> -n authentik describe secret authentik-pg-app` lists `username`, `password`.
The Ingress `authentik` exists but returns no page until WP4 (the Service does not exist yet; that is
expected).

Backup proof (operator-only, creates a Backup object): save as a temporary file outside the repo and apply:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: authentik-pg-first
  namespace: authentik
spec:
  cluster:
    name: authentik-pg
```
then `kubectl --context admin@<cluster> -n authentik get backup authentik-pg-first` must reach `completed`
(The operator applies this as a one-off; the repo has no manual-backup file by design, same as immich).

Rollback: do not delete the Cluster while Authentik uses it. Before first use the app can be deleted in Argo
UI (Prune=false protects the Cluster; delete it by hand if wanted, the operator).

PR title: **"feat: authentik database (CNPG), backup schedule and tailnet ingress"**. After merge the operator, in the
Argo UI: sync `authentik-infra` (first press "Diff", then Sync). Watch the Cluster until healthy.

STOP point: after the first backup `completed`.

---

### WP4: Authentik server and worker (Helm app `authentik`)

**Goal.** Deploy the chart. Branch `feat/authentik-app`.

Preconditions: WP3 synced and healthy, first backup completed; D1, D3, D4 answered.

Steps.

1. **Resolve the image digest** (ghcr.io; the template script `docs/templates/ghcr-app/new-app.sh` resolves ghcr
   names too, but a plain read-only query works here):
```bash
TAG=2026.8.5        # D1
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:goauthentik/server:pull" | jq -r .token)
curl -sI -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" \
  "https://ghcr.io/v2/goauthentik/server/manifests/$TAG" | grep -i '^docker-content-digest'
```
   Expected: one line `docker-content-digest: sha256:<64 hex>`. That value is `DIGEST`. If empty or an
   error, try without the `Accept` header; if still empty, STOP (The operator resolves it with `crane digest`).
2. **Render the chart locally to check the facts** (no cluster):
```bash
helm repo add authentik https://charts.goauthentik.io && helm repo update authentik
helm template authentik authentik/authentik --version 2026.8.5 -n authentik -f talos/values/authentik.yaml > /tmp/authentik-render.yaml
grep -n "kind: Deployment\|name: authentik-server\|name: authentik-worker\|secretRef\|name: authentik-secrets" /tmp/authentik-render.yaml
```
   Expected: Deployments `authentik-server` and `authentik-worker`, both with `secretRef` `authentik-secrets`,
   Service `authentik-server` (ports 80 and 443). Different names mean the Ingress in WP3 points at the wrong
   Service: STOP.
3. Create `talos/values/authentik.yaml`:

```yaml
# Values for the Authentik Helm chart 2026.8.5 (chart repo https://charts.goauthentik.io).
# Secrets are NOT here: the Secret `authentik-secrets` (sealed, talos/sealed-secrets/) provides
# AUTHENTIK_SECRET_KEY and the bootstrap admin variables to every pod through the chart's
# authentik.existingSecret mechanism. The database password comes from the CNPG-generated Secret.
# No Redis: Authentik no longer uses it (since 2025.10).
global:
  image:
    repository: ghcr.io/goauthentik/server
    tag: "2026.8.5"
    digest: "sha256:<DIGEST>"        # resolved in WP4 step 1; leaving the placeholder is a bug
  priorityClassName: hs-interactive
  nodeSelector:
    kubernetes.io/hostname: mini01   # D2
  securityContext:                   # pod level, applies to server and worker [UNVERIFIED that the chart applies global.securityContext to pods; confirm in the render]
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  env:
    - name: AUTHENTIK_POSTGRESQL__PASSWORD
      valueFrom:
        secretKeyRef:
          name: authentik-pg-app     # created by the CNPG operator, never in git
          key: password
    - name: AUTHENTIK_POSTGRESQL__SSLMODE
      value: require                 # CNPG serves TLS signed by its own CA; see section 3.3
authentik:
  log_level: info
  existingSecret:
    secretName: authentik-secrets    # WARNING from the chart: when set, authentik.* secret values are ignored
  postgresql:
    host: authentik-pg-rw            # CNPG read-write Service
    port: 5432
    name: authentik
    user: authentik
server:
  replicas: 1
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: "1"
      memory: 1Gi
  containerSecurityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop: ["ALL"]
    # readOnlyRootFilesystem: true     # NOT set: Authentik writes below /tmp and its home [UNVERIFIED]; try it in a later PR with emptyDir mounts
  ingress:
    enabled: false                   # the tailnet Ingress lives in authentik-infra (host name must come from tls.hosts)
worker:
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 384Mi
    limits:
      cpu: "1"
      memory: 1Gi
  containerSecurityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop: ["ALL"]
postgresql:
  enabled: false                     # the Bitnami subchart is NOT used; CNPG is
blueprints:
  configMaps: []
  secrets: []                        # WP15 adds the sealed blueprint Secret here
```

   Note on `hs-interactive`: it exists (P7). Note the `existingSecret` warning: with it set, nothing under
   `authentik.*` that is a secret value (secret_key, postgresql.password, email.password) is used, so those
   come only from the Secret/`global.env`.
4. Create `talos/apps-src/authentik.yaml` (multi-source like `talos/apps/immich.yaml`):

```yaml
# Authentik (identity provider) from the official Helm chart. Manual sync, no automated block.
# Needs: namespace authentik, sealed Secret authentik-secrets, app authentik-infra (database).
# Values: talos/values/authentik.yaml. Chart version equals the Authentik version (D1).
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: authentik
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://charts.goauthentik.io
      chart: authentik
      targetRevision: "2026.8.5"
      helm:
        valueFiles:
          - $values/talos/values/authentik.yaml
    - repoURL: https://github.com/BrunoLoureirooo/homelab_gitops
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: authentik
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
```

   Check against how a public HTTP Helm repo is declared by the existing velero app: `sed -n 1,30p argocd/apps/velero.yaml`
   (it uses a plain `repoURL` of the chart repository with no extra registration). If Argo needs a repository
   entry for `https://charts.goauthentik.io` it will say "repository not found" at sync: report to the operator
   (he adds the repository in Argo UI, Settings, Repositories; a the operator step).
5. `bash talos/render-apps.sh --force`; only `talos/apps/authentik.yaml` should be new.
6. Add to `talos/test/empty-cluster-expectations.txt`:
   `authentik                *       *       # manual sync; Helm chart from charts.goauthentik.io; needs the sealed authentik-secrets and the CNPG database`
7. Run guards; all `OK`. `grep -rn "sha256:<" talos/values/authentik.yaml` must print nothing (no placeholder left).
8. Add a note to `docs/BACKLOG.md`: Authentik row status `Partway`, note "Deployed via talos/values/authentik.yaml; SSO integrations pending" (only in the PR that is actually merged with the deploy).

Verification after the operator's sync (read-only):

- `kubectl --context admin@<cluster> -n authentik get pods` shows `authentik-server-*` and `authentik-worker-*` `1/1 Running` (the
  server needs up to ~10 minutes at first start: startupProbe allows 60 x 10 s) plus `authentik-pg-1`.
- `kubectl --context admin@<cluster> -n authentik logs deploy/authentik-worker --tail=50` shows migrations finishing and no
  `password authentication failed` and no TLS error. A TLS error means `SSLMODE=require` is not enough: STOP,
  report the line (decision on CA handling goes to the operator).
- `kubectl --context admin@<cluster> -n tailscale get pods | grep authentik` shows `ts-authentik-*` Running; the Ingress
  address: `kubectl --context admin@<cluster> -n authentik get ingress authentik` prints a host (do not copy it into files).
- `kubectl --context admin@<cluster> top pods -n authentik` against the section 4 numbers.

Rollback: Argo UI, sync the previous revision, or delete the app (data is in CNPG). Nothing else depends on
Authentik yet.

PR title: **"feat: deploy Authentik (Helm chart 2026.8.5)"**. After merge the operator: in Argo sync `authentik`
(Diff first; Sync). STOP point: pods Ready; do not log in yet (WP6 is the operator's).

---

### WP5: back-channel network spike (read-only, decision D5)

**Goal.** Find out which of N1 to N4 works, without changing the cluster. Output is a report, no PR unless a
repo-side fix is chosen.

Why. Browser to Authentik works over the tailnet. But Immich, Paperless, Actual, Argo CD (and Grafana for
the token call) are pods; their server-side calls to `https://authentik.<tailnet>.ts.net/...` need DNS and a
route and a valid TLS name from inside the cluster. Observed 2026-10-25: from an existing app pod, a tailnet
Ingress name does not resolve (`ENOTFOUND`).

Steps (all read-only).

1. From a pod with a shell or `node`, test resolution of the Authentik name AFTER WP4 (The operator gives you the
   name; do not write it to a file): `kubectl --context admin@<cluster> -n homeserver exec deploy/immich-server -- node -e "require('dns').lookup(process.argv[1],(e,a)=>console.log(e?e.code:'ok'))" <authentik-host>`
   Expected today: `ENOTFOUND`.
2. Find how the Talos nodes resolve: read `talos/patches/` and `talos/nodes/` for `nameservers`; report. Read the
   CoreDNS ConfigMap (`kubectl --context admin@<cluster> -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'`): on 2026-10-25 it has `forward . /etc/resolv.conf`.
3. Check whether pods can reach tailnet IPs at all (needed for every option): ask the operator for the tailnet address of the
   Authentik device (from the Tailscale admin console) and test a TCP connect from the pod to port 443 of it (same `node -e` with `net.connect`, timeout 5 s).
4. Read the Tailscale operator documentation of the installed version (v1.102.3) for a way to make an Ingress
   reachable from cluster pods by its tailnet name (the annotation `tailscale.com/experimental-forward-cluster-traffic-via-ingress`
   is named in some sources `[UNVERIFIED: could not open any page that documents it]`). Report whether it exists.
5. Report the results per option N1 to N4 with evidence. STOP; the operator decides D5. If N1/N2 is chosen, write a
   separate PR (CoreDNS change in the repo form the operator prefers, or a Talos machine-config change that
   the operator applies himself); never apply it.

Rollback: none (read-only).

---

### WP6: first login, admin users, MFA, break-glass (operator-only list; executor writes the PR text)

No repository change. The executor puts this list into a comment on the WP4 PR or hands it over.

1. Open `https://authentik.<tailnet>.ts.net/` on a tailnet device. With D3(a) the login page appears:
   user `akadmin`, password C3 (clipboard command in 6.3). With D3(b) open
   `https://authentik.<tailnet>.ts.net/if/flow/initial-setup/` immediately and set the `akadmin` password
   (trailing slash required).
2. Right away: avatar menu, **Settings** (user settings), change the `akadmin` password to a NEW long one and save it in the password manager.
3. **Admin interface** (avatar menu, "Admin interface"), **Directory > Users > Create**: username `<operator>`, name, your email, set a
   password (type: "Set password"). Open the user, **Groups > Add to existing group** and add the group
   `authentik Admins`.
4. Log out; log in as `<operator>`. In **User settings > MFA Devices > Enroll**, add a TOTP authenticator (or WebAuthn). Save the recovery
   codes in the password manager.
5. Test break-glass: in a private window log in as `akadmin` (works with password only). Then test the command
   path once: `kubectl --context admin@<cluster> -n authentik exec -it deployment/authentik-worker -c worker -- ak create_recovery_key 5 akadmin`,
   open the link in a private window to prove it works, and let it expire.
6. **System > Brands** (or Tenants in older versions): check the Domain/branding is `authentik-default`; no change needed.
7. **Events > Logs** should show your logins. If `akadmin` was created through the bootstrap, optionally
   delete the token list entry (if D4 was ignored): **Directory > Tokens and App passwords**.
8. Tell the executor "WP6 accepted".

Exact UI menu names can differ by release `[UNVERIFIED for 2026.8]`; the steps name the objects, find the
nearest equivalent and report differences.

---

### WP7: external URL and proxy-header check (read-only, then possibly a small PR)

Goal: Authentik builds correct `https://` links behind the Tailscale proxy.

1. The operator, logged in: open the Admin interface; hover the "Launch" link of any application later; for now
   check **Applications > Outposts > authentik Embedded Outpost** shows no error and
   **System > Settings** has no URL warning. Easiest proof: click **Directory > Users > <operator> > Create recovery link** (UI, 5 minutes):
   the link must start with `https://authentik.` . If it starts with `http://` the proxy headers are not trusted.
2. If `http://`: the fix is a sealed key `AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS` in `authentik-secrets` with
   the pod network CIDR (the executor reads it read-only: `kubectl --context admin@<cluster> get nodes -o jsonpath='{.items[*].spec.podCIDR}'`
   and passes it to the operator privately, NOT in a file). The operator re-seals `authentik-secrets` with the extra key
   (recipe 6.2 with the new `--from-literal` line; all keys must be given again) and Argo syncs
   `talos-sealed-secrets` (automatic), then the operator restarts the Deployments (a PR cannot do this; the operator can use the
   Argo UI "Restart" on both Deployments).
3. Whether Tailscale's proxy sets `X-Forwarded-Proto`/`X-Forwarded-For` is `[UNVERIFIED]`; the result of step 1 answers it.

PR (only if step 2 was needed): none in the repo apart from comment updates; the sealed file is replaced by the operator.

---

### WP8: Immich (OIDC)  — branch: none needed (UI configuration), report only

Depends on: WP6 accepted, D5 solved (the Immich server pod calls Authentik), D9 includes Immich.
Settings `[verified https://integrations.goauthentik.io/media/immich/ and https://docs.immich.app/administration/oauth]`.

**Authentik side (the operator, UI), checklist:**

1. **Applications > Applications > New Application** (the wizard also creates the provider).
   - Name: `Immich`; Slug: `immich`.
   - Provider type: **OAuth2/OpenID Connect**; Provider name: `immich-provider`.
   - Authorization flow: the default explicit (or implicit) consent flow (`default-provider-authorization-explicit-consent`).
   - Client type: Confidential. Signing key: any available (`authentik Self-signed Certificate`).
   - Redirect URIs (each **Strict**, type Authorization): `app.immich:///oauth-callback`,
     `https://immich.<tailnet>.ts.net/auth/login`, `https://immich.<tailnet>.ts.net/user-settings`.
     (Before authentik 2026.5 all URIs are the Authorization kind; on 2026.8 pick Authorization for each.)
   - Optional: Logout URI `https://immich.<tailnet>.ts.net/api/oauth/backchannel-logout`, method Back-channel.
   - Copy Client ID and Client Secret into the password manager.
2. Policy/access: **Applications > immich > Policy / Group / User Bindings**: bind the group `authentik Admins` or
   a new group `Homelab Users` (create it in Directory > Groups, add `<operator>`). Without a binding every
   authenticated user may open the application.

**Immich side (the operator, UI): Administration > Settings > OAuth Authentication:**

- Enable OAuth: on. Issuer URL: `https://authentik.<tailnet>.ts.net/application/o/immich/` (the verified form is
  `https://authentik.company/application/o/<application_slug>/`; trailing slash as shown).
- Client ID / Client Secret: from Authentik. Scope: default `openid email profile`. Button text: `Login with Authentik`.
- Auto Register: default on. Auto Launch: leave OFF (keeps the password login visible). Mobile redirect URI override: empty.
- Do NOT turn on "Disable password login" (Immich keeps the local admin as break-glass).
- Save. The client secret is stored in Immich's database (covered by `immich-pg` backups).

**Lock-out safe test order:** keep the current admin session open in window A; in a private window B click
"Login with Authentik" and sign in as `<operator>`; Immich creates a new user (by email). `[UNVERIFIED whether an
existing Immich user with the same email is linked automatically: the Immich page I read did not say. If a
second account appears, the operator links via Account Settings > OAuth in the existing account while logged in.]`

**Rollback:** disable OAuth in Immich settings (window A still logged in); delete the application in Authentik.

---

### WP9: Paperless-ngx (OIDC through allauth)

Depends on: the Paperless plan deployed `[ASSUMED]` (namespace `paperless`, Secret `paperless-secrets`), WP6, D5.
Settings `[verified https://integrations.goauthentik.io/documentation/paperless-ngx/]`.

**Authentik (the operator):** Application `Paperless`, slug `paperless`, OAuth2/OpenID provider `paperless-provider`; Redirect URI
(Strict, Authorization): `https://paperless.<tailnet>.ts.net/accounts/oidc/authentik/login/callback/`; signing key any; copy
Client ID/Secret; bind group `Homelab Users`.

**Paperless side.** Paperless takes its settings from environment variables. The values containing the host
name and the client secret go into the SEALED Secret of the Paperless app; the non-secret ones go into its
Deployment env. Executor's task = a PR in the Paperless app's folder (path from the Paperless plan
`[ASSUMED]`: `talos/manifests/paperless/`):

```yaml
# non-secret env in the Deployment (names verified)
- name: PAPERLESS_APPS
  value: allauth.socialaccount.providers.openid_connect
- name: PAPERLESS_SOCIAL_AUTO_SIGNUP
  value: "true"          # remove to allow only pre-created users
- name: PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS
  value: "true"
```

Sealed keys in `paperless-secrets` (The operator re-seals the whole Secret with the extra keys):

- `PAPERLESS_SOCIALACCOUNT_PROVIDERS` =
  `{"openid_connect":{"OAUTH_PKCE_ENABLED":true,"APPS":[{"provider_id":"authentik","name":"Authentik","client_id":"<client-id>","secret":"<client-secret>","settings":{"server_url":"https://authentik.<tailnet>.ts.net/application/o/paperless/.well-known/openid-configuration","fetch_userinfo":true}}],"SCOPE":["openid","profile","email"]}}`
  (single line, valid JSON; the operator substitutes the three placeholders when typing; the callback path
  `.../accounts/oidc/authentik/login/callback/` uses `provider_id` `authentik`, they must match).
- `PAPERLESS_LOGOUT_REDIRECT_URL` = `https://authentik.<tailnet>.ts.net/application/o/paperless/end-session/` (optional).

Keep `PAPERLESS_DISABLE_REGULAR_LOGIN` UNSET (default). Note the docs: even with it set, Django admin and
API login stay, so it is not a full lock. Test: private window, "Sign in with Authentik" button; local
superuser login unchanged. Rollback: remove the three env variables/keys, sync Paperless.

---

### WP10: Grafana (generic OAuth)

Depends on: the monitoring plan deployed `[ASSUMED]` (namespace `monitoring`, Grafana from a Helm chart whose values
accept `grafana.ini` and `envFromSecret`), WP6, D5 (or N4 below). Settings `[verified https://integrations.goauthentik.io/monitoring/grafana/]`.

**Authentik:** Application `Grafana`, slug `grafana`, provider `grafana-provider` OAuth2; Redirect URI (Strict, Authorization)
`https://grafana.<tailnet>.ts.net/login/generic_oauth`; Logout URI `https://grafana.<tailnet>.ts.net/logout` method Front-channel;
signing key any; under Advanced protocol settings, Selected Scopes add **"authentik default OAuth Mapping: Application Entitlements"**.
In the application, tab **Application entitlements**, create `Grafana Admins`, `Grafana Editors`, `Grafana Viewers`; bind
your user to `Grafana Admins` (names must match the expression exactly).

**Grafana side.** Host names in config: use environment variables fed from a sealed Secret in `monitoring`
(not `grafana.ini` in git). Keys of the Secret (The operator seals, namespace `monitoring`, name `grafana-oauth`):

```
GF_SERVER_ROOT_URL=https://grafana.<tailnet>.ts.net
GF_AUTH_GENERIC_OAUTH_CLIENT_ID=<client-id>
GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=<client-secret>
GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://authentik.<tailnet>.ts.net/application/o/authorize/
GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://authentik.<tailnet>.ts.net/application/o/token/
GF_AUTH_GENERIC_OAUTH_API_URL=https://authentik.<tailnet>.ts.net/application/o/userinfo/
GF_AUTH_SIGNOUT_REDIRECT_URL=https://authentik.<tailnet>.ts.net/application/o/grafana/end-session/
```

Non-secret values in Grafana's values/env (committed, no host): `GF_AUTH_GENERIC_OAUTH_ENABLED=true`,
`GF_AUTH_GENERIC_OAUTH_NAME=authentik`,
`GF_AUTH_GENERIC_OAUTH_SCOPES=openid profile email entitlements`,
`GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=contains(entitlements[*], 'Grafana Admins') && 'Admin' || contains(entitlements[*], 'Grafana Editors') && 'Editor' || 'Viewer'`.
Do NOT set `GF_AUTH_OAUTH_AUTO_LOGIN` (it would hide the local login form). The local `admin` login remains.

N4 option (no cluster DNS change): Grafana separates the browser URL (`AUTH_URL`) from the server calls
(`TOKEN_URL`, `API_URL`): set the last two to the in-cluster Service `http://authentik-server.authentik.svc.cluster.local/application/o/token/` and
`.../userinfo/`. Caveat `[UNVERIFIED]`: Authentik may derive the token issuer from the request host and
reject or mismatch; test in a private window. Rollback: unset the OAuth variables.

---

### WP11: Actual Budget (OpenID)

Depends on: the Actual Budget plan `[ASSUMED]`, WP6, D5. Settings `[verified https://integrations.goauthentik.io/miscellaneous/actual-budget/]`.

**Authentik:** Application `Actual Budget`, slug `actual-budget`, provider `actual-budget-provider`; Redirect URI (Strict, Authorization)
`https://actual.<tailnet>.ts.net/openid/callback` (use the device name the Actual plan chooses); signing key any.

**Actual side**, sealed keys in the Actual app's Secret (The operator re-seals, namespace `homeserver`):

```
ACTUAL_OPENID_DISCOVERY_URL=https://authentik.<tailnet>.ts.net/application/o/actual-budget/
ACTUAL_OPENID_CLIENT_ID=<client-id>
ACTUAL_OPENID_CLIENT_SECRET=<client-secret>
ACTUAL_OPENID_SERVER_HOSTNAME=https://actual.<tailnet>.ts.net
```

Behaviour: the FIRST user to sign in with OpenID becomes the server owner; other users are not created
automatically unless `ACTUAL_USER_CREATION_MODE=login` is set. Warning for lock-out: if Actual's owner becomes the SSO user, make sure
the existing server password login still works (`[UNVERIFIED whether the password login stays available once OpenID is
configured: the page does not say. Test in a private window and keep the budget file exported (File > Export)`]).
Rollback: remove the four keys.

---

### WP12: Jellyfin (SSO plugin)  — only if D9 includes it

State of the plugin `[verified https://github.com/9p4/jellyfin-plugin-sso (README)]`: supports Jellyfin >= 10.8, "100% alpha
software", **the repository is archived** (the author stopped maintaining it), works in the Web UI or in clients that support Quick Connect;
the official authentik page for Jellyfin describes LDAP, not this plugin, and states Jellyfin has no native external authentication
`[verified https://integrations.goauthentik.io/media/jellyfin/]`. Recommendation: do not use SSO for Jellyfin; if
TV/phone clients must keep working the plugin is risky (they use direct password login, which stays). If the operator insists:

1. Check the Jellyfin version: `kubectl --context admin@<cluster> -n homeserver get deploy jellyfin -o jsonpath='{.spec.template.spec.containers[0].image}'`; confirm >= 10.8 and read the plugin README for the supported maximum `[UNVERIFIED]`.
2. Authentik: Application `Jellyfin`, slug `jellyfin`, provider `jellyfin-provider` OAuth2; Redirect URI (Strict, Authorization)
   `https://jellyfin.<tailnet>.ts.net/sso/OID/redirect/authentik`; scopes openid, profile, email.
3. Jellyfin (the operator, UI): Dashboard > Plugins > Repositories > add `https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/manifest-release/manifest.json`, install "SSO Authentication", restart. Plugin settings: provider name `authentik`, OID endpoint `https://authentik.<tailnet>.ts.net/application/o/jellyfin/`, client id/secret, enabled, set roles. Add the login button HTML from the README to Branding > Login disclaimer.
4. The plugin is installed in Jellyfin's config volume, backed up by Velero with the Jellyfin config. A plugin is code running inside Jellyfin: it is a supply-chain risk (archived, unmaintained); mention in the PR.
Rollback: uninstall the plugin; local users unaffected.

---

### WP13: Argo CD (only if D11 says yes) — operator-run, outside Argo

Facts: Argo CD here is installed by `talos/install-argocd.sh` (chart `ARGOCD_CHART=10.9.2`, `dex.enabled=false`), NOT self-managed.
Settings `[verified https://integrations.goauthentik.io/infrastructure/argocd/]` (that page uses Dex: `dex.config` in `argocd-cm`,
`dex.authentik.clientSecret` in `argocd-secret`, redirect URI `https://argocd.<tailnet>.ts.net/api/dex/callback`, RBAC groups
`Argo CD Admins` -> `role:admin`, `Argo CD Viewers` -> `role:readonly`). Argo CD can also use its built-in OIDC
(`oidc.config`, no Dex) `[UNVERIFIED for authentik; redirect URI would be https://argocd.<tailnet>.ts.net/auth/callback]`.

Constraints: keep the local `admin` account enabled (it is, by default); do not set `admin.enabled: "false"`; do not set
`policy.default` to anything that removes `admin`. The config contains the host name and the client secret, so
the Helm values file for this change lives OUTSIDE git (The operator's machine) and is applied with
`helm upgrade --reuse-values -f <file> ...` run by the operator, which also contradicts "all changes through PR + Argo": that is
why the recommendation is to skip. Plan if chosen: the executor drafts a template with placeholders in the PR description only.
D5 is a prerequisite (Dex/Argo calls Authentik from a pod).

---

### WP14: Vaultwarden and apps without OIDC

**Vaultwarden.** Authentik has a community-level guide: environment variables `SSO_ENABLED`, `SSO_AUTHORITY`, `SSO_CLIENT_ID`,
`SSO_CLIENT_SECRET`, `SSO_SCOPES` (including `offline_access`), `SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION=false`,
`SSO_CLIENT_CACHE_EXPIRATION=0`, `SSO_SIGNUPS_MATCH_EMAIL=true`, `SSO_ONLY=false`, `DOMAIN`; callback
`https://<vaultwarden-host>/identity/connect/oidc-signin`; the provider must use no encryption key; a custom email scope
mapping is needed so `email_verified` is true or absent `[verified https://integrations.goauthentik.io/security/vaultwarden/ and https://github.com/dani-garcia/vaultwarden/wiki/Enabling-SSO-support-using-OpenId-Connect]`.
Caveats: SSO does not replace the master password. Whether the official image (as pinned in `argocd/values/vaultwarden.yaml`)
includes SSO or only a testing build, and in which version, I could not confirm `[UNVERIFIED: check the Vaultwarden release notes
for the pinned tag before anything]`. **Recommendation: do NOT enable.** Vaultwarden holds the credentials needed to recover
Authentik (C1, C3, the `akadmin` password); making it depend on Authentik creates a circular lock-out.

**Homepage.** No login; skip.

**Apps with no OIDC (forward-auth / proxy outpost). What is feasible with the Tailscale operator Ingress:**

- Forward-auth (single application or domain level) needs a reverse proxy that does a subrequest check (`auth_request`, Traefik forwardAuth)
  to `/outpost.goauthentik.io/auth/nginx` `[verified https://docs.goauthentik.io/add-secure-apps/providers/proxy/server_nginx/]`.
  The Tailscale operator Ingress is a `tailscale serve` proxy: it has no such hook `[UNVERIFIED: no document found that offers one]`.
  So direct forward-auth on the Tailscale Ingress is NOT feasible.
- Feasible A, proxy mode: the app's tailnet Ingress points at an Authentik **proxy outpost** Service, and the outpost proxies to the app
  (the outpost sits in the traffic path, needs no extra reverse proxy) `[verified https://docs.goauthentik.io/add-secure-apps/providers/proxy/]`.
  Outpost: image `ghcr.io/goauthentik/proxy`, ports 9000/9443, env `AUTHENTIK_HOST`, `AUTHENTIK_TOKEN`, `AUTHENTIK_INSECURE`
  `[verified https://docs.goauthentik.io/add-secure-apps/outposts/manual-deploy-kubernetes/]`. `AUTHENTIK_HOST` would be the in-cluster
  Service for API calls; browser redirects need the public Authentik URL, via `AUTHENTIK_HOST_BROWSER` `[UNVERIFIED: not on the page I could open]`.
  The token (secret) and the external host (host name) go in a sealed Secret. The app must tolerate being reached through the outpost.
- Feasible B: put a small nginx (or Caddy) pod with `auth_request` between the Tailscale Ingress and the app, with the outpost embedded in
  the Authentik server (`authentik-server` Service). More moving parts; same sealed-secret rule.
- Not feasible: relying on Tailscale identity headers as the login; they do not integrate with Authentik policies.
Nothing is built until an app needs it (D10). A package would be written then.

---

### WP15: blueprints (optional, D7)

Goal: keep the Authentik configuration of providers and applications as files so a rebuilt Authentik can be restored.

Rule: blueprint content contains tailnet host names (redirect URIs) and client ids, so the files cannot be committed in clear. They are
stored as keys of a SEALED Secret `authentik-blueprints` (namespace authentik; the chart supports `blueprints.secrets`), and the
non-host-bearing parts could live in a ConfigMap, but one mechanism is simpler: use the sealed Secret for all.

1. The operator exports the current configuration: `kubectl --context admin@<cluster> -n authentik exec deployment/authentik-worker -c worker -- ak export_blueprint > ~/authentik-export.yaml`
   (outside the repo; contains host names and object ids; client secrets are NOT included).
2. Split what you want to keep into files, e.g. `immich.yaml`:

```yaml
version: 1
metadata:
  name: homelab-immich
  labels:
    blueprints.goauthentik.io/description: "Immich OIDC application"
context: {}
entries:
  - model: authentik_providers_oauth2.oauth2provider
    id: immich-provider
    identifiers:
      name: immich-provider
    attrs:
      authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-explicit-consent]]
      invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
      client_type: confidential
      redirect_uris:
        - matching_mode: strict
          url: app.immich:///oauth-callback
        - matching_mode: strict
          url: https://immich.<tailnet>.ts.net/auth/login
        - matching_mode: strict
          url: https://immich.<tailnet>.ts.net/user-settings
  - model: authentik_core.application
    identifiers:
      slug: immich
    attrs:
      name: Immich
      provider: !KeyOf immich-provider
```

   The field names for `redirect_uris` and the flow slugs `[UNVERIFIED]` differ between releases: compare with the export from step 1 and
   copy its structure exactly. Do not invent attributes.
3. Seal the files into one Secret, key per file (`immich.yaml`, ...), namespace `authentik`, name `authentik-blueprints`:
   `kubectl create secret generic authentik-blueprints -n authentik --from-file=immich.yaml=<file> --dry-run=client -o json | KUBECONFIG=/dev/null kubeseal --cert argocd/sealed-secrets/pub-cert.pem --format yaml > talos/sealed-secrets/authentik-blueprints.yaml`
   and list it in `talos/sealed-secrets/kustomization.yaml`.
4. In `talos/values/authentik.yaml` set `blueprints.secrets: [authentik-blueprints]`. Render locally and check the mount path
   (`grep -n "blueprints" /tmp/authentik-render.yaml`); a ConfigMap is mounted at `/blueprints/mounted/cm-<name>`, the Secret path
   `[UNVERIFIED]` is read from the render.
5. After sync, **System > Blueprints** in the UI shows the instance with status `successful`; `ak` logs on the worker show the apply.
   Existing objects with the same identifiers are adopted, not duplicated (state `present` default).
Rollback: remove the key from values; the objects stay in the database.

---

### WP16: restore drill and docs

Described in section 8; PR adds `talos/dr/authentik-pg-recovery.yaml` and a short `docs/dr/talos-backups.md` section "Authentik Postgres"
modelled on "Immich Postgres". Branch `docs/authentik-restore`. PR title: **"docs: Authentik database restore drill"**.

## 8. Backup and restore

**What is covered by what.**

| Data | Mechanism | Where | Not covered |
|---|---|---|---|
| Authentik state (users, applications, providers, flows, policies, events, MFA devices) | CNPG WAL archiving + daily base backup (03:00 UTC), retention 14 days | bucket `authentik-pg` in MinIO on mini02 | the second copy on mini03 (PR #71) is planned; today MinIO is a single copy |
| Secrets (`authentik-secrets`, `authentik-pg-s3`) | sealed files in git (ciphertext) + the operator's password manager | repo | the sealing key itself (backed up per `docs/dr/talos-backups.md`) |
| Blueprints | sealed Secret in git (WP15) | repo | client secrets (write-only) |
| Configuration as clickable state | `ak export_blueprint` run by the operator before big changes | The operator's private storage (contains host names) | |
| Namespace `authentik` volumes | Velero does NOT include this namespace and need not: the only volume is the CNPG one, which has its own backup | | |

**Export procedure (the operator, monthly and before each upgrade):**
`kubectl --context admin@<cluster> -n authentik exec deployment/authentik-worker -c worker -- ak export_blueprint > ~/authentik-export-$(date +%F).yaml`.
Keep the file in the password manager as an attachment or on an encrypted disk; never in git.

**Restore test (executor writes it, the operator performs it).** The drill restores into a NEW throwaway cluster `authentik-pg-restore` in the
same namespace, reads a row count, deletes it. Create `talos/dr/authentik-pg-recovery.yaml` (modelled on `talos/dr/immich-pg-recovery.yaml`):

```yaml
# Restore DRILL for authentik-pg: creates a SECOND, independent cluster `authentik-pg-restore` from the
# WAL archive of authentik-pg, to prove the backups work. Never touches the running cluster.
#   apply:   kubectl --context admin@<cluster> apply -f talos/dr/authentik-pg-recovery.yaml   (the operator)
#   delete:  kubectl --context admin@<cluster> -n authentik delete cluster authentik-pg-restore  (the operator)
# For a REAL recovery of authentik-pg itself see docs/dr/talos-backups.md "Recovery" (a recovered cluster
# must archive under a NEW serverName, e.g. authentik-pg-r1).
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: authentik-pg-restore
  namespace: authentik
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:<PGTAG>@sha256:<PGDIGEST>   # same as cluster.yaml
  affinity:
    nodeSelector:
      kubernetes.io/hostname: mini01
  bootstrap:
    recovery:
      source: origin
      database: authentik
      owner: authentik
  externalClusters:
    - name: origin
      barmanObjectStore:
        destinationPath: s3://authentik-pg/
        endpointURL: http://velero-backup-target.velero.svc.cluster.local:9000
        serverName: authentik-pg
        s3Credentials:
          accessKeyId: { name: authentik-pg-s3, key: ACCESS_KEY_ID }
          secretAccessKey: { name: authentik-pg-s3, key: ACCESS_SECRET_KEY }
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { cpu: "1", memory: 768Mi }
  storage:
    size: 5Gi
    storageClass: topolvm-fast
```

Steps for the operator:
1. Confirm a completed backup: `kubectl --context admin@<cluster> -n authentik get backup`.
2. Apply the file; wait: `kubectl --context admin@<cluster> -n authentik get cluster authentik-pg-restore -w` until healthy.
3. Compare: `kubectl --context admin@<cluster> -n authentik exec authentik-pg-restore-1 -- psql -U postgres -d authentik -tAc "select count(*) from authentik_core_user"`
   and the same on `authentik-pg-1`; the counts match (the table name `[UNVERIFIED]`: list with `\dt authentik_core*` first).
4. Delete the drill cluster and its PVC. Record date and result in the PR.
Frequency: after the first deploy, and each time the CNPG operator or the Authentik major version changes.

## 9. Security

- Exposure: tailnet only, one Tailscale Ingress; nothing public. Valid TLS: the Tailscale operator's proxy provisions certificates from Let's Encrypt
  automatically for the Ingress name `[verified https://tailscale.com/kb/1439/kubernetes-operator-cluster-ingress]`, so browsers (and pods that can resolve the name) see a trusted certificate; the inside of the cluster is plain HTTP between proxy and
  `authentik-server` (as for every other app).
- Exact host names the apps will see: the Authentik URL is `https://authentik.<tailnet>.ts.net/` (device name `authentik`); apps are
  `https://immich.<tailnet>.ts.net`, `https://paperless.<tailnet>.ts.net`, `https://grafana.<tailnet>.ts.net`, `https://actual.<tailnet>.ts.net`, `https://jellyfin.<tailnet>.ts.net`, `https://argocd.<tailnet>.ts.net` (device names `[ASSUMED]` for the apps
  not yet deployed; use whatever the sibling plan chose). If a stale device exists the new name gets `-1`: then every URL here changes; check with
  `kubectl --context admin@<cluster> -n authentik get ingress authentik`.
- Authentication: strong password for `akadmin`; MFA for `<operator>`; consent screens on providers; policy bindings so only `Homelab Users`
  reach each app. Authentik is a single point of failure for SSO only; every app keeps its local login.
- Least privilege: namespace `restricted`; pods non-root (uid 1000), no privilege escalation, capabilities dropped, seccomp RuntimeDefault;
  root filesystem is writable for now (try read-only later). ServiceAccount `authentik` (from the chart) has a ClusterRole that can only `list`
  CustomResourceDefinitions and a namespaced Role for managed outposts (not used) `[verified in the local render]`; consider
  disabling it later. Database: separate Postgres user `authentik`, reachable only inside the cluster. A NetworkPolicy is optional and not
  part of this plan (no policies exist in the repo today).
- Secrets: sealed only; the bootstrap token is not created; the stale bootstrap password in the Secret is noted.
- Supply chain: image pinned by digest; chart pinned by version; Jellyfin plugin warning in WP12.
- Telemetry/error reporting: chart default `authentik.error_reporting.enabled: false` `[verified values.yaml]`.

## 10. Operations

- **Upgrade (PR):** read the release notes of the target version; check the chart version equals it; run a CNPG backup first (The operator applies a `Backup`
  object as in WP3 or waits for the daily one); change `targetRevision` in `talos/apps-src/authentik.yaml`, `global.image.tag` and `digest` in
  `talos/values/authentik.yaml`; run `talos/render-apps.sh --force`; guards; draft PR; the operator syncs after Diff. Go through every release in between when skipping minors.
- **Health:** `kubectl --context admin@<cluster> -n authentik get pods,cluster`; `kubectl --context admin@<cluster> -n authentik get backup,scheduledbackup`;
  in the UI: Admin interface dashboard, System Tasks, Events.
- **Logs:** `kubectl --context admin@<cluster> -n authentik logs deploy/authentik-server --tail=100`, same for `authentik-worker`, and `... logs authentik-pg-1`.
- **Resources:** `kubectl --context admin@<cluster> top pods -n authentik` and `kubectl --context admin@<cluster> top nodes`; raise limits if memory stays above 80 percent of the limit.
- **Troubleshooting table**

| Symptom | Where to look | Likely cause | Fix |
|---|---|---|---|
| Server pod stuck not Ready at first start | `logs deploy/authentik-server`, startupProbe | migrations running (up to ~10 minutes) or DB unreachable | wait; if `connection refused`/auth errors, check `get cluster authentik-pg`, Secret `authentik-pg-app` exists |
| `password authentication failed` | worker/server log | `AUTHENTIK_POSTGRESQL__PASSWORD` not from the right Secret, or DB recovered with a new password | check values `global.env`; restart Deployments (the operator) |
| TLS / `ssl` error to Postgres | worker log | `SSLMODE` mismatch | report to the operator; do not set `disable` without his decision |
| 404 at `/if/flow/initial-setup/` | browser | `akadmin` already exists (bootstrap env worked) or missing trailing slash | log in with the bootstrap password |
| Cannot log in as `akadmin` | UI | bootstrap values were ignored (DB existed at first start) | recovery 6.5 |
| Redirects go to `http://` | recovery link, login redirect | proxy headers not trusted | WP7 step 2 |
| Pod Security warning on sync | Argo sync message | a container lacks securityContext | STOP, report; do not relax the label yourself |
| App says "invalid issuer" / "discovery failed" / `ENOTFOUND` | app log | back-channel DNS (D5) or issuer URL typo (trailing slash) | WP5 |
| App says "redirect_uri mismatch" | Authentik Events > Logs | redirect URI typed differently (Strict match) | fix in the provider |
| CNPG backup `failed` | `describe backup`, `logs authentik-pg-1` | wrong MinIO credentials or missing bucket | re-seal `authentik-pg-s3`, create bucket |
| Locked out of everything | | | 6.5 recovery, then 6.6 |

## 11. Acceptance checklist and report format

Acceptance (The operator sees all of this):

- [ ] `https://authentik.<tailnet>.ts.net/` loads with a valid certificate on a tailnet phone and laptop.
- [ ] Login as `<operator>` with MFA works; `akadmin` break-glass works and the recovery-key command was tested once.
- [ ] `kubectl --context admin@<cluster> -n authentik get pods` all Ready; `get cluster authentik-pg` healthy.
- [ ] A completed CNPG backup in MinIO and the restore drill passed.
- [ ] For each integrated app: "Login with Authentik" works in a private window AND the local login still works.
- [ ] Argo CD, Vaultwarden, Kubernetes and Talos are NOT dependent on Authentik.
- [ ] Password manager has: secret key, bootstrap password (original), new `akadmin` password, `<operator>` password, MinIO pair, client secrets.
- [ ] `docs/BACKLOG.md` updated.

Report format after each package:

```
WP<n>: done | blocked | needs decision
PR: <url or none>
Guards: <20 OK lines or the failing line>
Verified: <commands run and their outputs, no secrets>
Differences from the plan: <anything different, with the evidence>
Needs from the operator: <steps or decisions>
```

## 12. Open questions and UNVERIFIED items

1. Release line: docs call 2026.8 "pre-release", GitHub releases are normal (D1).
2. Hardware minimums of Authentik (page not read): sizing in section 4 must be measured.
3. Whether the CNPG operator 1.25 accepts `tag@sha256` in `imageName`, the exact tag naming of `ghcr.io/cloudnative-pg/postgresql`, the generated Secret name `authentik-pg-app`.
4. Whether `AUTHENTIK_POSTGRESQL__SSLMODE=require` connects to CNPG's TLS (documented default is `verify-ca`).
5. Whether `global.securityContext` is applied to pods by the chart and whether the container runs with `readOnlyRootFilesystem`.
6. The mount path for `blueprints.secrets`; blueprint attribute names (`redirect_uris` shape, flow slugs) in 2026.8.
7. Which fields the secret key encrypts (impact of rotation).
8. Whether Tailscale's proxy sends `X-Forwarded-Proto/For`; whether Authentik trusts the pod network by default (WP7).
9. The back-channel network path (D5): CoreDNS/Talos DNS change, route from pods to tailnet addresses, any operator feature for in-cluster access by tailnet name.
10. Immich: automatic linking of an existing user by email; Actual: whether password login remains with OpenID; Vaultwarden: SSO in the pinned image.
11. `AUTHENTIK_HOST_BROWSER` for proxy outposts; whether the Argo Application needs the chart repository registered.
12. The UI menu names in 2026.8 (WP6).
13. Whether `talos/dr/minio/setup-users.sh` still works for the in-cluster MinIO (WP1 step 3).
14. Whether a leftover `authentik` Tailscale device exists (name becomes `authentik-1`).
