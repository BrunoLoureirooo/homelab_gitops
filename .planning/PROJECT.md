# Homelab: fast node stand-up

**Core value:** Any Debian node (mini01, mini02) can be rebuilt from bare metal to a working k3s member in minutes, from what is in this repo, with no hand-typed secrets in git.

## Context
- Public repo (this one); Ansible (`ansible/`), ArgoCD (`argocd/`), architecture in `docs/homelab-brief.md` and `docs/dr/mini02-talos.md`.
- Learning is the priority: follow real-infrastructure patterns (a golden image mirrors what the operator uses at work).
- Rules: one PR per step off a fresh branch from `origin/main`; the operator merges; never touch `ansible/**` casually (merging it auto-deploys to mini01); CI image builds run on GitHub-hosted runners only, never the self-hosted runner on mini01.
- Part of "B" (make install repeatable) of the disaster-recovery plan. Other DR items (Postgres backup, sealed-secrets key, Tailscale identity, runner registration) are separate work.

## Out of scope for this project
- Cluster workloads, ArgoCD apps, storage architecture (tracked in docs/).
