# Secrets setup

Deploy secrets live in GitHub **environments** that only `main` can use
(branch policy `main`), not in repo-level secrets. Names only here; never put
values in git.

Environments must exist before env secrets can be set. Either run
`.github/scripts/harden-repo.sh` first (creates them with the right branch
policy and reviewers), or create one by hand (no branch policy, so add that in
Settings afterwards):

```sh
gh api -X PUT repos/BrunoLoureirooo/homelab_gitops/environments/<name>
```

| Environment | Used by | Reviewer |
|---|---|---|
| `victus` | `deploy.yml` job `victus` (manual) | owner |
| `mini04` | `deploy.yml` job `mini04` (push to main, manual) | none (automatic deploys) |
| `talos-apply` | `talos-deploy.yaml` push / `mode=apply` | owner |
| `talos-check` | `talos-deploy.yaml` `mode=check` | none |

Each command prompts for the value (or reads stdin); run them from a shell
where the value is not recorded in history.

## Tailscale (all workflows): federated identity, no secrets

Every Tailscale step (`deploy.yml` victus and mini04, `talos-deploy.yaml`) joins
the tailnet by workload identity federation (OIDC). There are no Tailscale
secrets; the two values below are repo **variables**:

```sh
R=BrunoLoureirooo/homelab_gitops
gh variable set TS_CLIENT_ID -R $R --body <client-id>
gh variable set TS_AUDIENCE  -R $R --body <audience>
```

In the Tailscale admin console (Settings, Trust credentials) add a federated
identity:

- issuer: GitHub
- subject: `repo:BrunoLoureirooo/homelab_gitops:environment:*`
- scope: `auth_keys` write
- tag: `tag:ci`

Copy the client ID and audience the console shows into the variables above.
The jobs need `id-token: write`, which is granted at job level in `deploy.yml`
and at top level in `talos-deploy.yaml`.

Tailnet policy (placeholders only; use your own device names):

```json
{
  "tagOwners": {
    "tag:ci": ["<owner-login>"]
  },
  "hosts": {
    "mini01": "100.x.y.z",
    "mini02": "100.x.y.z",
    "mini03": "100.x.y.z"
  },
  "grants": [
    { "src": ["tag:ci"], "dst": ["mini01", "mini02", "mini03"], "ip": ["tcp:50000", "tcp:6443"] },
    { "src": ["tag:ci"], "dst": ["mini04", "victus"], "ip": ["tcp:22"] }
  ]
}
```

The Talos nodes are untagged, so they are reached through `hosts` aliases
(one per node; use your real tailnet addresses, never commit them). Narrow any
existing allow-all grant so its `src` is only `autogroup:member`, `tag:k8s` and
`tag:k8s-operator`; then `tag:ci` gets nothing beyond the grants above.

Possible future improvement: tag the nodes `tag:talos` by creating their auth
keys (`talos/secrets`) with that tag, then grant `tag:ci` to `tag:talos`
instead of the host aliases.

## victus

```sh
R=BrunoLoureirooo/homelab_gitops
gh secret set ANSIBLE_VAULT_PASSWORD  --env victus -R $R
gh secret set ANSIBLE_BECOME_PASSWORD --env victus -R $R
gh secret set CI_DEPLOY_SSH_KEY       --env victus -R $R < ~/.ssh/homelab-ci
```

## mini04

Same as victus without the become password (sudo uses the vault's
`vault_become_password_mini04`).

```sh
R=BrunoLoureirooo/homelab_gitops
gh secret set ANSIBLE_VAULT_PASSWORD --env mini04 -R $R
gh secret set CI_DEPLOY_SSH_KEY      --env mini04 -R $R < ~/.ssh/homelab-ci
```

## talos-apply and talos-check

`talos-deploy.yaml` reads one secret, `SOPS_AGE_KEY`. Set it in each
environment:

```sh
R=BrunoLoureirooo/homelab_gitops
gh secret set SOPS_AGE_KEY --env talos-apply -R $R < ~/.config/sops/age/keys.txt
gh secret set SOPS_AGE_KEY --env talos-check -R $R < ~/.config/sops/age/keys.txt
```

Variables it reads (`gh variable set NAME -R $R --body <value>`, repo level or
per environment with `--env`):

- `TALOS_NODES`: `mini01=mini01 mini02=mini02 mini03=mini03` (space separated
  `name=endpoint`, MagicDNS short names, control plane first).
- `TALOS_PING_HOST`: a Talos node's short name; the Tailscale step pings it
  before anything runs.
- `TS_CLIENT_ID`, `TS_AUDIENCE`: see the Tailscale section above.

Both workflows start with a step that fails with `::error::` naming any missing
variable or secret (names only, never values).

## Repo-level variable

`MINI04_USER` is mini04's login. It is a variable, not a secret, and stays out
of git:

```sh
gh variable set MINI04_USER -R BrunoLoureirooo/homelab_gitops --body <login>
```
