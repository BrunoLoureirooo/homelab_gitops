# talos: the Talos cluster

Machine config, CI harness, Argo CD app set and cutover helpers for the Talos cluster (mini01
control plane, mini02 worker, mini03 worker VM). Overview: `../README.md`; roadmap:
`.planning/ROADMAP.md`; rebuilding a node: `docs/rebuild-node.md`. The CI jobs touch no live
host; the scripts that change the live cluster are run by the operator.

| Path | Role |
|---|---|
| `versions.env`, `schematics/`, `fetch-assets.sh`, `refresh-pins.sh` | pinned Talos/Kubernetes/tool versions, Image Factory schematics, asset download with hash checks |
| `test/direct-boot.sh`, `test/lib.sh` | the one QEMU driver and the shell helpers every job uses |
| `test/jobs/*.sh` | one CI job per script (header `# talos-job: kvm=yes\|no timeout=<min> [heavy=yes]`) |
| `test/patches/` | CI-only machine config patches (the only place `/dev/` paths and QEMU addresses may appear) |
| `cluster.env`, `patches/`, `nodes/`, `render.sh` | machine config as patches plus per-node files; `render.sh` builds a node's config |
| `.sops.yaml`, `secrets/` | SOPS+age secrets bundle workflow (public recipient only; see `secrets/README.md`) |
| `DECISIONS.md` | decisions only the operator can make, with defaults CI can use |

## Pins

`versions.env` holds every version and sha256. While `PINS-PENDING` exists the
values are placeholders and the VM jobs are skipped. Compute them on a machine
with internet:

    bash talos/refresh-pins.sh --write      # then commit versions.env

or dispatch the `Talos` workflow with `refresh_pins` and copy the uploaded
`versions.env.proposed` over `versions.env` (delete `PINS-PENDING`). To move to a
new Talos version: edit `TALOS_VERSION` (and the other manual versions), rerun
the script, commit.

## Run a job locally

On a Linux box with KVM: `bash talos/test/jobs/boot-single.sh` (needs `sudo`
for apt, `/dev/kvm`, internet). Reports land in
`tal-report-<job>.txt` and `findings-<job>.txt`; serial logs in `serial-*.log`.
Secrets are generated per run in `$RUNNER_TEMP/tal` (or `/tmp/tal`) and scrubbed
from every log.

## Cost (private repo, metered Actions minutes)

Light jobs: about 70 job-minutes per push that touches `talos/`. Heavy jobs
(plan 15-04, `heavy=yes`): about 230 job-minutes per full run; they run only on
a manual dispatch with `extended` or on a pull request labelled `talos-full`.

## Notes

- Two-node jobs join the VMs with a point-to-point socket network. If that proves
  unreliable on hosted runners, the fallback is a tap bridge (`ip tuntap` plus
  `-netdev tap`); the assertions do not change.
- The system disk has boot index 0 and the ISO index 1, so a blank disk falls
  through to the installer and an installed disk boots first.
