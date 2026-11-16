# Handoff (updated 2026-10-11, after planning completed)

Branch: `plan-golden-image` (worktree `.claude/worktrees/service-roles`), based on `origin/main`. Local commits only: nothing pushed or merged. This session changed nothing on mini01, victus or the cluster (read-only access throughout).

## State

| Item | State |
|---|---|
| Phase 1 spec (`phases/01-golden-image/01-SPEC.md`) | Done (21 requirements), SPEC/REQUIREMENTS consistency fixed after the checker |
| Research (`01-RESEARCH.md`, `01-RESEARCH-DR.md`, `01-RESEARCH-TPM2.md`) | Done |
| Validation strategy (`01-VALIDATION.md`) | Done, map covers all 79 tasks |
| Plans `01-01` .. `01-27` + `01-PLAN-INDEX.md` | Done: 27 plans, 11 waves, one PR each |
| Plan checker | Round 1: 0 blockers, 4 warnings (applied), 4 advisories (recorded in the index). Round 2 not run (changes were small text fixes) |
| Phase 1.1 MagicDNS spec (`phases/01.1-magicdns-tls-san/`) | Spec written; not discussed or planned |
| Execution | NOT started. Do not execute until the operator has reviewed the plans |

## What to do next

1. Read `01-PLAN-INDEX.md` (plan table, merge order, flagged assumptions).
2. Answer the flagged assumptions (index section d); defaults are in the plans: Sealed Secrets `keyrenewperiod: "0"` (merge 01-08 before ~2026-10-26), reuse Velero's MinIO user for DB dumps, no second off-victus backup copy (recorded risk), separate Vault id `luks` for the recovery passphrase, TPM2 skipped, locations of offline Tang-key / LUKS-header / Sealed-key backups are yours to choose.
3. Optionally re-run the three read-only judges (host, cluster, plan) against the finished plans, then `/gsd-plan-review-convergence` or `/gsd-review`.
4. Push the branch and open a docs-only PR for `.planning/` when you want it reviewed (not done).
5. Execute with `/gsd-execute-phase 1` starting at plan 01-01 (deploy path filter, `.github/` only; nothing under `ansible/**` may merge before it).

## Private audit inputs (NOT in the repo, contain host details)

`<private audit directory>` (`mini01-host.md`, `mini01-cluster.md`, `repo-provisioning.md`, `judge-host.md`, `judge-cluster.md`, `judge-plan.md`). They vanish if the job is deleted: copy them somewhere private. Never commit them.

## Root-only facts still missing (run on mini01, read-only; do not paste output into the repo)

`sudo vgs; sudo lvs` (does 64+8 GiB fit the 256 GB disk with TopoLVM data?); NIC firmware in `dmesg` (is `firmware-realtek` needed in the initramfs?); `sudo ls /var/lib/rancher/k3s/server/manifests /var/lib/rancher/k3s/server/static/charts`; first 3 characters of the k3s token file (token format); `mokutil --sb-state`. Several are operator-run checks inside plan 01-15 and 01-24.

## Decisions taken by the operator

Preseed via Ventoy; installer asks disk + LUKS passphrase + admin password; password equals `ANSIBLE_BECOME_PASSWORD`; root 64 GiB / swap 8 GiB; generic template + per-node profiles; Tailscale join via a new Ansible role; MagicDNS move delayed to Phase 1.1; one big Phase 1; mini01 disk migration only on request; unattended unlock wanted, Tang on victus primary.

## Decisions taken by the assistant on defaults (review)

mini01 `MIN_DISK_GIB` 160; per-node Ventoy menu; LUKS pre-erase off; unplug/identify the Toshiba at the disk prompt; TPM2 skipped this phase; CNPG adopted byte-identical (no upgrade); Immich DB backup as pg_dump CronJob; Argo order scripted not waved; k3s rebuild default = fresh cluster with break-glass copy; restic CronJob retired; edge/prohibition rows in the spec resolved by the assistant.
