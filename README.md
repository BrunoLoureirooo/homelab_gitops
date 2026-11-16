# homelab_gitops

GitOps repo for a small home Kubernetes cluster running **Talos Linux**: a
control-plane node (`mini01`), a storage-backend worker (`mini02`) and a worker
that runs as a libvirt VM on a desktop (`mini03` on `victus`). Everything is
reachable only over Tailscale, with no router involvement and no public
exposure. Nothing sensitive is committed in clear text: cluster secrets are
Sealed Secrets, machine secrets are SOPS+age, host secrets are Ansible Vault.

Host and personal details (tailnet name, addresses, MAC addresses, disk serials)
are deliberately absent. Docs use placeholders such as `<tailnet>`, `<lan-ip>`
and `<victus-tailnet-ip>`; `.github/scripts/check-no-host-details.sh` enforces it.

## Layout

```
talos/      The cluster. Machine config as patches plus per-node files
            (patches/, nodes/, render.sh), pinned Talos/Kubernetes versions
            (versions.env, schematics/), a QEMU/KVM CI harness (test/), the
            cutover and disaster-recovery helpers (scripts/, dr/), and the
            Argo CD app set the cluster actually syncs: apps/ (generated, never
            hand-edited), apps-src/ (Talos-only apps), manifests/, values/,
            sealed-secrets/. root.yaml is the App-of-Apps root. See
            talos/README.md.
argocd/     The shared source for that app set: one Application per workload
            in apps/, Helm values in values/, plain manifests in manifests/
            and SealedSecrets in sealed-secrets/. It is not applied to a
            cluster directly; talos/render-apps.sh reads it (plus
            talos/apps-overrides.yaml and talos/apps-src/) and writes
            talos/apps/ and talos/manifests/. See argocd/README.md.
ansible/    Host config for the two machines outside the cluster: victus (Arch
            desktop, optional host of the mini03 VM) and mini04 (Debian kiosk
            display host). See ansible/README.md.
docs/       docs/rebuild-node.md (bare machine to a working Talos node),
            docs/mini01-coverage.md (ledger of what the node consists of),
            docs/dr/ (restore and disaster-recovery runbooks), docs/plans/
            (work-package plans for individual apps), docs/templates/ghcr-app/
            (add an app that runs a published GHCR image), docs/BACKLOG.md and
            docs/homelab-brief.md (scope and ground rules).
.planning/  Planning notes from the original build (roadmap, requirements,
            handoff). Historical; the code and the docs above are current.
.github/    Workflows and guard scripts, below.
renovate.json   automated PRs for Helm chart versions and image tags
```

## How a change reaches the cluster

1. Edit the app in `argocd/` (shared apps) or `talos/apps-src/` (Talos-only apps),
   or the machine config in `talos/patches/` and `talos/nodes/`.
2. Regenerate the app set: `talos/render-apps.sh --force`. `talos/apps/` and
   `talos/manifests/` are generated, and a guard fails if they are hand-edited
   or out of date.
3. Run the guards locally: `bash .github/scripts/run-all-guards.sh`.
4. Open a PR and merge it. Argo CD apps are manual-sync on purpose: the operator
   syncs each app in the Argo CD UI after reviewing the diff.
5. Machine config reaches the nodes through the `Talos deploy` workflow
   (`.github/workflows/talos-deploy.yaml`): a GitHub-hosted runner joins the
   tailnet as an ephemeral `tag:ci` node, and applying needs an approved
   environment. It never runs for a pull request.

## CI

| Workflow | What it does |
|---|---|
| `guards.yaml` | runs every `.github/scripts/check-*.sh` on each PR (no unreviewed Argo CD auto-sync, no raw `Secret` objects, no host details, no unpinned actions, rendered apps up to date, and more) |
| `lint.yaml` | ansible-lint, ruff, whole-repo yamllint, gitleaks |
| `validate.yaml` | helm lint and kubeconform on the manifests |
| `talos.yaml` | boots the pinned Talos image in QEMU/KVM on a hosted runner and runs the scripts in `talos/test/jobs/` |
| `talos-deploy.yaml` | applies Talos machine config and upgrades over the tailnet, after approval |
| `deploy.yml` | runs the Ansible playbooks for victus (manual) and mini04 (manual, or on a push that touches its files) on GitHub-hosted runners over Tailscale |

## Secrets

- In-cluster secrets are Sealed Secrets (`talos/sealed-secrets/`,
  `argocd/sealed-secrets/`). The public certificate is committed; the private
  key never is. A guard rejects a raw `kind: Secret`.
- Talos machine secrets are a SOPS+age bundle (`talos/secrets/`, public
  recipient only).
- Host secrets for Ansible are in an Ansible Vault file
  (`ansible/group_vars/all/vault.yml`; the variables are listed in
  `vault.yml.example`).
- CI secrets are GitHub Actions secrets and are referenced by name only.

## Getting started

- Rebuilding or adding a Talos node: `docs/rebuild-node.md`, then `talos/README.md`.
- Adding an app: `argocd/README.md` and `docs/templates/ghcr-app/README.md`.
- The victus and mini04 hosts: `ansible/README.md`.
- Restores and drills: `docs/dr/`.
