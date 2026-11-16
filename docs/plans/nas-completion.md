# Plan: finish the NAS (hand-off)

Audience: a local language model working on this repository for the operator. Follow it literally, one work
package at a time. Where it says STOP, stop and report to the operator; do not decide for him.

Written 2026-10-24. The service list lives in `docs/BACKLOG.md`.

## 0. How to work (read this first, every time)

1. You change files in the repository and open pull requests. **Nothing else.** the operator merges and
   syncs Argo. Never change the live cluster.
2. Allowed cluster access is **read-only**: `get`, `describe`, `logs`, `top`, `exec ... -- <read-only
   command>`. Always pass `--context admin@<cluster>`. Forbidden: `apply`, `create`, `delete`, `patch`,
   `edit`, `scale`, `rollout`, `replace`, `label`, `annotate`, `drain`, `cordon`, `taint`, any
   `talosctl apply-config`, `upgrade`, `reset`, and any `argocd app sync`.
3. **Secrets never enter the repo in clear text**, and never enter a chat, a log or a PR description.
   Secrets are sealed (`kubeseal` with the committed certificate, `argocd/sealed-secrets/pub-cert.pem`)
   by the operator or with his values typed in by him. If a command prints a secret, stop and tell the operator.
4. The repo has guards that reject host details. Do **not** write IPv4 addresses, MAC addresses, disk
   serial numbers or `/dev/disk/by-id` names into any committed file. Use placeholders such as `<node>`.
5. One concern per pull request. Branch from current `origin/main`: `git fetch origin && git switch -c
   <branch> origin/main`. Open PRs as **drafts**. Never push to `main`, never force-push, never merge.
6. Before every commit run `bash .github/scripts/run-all-guards.sh`. All lines must start with `OK`.
   If one says `FAIL`, fix it or stop and report. Never edit a guard to make it pass.
7. Generated files: after changing `talos/apps-src/*.yaml`, run `talos/render-apps.sh --force` and commit
   the result under `talos/apps/`.
8. Report after each work package in the format of section 8.
9. If something here does not match what you see, trust what you see, write down the difference, and
   ask the operator. Do not guess.

## 1. Where things are

| What | Where |
|---|---|
| Samba pod manifests | `talos/manifests/samba-nas/` (`deployment.yaml`, `service.yaml`, `namespace.yaml`, `kustomization.yaml`) |
| Argo app for it | `talos/apps-src/samba-nas.yaml` (manual sync), generated copy in `talos/apps/` |
| Samba credential | sealed Secret `samba-nas-credentials` (key `credential`) in `talos/sealed-secrets/samba-nas-credentials.yaml` |
| ZFS pool creation | `talos/storage/zfs-pool-job.yaml`, tool pins in `talos/storage/pins.env` |
| Storage decision and history | `talos/STORAGE-DECISION.md` |
| Hardware runbook | `docs/dr/mini02-talos.md` |
| CI proofs | `talos/test/jobs/nas-pod.sh`, `talos/test/jobs/csi-smb.sh` |
| App expectation list | `talos/test/empty-cluster-expectations.txt` |
| Service backlog | `docs/BACKLOG.md` |
| Guards | `.github/scripts/run-all-guards.sh` |

Namespace of the NAS: `nas`. Deployment: `samba-nas`. Node: `mini02` (cordoned on purpose; the pod
tolerates it). Shares served: `media`, `music`, `paperless`, `immich`, all with one account `homelab`
(uid 1000). Datasets on the ZFS mirror `tank`, mounted on the node at `/var/mnt/tank`:
`tank/nas` (shares `media`, `music`, `paperless` are folders under it), `tank/immich` (quota 128 GB),
`tank/backups` (quota 128 GiB, MinIO data for Velero).

## 2. Known state (from the operator's records; verify in work package 1)

- The Samba pod runs. The share `immich` is in use (Immich's library, through the SMB CSI driver).
- `tank/nas` is empty. The `media` share is kept but unused: Jellyfin's library is on mini01's local
  Toshiba disks, not on the NAS (decision 2026-10-19).
- Nothing in the repo creates the datasets or sets their quotas; they were created by hand.
- Nothing schedules a ZFS scrub, and nothing alerts on a degraded pool.
- The `music` and `paperless` shares exist but have no consumer yet. Paperless is a planned service.
- Exposure of these shares on the tailnet has not been decided.
- A second copy of the photo library outside mini02 has not been decided.

## 3. Decisions that belong to the operator (do not make them)

| Id | Question | Recommended default (propose, do not apply) |
|---|---|---|
| D1 | Keep or remove the empty `media` share? | Remove it (nothing uses it) |
| D2 | Expose `music` and `paperless` on the tailnet? | No; keep LAN and in-cluster only until a consumer needs it |
| D3 | One Samba account for all shares, or separate accounts? | Separate accounts for `paperless` and `music`; `immich` stays on its own |
| D4 | Second copy of the photo library: cloud bucket, external disk, both? | Decide separately; out of scope here |

Work packages that depend on a decision say so. If the operator has not answered, **STOP** at that package
and move to the next independent one.

## 4. Definition of done for the NAS

All must be true:

1. The datasets and their quotas are described in the repo and can be recreated from it (WP2).
2. The share list matches what is used (WP3, per D1).
3. Per-share accounts exist if the operator chose D3 (WP4).
4. Tailnet exposure exists only if the operator chose D2 (WP5).
5. A monthly scrub runs and a degraded pool is visible (WP6).
6. The disk-loss drill is written down and the operator has done it once (WP7).
7. `docs/dr/mini02-talos.md`, `talos/STORAGE-DECISION.md` and `docs/BACKLOG.md` are up to date (WP8).

## WP1. Audit (read-only; no pull request)

Goal: confirm section 2 before changing anything.

Run these, with `--context admin@<cluster>`, and record the output (without secrets):

    kubectl -n nas get pods,svc,deploy -o wide
    kubectl -n nas describe pod -l app.kubernetes.io/name=samba-nas
    kubectl -n nas logs deploy/samba-nas -c samba --tail=50
    kubectl -n nas exec deploy/samba-nas -c samba -- df -h /shares/nas /shares/immich-data
    kubectl -n nas exec deploy/samba-nas -c samba -- ls -la /shares/nas /shares/nas/music /shares/nas/paperless

- `df` shows the size of each dataset; a ZFS quota appears as the filesystem size. Note the sizes.
- Check the repo for anything that creates datasets or quotas: `grep -rn -E 'zfs (create|set)|quota' talos docs`.
  Expected: nothing outside `talos/test/` (that is the gap WP2 closes).
- Check that nothing schedules a scrub: `grep -rn 'scrub' talos docs`.

Deliverable: a report listing what matched section 2 and what did not.

## WP2. Describe the datasets and quotas in the repo

Branch: `nas/datasets`. Goal: `tank/nas`, `tank/immich`, `tank/backups` and their quotas are
reproducible from the repo.

1. Read `talos/storage/zfs-pool-job.yaml` completely. Reuse its image, privileges, node selector
   and its way of running ZFS commands. Do not invent a different mechanism.
2. Create `talos/storage/zfs-datasets-job.yaml`: a Job that, for each dataset, runs
   `zfs list <dataset>` and creates it only if missing, then sets the quota with `zfs set`
   (idempotent). Quotas from section 1; for `tank/nas` use the value the operator gives you. If he has not,
   **STOP and ask**. Use `set -eu`. The Job must be safe to run twice. It must never run `zfs destroy`,
   `zpool destroy` or `zpool create`.
3. The Job must **not** be applied by you and must not be picked up by an automated Argo app. Document
   in a header comment that the operator runs it, how, and what output to expect.
4. Add a short section to `docs/dr/mini02-talos.md` named "Datasets and quotas" with the exact steps
   for the operator.
5. Run the guards. Open a draft PR titled "nas: describe ZFS datasets and quotas".

Verification the operator does: after he runs the Job, the Job log ends with the list of datasets and
quotas, and `df` inside the Samba pod shows the same sizes.

## WP3. Shares match what is used (needs D1)

Branch: `nas/shares`. If D1 is "remove":

1. In `talos/manifests/samba-nas/deployment.yaml` delete the env entry `SAMBA_VOLUME_CONFIG_media`
   and `media` from the loop `for s in media music paperless` in the init container.
2. Do **not** delete any data. The folder `/shares/nas/media` stays on disk, empty.
3. Update `talos/STORAGE-DECISION.md`, section "Samba and SMB access" and "Jellyfin library".
4. Run `kubectl kustomize talos/manifests/samba-nas > /dev/null` and the guards. Draft PR
   "nas: drop the unused media share".

If D1 is "keep", write that in the STORAGE-DECISION file and skip the rest of this package.

## WP4. Separate accounts per share (needs D3; skip if D3 is "one account")

Branch: `nas/accounts`. Read the image's documentation for `ACCOUNT_<user>`, `UID_<user>` and
`SAMBA_VOLUME_CONFIG_<share>` (already used in `deployment.yaml`). For each new account:

1. Add env entries `ACCOUNT_<name>` (from a new sealed Secret key) and `UID_<name>`, and restrict the
   share with `valid users = <name>`.
2. Do **not** create the Secret. Write the exact command for the operator in the PR description, using
   placeholders only, in the style of the "Samba" step in `docs/dr/mini02-talos.md`. The operator seals it.
3. Make sure the init container still creates the folders with the correct owner for each uid.
4. Draft PR "nas: per-share accounts". STOP: it cannot sync until the operator has sealed the new Secret.

## WP5. Tailnet exposure (needs D2 = yes; otherwise skip)

Branch: `nas/tailnet`. Goal: reach SMB from outside the home through the Tailscale operator.

1. Read the existing examples: `talos/manifests/jellyfin/ingress.yaml` (HTTP through an Ingress) and
   the Service `adguard-dns` in `talos/manifests/adguard-home/service.yaml` (a non-HTTP service
   exposed on its own tailnet device). The operator itself is the Argo app `talos/apps/tailscale-operator.yaml`.
2. SMB is TCP, not HTTP: copy the AdGuard DNS pattern, which is a Service with `type: LoadBalancer`,
   `loadBalancerClass: tailscale` and the annotation `tailscale.com/hostname: nas`, selecting the
   `samba-nas` pods, with port 445. Check the installed operator's documentation for this pattern before
   relying on it; do not rely on memory.
3. Add it in a new file in `talos/manifests/samba-nas/` and list it in the kustomization. Hostname
   for the tailnet device: `nas`.
4. Check the Tailscale access rules (ACL) allow the device tag the operator uses. You cannot read or
   edit them; **list the requirement in the PR description for the operator**.
5. Draft PR "nas: expose SMB on the tailnet". Mention that clients mount
   `smb://nas/<share>` and that SMB over the internet is slower than at home.

## WP6. Scrub and health

Branch: `nas/scrub`. Goal: a monthly `zpool scrub tank` and a visible result.

1. Base a CronJob on the privileged pattern in `talos/storage/zfs-pool-job.yaml` (same image, same
   node selector, same mounts). It runs `zpool scrub tank`, waits for completion
   (`zpool wait -t scrub tank`), then prints `zpool status tank`.
2. Schedule: monthly, off-peak. `concurrencyPolicy: Forbid`, `successfulJobsHistoryLimit: 3`,
   `failedJobsHistoryLimit: 3`, `activeDeadlineSeconds` generous (a scrub of a 1 TB mirror takes hours).
3. It must be read-only apart from the scrub itself. No `zpool clear`, no `zpool destroy`.
4. Put it in its own folder and as its own manual-sync Argo app, following `talos/apps-src/samba-nas.yaml`
   (copy its structure and comments), add the matching line to
   `talos/test/empty-cluster-expectations.txt`, and run `talos/render-apps.sh --force`.
5. Write in the PR description how the operator reads the result (`kubectl -n <ns> logs job/<name>`), and
   that real alerting arrives with the monitoring service (see `docs/BACKLOG.md`).
6. Guards, draft PR "nas: monthly ZFS scrub".

## WP7. Disk-loss drill (document only; the operator performs it)

Branch: `nas/drill`. Write `docs/dr/zfs-disk-loss-drill.md`, steps for the operator:

1. Take a current backup and check it completed (`velero backup get`).
2. Note `zpool status tank` (both disks ONLINE).
3. Power mini02 off, pull ONE mirror disk, power on. The pool shows DEGRADED; confirm the Samba
   share and the Immich library still read correctly.
4. Power off, reinsert the disk, power on, and watch the resilver finish in `zpool status`.
5. Run a scrub; expect zero errors.
Add an "if it goes wrong" section: stop, do not run `zpool destroy` or `zpool create`, ask for help.
Draft PR "nas: disk-loss drill runbook".

## WP8. Documentation and backlog

Branch: `nas/docs`. After the other packages are merged: update `docs/dr/mini02-talos.md`,
`talos/STORAGE-DECISION.md` and the NAS row in `docs/BACKLOG.md` (Partway to Done only when section 4
is entirely true). Draft PR "nas: documentation after completion".

## 5. Order

WP1 first. Then WP2, WP6 and WP7 (independent of the decisions). WP3, WP4 and WP5 as the operator answers
D1 to D3. WP8 last.

## 6. Do not

- Do not touch the Immich Helm values, the Immich claim, or any data on `tank/immich`.
- Do not delete or move any files on the NAS.
- Do not change the Velero schedules or the MinIO configuration.
- Do not change any Talos machine configuration or volume patch.
- Do not run any command that is not in section 0 as allowed.

## 7. When to stop and ask the operator

A guard fails and you cannot fix it by an obvious edit. A command prints a secret. Output differs from
section 2. You would need a live change. A decision (D1 to D4) is needed. You are unsure.

## 8. Report format (after each package)

    WP<number>: <done | blocked | needs decision>
    PR: <url or none>
    Guards: <all OK | list of FAIL>
    Verified: <what you ran and saw, with no secrets>
    Differences from this plan: <list or none>
    Needs from the operator: <list or none>
