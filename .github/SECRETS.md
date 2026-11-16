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

## victus

```sh
R=BrunoLoureirooo/homelab_gitops
gh secret set ANSIBLE_VAULT_PASSWORD  --env victus -R $R
gh secret set ANSIBLE_BECOME_PASSWORD --env victus -R $R
gh secret set CI_DEPLOY_SSH_KEY       --env victus -R $R < ~/.ssh/homelab-ci
gh secret set TS_OAUTH_CLIENT_ID      --env victus -R $R
gh secret set TS_OAUTH_SECRET         --env victus -R $R
```

## mini04

Same as victus without the become password (sudo uses the vault's
`vault_become_password_mini04`).

```sh
R=BrunoLoureirooo/homelab_gitops
gh secret set ANSIBLE_VAULT_PASSWORD --env mini04 -R $R
gh secret set CI_DEPLOY_SSH_KEY      --env mini04 -R $R < ~/.ssh/homelab-ci
gh secret set TS_OAUTH_CLIENT_ID     --env mini04 -R $R
gh secret set TS_OAUTH_SECRET        --env mini04 -R $R
```

## talos-apply and talos-check

`talos-deploy.yaml` reads `SOPS_AGE_KEY` and `TS_OAUTH_SECRET` as secrets.
Set both in each environment:

```sh
R=BrunoLoureirooo/homelab_gitops
for e in talos-apply talos-check; do
  gh secret set SOPS_AGE_KEY   --env "$e" -R $R
  gh secret set TS_OAUTH_SECRET --env "$e" -R $R
done
```

Non-secret values it reads as variables: `TALOS_NODES`, `TS_CLIENT_ID`,
`TS_AUDIENCE`, `TALOS_PING_HOST` (set with `gh variable set NAME -R $R --body <value>`,
repo level or per environment with `--env`). When `TS_AUDIENCE` is set the
workflow uses OIDC and `TS_OAUTH_SECRET` is not read.

## Repo-level variable

`MINI04_USER` is mini04's login. It is a variable, not a secret, and stays out
of git:

```sh
gh variable set MINI04_USER -R BrunoLoureirooo/homelab_gitops --body <login>
```
