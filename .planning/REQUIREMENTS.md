# Requirements

Detail and acceptance criteria live in `phases/01-golden-image/01-SPEC.md` (R1-R22).

- **IMG-01** A reproducible, encrypted Debian 13 install (preseed + LUKS/LVM `vg0` + Tang network-bound unlock on victus with dropbear fallback) for mini01-class UEFI hardware. (R1, R2, R3, R7, R8)
- **IMG-02** A generic, secret-free model: node-agnostic template, committed per-node profiles, local render, Ventoy menu; no secret or host detail in git, CI or artifacts. (R4, R5, R21)
- **IMG-03** CI proves the install in QEMU (incl. rebuild-over-existing-disk, negative control) and runs Ansible against the built VM. (R6, R12)
- **IMG-04** Ansible is bare-node ready: Tailscale join role, bare-node fixes, declared host baseline, deploy path filter; every change a proven live no-op. (R9, R10, R11) IP/`tls-san` de-hardcoding moved to Phase 1.1.
- **IMG-05** GitOps and DR are rebuildable: CNPG operator in git, Postgres backup, Sealed Secrets key restore, Velero hardening and restore drill, empty-cluster sync order, k3s server state and victus rejoin. (R13-R18)
- **IMG-06** A rebuild runbook and a coverage ledger prove every live mini01 item is declared, documented, expendable or restored, with none uncovered. (R19, R20)
