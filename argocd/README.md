# argocd/: shared source for the cluster's Argo CD app set

This directory is **source**, not a deployment target. The cluster runs Talos, and its
App-of-Apps root (`talos/root.yaml`) watches `talos/apps/`. That directory is generated:

```
argocd/apps/*.yaml             one Application per workload (this directory)
talos/apps-overrides.yaml      what differs on the Talos cluster
talos/apps-src/*.yaml          Applications that exist only on Talos
        |  talos/render-apps.sh --force
        v
talos/apps/*.yaml              the Applications the cluster syncs (never edit by hand)
talos/manifests/<app>/         generated copies of manifest directories that need Talos changes
```

`talos/render-apps.sh` reads `argocd/apps/` and never edits it. It applies the overrides
(`exclude`, `rename`, `path`, `extra_valuefiles`, `manifest_copies`; the file documents each) and
adds the apps from `talos/apps-src/`. The output is deterministic, and
`.github/scripts/check-talos-apps.sh` fails CI if `talos/apps/` or `talos/manifests/` differ from
what the script produces, so a change here is not finished until the render is committed too.

## What is here

| Path | Contents |
|---|---|
| `apps/` | `cert-manager`, `cluster-baseline`, `cp-reserva-bot`, `immich`, `immich-infra`, `sealed-secrets`, `secrets` (rendered as `sealed-secrets-set`), `tailscale-operator`, `vaultwarden`, `vaultwarden-pvc`, `velero` |
| `values/` | Helm value overrides for the charts above (`immich`, `vaultwarden`, `velero`, `tailscale-operator`, `cp-reserva-bot`) |
| `manifests/` | plain manifests for apps that are not charts: `cluster-baseline`, `immich-infra`, `tailscale-operator` (ProxyClass), `vaultwarden-pvc` |
| `sealed-secrets/` | SealedSecrets (ciphertext) and the controller's public certificate `pub-cert.pem`; see `sealed-secrets/README.md` |
| `OPERATIONS.md` | the operator's checklist for changes and syncs |

Some values and manifests here are overridden or replaced for Talos (for example
`talos/values/*.yaml` are appended to the chart value files, and `talos/manifests/immich-infra`
replaces the path of `immich-infra`). Check `talos/apps-overrides.yaml` before assuming a file in
this directory is what the cluster uses. Apps that are only on the Talos cluster (monitoring,
Jellyfin, AdGuard Home, the NAS, backups, Actual Budget and others) live in `talos/apps-src/`
and `talos/manifests/`.

## Conventions

- **Manual sync.** An Application starts with no `syncPolicy.automated` block and is synced by
  the operator in the Argo CD UI after reading the diff. `.github/scripts/check-argocd-safety.sh`
  fails the build if `automated:` appears without a `# automated-sync: reviewed ...` comment
  directly above it, so turning it on is always a deliberate, reviewed decision. Apps that hold
  data (Immich, Vaultwarden, their PVCs) stay manual permanently.
- **Never commit a raw `Secret`.** `.github/scripts/check-no-raw-secrets.sh` rejects it. Seal the
  value with `kubeseal` against the public certificate and commit the `SealedSecret`
  (`argocd/sealed-secrets/` for shared apps, `talos/sealed-secrets/` for Talos-only ones). Read the
  value into a hidden prompt (`read -rs`) rather than a command line, and never paste it anywhere.
- **Pin versions.** Chart `targetRevision`s and image tags are explicit. Renovate watches
  `argocd/**` (`renovate.json`) and opens the bump PRs.
- **Back up what matters.** Velero's file-system backup is opt-in per volume: a pod whose PVC
  must be backed up needs the annotation `backup.velero.io/backup-volumes: <volume name>` in its
  values. After adding an app, confirm the first backup produced a PodVolumeBackup for it.
- **Host details stay out.** Comments and docs use placeholders (`<tailnet>`, `<lan-ip>`); a few
  value files still carry the tailnet hostname of an app (see the PR that scrubbed this repo
  for the list and the intended fix).

## Adding or changing an app

1. Add or edit `argocd/apps/<app>.yaml` (and its values or manifests), or
   `talos/apps-src/<app>.yaml` if the app exists only on Talos.
2. If the Talos cluster needs something different, add it to `talos/apps-overrides.yaml`.
3. Run `talos/render-apps.sh --force` and commit the regenerated `talos/apps/` and
   `talos/manifests/`.
4. Run `bash .github/scripts/run-all-guards.sh`.
5. Open a PR, merge, and follow `OPERATIONS.md` to sync.

To publish a project that ships its own GHCR image, use `docs/templates/ghcr-app/README.md`.

## CI that covers this directory

- `validate.yaml`: helm lint and `kubeconform -strict -ignore-missing-schemas` on the manifests.
- `guards.yaml`: every `.github/scripts/check-*.sh`, including the safety, raw-secret and
  rendered-apps checks above.
- `lint.yaml`: whole-repo yamllint and gitleaks.
