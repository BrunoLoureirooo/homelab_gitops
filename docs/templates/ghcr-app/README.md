# Run a project's published GHCR image on the Talos cluster

For a GitHub project that publishes its own container image on `ghcr.io` and needs a few secret
values (API keys, tokens). Everything reaches the cluster through a PR and an Argo sync; nothing is
applied by hand.

## 1. Read the project

Find the image name and a version tag on the repo's Packages page. Read its Dockerfile or compose
file: exposed port, required environment variable names, the data directory, whether it needs root,
devices or a lot of memory. You are running code you did not write.

## 2. Generate the manifests

```
docs/templates/ghcr-app/new-app.sh <app> ghcr.io/<owner>/<name>:<tag> <port>
talos/render-apps.sh --force
```

- Use a real version tag, never `latest`. The script asks ghcr.io for the tag's digest (curl and
  jq, no Docker needed) and pins the image by digest; the tag stays in a comment.
- If the package is private, first `export GHCR_USER=<github-user> GHCR_TOKEN=<read:packages token>`
  (and see step 4). If the script still cannot resolve the tag, check the name and tag on the
  Packages page, or pass the digest as a fourth argument.
- It also appends the line `check-talos-apps` requires to `talos/test/empty-cluster-expectations.txt`.

Then edit `talos/manifests/<app>/deployment.yaml`: the data path (`/data` is a placeholder), the
probe paths, resources, extra plain settings under `env:`. Delete `ingress.yaml` and its line in
`kustomization.yaml` to keep the app off the tailnet. Delete the PVC and its volume if the app keeps
no state.

### Optional: write to a folder on a Toshiba disk

For an app that takes an output directory (for example books). In `deployment.yaml`, uncomment the
three blocks marked MEDIA DISK (1 of 3, 2 of 3, 3 of 3):

- the `initContainers` block, which creates the folder as uid 1000 so the app can write to it;
- the `<APP>_OUTPUT_DIR` variable (the app name in capitals, dashes as underscores, for example
  `PINGBOARD_OUTPUT_DIR`) set to `/books`; rename it to the exact variable the app reads;
- the `books` volumeMount and the `disk` and `books` volumes.

disk1 is `/var/mnt/media`, disk2 is `/var/mnt/media2`. Change both host paths (and the folder name
`Books`) together. The app sees only the one folder, at `/books`. This data is not backed up by
Velero, like the Jellyfin library.

## 3. Seal the secret values

```
docs/templates/ghcr-app/seal-secret.sh <app> API_KEY OTHER_KEY
```

- Use the exact environment variable names the project documents. Each key becomes a variable of the
  same name in the pod (the Deployment loads the whole Secret with `envFrom`).
- It asks for each value with echo off and seals them with the repo's public certificate into
  `talos/sealed-secrets/<app>-secrets.yaml` (namespace `homeserver`), and lists the file in
  `talos/sealed-secrets/kustomization.yaml`. The clear values never touch disk, the screen, or shell
  history. Only the sealed file is committed.
- If a value ever lands in a chat or log, revoke it at the provider and re-seal.
- To change a value later: delete the sealed file and its line in the kustomization, run the script
  again, commit.

## 4. Private package only: image pull secret

A public package needs nothing. For a private one, make a read-only token (`read:packages`), and seal
a pull secret the same way:

```
read -rs TOKEN
kubectl create secret docker-registry ghcr-pull -n homeserver \
    --docker-server=ghcr.io --docker-username=<github-user> --docker-password="$TOKEN" \
    --dry-run=client -o json |
  KUBECONFIG=/dev/null kubeseal --cert argocd/sealed-secrets/pub-cert.pem --format yaml \
    > talos/sealed-secrets/ghcr-pull.yaml
unset TOKEN
```

(This is the same pattern as `docs/dr/talos-backups.md`. The token is visible in the process list of
your own Mac for a moment; it is not on disk or in shell history. I have not run this exact
command.)

List `ghcr-pull.yaml` under `resources:` in `talos/sealed-secrets/kustomization.yaml` and uncomment
`imagePullSecrets` in the Deployment.

## 5. PR, merge, sync

Run `bash .github/scripts/run-all-guards.sh`, open a PR and merge it. The `talos-sealed-secrets` app
syncs the Secret on its own; then sync the new `<app>` app in Argo by hand (manual sync on purpose).
Check the pod, its logs and the Argo health. A pod stuck in `CreateContainerConfigError` means the
Secret has not synced yet.

## Updating the app

`new-app.sh` is for a new app only. To update, pick the new tag, get its digest
(the digest is shown for each version on the package page on GitHub), change the `@sha256:` line and the
tag comment in the Deployment, open a PR.
