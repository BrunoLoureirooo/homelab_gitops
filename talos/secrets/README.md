# talos/secrets: encrypted secrets only

This directory holds SOPS+age encrypted files and nothing else. Never put a
plaintext bundle, a talosconfig, a kubeconfig or the private age key here.

| File | What |
|---|---|
| `secrets.sops.yaml` | the Talos secrets bundle (cluster CA, tokens), encrypted |
| `tailscale-<node>.sops.yaml` | a complete `ExtensionServiceConfig` named `tailscale` that adds the auth key, encrypted |

## 1. Create the age key pair (offline machine, decision D3)

    age-keygen -o <keyfile>
    age-keygen -y <keyfile>        # prints the PUBLIC recipient

Keep `<keyfile>` only on encrypted offline media plus one second copy; never only
on mini01 and never inside the cluster. Paste only the public recipient line into
`talos/.sops.yaml` (replace the placeholder) and commit that.

## 2. Create and encrypt the secrets bundle

    talosctl gen secrets -o <tmpfile>
    sops -e --input-type yaml --output-type yaml <tmpfile> > talos/secrets/secrets.sops.yaml
    shred -u <tmpfile>             # or rm -P on macOS

Rendering then decrypts it for the duration of one render and removes the
plaintext copy on exit (`render.sh --check-secrets-clean` proves nothing is left).

## 3. Tailscale auth key (per node, at cutover time)

In the admin console create a single-use, pre-approved, untagged key with a one-day expiry
(tagging it `tag:talos` is a possible future improvement). Put the complete service config in a
temporary file, encrypt it with `sops -e` into `tailscale-<node>.sops.yaml`
(same document as `patches/tailscale.yaml` plus the auth key environment entry),
then shred the temporary file. The key is never written to git, a log or a PR
description.

## 3b. Disk inventory (mini01's two Toshibas)

Both 320 GB Toshibas are formatted by Talos and they are the same model, so each is
pinned by serial number. On the live mini01 read them with `lsblk -dno NAME,SERIAL`
(the serials are not printed by `hw-capture.sh`), then:

    printf 'media: <serial of the disk that is /srv/media today>\nmedia2: <serial of the other>\n' > <tmpfile>
    sops -e --filename-override secrets/disks-mini01.sops.yaml --input-type yaml --output-type yaml <tmpfile> > talos/secrets/disks-mini01.sops.yaml
    rm -P <tmpfile>

`render.sh` decrypts it and builds the `media` (`/var/mnt/media`) and `media2`
(`/var/mnt/media2`) volumes from it. Without the file only one size-band `media` volume is
rendered, which is ambiguous with two matching disks, so the preflight fails (PF-11).

## 4. Rotation and loss

Rotate by creating a new key pair, adding the new recipient to `.sops.yaml`,
`sops updatekeys` on each file, then retiring the old key. What the key protects:
the whole cluster CA. Losing both copies of the private key means losing the
bundle, which means a new cluster identity: workload data is restored from Velero.
Keep a backup of the encrypted bundle outside this repository too.
