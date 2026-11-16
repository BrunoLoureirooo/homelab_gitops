# CLAUDE.md

## Public repository

This repo is PUBLIC. Everything committed is world-readable, history included.

- No private data anywhere in the tree: code, docs, comments, fixtures, planning files.
- Private data means: tailnet names and hostnames, Tailscale/LAN/public IPs, MACs, serials, emails, phone numbers, schedules/locations/routines, credentials, tokens and keys.
- A chart's committed `values.yaml` defaults count as part of the tree too.
- Put such values in a SealedSecret (`kubeseal --cert argocd/sealed-secrets/pub-cert.pem`), SOPS (`talos/secrets/`) or Ansible Vault (`ansible/group_vars/all/vault.yml`).
- In docs use placeholders: `<tailnet>`, `<host>.<tailnet>.ts.net`, `<ip>`.
- `.github/scripts/check-no-host-details.sh` is the guard; run it (and `run-all-guards.sh`) before every commit.
- The owner's name and country are fine (already public on their profile).
