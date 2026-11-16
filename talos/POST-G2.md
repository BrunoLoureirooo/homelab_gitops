# After gate G2 (operator-run; plan 15-09 Tasks 5 and 6)

Nothing here runs before `G2: PASS <date>` is in `talos/CUTOVER.md`. Each step starts
with the gate check:

    grep -q '^G1 DECISION: go' talos/FINDINGS.md && grep -q '^G2: PASS' talos/CUTOVER.md

## 1. Prove the new deploy path works (plan 15-08 merged first)

Actions, "Talos deploy", `mode=check`, `scope=config`; then `scope=argocd-health`. Make a
trivial reviewed config change (a node label), approve the `talos-apply` environment,
confirm `DEPLOY ... APPLIED`, then revert it the same way. Put the `DEPLOY` lines in the
pull request description (node name and result only).

## 2. Retire the Ansible deploy path (ONE commit)

After you say "retire ansible deploy". In a single commit, so that no commit exists in
which a push to `ansible/**` can still deploy:

- remove everything mini01-side from `.github/workflows/deploy.yml`. Decided 2026-10-15
  (the operator): keep a minimal Ansible for the victus host only, so drop its `push` trigger and
  the mini01 job and leave only the victus job under `workflow_dispatch` (deleting the
  whole workflow is the other option, not chosen);
- put a legacy banner at the top of `ansible/README.md` (done);
- write `talos/G2-PASSED` (a one-line file with the date), which also switches
  `check-runbook.sh` and `check-coverage-ledger.sh` to strict path checking.

Then `bash .github/scripts/check-workflow-safety.sh` must pass.

## 3. Cleanups, in this order, each on the machine named

1. GitHub, Settings, Actions, Runners: remove the self-hosted runners for the old mini01
   and for victus.
2. victus: stop and disable the runner service and delete its work directory.
3. victus: remove the old mini01 runner SSH key from `authorized_keys` if it was added
   there (the deploy doc names the comment).
4. GitHub: delete the secret `ANSIBLE_VAULT_PASSWORD` and the environment `mini01` with
   its `ANSIBLE_BECOME_PASSWORD`.
5. victus: DONE 2026-11-04 (k3s agent uninstalled, standalone MinIO and its data removed, the 512 wiped).
   The victus HOST is not part of the Talos cluster; keep Tailscale. A Talos worker, mini03, runs on victus
   later as a libvirt VM (decided 2026-10-15, reworked 2026-10-19: arr stack, torrents behind a
   VPN and a second copy of the backups), see `docs/dr/mini03.md`; that is a separate step after
   this checklist, not part of it.

## 4. Close PR #40 without merging (you, never the assistant)

Preconditions: both gate lines above, and `bash talos/scripts/check-no-image-dependency.sh`
exits 0. Salvage decision: name anything from #40 you want on `main` (default: nothing).

    gh pr close 40 --comment "Superseded by the Talos route (Phase 1.5): G1 and G2 passed. Branch kept for 30 days for reference."

Do not pass `--delete-branch`. After 30 days:
`git push origin --delete phase1/image-install` and remove the local worktree.

## 5. Apply the planning rewrite

The planning rewrite files were applied and removed. Run `bash .github/scripts/check-runbook.sh`,
`bash .github/scripts/check-coverage-ledger.sh` and
`bash .github/scripts/check-talos-secrets.sh`; fill the drill record of
`docs/rebuild-node.md` from `talos/CUTOVER.md` and turn each proven `DRILL-PENDING` row
of the ledger into `RESTORED`.

## 6. Merge the Argo CD trees (decision D8)

Done in the draft PR "merge the Argo trees, step 1": the k3s-only apps are deleted
(`argocd/apps/minio.yaml`, `topolvm.yaml`, `argocd/charts/minio`, `argocd/values/topolvm.yaml`,
`argocd/sealed-secrets/minio-creds.yaml`) and `exclude:` in `talos/apps-overrides.yaml` is empty.

Still to do after that PR, once the Talos root has been healthy for the two-week hold:
make `argocd/apps/` the only tree (move the Talos-only apps from `talos/apps-src/` in, apply the
`rename`, `path`, `extra_valuefiles` and `manifest_copies` overrides to the sources, point
`talos/root.yaml` at it, delete `talos/render-apps.sh`, `talos/apps/` and the overrides file) and
update `check-talos-apps.sh` accordingly. This is deferred deliberately: the generator is what
CI uses to prove the Talos set matches the live set, and that proof is no longer needed only
after the live k3s cluster is gone.
