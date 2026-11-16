# Operator checklist: what needs a human

Everything in this repo is automated or GitOps-managed except the steps below: generating a
credential, running a command by hand, clicking sync in the Argo CD UI. This is the checklist;
each item links to where the detail lives.

The cluster is Talos. `argocd/` is the shared source for its app set, and
`talos/render-apps.sh` turns it into `talos/apps/` (see `argocd/README.md`).

## Changing an existing app

- [ ] Edit the app under `argocd/` (or `talos/apps-src/` for a Talos-only app).
- [ ] `talos/render-apps.sh --force`, then commit the regenerated `talos/apps/` and
      `talos/manifests/`.
- [ ] `bash .github/scripts/run-all-guards.sh` is green; open the PR and merge it.
- [ ] In the Argo CD UI, open the app and read the diff in full. Sync only when it shows what
      you expect. Apps are manual-sync on purpose; only the apps marked
      `# automated-sync: reviewed` sync themselves.
- [ ] Apps that hold data (Immich, Vaultwarden, their PVCs) stay manual permanently. Take or
      confirm a recent Velero backup before syncing a change to one.

## Adding a secret

- [ ] Seal it with `kubeseal` against `argocd/sealed-secrets/pub-cert.pem`, reading the value
      from a hidden prompt (`read -rs`). Commands for each existing secret are in
      `argocd/sealed-secrets/README.md`; the Talos-only ones are described in
      `talos/sealed-secrets/kustomization.yaml` and `docs/dr/talos-backups.md`.
- [ ] Commit only the `SealedSecret`. If a value ever lands in a chat or a log, revoke it at the
      provider and re-seal.
- [ ] Apps that read a Secret as environment variables only pick it up at start: restart the
      workload after the secret syncs.

## Machine config, nodes and rebuilds

- [ ] Machine config changes reach the nodes through the `Talos deploy` workflow (check first,
      then apply, which needs the approved environment): `docs/dr/talos-deploy.md`.
- [ ] Rebuilding a node from bare metal: `docs/rebuild-node.md`.
- [ ] Bringing up an empty cluster, in the right app order: `talos/bootstrap-argocd.sh`
      (its header lists the steps). After `sealed-secrets` is up, back its sealing key up
      off-cluster; there is no recovery path from git if it is lost
      (`talos/dr/verify-sealing-key.sh`, `talos/dr/restore-sealing-key.sh`).
- [ ] Backup and restore drills: `docs/dr/talos-backups.md`.

## The hosts outside the cluster

- [ ] victus and mini04 are configured by Ansible: `ansible/README.md` (Day 0, vault, running
      the playbooks, the CI deploy workflow).

## Still open

Anything listed as UNVERIFIED or DRILL-PENDING in `docs/`, `docs/mini01-coverage.md` and
`talos/CUTOVER.md` has not been proven yet; close those out with a real run before relying on
them.
