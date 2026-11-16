# Sealed Secrets

One SealedSecret per Secret, safe to commit: the values are encrypted, and
only the in-cluster sealed-secrets controller can decrypt them. Deployed by
`argocd/apps/secrets.yaml` (manual sync). Each file carries its own
namespace.

| File | Secret | Used by |
|---|---|---|
| `minio-creds.yaml` | `velero/minio-creds` (`root-user`, `root-password`) | MinIO's root account |
| `immich-db-creds.yaml` | `homeserver/immich-db-creds` (`username`, `password`) | Immich's CNPG Postgres |
| `vaultwarden-admin.yaml` | `homeserver/vaultwarden-admin` (`token`) | Vaultwarden's admin panel |
| `operator-oauth.yaml` | `tailscale/operator-oauth` (`client_id`, `client_secret`) | Tailscale operator |
| `velero-cloud-credentials.yaml` | `velero/cloud-credentials` (`cloud`) | Velero -> MinIO (scoped user) |
| `cp-reserva-bot.yaml` | `cp-reserva-bot/cp-reserva-bot` (`CP_PASS_NUMBER`, `CP_DOC_TYPE`, `CP_DOC_NUMBER`, `FRIEND_PHONE`, `CP_EMAIL`, `CP_PASSWORD`) | cp-reserva-bot, as its environment |

The first four were sealed 2026-09-26 from the **live** values (adopted, not
replaced), so nothing that uses them changed.

`cp-reserva-bot` was sealed 2026-09-27 from the env file the bot ran with by
hand on victus (`~/.config/cp-reserva-bot/env`), piped straight through
`kubectl create secret generic --from-env-file=/dev/stdin --dry-run=client`
into `kubeseal`. Its namespace is created by the `cp-reserva-bot` app, so
sync that app before this one on the first deploy.

## Changing one value later

Re-seal just that key into the existing file; the other keys stay as they
are, and no cluster access is needed (only `kubeseal` and `pub-cert.pem`).
`read -rs` keeps the value off the screen and out of shell history:

```bash
read -rs NEW   # type or paste the new value, then Enter
printf %s "$NEW" \
  | kubectl create secret generic cp-reserva-bot -n cp-reserva-bot \
      --from-file=CP_PASSWORD=/dev/stdin --dry-run=client -o json \
  | kubeseal --cert argocd/sealed-secrets/pub-cert.pem --format yaml \
      --merge-into argocd/sealed-secrets/cp-reserva-bot.yaml
unset NEW
```

Swap `CP_PASSWORD` for the key you're changing (a new key works the same
way), and the name, namespace and file for another Secret. `--format yaml`
matters: without it `--merge-into` rewrites the file as JSON. Commit, merge,
sync `secrets`. Apps that load a Secret as environment variables (like
cp-reserva-bot) only read it at startup, so restart them afterwards:
`kubectl -n cp-reserva-bot rollout restart deploy/cp-reserva-bot`.

## cp-reserva-bot's WhatsApp session is not a secret here

The linked WhatsApp session (`wa-auth/`) and `state.json` are state on the
bot's PVC, not in git. To move an already-linked session in instead of
linking again, stop the bot everywhere else, then from a machine that has
both the session and the kubeconfig:

```bash
tar -C ~/.local/share/cp-reserva-bot -cf - wa-auth state.json \
  | kubectl -n cp-reserva-bot exec -i deploy/cp-reserva-bot -- tar -xf - -C /data
kubectl -n cp-reserva-bot rollout restart deploy/cp-reserva-bot
```

Or link a new one:
`kubectl -n cp-reserva-bot exec deploy/cp-reserva-bot -- node src/cli.ts link-whatsapp --phone +351...`
and restart.

## `pub-cert.pem`

The controller's **public** certificate. It can only encrypt, never
decrypt, so it's safe to commit, and it lets you seal without cluster
access (`kubeseal --cert argocd/sealed-secrets/pub-cert.pem`). If the
controller's key is ever rotated or restored, refresh it:

```bash
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d > argocd/sealed-secrets/pub-cert.pem
```

## Sealing a Secret - do NOT pipe `kubectl get secret -o yaml` straight in

`kubeseal` copies the input's annotations and labels into the SealedSecret
**unencrypted**. A Secret created with `kubectl apply` carries
`kubectl.kubernetes.io/last-applied-configuration`, which holds a
**plaintext copy of its values** - piping it straight to `kubeseal` would
commit the secret in the clear. Strip it down to name, namespace, type and
data first:

```bash
kubectl -n <ns> get secret <name> -o json \
  | python3 -c 'import json,sys; s=json.load(sys.stdin); json.dump({"apiVersion":"v1","kind":"Secret","type":s.get("type","Opaque"),"metadata":{"name":s["metadata"]["name"],"namespace":s["metadata"]["namespace"]},"data":s["data"]},sys.stdout)' \
  | kubeseal --cert argocd/sealed-secrets/pub-cert.pem --scope strict --format yaml \
  > argocd/sealed-secrets/<name>.yaml
```

For a brand-new value, build the input with `kubectl create secret generic
<name> -n <ns> --from-literal=... --dry-run=client -o json` instead (no
annotations to strip). Never commit the plaintext intermediate.

## Adopting a Secret that already exists live

The controller won't overwrite a Secret it didn't create ("already exists
and is not managed by SealedSecret"). Before syncing the `secrets` app for
the first time, mark each live one as adoptable:

```bash
kubectl -n velero     annotate secret minio-creds       sealedsecrets.bitnami.com/managed=true
kubectl -n homeserver annotate secret immich-db-creds   sealedsecrets.bitnami.com/managed=true
kubectl -n homeserver annotate secret vaultwarden-admin sealedsecrets.bitnami.com/managed=true
kubectl -n tailscale  annotate secret operator-oauth    sealedsecrets.bitnami.com/managed=true
```

## `velero-cloud-credentials.yaml` - not sealed yet

Velero's own MinIO user, scoped to its bucket instead of MinIO's root
account. Generated by `ansible-playbook prepare-velero.yml --ask-vault-pass`,
whose last task prints the exact `kubectl create secret ... | kubeseal`
command.

Until then, `velero/cloud-credentials` is a hand-made copy of the old
`velero` Secret (still the root credential), made on 2026-09-26 to get
Velero running again. Delete that copy right before syncing the sealed
version, or annotate it as above: the controller won't overwrite it
otherwise.

## Back up the controller's key

Losing it makes everything here permanently undecryptable - there's no
recovery from git. Backed up offline 2026-09-26; see
`argocd/apps/sealed-secrets.yaml`'s header for the command.
