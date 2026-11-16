# Plan: Actual Budget (actual-server) on the homeserver

Audience: a local language model working on this repository for the operator. Follow it literally, one work
package at a time. Where it says STOP, stop and report to the operator; do not decide for him.

Written 2026-10-25. Facts marked `[verified <url>]` were read from official sources on that date.
Facts marked `[UNVERIFIED]` were not confirmed; each says how you confirm it. Facts marked `[ASSUMED]`
depend on a sibling plan you cannot read.

## 0. Purpose, scope, non-goals, definition of done

**Purpose.** Run Actual Budget (self-hosted personal finance, local-first, with a small sync server
called `actual-server`) on the Talos cluster, reachable only on the tailnet over valid HTTPS, with its
data on a `topolvm-fast` PVC that Velero backs up every night.

**In scope.**
- Namespace `homeserver`, one Deployment on mini01, one PVC, one Service, one Tailscale Ingress, one
  Argo Application (`actual-budget`, manual sync).
- Documented, tested password handling (server password, budget encryption password), backup, restore
  and upgrade procedures.
- Optional later packages, each behind a the operator decision: bank-sync provider (infrastructure only),
  OIDC login through Authentik.

**Non-goals.**
- No public internet exposure. No LAN exposure. No Funnel.
- No import of the operator's real budget data by the executor. The operator does that himself in the browser.
- No choice of bank-sync provider and no creation of provider accounts (The operator's decision D4).
- No change to Velero, Authentik, Tailscale or any other service. This plan only consumes them.

**Definition of done** (all must be true; section 11 has the detailed checklist):
- [ ] WP1 audit report delivered and approved.
- [ ] WP2 PR merged; Argo app `actual-budget` synced; pod `Running 1/1`; Argo `Synced` and `Healthy`.
- [ ] the operator opens the tailnet URL in a browser, sets the server password, creates a test budget.
- [ ] the operator recorded the server password and (if used) the budget encryption password in Vaultwarden.
- [ ] The PVC shows up in a Velero backup of namespace `homeserver` (PodVolumeBackup Completed).
- [ ] The restore drill (WP3) passed and the operator opened a restored copy of the budget in a scratch namespace.
- [ ] Optional: WP4 (bank sync) and WP5 (OIDC) either done or explicitly deferred by the operator.

## 1. Rules for the executor

1. You change files in the repository and open pull requests. Nothing else. The operator merges the PRs and
   syncs Argo himself in the Argo web UI. Never change the live cluster.
2. Cluster access is read-only: `get`, `describe`, `logs`, `top`, and `exec ... -- <read-only command>`.
   Always pass `--context admin@<cluster>`. Forbidden: `apply`, `create`, `delete`, `patch`, `edit`,
   `scale`, `rollout`, `replace`, `label`, `annotate`, `drain`, `cordon`, `taint`, `talosctl
   apply-config|upgrade|reset`, `argocd app sync`, `velero backup create`, `velero restore create`.
   Do not suggest `kubectl patch/apply` as a fix for anything: every change goes through a PR and an
   Argo sync. Steps that need a cluster write (the restore drill) are in the copy-paste lists for the operator.
3. Secrets never enter the repo in clear text and never enter a chat, a log, a PR description or your
   report. Never run `get secret -o yaml|json|jsonpath`. `describe secret` (key names only) is allowed.
   If a command prints a secret, stop and tell the operator. Sealing is done by the operator (or with values he types
   in himself).
4. Do not write IPv4 addresses, MAC addresses, disk serials, `/dev/disk/by-id` names or any host name
   ending in `.ts.net` into any file. Use placeholders (`<tailnet-name>`, `<node-ip>`). The guard
   `.github/scripts/check-no-host-details.sh` rejects them and prints only file and line.
5. One concern per PR. Branch from current `origin/main`: `git fetch origin && git switch -c <branch>
   origin/main`. Open PRs as drafts. Never push to `main`, never force-push, never merge, never delete
   a branch.
6. Before every commit run `bash .github/scripts/run-all-guards.sh`. All 20 lines must be `OK`. Never
   edit a guard to make it pass. Commit messages end with the line
   `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; PR descriptions end with the line
   `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
7. After changing `talos/apps-src/*.yaml` run `talos/render-apps.sh --force` and commit the result under
   `talos/apps/`.
8. Every PVC sets `storageClassName: topolvm-fast` (the cluster has no default class; the template's PVC
   lacks it). Every container sets explicit `resources` (the namespace LimitRange defaults CPU to 500m).
9. Never use a `latest` tag, and never use a moving tag such as `edge` or `nightly`. Pin by digest.
10. STOP conditions (stop, write the report, wait for the operator): a command prints something this plan does
    not predict and the difference matters; a guard fails and you cannot fix it by editing your own files;
    a package depends on a decision in section 5 that the operator has not answered; you would need a cluster
    write; you would need to read or print a secret; the image digest cannot be resolved.
11. Never decide a the operator decision. Where section 5 has a "recommended default", you may only use it if
    the operator said "use the defaults" in writing.
12. If reality differs from this plan, trust what you see, write down the difference, and ask.

## 2. Prerequisites and dependencies

Run each check from the repo root. "Ready" means the output matches. If not, do what the third column says.

| Need | Read-only proof command | If not ready |
|---|---|---|
| Cluster reachable | `kubectl --context admin@<cluster> get nodes` shows `mini01` `Ready` | STOP, tell the operator. |
| Namespace `homeserver` exists | `kubectl --context admin@<cluster> get ns homeserver` | STOP (owned by `talos/manifests/cluster-baseline`). |
| StorageClass | `kubectl --context admin@<cluster> get sc` shows `topolvm-fast` (not default) | STOP. |
| Tailscale operator | `kubectl --context admin@<cluster> -n tailscale get pods` all `Running`; `kubectl --context admin@<cluster> get ingressclass` lists `tailscale` | STOP. |
| Velero nightly schedule | `kubectl --context admin@<cluster> -n velero get schedule` shows `velero-homeserver-nightly` `Enabled` | STOP. |
| Velero node agent on mini01 | `kubectl --context admin@<cluster> -n velero get pods -o wide` shows a `node-agent` pod on `mini01` | STOP: fs-backup of the PVC cannot work. |
| Sealed Secrets controller | `kubectl --context admin@<cluster> -n kube-system get pods` (or `-A \| grep sealed`) shows it `Running` | Only needed for WP4/WP5; STOP those packages if missing. |
| Authentik (WP5 only) [ASSUMED] | namespace `authentik`; `kubectl --context admin@<cluster> -n authentik get pods` all Ready; Service name unknown | WP5 is blocked until the authentik plan is done. |
| Backup restore drill script | `ls talos/dr/velero-restore-drill.sh` exists | STOP (WP3 uses it). |

**What depends on this service:** the `homepage` plan may add a tile for Actual `[ASSUMED]`; nothing else.
The authentik plan may list Actual as an OIDC client (WP5 is the interface).

**Capacity read on 2026-10-25** (`kubectl --context admin@<cluster> top nodes`): mini01 740m CPU (18%),
5077Mi memory (45% of about 11 GiB); mini02 125m CPU, 1193Mi (16%). Re-run in WP1 and quote the new numbers.

## 3. Facts about this service

| Fact | Value | Source |
|---|---|---|
| Image (Docker Hub) | `docker.io/actualbudget/actual-server` | [verified https://actualbudget.org/docs/install/docker] |
| Image (GHCR mirror) | `ghcr.io/actualbudget/actual-server`. The tag `26.10.0` resolves on both registries to the SAME digest `sha256:24645e971da6bb1a1f953d6859e307a0b29be1e8b4130a35b3220c209b5b860c` (checked 2026-10-25 with the registry HTTP API). | [verified https://hub.docker.com/r/actualbudget/actual-server/tags and https://ghcr.io/v2/actualbudget/actual-server/manifests/26.10.0] |
| Current stable tag | `26.10.0` (Debian-based, amd64+arm64, pushed 2026-10-02). Variant `26.10.0-alpine` also exists. Do NOT use `latest`, `edge`, `nightly` (moving, pre-release), or `sha-*`. Use the Debian `26.10.0`. Re-check the newest `NN.NN.N` tag in WP1. | [verified https://hub.docker.com/v2/repositories/actualbudget/actual-server/tags] |
| Digest for the PR | Resolve it again in WP2 (step 1). Because the GHCR mirror exists, `docs/templates/ghcr-app/new-app.sh` can resolve it itself using `ghcr.io/actualbudget/actual-server:26.10.0`. For any other registry, see the fallback command in WP2 step 1. | repo script + above |
| Port | 5006 (`ACTUAL_PORT`, default 5006) | [verified https://actualbudget.org/docs/config/] |
| Data directory | `/data` (`ACTUAL_DATA_DIR`). The server creates `server-files/` (holds `account.sqlite`: hashed server password, list of budgets, session token, and bank-sync secrets) and `user-files/` (budget files as binary blobs). | [verified https://actualbudget.org/docs/install/docker and https://actualbudget.org/docs/config/] |
| Image user | The Dockerfile creates user `actual`, uid/gid 1001, and chowns `/data` to it; the final image has no explicit `USER` line in the repository Dockerfile, so it may run as root by default. The plan therefore sets `runAsUser: 1001`, `runAsGroup: 1001`, `fsGroup: 1001` explicitly. | [verified https://raw.githubusercontent.com/actualbudget/actual/master/sync-server.Dockerfile] |
| Entrypoint | `tini -g -- node build/app.js` | [verified same Dockerfile] |
| Health endpoint | `GET /health` (also `GET /info`) on port 5006, defined in the server's `app.ts` | [verified https://raw.githubusercontent.com/actualbudget/actual/master/packages/sync-server/src/app.ts] |
| Server password | No environment variable in the stable docs. The server asks for it in the browser on first open ("bootstrap"). Stored hashed in `account.sqlite`. | [verified https://actualbudget.org/docs/config/ (no password variable listed); the CLI script below] |
| Password reset CLI | `yarn reset-password` in the sync-server package runs `build/scripts/reset-password.js`; if no password is set it sets one, else it changes it. It prompts interactively. In the container the equivalent is `node build/scripts/reset-password.js` from `/app` `[UNVERIFIED in the container; confirm with step in section 6.4]`. | [verified https://raw.githubusercontent.com/actualbudget/actual/master/packages/sync-server/package.json and .../src/scripts/reset-password.js] |
| Login methods | `ACTUAL_LOGIN_METHOD` (`password` default), `ACTUAL_ALLOWED_LOGIN_METHODS` (default `password,header,openid`) | [verified https://actualbudget.org/docs/config/] |
| Secure context | Actual needs a "Secure Context" and the COOP/COEP headers for `SharedArrayBuffer` (its SQLite engine). The server sets the headers itself; a proxy must not duplicate them or the client fails with `SharedArrayBufferMissing`. | [verified https://actualbudget.org/docs/config/reverse-proxies] |
| Secret files | `ACTUAL_OPENID_CLIENT_SECRET_FILE` and `ACTUAL_GITHUB_TOKEN_FILE` read secrets from a file (works with Kubernetes secret volumes); `_FILE` variables take priority. | [verified https://actualbudget.org/docs/config/] |
| OIDC variables | `ACTUAL_OPENID_DISCOVERY_URL`, `ACTUAL_OPENID_CLIENT_ID`, `ACTUAL_OPENID_CLIENT_SECRET`, `ACTUAL_OPENID_SERVER_HOSTNAME`, optional `ACTUAL_OPENID_AUTHORIZATION_ENDPOINT`, `ACTUAL_OPENID_TOKEN_ENDPOINT`, `ACTUAL_OPENID_USERINFO_ENDPOINT`, `ACTUAL_OPENID_AUTH_METHOD`, `ACTUAL_OPENID_ENFORCE`, `ACTUAL_TOKEN_EXPIRATION`, `ACTUAL_USER_CREATION_MODE`. Redirect URI to register at the provider: `https://<actual-host>/openid/callback`. | [verified https://actualbudget.org/docs/config/oauth-auth] |
| Bank sync providers | Akahu (NZ), Enable Banking (Europe, EXPERIMENTAL: nightly images only), GoCardless BankAccountData (Europe, NOT accepting new accounts since July 2025), SimpleFIN Bridge (North America), Pluggy.ai (Brazil). Provider keys are entered in the Actual UI and stored on the server (in `account.sqlite`), NOT covered by end-to-end encryption. | [verified https://actualbudget.org/docs/advanced/bank-sync, .../gocardless, .../enable-banking] |
| Debug logging | Env `DEBUG`: `actual-sensitive:openid`, `actual-sensitive:bank-sync` (+ provider), `actual-sensitive:server`. These log credentials: only temporarily. | [verified https://actualbudget.org/docs/troubleshooting/server] |
| Memory/CPU | Not documented officially. `[UNVERIFIED]`: expect roughly 100-250 MiB resident at idle for a Node server with a few budgets. WP1 step 6 and the post-deploy check in WP2 measure the real value with `kubectl top pod`; adjust limits in a later PR if it differs. | none |
| Replicas | Exactly 1. SQLite on a RWO volume; never scale. | design |
| End-to-end encryption | Optional, per budget file, set in the app (Settings, Encryption). A key is derived from a second password. Cannot be turned off later. Losing the password with no local copy loses the data. A forgotten key can be reset only if a local copy of the budget still exists (sync reset). | [verified https://actualbudget.org/docs/getting-started/sync] |
| Release notes | Calendar versions `YY.M.N`. Check them before every upgrade. | [verified https://actualbudget.org/docs/releases] |
| Upgrade (docs) | Stop the container, pull the new image, start again with the same `/data` volume. The server runs its own database migrations at start. Shipped migration files are never edited (CI-enforced), and destructive migrations produce a warning in release notes. | [verified https://actualbudget.org/docs/install/docker; https://actualbudget.org/docs/releases (#8446)] |

## 4. Architecture and placement

**Placement: mini01, namespace `homeserver`.** Reasons: it is the only schedulable worker with
spare RAM (about 6 GiB free of about 11 GiB at the reading above); Velero's node agent there is what
backs up `topolvm-fast` volumes; mini02 is cordoned on purpose; mini03 does not exist yet. The app is
tiny, so it does not matter for CPU. If WP1 shows mini01 above 85% memory, STOP and ask the operator (decision
D7).

```
 the operator's phone/laptop (on the tailnet)
        |  HTTPS (valid certificate issued for the tailnet name)
        v
 Tailscale proxy pod (namespace tailscale, created by the operator from the Ingress)
        |  plain HTTP inside the cluster
        v
 Service actual-budget :5006  (ClusterIP, namespace homeserver)
        v
 Pod actual-budget (mini01), 1 replica, strategy Recreate
        |  mounts
        v
 PVC actual-budget-data (topolvm-fast, 2Gi, RWO)  ->  /data
        |   server-files/account.sqlite, user-files/*.blob
        v
 Velero nightly (schedule velero-homeserver-nightly), kopia fs-backup via the pod annotation,
 stored in MinIO on mini02
```

**Why HTTPS matters.** The Actual web client runs its SQLite engine in the browser using
`SharedArrayBuffer`. Browsers only allow that in a secure context (HTTPS, or `localhost`) with the
cross-origin isolation headers. Plain `http://` to a tailnet name or any other address will load the
login page but then fail with a `SharedArrayBufferMissing` error or an "unsupported browser" banner
[verified https://actualbudget.org/docs/config/reverse-proxies]. The Tailscale operator Ingress serves
a valid Let's Encrypt certificate for the tailnet name (HTTPS must be enabled for the tailnet in the
Tailscale admin console, which Immich, Jellyfin and Vaultwarden already rely on; see
`talos/manifests/jellyfin/ingress.yaml`). Therefore no `ACTUAL_HTTPS_*` setting is needed and none must
be set. `[UNVERIFIED]`: that the Tailscale proxy does not add duplicate COOP/COEP headers. It should not
(it proxies unchanged); WP2 verification step checks the headers with `curl -sI` by the operator, and the
troubleshooting table has the symptom.

**Storage.** One PVC `actual-budget-data`, `storageClassName: topolvm-fast`, `ReadWriteOnce`, `2Gi`.
Sizing reasoning: the server stores each budget file as one blob plus the sync change log; a
multi-year personal budget is typically a few MB to tens of MB, and `account.sqlite` is tiny. 2Gi is
generous. Local-path volumes are not size-enforced on this class `[UNVERIFIED: confirm in WP1 with the
existing jellyfin-config PVC, 5Gi, as reference]`; the size is still the request recorded for Velero and
for later migration. Sync reset compresses the budget history (see section 10).

**Resources** (container requests/limits; mini01 reading in section 2):

| | request | limit | Why |
|---|---|---|---|
| CPU | 25m | 500m | Idle is near zero; bursts when a budget file is uploaded or a sync reset runs. 500m equals the namespace default, stated explicitly as required. |
| Memory | 128Mi | 512Mi | Node server plus SQLite; headroom for large budget uploads. `[UNVERIFIED]` see section 3; revise after observing `kubectl top pod`. |
| ephemeral storage | none set | none set | Not used by other apps here. |

**Network.** No NetworkPolicy exists for the namespace today `[UNVERIFIED: WP1 step 7 checks]`; if the
cluster has none, do not add one in this plan (record it under open questions).

## 5. Decisions for the operator

STOP at any package that depends on an unanswered decision. Ask once, collect all answers.

| ID | Question | Options and trade-offs | Recommended default | If decided otherwise |
|---|---|---|---|---|
| D1 | Tailnet device name for the app | `actual` (short, matches `tls.hosts`) / other. A stale device with the same name in the tailnet makes the new one register as `actual-1`. | `actual` | Change `tls.hosts` in WP2 `ingress.yaml`; the URL changes. |
| D2 | PVC size | 1Gi / 2Gi / 5Gi. Bigger costs nothing now on local-path but affects later migration. | 2Gi | Change `storage:` in `pvc.yaml`. |
| D3 | End-to-end encryption of the budget | On: the server (and anyone with the PVC or a Velero backup) cannot read the budget; BUT losing the encryption password loses the data and it cannot be turned off. Off: the server password only protects access; backups contain readable data (still encrypted at rest in MinIO only if the operator configured that; not assumed). Bank-sync secrets are NOT covered by it either way. | On, with the password recorded in Vaultwarden BEFORE enabling | If off, skip section 6.2 and the WP2 the operator step "enable encryption". |
| D4 | Bank sync | (a) None: import OFX/QIF/CSV files by hand: zero infrastructure and zero third-party credentials. (b) Enable Banking (EU, covers Portuguese banks; experimental, needs the nightly image, which this plan refuses to pin; the operator must wait for it in a stable release or accept a nightly pin). (c) GoCardless BankAccountData (EU incl. Portugal; closed to NEW accounts since July 2025, so only works if the operator already has an account). (d) SimpleFIN Bridge: North American banks only, not useful for Portuguese banks. | (a) None for now | WP4 stays skipped. Choose b or c only after the operator confirms his bank is listed by the provider; see WP4. `[UNVERIFIED]`: exact Portuguese bank coverage of each provider; the operator checks the provider's bank list himself. |
| D5 | OIDC login through Authentik | Now/later/never. Server password only is simplest; OIDC gives MFA and removes a shared password but adds a hard dependency on Authentik being up and a sealed client secret. Needs the Authentik plan finished. | Later (WP5 after Authentik is stable) | If never, skip WP5. |
| D6 | Where the operator keeps the credentials | Vaultwarden (deployed on the tailnet) recommended. If Vaultwarden were down, no copy exists; keep an offline copy of the encryption password too. | Vaultwarden plus a paper or offline copy of the encryption password | None for the plan. |
| D7 | Placement if mini01 is more than 85% memory used at WP1 time | Stay on mini01 / move to mini03 when it exists (`nodeSelector: kubernetes.io/hostname: mini03`, PVC re-created there, data restored from Velero). | Stay on mini01 | WP2 `nodeSelector` changes; STOP and ask. |
| D8 | Velero retention for this PVC | Inherits the nightly schedule's retention (see WP1 step 5). Ask only if retention is shorter than 30 days. | Inherit | A dedicated schedule is a separate PR, not in this plan. |

## 6. Credentials and secret handling

### 6.1 Inventory

| # | Credential | What it is | Created by / how | Secret name, key | Sealed file | How the app receives it | Where first set / discovered |
|---|---|---|---|---|---|---|---|
| C1 | Actual server password | The one login password for the whole server (hashed in `account.sqlite`) | The operator, in the browser, on first open. Generate: `openssl rand -base64 24 \| pbcopy`, paste into the browser field, then store in Vaultwarden. | None. Not a Kubernetes Secret. No env var exists for it. | none | Entered via the web UI; stored hashed in the PVC | "Password discovery" in 6.3 |
| C2 | Budget end-to-end encryption password | Separate password that derives the key encrypting one budget file; set per budget | The operator, in the app (Settings, Encryption, Enable). Generate: `openssl rand -base64 24 \| pbcopy`. | None | none | Entered in the browser on each new device; never reaches the server | 6.2 |
| C3 | Bank-sync provider credentials (only if D4 is b/c) | Provider application ID/key file, secret ID/key, and account tokens | The operator, at the provider's site | None required: entered in the Actual UI (More, Bank Sync), stored on the server in `account.sqlite` [verified https://actualbudget.org/docs/advanced/bank-sync] | none | UI | WP4 |
| C4 | OIDC client secret (only if D5 is yes) | Client secret of an Authentik OAuth2/OpenID provider for Actual | The operator creates the provider in Authentik; Authentik generates the client secret | Secret `actual-budget-secrets`, key `ACTUAL_OPENID_CLIENT_SECRET` | `talos/sealed-secrets/actual-budget-secrets.yaml` | `envFrom` the Secret (or the `_FILE` variant, see WP5) | WP5 |
| C5 | OIDC client ID, discovery URL, server hostname (only D5) | Not secret in principle, but they contain the full tailnet name or Authentik host name (guard) | The operator at sealing time | Secret `actual-budget-secrets`, keys `ACTUAL_OPENID_CLIENT_ID`, `ACTUAL_OPENID_DISCOVERY_URL`, `ACTUAL_OPENID_SERVER_HOSTNAME` | same file | `envFrom` | WP5 |
| C6 | Velero/MinIO credentials | Used by Velero, not by this app | Already exist (`velero-cloud-credentials`) | n/a | `talos/sealed-secrets/velero-cloud-credentials.yaml` | n/a | n/a |

Rationale for "no Secret in WP2": the stable server has no variable for the server password, and the
app needs no API key, so the first deployment has NO sealed Secret. The Deployment still carries an
`envFrom` with `optional: true` so WP5 only adds the sealed file.

**Where full host names go.** The guard rejects `*.ts.net` in files. Anything needing the full tailnet
name (`ACTUAL_OPENID_SERVER_HOSTNAME`, the Enable Banking redirect URL) is never written in a plain file:
it is a key of the sealed Secret (ciphertext is allowed) or typed into a provider's web console by the operator.

### 6.2 Budget encryption password (C2): mandatory instructions for the operator

Tell the operator before WP2 is merged, and again in the WP2 report:
1. Decide D3. If encryption is on, generate the password with `openssl rand -base64 24 | pbcopy`
   (it goes to the clipboard, not the screen).
2. Open Vaultwarden and create an entry "Actual Budget encryption password" and paste. Save it. Only
   then enable encryption in Actual (Settings, Show advanced settings, Encryption).
3. Also keep an offline copy (printed or on an encrypted USB stick not on mini01).
4. Know the consequences: no recovery by the operator or by Velero; a Velero restore restores the encrypted
   file, which is useless without the password [verified https://actualbudget.org/docs/getting-started/sync].
   Enabling encryption triggers a sync reset on the server.
5. This password is different from C1. They must not be the same.

If C2 is lost but a device still holds a local, decrypted copy of the budget: open it there, Settings,
Encryption, reset the key (sync reset, new password). If no local copy exists: the data is lost; restore
from an earlier Actual export (see section 8) that was taken unencrypted.

### 6.3 Password discovery (C1)

- Fresh server (no password yet): opening the URL shows a page that asks to "choose a password"
  (the bootstrap). Whatever the operator types becomes the server password. There is no generated default and
  nothing in the pod logs. Therefore: the first person who opens the URL sets the password. Because the
  URL is tailnet-only, this is acceptable, but the operator should do it immediately after the sync.
- If the page instead shows a login box, a password already exists (for example data restored from a
  backup): use the password from that time, from Vaultwarden.
- Where set: the browser UI. Change later: Settings (in a open budget), "Change server password"
  `[UNVERIFIED]`: confirm the exact menu label in the running version; the server API
  `change-password` is used by that screen. If the label differs, use 6.4.
- How the operator retrieves it later: it is not in the cluster. He reads it from Vaultwarden. No kubectl
  command can show it (it is hashed). Do not tell the executor to look for it.
- What breaks if lost: nobody can sign in to the server; budgets stay on the PVC and in each device's
  local copy. Use 6.4.
- Rotate: change it in the UI (if the menu exists) or reset with 6.4; update Vaultwarden.

### 6.4 Lost server password: recovery procedure (The operator performs; executor writes it into the PR text)

The documented tool is the server's `reset-password` script, which prompts for a new password and, if
a password already exists, replaces it [verified
https://raw.githubusercontent.com/actualbudget/actual/master/packages/sync-server/src/scripts/reset-password.js].
It needs an interactive terminal inside the pod, which is a cluster `exec`, so it is a the operator action
(`exec` of a state-changing command is not allowed to the executor):

```
kubectl --context admin@<cluster> -n homeserver exec -it deploy/actual-budget -- node build/scripts/reset-password.js
```

Expected: the line "It looks like you already have a password set. Let's reset it!", a hidden prompt
for the new password, then `Password changed!`. The working directory of the container is `/app`; if
Node says the file is not found, list `/app/build/scripts` with `kubectl ... exec deploy/actual-budget -- ls
build/scripts` (read-only) and use the real file name. This is `[UNVERIFIED]` inside the 26.10.0 image
until WP1/WP3 confirms the path with that read-only `ls`.
Fallback if the script cannot run: STOP and ask the operator. Do not edit `account.sqlite` on the live volume and do not guess its schema `[UNVERIFIED]`; a restored scratch copy (WP3) can be used to inspect state safely.
After resetting, the operator stores the new password in Vaultwarden. Other devices keep working until their
token expires, then ask for the password.

### 6.5 Sealing (WP4/WP5 only)

`docs/templates/ghcr-app/seal-secret.sh actual-budget KEY...` creates `actual-budget-secrets` in
namespace `homeserver`, key per variable. It prompts for values with echo off. Never run it for WP2.

## 7. Work packages

Package order: WP1 audit, WP2 deploy, WP3 backup/restore drill docs and checks, WP4 bank sync (optional),
WP5 OIDC (optional). Branch names: `feat/actual-budget`, `docs/actual-budget-backup`, etc.

### WP1: read-only audit (no PR, report only)

Goal: confirm the facts in sections 2 to 4 still hold. No repository change.
Preconditions: none. Branch: none.

1. Read `docs/templates/ghcr-app/README.md`, `new-app.sh`, `seal-secret.sh`, the `*.tmpl` files and
   `talos/manifests/jellyfin/{deployment,pvc,service,ingress,kustomization}.yaml`. Why: conventions.
2. `gh pr list --state all --limit 40` and look for an existing `actual-budget` PR or branch.
   `ls talos/manifests talos/apps-src | grep -i actual` must print nothing. If it prints something, STOP.
3. `kubectl --context admin@<cluster> top nodes`. Quote the output in the report. If mini01 memory
   is above 85%, STOP (decision D7).
4. `kubectl --context admin@<cluster> get sc` shows `topolvm-fast`. `kubectl --context admin@<cluster> get pvc -A` shows the reference PVCs (jellyfin-config 5Gi etc.).
5. Backups: `kubectl --context admin@<cluster> -n velero get schedule velero-homeserver-nightly -o yaml`
   (a Schedule object holds no secrets). Record `spec.schedule`, `spec.template.ttl`,
   `includedNamespaces`, and whether `defaultVolumesToFsBackup` is absent. Expected: schedule `0 10 * * *`,
   namespace `homeserver`, `defaultVolumesToFsBackup` absent, so the PVC needs the pod annotation
   `backup.velero.io/backup-volumes: data` (the annotation name used by `talos/values/velero.yaml` and
   `talos/test/backup-lib.sh`). If `defaultVolumesToFsBackup: true` is set, the annotation is harmless;
   report the difference.
6. `kubectl --context admin@<cluster> -n homeserver get pods -o wide` and
   `kubectl --context admin@<cluster> -n homeserver top pods` to see the real footprint of neighbours.
7. `kubectl --context admin@<cluster> get networkpolicy -A` (record result; if none, note it).
8. Verify the version tag is still the newest stable: run
   `curl -s "https://hub.docker.com/v2/repositories/actualbudget/actual-server/tags?page_size=100&name=2" | jq -r '.results[].name' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -3`.
   Expected: `26.10.0` or a newer `YY.M.N`. If newer, read its release notes at
   https://actualbudget.org/docs/releases for breaking changes and report to the operator before using it; if
   unsure use `26.10.0`.
9. Confirm the image's default user and the reset script path read-only from the Dockerfile at the
   tag: `curl -sL https://raw.githubusercontent.com/actualbudget/actual/v26.10.0/sync-server.Dockerfile | grep -nE 'USER|CMD|EXPOSE'`. Record the output; note if a `USER` line exists
   (if it names a different uid than 1001, STOP and ask).
10. Confirm Argo and sealed-secret names: `grep -n "actual" talos/test/empty-cluster-expectations.txt` prints nothing.
11. Report using the section 11 format. STOP: wait for the operator's answers to D1 to D3 (and D4 to D6 can wait).

Rollback: nothing changed.

### WP2: deploy Actual Budget

Goal: manifests, Argo app, expectations line, so that after merge and sync the server runs.
Branch: `feat/actual-budget`. Preconditions: WP1 approved; D1, D2 answered.

Step 1. Create the branch: `git fetch origin && git switch -c feat/actual-budget origin/main`.

Step 2. Generate the skeleton with the template (it resolves the digest from GHCR and adds the
expectations line):
```
docs/templates/ghcr-app/new-app.sh actual-budget ghcr.io/actualbudget/actual-server:26.10.0 5006
```
Expected output: `resolved ghcr.io/actualbudget/actual-server:26.10.0 to sha256:<64 hex>` (it should equal
`24645e971da6bb1a1f953d6859e307a0b29be1e8b4130a35b3220c209b5b860c`; if different, report it, use what the
registry returns, and cross-check with the Docker Hub command below), then `created talos/manifests/actual-budget/ and talos/apps-src/actual-budget.yaml`.
Fallback if the script cannot resolve: pass the digest as the 4th argument. For a Docker Hub image the
read-only registry query is:
```
TOKEN=$(curl -s 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:actualbudget/actual-server:pull' | jq -r .token)
curl -sI -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
  https://registry-1.docker.io/v2/actualbudget/actual-server/manifests/26.10.0 | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}'
```
It must print `sha256:` followed by 64 hex characters. Why this matters: the digest pins the exact image.

Step 3. Overwrite the generated files with these exact contents (the template data path and PVC class
are wrong for this cluster). Replace `<DIGEST>` with the 64 hex characters (no `sha256:` prefix is
included in the placeholder; keep `@sha256:` in the file). If you used the script's digest, leave that line as generated.

`talos/manifests/actual-budget/deployment.yaml`:
```yaml
# Actual Budget (actual-server) on mini01. One replica, Recreate: the data is SQLite on a RWO volume,
# never scale it. Pinned by digest; the tag stays in the comment.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: actual-budget
  labels:
    app.kubernetes.io/name: actual-budget
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: actual-budget
  template:
    metadata:
      labels:
        app.kubernetes.io/name: actual-budget
      annotations:
        # Velero opt-in: back up the pod volume named `data` with file-system backup (kopia).
        backup.velero.io/backup-volumes: data
    spec:
      nodeSelector:
        kubernetes.io/hostname: mini01
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        runAsGroup: 1001
        fsGroup: 1001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: actual-budget
          image: ghcr.io/actualbudget/actual-server@sha256:<DIGEST> # 26.10.0
          ports:
            - name: http
              containerPort: 5006
          # No Secret yet: the server password is set in the browser. WP5 (OIDC) adds the sealed
          # Secret actual-budget-secrets; `optional: true` lets the pod start without it.
          envFrom:
            - secretRef:
                name: actual-budget-secrets
                optional: true
          env:
            - name: ACTUAL_DATA_DIR
              value: /data
            - name: ACTUAL_PORT
              value: "5006"
          resources:
            requests:
              cpu: 25m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          readinessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 30
            periodSeconds: 30
          startupProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 5
            failureThreshold: 36
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: actual-budget-data
```
Why `readOnlyRootFilesystem` is not set: Node, the server and its migrations may write outside `/data`
`[UNVERIFIED]`. Try it in a later PR after the operator sees the pod healthy (section 9).

`talos/manifests/actual-budget/pvc.yaml`:
```yaml
# Actual's data: server-files/account.sqlite (hashed server password, budget list, bank-sync secrets)
# and user-files/ (budget blobs). The class is named explicitly: the cluster has no default class.
# Velero covers it through the pod annotation in deployment.yaml (daily, namespace homeserver).
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: actual-budget-data
  labels:
    app.kubernetes.io/name: actual-budget
spec:
  storageClassName: topolvm-fast
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 2Gi
```

`talos/manifests/actual-budget/service.yaml`: the generated one is correct (name `actual-budget`, port
5006, `targetPort: http`). Do not change it.

`talos/manifests/actual-budget/ingress.yaml` (D1 default `actual`):
```yaml
# Actual Budget on the tailnet only, served by the Tailscale operator. The hostname is tls.hosts;
# the full tailnet name is a host detail and is not committed. HTTPS is mandatory for this app: the
# browser needs a secure context for SharedArrayBuffer. A stale `actual` device in the tailnet makes
# the new one register as `actual-1`: delete the stale device in the Tailscale admin console first.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: actual-budget
  labels:
    app.kubernetes.io/name: actual-budget
spec:
  ingressClassName: tailscale
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: actual-budget
                port:
                  number: 5006
  tls:
    - hosts:
        - actual
```
This is the same form as `talos/manifests/jellyfin/ingress.yaml`.

`talos/manifests/actual-budget/kustomization.yaml`: the generated one is correct (namespace
`homeserver`; resources deployment, service, pvc, ingress). Do not change it.

Step 4. Edit `talos/test/empty-cluster-expectations.txt`: the script appended a line
`actual-budget *       *       # manual sync; GHCR image app, needs its sealed actual-budget-secrets`.
Rewrite its comment so it is true: `# manual sync; no Secret until the OIDC step`. Keep the columns.

Step 5. Run `talos/render-apps.sh --force`. Expected: it creates `talos/apps/actual-budget.yaml` and
changes nothing else. Check `git status --short` lists exactly: `talos/apps-src/actual-budget.yaml`,
`talos/apps/actual-budget.yaml`, `talos/manifests/actual-budget/*` (4 files), and
`talos/test/empty-cluster-expectations.txt`. Anything else: STOP.

Step 6. Dry-validate: `kubectl kustomize talos/manifests/actual-budget` (client-side only, no cluster
write). Expected: four objects (Deployment, Service, PersistentVolumeClaim, Ingress), all with namespace
`homeserver`.

Step 7. `bash .github/scripts/run-all-guards.sh`: all 20 `OK`.

Step 8. Commit: `feat: Actual Budget on mini01 (tailnet only, topolvm-fast PVC, Velero opt-in)` plus the
Co-Authored-By line. Push the branch and open a DRAFT PR.

PR title: `feat: Actual Budget (actual-budget app)`. PR description:
```
Adds the Argo app `actual-budget` (manual sync): actualbudget/actual-server 26.10.0 pinned by digest,
one replica on mini01, PVC actual-budget-data (topolvm-fast, 2Gi), tailnet-only HTTPS Ingress `actual`.
Velero: the pod carries backup.velero.io/backup-volumes: data, so the nightly homeserver backup
includes /data. No Secret in this PR: the server password is set in the browser on first open.

After merging, the operator:
1. In the Tailscale admin console delete any stale device named `actual`.
2. In Argo sync `actual-budget`. Watch: PVC Bound (first consumer binds it), pod 1/1 Running.
3. Open https://actual.<tailnet-name> and choose the server password (generate with
   `openssl rand -base64 24 | pbcopy`, store in Vaultwarden first).
4. If using end-to-end encryption: record its password in Vaultwarden BEFORE enabling it.
5. Create a test budget with a few fake transactions.

Not covered: bank sync (decision D4), OIDC (D5).
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

Verification after the operator syncs (executor, read-only):
- `kubectl --context admin@<cluster> -n homeserver get pvc actual-budget-data` → `Bound`, class `topolvm-fast`.
- `kubectl --context admin@<cluster> -n homeserver get pods -l app.kubernetes.io/name=actual-budget -o wide` → `1/1 Running`, node `mini01`.
- `kubectl --context admin@<cluster> -n homeserver logs deploy/actual-budget --tail=30` → the server
  listening on port 5006 and no error lines (the exact wording `[UNVERIFIED]`).
- `kubectl --context admin@<cluster> -n homeserver top pod -l app.kubernetes.io/name=actual-budget` → record memory; if above 400Mi at idle, report (limit 512Mi).
- `kubectl --context admin@<cluster> -n homeserver get ingress actual-budget` → an address column filled in; `kubectl --context admin@<cluster> -n tailscale get pods` shows a new proxy pod for the ingress.
- operator-only (browser and terminal on a tailnet device): `curl -sI https://actual.<tailnet-name>/health` returns `200`; the same `curl -sI` on `/` shows `cross-origin-embedder-policy` and `cross-origin-opener-policy` ONCE each (duplicates would break SharedArrayBuffer).
- `kubectl --context admin@<cluster> -n homeserver exec deploy/actual-budget -- ls /data` → shows `server-files` and `user-files` after first use (read-only command).

Rollback: revert the PR; the operator syncs `actual-budget` (manual sync does not prune a deleted Application
resource automatically; the operator deletes the Argo app and the PVC himself in the Argo UI if he really wants
the data gone; the PVC has reclaim `Retain`, so the volume data stays on mini01 until removed by hand).

STOP point: report, wait for the operator to confirm he can open the app and sign in.

### WP3: backup coverage proof and restore drill

Goal: prove that the PVC is in Velero backups and that a restored copy opens. Branch:
`docs/actual-budget-backup` only if a doc change is needed; otherwise no PR. Preconditions: WP2 done, at
least one nightly backup has run AFTER the operator created the test budget (nightly at 10:00 UTC).

Executor read-only steps:
1. `kubectl --context admin@<cluster> -n velero get backups --sort-by=.metadata.creationTimestamp | tail -3`
   → newest `velero-homeserver-nightly-<timestamp>` with `Completed`. Note the name `<BACKUP>`.
2. `kubectl --context admin@<cluster> -n velero get podvolumebackups -l velero.io/backup-name=<BACKUP>`
   → a row for pod `actual-budget-...`, volume `data`, status `Completed`. If there is no row:
   the annotation did not apply. Check `kubectl --context admin@<cluster> -n homeserver get pod -l app.kubernetes.io/name=actual-budget -o jsonpath='{.items[0].metadata.annotations}'` (annotations
   are not secret) contains `backup.velero.io/backup-volumes`. If it does not, the Deployment annotation
   is on the wrong level (must be under `spec.template.metadata`); fix in a new PR.
3. Read `talos/dr/velero-restore-drill.sh --help` and `docs/dr/talos-backups.md` section "Restore drill".

Copy-paste list for the operator (the restore drill writes to the cluster, so only he runs it):
```
# 1. Restore the newest nightly backup into the scratch namespace restore-drill (never the live one)
talos/dr/velero-restore-drill.sh --backup <BACKUP> --live admin@<cluster> \
  --source-ns homeserver --target-ns restore-drill --pvc actual-budget-data \
  --sqlite server-files/account.sqlite
# expected: FILES and BYTES lines, "SQLITE integrity_check ok", then DRILL PASS
# 2. Open the restored data in a scratch copy of the app. The drill's allow-list excludes services and
#    ingresses on purpose, so use a port-forward to the restored Deployment (it restores workloads):
kubectl --context admin@<cluster> -n restore-drill get pods
kubectl --context admin@<cluster> -n restore-drill port-forward deploy/actual-budget 5006:5006
# 3. In a browser open http://localhost:5006 (localhost counts as a secure context, so Actual works),
#    sign in with the server password from Vaultwarden, open the test budget (enter the encryption
#    password if enabled), and check the fake transactions are there.
# 4. Clean up: stop the port-forward (Ctrl-C), then delete the scratch namespace
kubectl --context admin@<cluster> delete namespace restore-drill
```
`[UNVERIFIED]`: the exact flags of the drill script (read its header: shown above in `--help`/source
comment) and whether the drill's restored Deployment starts (it needs the node and image; Velero
restores the pod with the same node selector). If the restored pod cannot start (for example the
Tailscale Ingress is excluded, which is intended), report; this is acceptable only if the SQLITE check
passes AND the operator can still open the budget in a different way (see 8.4).
STOP: The operator states the result of step 3.

### WP4: bank sync (OPTIONAL, only after D4 is b or c; infrastructure only)

Goal: make bank sync possible; Actual itself does not need new Kubernetes objects. Preconditions: D4
answered with a provider and the operator confirmed his bank is supported by that provider.

Findings that shape the work [verified https://actualbudget.org/docs/advanced/bank-sync]:
- Provider keys are typed into the Actual UI (More, Bank Sync, Set up <provider>) and stored on the
  server in `account.sqlite`, therefore on the PVC and in the Velero backups. They are NOT a Kubernetes
  Secret and NOT sealed. So no sealed file is created for them; the plan's "sealed secret keys" idea does
  not apply to the stable docs. `[UNVERIFIED]`: some providers may also accept environment variables;
  none are documented on https://actualbudget.org/docs/config/ at the verification date.
- Enable Banking (Europe, experimental) is only in nightly images and needs a redirect URL
  `https://<actual-host>/enablebanking/auth_callback` registered in the provider console: The operator types the
  real host in the console; it is never committed.
- GoCardless is closed to new accounts (existing accounts still work).
- SimpleFIN covers North America only.
- Egress: the pod must reach the provider's HTTPS API (outbound internet). The cluster has no NetworkPolicy
  recorded in WP1 step 7; if it does, WP4 adds an egress rule in a PR.
- Security consequence: end-to-end encryption does NOT protect the provider tokens; anyone with the
  PVC or a Velero restore can read them. The operator accepts this by choosing D4 b/c.

Steps for the executor: (1) WP1-style re-check of egress: `kubectl --context admin@<cluster> -n homeserver exec deploy/actual-budget -- node -e "fetch('https://example.org').then(r=>console.log(r.status))"` (read-only network check; expected `200`). (2) If the chosen provider is Enable Banking and the image must be a nightly: STOP and ask the operator (rule 9 forbids moving tags; a pinned `sha-<hash>` or dated nightly digest is a the operator decision). (3) Write the the operator copy-paste list in the PR text: create provider account, copy IDs, open Actual, More, Bank Sync, paste into the dialog, link accounts, choose automatic sync frequency (every 12 hours/day/week; only while Actual is open) [verified same page], store provider credentials in Vaultwarden. (4) Troubleshooting: temporarily set `DEBUG=actual-sensitive:bank-sync,actual-sensitive:<provider>` via a PR, remove after use (sensitive logs hold credentials).

No code change is needed unless the egress policy requires it. Rollback: in the UI, remove the bank link and
delete the provider keys; revoke them at the provider.

### WP5: OIDC login through Authentik (OPTIONAL, after D5 = yes)

Goal: sign in to Actual with Authentik. Branch `feat/actual-budget-oidc`. Preconditions: Authentik
healthy `[ASSUMED]` in namespace `authentik`; its plan provides an OAuth2/OpenID provider for Actual;
The operator gives the client ID and secret; Authentik's discovery URL (contains its full host name).
Reminder from the docs: with OIDC enabled, the server password can still be used as long as
`ACTUAL_ALLOWED_LOGIN_METHODS` includes `password`; do NOT set `ACTUAL_OPENID_ENFORCE=true` until a
full test passes and the password is recorded, otherwise a broken Authentik locks the operator out
[verified https://actualbudget.org/docs/config/oauth-auth for the variable names; behaviour of ENFORCE
`[UNVERIFIED]`: read the page text for `ACTUAL_OPENID_ENFORCE` before using].

Steps:
1. The operator creates in Authentik an OAuth2/OpenID provider and application named `actual`, with redirect URI
   `https://actual.<tailnet-name>/openid/callback` (typed by the operator), and copies client ID and secret.
2. The operator seals (the executor prepares the exact command; the operator runs it):
```
docs/templates/ghcr-app/seal-secret.sh actual-budget \
  ACTUAL_OPENID_DISCOVERY_URL ACTUAL_OPENID_CLIENT_ID ACTUAL_OPENID_CLIENT_SECRET ACTUAL_OPENID_SERVER_HOSTNAME
```
   Values: discovery URL as given by Authentik (`.../.well-known/openid-configuration`), client ID, client
   secret, server hostname `https://actual.<tailnet-name>`. Expected output:
   `sealed .../talos/sealed-secrets/actual-budget-secrets.yaml (4 keys) and listed it in ...kustomization.yaml`.
   The file lands in `talos/sealed-secrets/`; the Deployment already has `envFrom` with the optional
   Secret, so no Deployment change is needed.
3. Executor: `bash .github/scripts/run-all-guards.sh`; commit the sealed file and the kustomization line only.
   PR title `feat: Actual Budget OIDC secret`.
4. After merge, `talos-sealed-secrets` syncs by itself. A Secret change does not restart the pod: The operator
   restarts it via a PR (bump an annotation) or by deleting the pod in the Argo UI (Argo "restart"/delete of
   the pod is allowed for the operator). Verify (read-only): `kubectl --context admin@<cluster> -n homeserver describe secret actual-budget-secrets` lists the four key names (no values).
5. The operator opens the login page: it should now offer the OpenID option. Test with `ACTUAL_USER_CREATION_MODE`
   unset first. Record the OIDC provider info in Vaultwarden.

Rollback: remove the sealed file line from `talos/sealed-secrets/kustomization.yaml` (Argo prune is OFF,
so the operator deletes the Secret in the Argo UI as well) and restart the pod; the server password still works.

## 7a. Coverflex meal-card importer (OPTIONAL, added to the same PR; the operator runs every step)

What it is: `actual-mealcards` (github.com/rodriguestiago0/actual-mealcards), pinned `1.0.43` by digest, in
`talos/manifests/actual-budget/mealcards.yaml`. Every 4 hours it logs in to Coverflex and imports new
transactions into one Actual account. Coverflex only; Edenred is switched off. It ships at **0 replicas**
because it cannot start without the Secret and the two ids below.

Risks, read before enabling:

- It is unofficial: it logs in the way the Coverflex phone app does. If Coverflex changes that, the importer
  stops until the project updates. Nothing else in the cluster depends on it.
- The login token expires. In the last 30 days the importer logs a warning (and, once a notification address
  is set, a reminder). When it expires, repeat steps 6 to 8 below.
- The pod holds your Coverflex email, password and token. They live only in the sealed Secret.
- Failure messages (`NOTIFICATION_URL`) need an alert channel, which does not exist yet (see the monitoring
  plan). Until then, check `kubectl -n homeserver logs deploy/actual-mealcards` now and then.
- The image comes from Docker Hub, maintained by one person. Its Dockerfile runs `node index-cron.js` as the
  `node` user. Read the project's code once before enabling it. `[UNVERIFIED]` who maintains it long term.

Steps, in order:

1. Merge the PR and sync `actual-budget` in Argo. Do the normal Actual first-run steps (WP2) and confirm the
   budget works. The importer pod stays at 0.
2. In Actual, create the account that will hold the card (for example "Coverflex meals"), an on-budget or
   off-budget account as you prefer. Do not enter transactions by hand.
3. Copy the account id: open the account in Actual; the long id is in the browser address bar. That is
   `COVERFLEX_ACTUAL_ACCOUNT`.
4. Find the budget's Sync ID: Actual, Settings, Advanced settings, "Sync ID". Keep it for step 7.
5. Opening balance: the importer does not set one. Add one transaction by hand, dated before the first
   imported one, for the balance the card had then. Also decide `COVERFLEX_IMPORT_FROM` if you do not want the
   whole history (default: everything).
6. Create the Coverflex token once, on your Mac (it asks for the one-time code Coverflex sends you):
   ```
   read -rs COVERFLEX_PASSWORD; export COVERFLEX_PASSWORD
   export COVERFLEX_USERNAME='<your Coverflex email>'
   docker run -it --rm -e COVERFLEX_USERNAME -e COVERFLEX_PASSWORD \
     docker.io/rodriguestiago0/actual-mealcards@sha256:89243a4eb9ed9a8a3c57c003ff3f25fba2d5b7add99d7fe26aa468228d4d03eb \
     node index.js get-coverflex-token
   ```
   It prints a token. Copy it to a safe place (Vaultwarden); do not paste it into the repo or a chat.
7. Seal the credentials (asks for each value with input hidden; the certificate comes from the live cluster):
   ```
   bash talos/scripts/seal-actual-mealcards.sh
   ```
   Values: the Actual server password, the Sync ID, the Coverflex email, password and token, and the budget's
   encryption password only if you turned on end-to-end encryption (otherwise press Enter to skip it).
8. In a PR, set the two ids in `actual-mealcards-config` (`COVERFLEX_ACTUAL_ACCOUNT` from step 3 and
   `COVERFLEX_ACCOUNT`, the Coverflex pocket id of the meal card; `[UNVERIFIED]` where the app shows it, the
   project README only names it `pocket_id`), set `replicas: 1`, and commit the sealed file with the script's
   one-line kustomization change. After the merge, sync `talos-sealed-secrets`, then `actual-budget`.
9. Check, without waiting 4 hours: `kubectl --context admin@<cluster> -n homeserver exec deploy/actual-mealcards -- node index.js import-coverflex --dry-run`
   first (preview only, saves nothing), then the same without `--dry-run` once the preview looks right.
10. Calendar a reminder for about a month before the token expires, and repeat steps 6, 7 and 8 then.

Rollback: set `replicas: 0` in a PR and sync. Transactions already imported stay in Actual.

### 7b. Hardening of the importer, and what is NOT enforced

The importer holds the Actual server password and the Coverflex login and token. What a compromised one could do:
read, edit or delete the whole budget; read the Coverflex account (the token skips the one-time code); send data
anywhere on the internet. It has no host access and no cluster permissions.

Done in this PR:

- `automountServiceAccountToken: false` on the importer and on Actual: neither talks to the Kubernetes API, so no
  API token is mounted into either pod. **Enforced** by Kubernetes.
- A ready-to-use `NetworkPolicy` (below), deliberately NOT in the kustomization: it would be ignored today, and the
  repo guards (`check-talos.sh` rule h, `check-no-host-details.sh`, the offline guard self-test) forbid the private
  address ranges it must spell out anywhere under `talos/`. When a policy controller is added, the guards need a
  deliberate exemption for these fixed ranges, and the policy moves into `mealcards.yaml`.

**Network policy: not enforced yet.** The cluster's network layer is flannel alone (`kube-flannel` with
`--ip-masq --kube-subnet-mgr`, plus `kube-proxy`), read live on 2026-11-07. Flannel does not implement
NetworkPolicy and no policy controller runs in `kube-system`, so the policy above is accepted and then ignored. The
only other NetworkPolicies in the cluster are 4 from the Argo CD chart, which are ignored the same way.

Limits of the rule even once enforced: a NetworkPolicy cannot match DNS names, so "Coverflex" is approximated by
"HTTPS to any public address". A compromised importer could still send data to any public HTTPS server. Only an egress
proxy or a DNS-aware policy (for example Cilium FQDN rules) closes that, and it is out of scope here.

The policy, for the day it can be enforced (no ingress; egress to DNS, the Actual pod on 5006, and HTTPS to public
addresses only):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: actual-mealcards, namespace: homeserver }
spec:
  podSelector: { matchLabels: { app.kubernetes.io/name: actual-mealcards } }
  policyTypes: [Ingress, Egress]
  ingress: []
  egress:
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
          podSelector: { matchLabels: { k8s-app: kube-dns } }
      ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]
    - to:
        - podSelector: { matchLabels: { app.kubernetes.io/name: actual-budget } }
      ports: [{ protocol: TCP, port: 5006 }]
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [<the three RFC 1918 private ranges>, <the CGNAT range Tailscale uses>, <link-local>]
      ports: [{ protocol: TCP, port: 443 }]
```

Smallest fix, as a separate change (not in this PR; it changes cluster networking and needs its own rehearsal):

1. Add **kube-router in firewall-only mode** next to flannel (`--run-firewall=true --run-router=false
   --run-service-proxy=false`). It enforces NetworkPolicy and leaves flannel and kube-proxy alone. `[UNVERIFIED]`
   Talos documents this combination, but the exact image tag, flags and Talos privileges must be checked against
   the Talos 1.14 docs before use.
2. Roll it out on one node first, check that DNS, Ingress, Velero and Argo traffic still work, then apply the
   policies. Test by running a pod with the importer's labels and confirming a request to another service fails.
3. The heavier alternative is replacing the CNI with Cilium: it also gives DNS-aware rules, but it is a cluster-wide
   network change. Not recommended for this alone.

Also consider: a separate Coverflex password if the account allows one, and reading the importer's source before the
first run (the project is a one-maintainer repo with 18 stars on 2026-11-07).

## 8. Backup and restore

| What | Mechanism | Covered? |
|---|---|---|
| `/data` (account.sqlite, user-files blobs) | Velero nightly (`velero-homeserver-nightly`, 10:00 UTC, namespace `homeserver`), file-system backup because the pod annotation `backup.velero.io/backup-volumes: data` is present | Yes, once the pod has run and the backup finished |
| Budget content in readable form | Actual's own export (Settings, Export data: a zip of the budget; the operator does this monthly and before every upgrade and stores it in Vaultwarden attachments or on the NAS) | Manual, by the operator |
| Encryption password and server password | Vaultwarden | Manual, by the operator |
| Bank-sync tokens | Inside `/data/server-files/account.sqlite`, so part of the Velero backup; NOT end-to-end encrypted | Yes, by Velero |
| Deployment/Ingress manifests | Git | Yes |
| mini03 second copy | PR #71 (planned) | Not yet |

**Consistency note.** SQLite is written in WAL mode `[UNVERIFIED]`; kopia reading the live files may
capture them mid-write. The CI roundtrip proves WAL-mode SQLite restores correctly
(`talos/test/jobs/velero-roundtrip.sh`, [verified docs/dr/talos-backups.md]). The budget is also stored on
every device's local copy and in the Actual export, which are the second line of defence. Because the
risk is not zero, the monthly export is a requirement, not an option.

**8.4 Restore test (written by the executor in WP3, performed by the operator).** The test in WP3 restores the
nightly backup into `restore-drill`, checks `PRAGMA integrity_check` on `account.sqlite`, and opens the
budget through a port-forward. A cheaper alternative if the restored Deployment does not start: The operator
imports a fresh Actual export into a local Actual (Docker or the desktop client) and confirms it opens.
Do the full drill once after WP2, and once after each major version upgrade.

**Real restore of the live app (disaster).** the operator, not the executor: delete the Argo app resources for
`actual-budget` (keep the Application), run `velero restore create --from-backup <BACKUP> --include-namespaces
homeserver --selector app.kubernetes.io/name=actual-budget` (adapt per `docs/dr/talos-backups.md`), then
sync the app and open it. Use the password from Vaultwarden.

## 9. Security

- Exposure: tailnet only, through the Tailscale operator Ingress. No LoadBalancer, no NodePort, no
  hostPort, no public hostname. Tailscale ACLs decide who on the tailnet may reach `actual`.
- Authentication: server password (hashed) now; OIDC through Authentik later (WP5). Do NOT use
  `ACTUAL_LOGIN_METHOD=header` (it trusts an HTTP header and is unsafe without a trusted auth proxy)
  [verified https://actualbudget.org/docs/config/]. First-open race: whoever opens the URL first sets the
  password; the URL is tailnet-only, and the operator sets it immediately after sync.
- Data at rest: PVC on mini01 disk (is the disk encrypted? Talos LUKS state `[UNVERIFIED]`: see
  `docs/dr/mini02-talos.md` / the mini01 runbook); backups in MinIO on mini02. Use end-to-end
  encryption (D3) to protect the budget from backup readers.
- Pod hardening applied: `runAsNonRoot`, uid/gid 1001, `fsGroup: 1001`, `seccompProfile: RuntimeDefault`,
  `allowPrivilegeEscalation: false`, all capabilities dropped, no hostPath, no privileged, default
  ServiceAccount with no extra RBAC (add `automountServiceAccountToken: false` to the pod spec in a
  follow-up if WP2 shows the server does not need it; it does not talk to the Kubernetes API).
- Not applied: `readOnlyRootFilesystem` (the server may write temp files; `[UNVERIFIED]`, test in a
  follow-up PR with an `emptyDir` on `/tmp`).
- The namespace `homeserver` is `privileged` Pod Security, so the settings above are not enforced by the
  namespace; they are our own discipline.
- Egress: unrestricted today (no NetworkPolicy). Needed only for bank sync/OIDC discovery.

## 10. Operations

**Upgrade procedure** (a PR; weekly or monthly check):
1. The operator exports the budget (Settings, Export data) and, if possible, triggers a manual Velero backup of
   `homeserver` (his action).
2. Executor reads the release notes between the current and the new version at
   https://actualbudget.org/docs/releases; lists breaking changes and migrations in the PR. Actual
   uses `YY.M.N` versions; the server migrates its database on start and shipped migration files are
   immutable, but a migration is one-way: the data on the PVC cannot be opened by an older server after
   an upgrade. Therefore the pre-upgrade backup is mandatory. Client and server versions should match;
   a newer client talking to an older server (or the reverse) can refuse to sync until they match.
3. Resolve the new digest (WP2 step 2 command with the new tag), edit the `image:` line and the tag
   comment in `talos/manifests/actual-budget/deployment.yaml`, run the guards, open a draft PR.
4. The operator merges, syncs `actual-budget` in Argo (Recreate: a few seconds of downtime), opens the app, and
   checks the budget loads and syncs.
5. Rollback: revert the PR and sync. If the new version already migrated the data, restore the PVC from
   the pre-upgrade Velero backup (section 8) because a downgrade is not supported
   `[UNVERIFIED]`: the docs do not state it; treat it as unsupported.

**Sync reset** (compresses the change history): Settings, Reset sync. Do it from the device with the most
up-to-date copy; other devices must revert and re-download [verified https://actualbudget.org/docs/getting-started/sync].

**Health:** `kubectl --context admin@<cluster> -n homeserver get pods -l app.kubernetes.io/name=actual-budget`;
Argo app `Synced`/`Healthy`; `GET /health` returns 200.
**Logs:** `kubectl --context admin@<cluster> -n homeserver logs deploy/actual-budget --tail=100`.
**Resource watch:** `kubectl --context admin@<cluster> -n homeserver top pod` weekly for the first month.
**Disk:** `kubectl --context admin@<cluster> -n homeserver exec deploy/actual-budget -- du -sh /data`.

**Troubleshooting table**

| Symptom | Where to look | Likely cause | Fix |
|---|---|---|---|
| Browser shows `SharedArrayBufferMissing` / "Actual requires a secure context" / unsupported banner | Browser dev tools console; address bar scheme | Opened over `http://` or an address that is not the tailnet HTTPS name | Use `https://actual.<tailnet-name>`. Do not use the pod IP, a port-forward from another machine, or http. `localhost` is allowed (secure context). |
| Same error over HTTPS | `curl -sI https://actual.<tailnet-name>/` from a tailnet device: count `cross-origin-opener-policy` and `cross-origin-embedder-policy` lines | Duplicated COOP/COEP headers from a proxy in front [verified https://actualbudget.org/docs/config/reverse-proxies] | Remove the proxy that adds them; this plan's Ingress adds none. Report to the operator. |
| Page does not load / TLS certificate error | `kubectl --context admin@<cluster> -n tailscale get pods`; the operator proxy pod logs | HTTPS not enabled for the tailnet, or stale device named `actual` made the new one `actual-1` | The operator deletes the stale device in the Tailscale admin console, or uses the `-1` name; check HTTPS is enabled in the admin console. |
| Pod `Pending` | `kubectl ... describe pod`; `get pvc` | PVC Pending with WaitForFirstConsumer until the pod schedules; node selector wrong | Check `nodeSelector` is `mini01`; check `storageClassName: topolvm-fast`. |
| Pod `CrashLoopBackOff`, log "EACCES" or "permission denied" on `/data` | Pod logs | Volume owned by a different uid than 1001 | Confirm `fsGroup: 1001` and `runAsUser: 1001`; report; do not chmod by hand. |
| Pod `CreateContainerConfigError` | `describe pod` | `actual-budget-secrets` missing and `optional` removed | Keep `optional: true` (WP2) or sync `talos-sealed-secrets` first. |
| "Cannot open budget" / budget stuck loading / "out of sync" in the app | Browser dev tools; server log | Local browser data differs from server (after a sync reset, a restore, or a server upgrade) | In the app: Close file, re-download from the server ("revert to latest version"); if the local file is the good one, "Reset sync" from it. Keep the export taken before the action. |
| "Failed to sync" / sync error banner | Server logs; `/health`; network | Server restarting, tailnet down on the device, or client/server version mismatch | Wait for pod Ready; reconnect Tailscale; update the client to the server's version. |
| Login page shows but password rejected | Vaultwarden entry | Wrong password; or restored data holds an older password | Use 6.4 to reset. |
| "File is encrypted" / password prompt on opening a budget | Vaultwarden | Encryption password required on a new device | Enter C2. If lost, see 6.2. |
| Bank sync errors (WP4) | `DEBUG=actual-sensitive:bank-sync,actual-sensitive:<provider>` via PR; the Bank Sync page | Expired consent (GoCardless EUA expires; relink), wrong keys, provider outage | Relink the account in the UI; rotate keys at the provider; remove DEBUG after. |
| OIDC login fails (WP5) | `DEBUG=actual-sensitive:openid` via PR | Redirect URI mismatch; wrong discovery URL; Authentik down | Fix the redirect `https://actual.<tailnet-name>/openid/callback`; password login stays as fallback. |
| Velero PodVolumeBackup missing | WP3 step 2 | Annotation on the wrong object (Deployment metadata instead of pod template), or node agent not on mini01 | Fix in a PR; check node-agent pod. |
| Memory near 512Mi | `top pod` | Large budget upload or sync reset | Raise the limit in a PR to 768Mi; check for leaks after updates. |

## 11. Acceptance checklist and report format

The operator should see all of these working:
- [ ] Argo `actual-budget`: `Synced`, `Healthy`; `talos-sealed-secrets` unchanged.
- [ ] `https://actual.<tailnet-name>` opens in a browser on a tailnet device, valid certificate, no SharedArrayBuffer warning.
- [ ] Server password set; stored in Vaultwarden; login works after closing and reopening.
- [ ] Test budget created; added data survives a pod restart (The operator deletes the pod in Argo; data still there).
- [ ] If D3 = on: encryption enabled after the password was saved in Vaultwarden and in an offline copy; second device asks for it.
- [ ] Actual export taken and stored.
- [ ] `kubectl ... get podvolumebackups` shows Completed for volume `data` of the actual-budget pod.
- [ ] WP3 restore drill: `DRILL PASS`, and the operator opened the restored budget; scratch namespace deleted.
- [ ] Phone works (PWA over the tailnet HTTPS name).
- [ ] No IPv4, `.ts.net` or secret in the repository; 20 guards `OK`.
- [ ] (optional) Bank sync linked and one automatic sync observed.
- [ ] (optional) OIDC login works; password login still available.

**Report format after every package:**
```
WP<n>: done | blocked | needs decision
PR: <url or none>
Guards: <20 OK | which failed>
Verified: <commands run and what they printed, secrets omitted>
Differences from the plan: <list or none>
Needs from the operator: <list or none>
```

## 12. Open questions and UNVERIFIED items

1. Memory and CPU use of the server (no official numbers). Confirm with `kubectl top pod` after WP2.
2. Whether the 26.10.0 image runs as root unless `runAsUser` is set (the Dockerfile at master has no `USER`
   line). WP1 step 9 reads the tag's Dockerfile; WP2 sets uid 1001 explicitly. If the pod fails with a
   permission error, report instead of removing the setting.
3. Path of the reset script inside the container (`node build/scripts/reset-password.js` from `/app`).
   Confirm read-only with `kubectl ... exec deploy/actual-budget -- ls build/scripts`.
4. Exact label of the in-app "change server password" menu entry in the running version.
5. Exact wording of the startup log line; healthy log check is "no errors" until seen.
6. Whether SQLite uses WAL and how that interacts with live file-system backup beyond the CI proof.
7. Portuguese bank coverage of Enable Banking and GoCardless: The operator checks the providers' lists. Enable Banking is experimental (nightly-only); GoCardless is closed to new accounts.
8. Whether environment variables for bank-sync provider keys exist (the config page lists none).
9. Behaviour of `ACTUAL_OPENID_ENFORCE`, `ACTUAL_USER_CREATION_MODE` and multi-user mode with a single-user household: read https://actualbudget.org/docs/config/oauth-auth and https://actualbudget.org/docs/config/multi-user before WP5.
10. Whether `readOnlyRootFilesystem` works (needs an `emptyDir` for `/tmp`).
11. Whether mini01's disks are encrypted at rest (see the Talos runbooks).
12. Whether the Tailscale ingress proxy adds COOP/COEP headers (expected: no).
13. Authentik namespace `authentik` and the OAuth provider setup `[ASSUMED]` from the authentik plan.
14. Placement on mini03 later (D7) and the second backup copy (PR #71).
15. The downgrade path after a migration is undocumented; treat as unsupported.
16. Whether the repo's Velero retention for this schedule is 30 days (the older `argocd/values/velero.yaml` sets 720h; WP1 step 5 confirms the Talos value).
