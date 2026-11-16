# mini01 coverage ledger (Talos)

What the Talos mini01 consists of, and for each part how a rebuild gets it back.
The ledger names things; it never contains addresses, identifiers, keys or values.
`.github/scripts/check-coverage-ledger.sh` keeps it honest.

> Status: written before the first drill (plan 15-09). Rows that restore data are
> `DRILL-PENDING` until their drill passes in the drill record of
> `docs/rebuild-node.md`; then they become `RESTORED`.

Dispositions:

- `DECLARED`: defined in a file of this repository (the Detail column is that path,
  which must exist).
- `MANUAL-DOCUMENTED`: a human step, written down (the Detail column is an anchor in
  `docs/rebuild-node.md`, which must exist).
- `EPHEMERAL`: deliberately not kept, with a reason of at least five words.
- `RESTORED`: comes back from a backup, proven by a PASS drill (the Drill column).
- `DRILL-PENDING`: restores from a backup but the proving drill has not passed yet
  (the Drill column names it).
- `UNCOVERED` is not allowed to appear.

| Item | Category | Disposition | Detail | Drill |
|---|---|---|---|---|
| Install disk selection | machine-config | DECLARED | talos/nodes/mini01.yaml | |
| Common kernel arguments, sysctls and time sync | machine-config | DECLARED | talos/patches/common.yaml | |
| Control-plane settings and certificate SANs | machine-config | DECLARED | talos/patches/controlplane.yaml | |
| Worker settings | machine-config | DECLARED | talos/patches/worker.yaml | |
| Tailscale extension service configuration | machine-config | DECLARED | talos/patches/tailscale.yaml | |
| System extensions through the schematic | extensions | DECLARED | talos/schematics/mini01.yaml | |
| Data and media volumes of mini01 | volumes | DECLARED | talos/patches/volumes-mini01.yaml | |
| mini02 node configuration | machine-config | DECLARED | talos/nodes/mini02.yaml | |
| Pinned Talos version, media hashes and tool pins | machine-config | DECLARED | talos/versions.env | |
| Cluster secrets bundle (encrypted, key held offline) | machine-config | MANUAL-DOCUMENTED | docs/rebuild-node.md#boot-install-and-bootstrap | |
| Sudoers rules | host-userland | EPHEMERAL | no host userland exists on Talos, which is immutable and API-only | |
| SSH daemon settings | host-userland | EPHEMERAL | no host userland exists on Talos, which is immutable and API-only | |
| Installed packages | host-userland | EPHEMERAL | no host userland exists on Talos, which is immutable and API-only | |
| Host firewall rules | host-userland | EPHEMERAL | no host userland exists on Talos, which is immutable and API-only | |
| Systemd units and timers | host-userland | EPHEMERAL | no host userland exists on Talos, which is immutable and API-only | |
| Login users and groups | host-userland | EPHEMERAL | no host userland exists on Talos, which is immutable and API-only | |
| k3s service files | host-userland | EPHEMERAL | the k3s service is replaced by the Talos Kubernetes control plane | |
| Argo CD root application | platform-apps | DECLARED | talos/root.yaml | |
| Cluster baseline | platform-apps | DECLARED | argocd/apps/cluster-baseline.yaml | |
| Sealed Secrets controller | platform-apps | DECLARED | argocd/apps/sealed-secrets.yaml | |
| Sealed secrets for the apps | platform-apps | DECLARED | argocd/apps/secrets.yaml | |
| Talos-only sealed secrets | platform-apps | DECLARED | talos/apps-src/talos-sealed-secrets.yaml | |
| Certificate manager | platform-apps | DECLARED | argocd/apps/cert-manager.yaml | |
| Tailscale operator | platform-apps | DECLARED | argocd/apps/tailscale-operator.yaml | |
| Velero and its hourly schedule | platform-apps | DECLARED | argocd/apps/velero.yaml | |
| Immich database cluster | platform-apps | DECLARED | argocd/apps/immich-infra.yaml | |
| Immich | platform-apps | DECLARED | argocd/apps/immich.yaml | |
| Vaultwarden volume claim | platform-apps | DECLARED | argocd/apps/vaultwarden-pvc.yaml | |
| Vaultwarden | platform-apps | DECLARED | argocd/apps/vaultwarden.yaml | |
| cp-reserva-bot | platform-apps | DECLARED | argocd/apps/cp-reserva-bot.yaml | |
| Jellyfin application | platform-apps | DECLARED | talos/apps-src/jellyfin.yaml | |
| Jellyfin manifests with Quick Sync device access | platform-apps | DECLARED | talos/manifests/jellyfin/kustomization.yaml | |
| Storage class for local volumes | platform-apps | MANUAL-DOCUMENTED | docs/rebuild-node.md#platform-and-restore-order | |
| Sealed-secrets private key | cluster-data | MANUAL-DOCUMENTED | docs/rebuild-node.md#platform-and-restore-order | |
| Standalone MinIO on the backup host | cluster-data | MANUAL-DOCUMENTED | docs/rebuild-node.md#platform-and-restore-order | |
| Vaultwarden vault data | cluster-data | DRILL-PENDING | | D-VW |
| Immich database | cluster-data | DRILL-PENDING | | D-PG |
| Immich photo library | cluster-data | DRILL-PENDING | | D-LIB |
| cp-reserva-bot WhatsApp session | cluster-data | DRILL-PENDING | | D-CP |
| etcd cluster state | cluster-data | DRILL-PENDING | | D-ETCD |
| Whole-node rebuild from bare metal | cluster-data | DRILL-PENDING | | D-REBUILD |
| Upgrade and rollback keep the data volumes | cluster-data | DRILL-PENDING | | D-UPGRADE |
| Recovery after losing the system disk | cluster-data | DRILL-PENDING | | D-DISKLOSS |
| Secure Boot state is whatever the cutover record says | accepted-risks | MANUAL-DOCUMENTED | docs/rebuild-node.md#accepted-risks | |
| Disk encryption is deferred | accepted-risks | MANUAL-DOCUMENTED | docs/rebuild-node.md#accepted-risks | |
| Single control plane | accepted-risks | MANUAL-DOCUMENTED | docs/rebuild-node.md#accepted-risks | |
| Backup copy lives on one host | accepted-risks | MANUAL-DOCUMENTED | docs/rebuild-node.md#accepted-risks | |
| Non-database volumes can lose up to an hour | accepted-risks | MANUAL-DOCUMENTED | docs/rebuild-node.md#accepted-risks | |

## Read-only re-audit of the live node (operator-run, after the cutover)

Nothing here is committed; the output stays on your machine. The question to answer
in the pull request is "is there anything on the node or in the cluster without a
row above?":

- `talosctl -n <node> get extensions`
- `talosctl -n <node> get machineconfig` (stored locally, never committed)
- `kubectl get ns,pvc -A`
