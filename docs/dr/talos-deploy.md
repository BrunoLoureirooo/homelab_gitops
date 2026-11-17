# Talos deploy path

How a change to the Talos machine config (or a version bump) reaches mini01 and
mini02, after the cutover (gate G2). Until G2 passes, the old Ansible path in
`.github/workflows/deploy.yml` stays exactly as it is.

## What it does

A GitHub-hosted workflow, `.github/workflows/talos-deploy.yaml`, wraps two
scripts that CI also runs against a throwaway Talos cluster:

| Piece | Role |
|---|---|
| `talos/deploy/apply.sh --mode check\|apply` | renders every node's config, validates all of them first, shows a dry-run diff (as a line count only), then applies one node at a time, control plane first, with a health wait between nodes |
| `talos/deploy/upgrade.sh --talos\|--k8s` | rolls a pinned Talos or Kubernetes version out, control plane first, using the installer image built from the node's schematic id (never `latest`) |
| the workflow | joins the tailnet as an ephemeral node tagged `tag:ci`, decrypts the SOPS secrets into the runner temp directory, runs the script, deletes the secrets, optionally reports or syncs ArgoCD Applications |

It runs on a push to `main` that touches `talos/patches`, `talos/nodes`,
`talos/schematics`, `talos/cluster.env`, `talos/secrets` or `talos/versions.env`,
and on a manual run. It can never be triggered by a pull request (rule F of
`.github/scripts/check-workflow-safety.sh`).

## One-time setup (the operator)

These live outside the repo. They are safe to do before the cutover: nothing
uses them until a Talos node is on the tailnet.

1. **Tailnet policy.** Add the tag owner for `tag:ci` (you own it). The Talos
   nodes are untagged, so add `hosts` aliases `mini01`, `mini02` and `mini03`
   (placeholder addresses `100.x.y.z` here; keep the real ones out of git) and
   one grant: `tag:ci` may reach `mini01`, `mini02` and `mini03` on tcp:50000
   and tcp:6443 only. The deploy jobs also need `tag:ci` to `mini04` and
   `victus` on tcp:22. Narrow any allow-all grant to src `autogroup:member`,
   `tag:k8s` and `tag:k8s-operator`, so `tag:ci` reaches nothing else.
   Future improvement: tag the nodes `tag:talos` via the auth keys in
   `talos/secrets`, then grant to that tag instead of the aliases.
2. **CI identity.** Create a federated identity for GitHub OIDC (issuer
   GitHub, subject `repo:BrunoLoureirooo/homelab_gitops:environment:*`), scoped
   to the `auth_keys` write permission with tag `tag:ci`. Note the client id and
   audience: neither is a secret. Full steps: `.github/SECRETS.md`.
3. **GitHub environments** (repository Settings, Environments): create
   `talos-check` (no reviewer) and `talos-apply` (required reviewer: you,
   restricted to branch `main`). Add the secret `SOPS_AGE_KEY` to both (the age
   private key that decrypts `talos/secrets/`; keep your own offline copy).
   There is no Tailscale secret.
4. **Repository variables:** `TALOS_NODES` (space separated `name=endpoint`
   pairs, control plane first, MagicDNS short names, for example
   `mini01=<short-name> mini02=<short-name>`), `TS_CLIENT_ID` and `TS_AUDIENCE`
   (the client id and audience from step 2) and `TALOS_PING_HOST` (a Talos
   node's short name, set after the node exists; the workflow pings it before
   doing anything). The workflow fails fast, naming any that is missing.
5. Reply in the PR with: the environment names created and
   the secret names set. Never paste a value.

Secret names only are written anywhere in this repo. Values never are.

## Normal use

1. Merge a change under `talos/` to `main`. The workflow starts and waits at the
   `talos-apply` environment.
2. Open the run, read the check output of the previous commit if you like (see
   below), approve.
3. Watch: one `DEPLOY node=<name> mode=apply result=...` line per node. A node
   that fails validation or health stops the run before the next node.

## Checking without applying

Run the workflow manually with `mode: check`. It uses the `talos-check`
environment (no approval), prints `result=NOCHANGE` or
`result=CHANGES changed_lines=<n>` per node and changes nothing. The diff itself
is not printed on purpose: a machine config diff can contain values.

Locally the same script works with `TALOSCONFIG` and `TALOS_NODES` set:
`bash talos/deploy/apply.sh --mode check`.

## Upgrades

Run the workflow manually with `scope: talos-upgrade` or `scope: k8s-upgrade`.
`mode: check` only prints the plan; `mode: apply` upgrades. Order: control
plane (mini01) first, then the worker (mini02), health check in between.

With one control plane, upgrading mini01 makes the Kubernetes API unavailable
for a few minutes. Workloads on both nodes keep running. Do not combine an
upgrade with a config change in the same run. The version pins are in
`talos/versions.env`; a bump is a pull request that changes them, then a manual
upgrade run.

## Rollback

- **Config change:** revert the commit and let the workflow apply the previous
  config (the same path, the same approval).
- **Talos upgrade:** Talos writes the new system to the spare A/B slot and boots
  back into the old one if the new one does not come up. If a node boots but
  misbehaves, `talosctl rollback` returns it to the previous slot.
- **Whole node lost:** rebuild from the repo and Velero as written in the
  cutover runbook (plan 15-07).

## Retiring the Ansible path (after G2)

Plan 15-09 Task 5, only after G2 has passed and you confirm. It removes the
auto-deploy trigger (`deploy.yml`), unregisters the self-hosted runners and
adds a banner to `ansible/` saying it is legacy and used only for victus host
configuration. The `ansible/` tree is kept, not deleted.

## victus: the host leaves the cluster, a Talos worker VM joins it

The victus HOST stays on Arch as the operator's desktop and is not a Talos node. It
cannot be a k3s agent of a Talos control plane, so the host left the cluster at
the cutover (plan 15-07; the k3s agent was uninstalled on 2026-11-04). Backups no
longer live on victus: the primary target is MinIO on mini02, and the second copy
goes to the replica on mini03 (below). The standalone MinIO on victus and its data
were removed on 2026-11-04.

Decided 2026-10-15 (the operator): after gate G2, victus also runs a Talos WORKER, mini03, as a
libvirt/QEMU VM on that same Arch host, so the cluster side of victus (node
config, workloads: arr stack, torrents, backup replica) is managed from this repository while the machine stays a
desktop for gaming and dev. Design, resource limits and the order of work are in
`docs/dr/mini03.md`. This path does not apply to the cutover itself: the VM
comes after G2.

## Why no self-hosted runner

A self-hosted runner needs SSH and a package manager on the host; Talos has
neither, and a runner inside the cluster could not fix the cluster it runs on.
A GitHub-hosted runner that joins the tailnet for the length of one job needs no
inbound port at home and leaves nothing behind (the node is ephemeral and the
secrets are deleted in a final step). The only way in is the Talos API and the
Kubernetes API, restricted by the tailnet policy to `tag:ci`.
