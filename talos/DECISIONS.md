# Decisions for the operator (plan 15-02, task 4)

Four decisions only you can make. Each has a default so CI keeps moving. Edit the
`ANSWER:` line (leave `DEFAULT` to accept the default). Plan 15-07 will not start
the hardware step until none of them is still `DEFAULT`:
`bash .github/scripts/check-talos-config.sh --require-decisions`.

## D1: Secure Boot and the UKI installer

Options:
- (a) Secure-Boot-capable UKI installer, Sidero's keys enrolled by hand in the
  firmware. Keeps the upgrade path to Secure Boot; may be impossible on the 2018
  BIOS.
- (b) UKI installer with Secure Boot disabled. Keeps (a) open later; the docs say a
  classic GRUB install cannot be upgraded to Secure Boot.
- (c) Classic installer with Secure Boot disabled. Cannot move to Secure Boot later
  without a reinstall.

Default (the operator, 2026-10-12): try (a) first; if the BIOS refuses setup mode or the
enrolment fails, fall back to (b) and record the accepted risk. (c) is used only
when the `find-uki-boot` job (plan 15-04) is not PASS.

ANSWER: (b) UKI installer with Secure Boot disabled (the operator, 2026-10-15). mini01 installs from the Secure Boot (UKI) ISO and the installer-secureboot image; no keys are enrolled and the firmware Secure Boot stays off, so the BIOS and the Debian rollback are untouched. Set by INSTALLER in talos/nodes/mini01.env.

## D2: Cluster endpoint form

Options:
- a short hostname (`mini01`) that resolves from the nodes through a DHCP
  reservation or a MagicDNS short name (default);
- a fixed LAN address kept only in the untracked `talos/local/cluster.local.env`;
- a tailnet name kept only in the same untracked file.

The full tailnet name and any address never enter git.

ANSWER: a short hostname, `mini01` (the operator, 2026-10-15). Needs a DHCP reservation or a MagicDNS short name for mini01 (and victus) before the cutover.

## D3: Custody of the age private key (it protects the whole cluster CA)

Describe the medium and the two copies in words only, for example "an offline
encrypted drive and a printed copy in a safe place". Nothing machine-specific. The
key is never only on mini01 and never inside the cluster. Creation steps are in
`secrets/README.md`.

ANSWER: an encrypted offline drive plus a printed copy, two physically separate places, neither on mini01 nor inside the cluster (the operator, 2026-10-15).

## D4: Disk selectors

Confirm the install target of mini01 is the 256 GB NVMe, and whether `type` plus
`size` is enough or `busPath` or `model` is needed. These are hardware facts the
repository cannot read: answer from the BIOS screen or a read-only disk listing on
the machine, and put the result in the untracked `talos/local/<node>.local.env`.
The 512 GB disk also matches the committed selector (nvme, at least 200 GB), which
is why the 512 is physically out of the machine at install time.

Defaults: mini01 `nvme` and `>= 200GB`; mini02 `ssd` and `>= 100GB`.

ANSWER: the defaults stand (the operator, 2026-10-15): mini01 `nvme` and `>= 200GB`, mini02 `ssd` and `>= 100GB`. The 512 GB disk also matches mini01's selector, so it is physically out of the machine at install time and the install disk is confirmed against the printed disk list.
