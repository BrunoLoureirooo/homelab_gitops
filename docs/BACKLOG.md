# Homelab backlog

The single list of services and their state. Update it in the same PR that changes a service's
state. Last reviewed: 2026-11-05.

Status words: **Done** (running, verified), **Partway** (some of it exists), **Planned** (agreed, not
started), **Running off-cluster**, **To remove**, **Dropped**.

## Services

| Service | Status | Notes |
|---|---|---|
| Immich | Done | Library on mini02 over SMB (`tank/immich`), reachable on the tailnet |
| Vaultwarden | Done | |
| AdGuard Home | Done | Blocking verified |
| Jellyfin | Done | Library on mini01's two Toshiba disks; Quick Sync playback |
| Velero backups (MinIO on mini02) | Done | Nightly and hourly schedules; second copy is below |
| Tailscale access (operator) | Done | |
| Sealed secrets | Done | |
| cp-reserva-bot | Done | Running |
| NAS (Samba on the mini02 ZFS pool) | Partway | Running; ZFS datasets job, SMB on the tailnet are merged; shares are `shared`, `paperless`, `immich`. Hand-off plan: `docs/plans/nas-completion.md` |
| mini03 (VM on victus) | Partway | Talos worker VM on victus, joined 2026-11-05 (labels `tier=mobile`, `pool=media-backup`, taint `NoSchedule`; volumes `data`, `backups`, `staging`). Still to do: smoke test, victus reboot test, detach the install ISO, rebuild runbook |
| Second backup copy (on mini03) | Partway | Replica MinIO live; first mirror complete 2026-11-05 (4,698 objects, 51.7 GiB), daily at 13:00 UTC. Pending: restore drill and a failure alert |
| Sonarr and the arr stack | Planned | Runs on mini03 |
| Torrent client with gluetun VPN | Planned | VPN provider undecided (port forwarding needs ProtonVPN or PIA) |
| Paperless | Planned | Uses the NAS `paperless` share |
| Monitoring | Partway | Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter drafted in the `monitoring` app (plan `docs/plans/monitoring.md`); not synced yet (PR #128 open; alerts go to Discord, decisions D1/D4 made; the webhook secret still has to be sealed). Pending: probes, display |
| Authentik | Pending | Single sign-on (identity provider) |
| Uptime Kuma | Dropped | Redundant with Prometheus/Alertmanager + healthchecks.io watchdog |
| Actual Budget | Partway | Drafted: manifests and manual-sync Argo app `actual-budget` (mini01, tailnet only, 2Gi `topolvm-fast`, covered by the nightly `homeserver` Velero backup). Also drafted: Coverflex meal-card importer (`actual-mealcards`), shipped at 0 replicas until the Actual account, token and sealed Secret exist (plan section 7a). Not synced yet. Plan: `docs/plans/actual-budget.md` |
| Homepage | Planned | Dashboard |
| Terraria server | Planned | Game server; node to be decided |
| Local LLM | Running off-cluster | On Bruno's work hardware, outside business hours; not part of this cluster |
| spotify-saver | Removed (repo and cluster); leftover volume pending | See "Leftover: spotify-saver" below |
| Home Assistant | Dropped | Removed from the plan 2026-10-24 |

## Leftover: spotify-saver

The app is gone from the repo and the cluster. One step remains for Bruno: delete the Released
PersistentVolume bound to `homeserver/spotifysaver-data` (it was empty). Two reminders that need a person:

- Remove the `spotifysaver` device in the Tailscale admin console (Machines).
- Delete the app in the Spotify developer dashboard.

## Other open work (not services)

- mini03 finish line (`docs/plans/mini03-vm.md`, section 0): the smoke-test pod (WP8), the two-way
  network and MTU check (WP10), the victus reboot test (WP11), then detach the install ISO.
- Restore drill from the mini03 replica (restore Vaultwarden into a scratch namespace): the only proof the
  second copy is usable.
- Failure alert for the mirror job and for `tank/backups` usage: the alert rules are written (monitoring app);
  they reach your phone only once the alert channel is chosen (decision D1 in the monitoring plan).
- Rebuild mini03 from the repo alone: the endpoint address lives only in an untracked local file, the VM
  settings in `~/victus-vm.local.yml`, and the first-boot lessons are not written down yet.
- Second copy of the photo library outside the house: decision pending (cloud bucket, external disk, or
  both). The mini03 replica is a second machine, not a second site.
- mini01 CPU upgrade (7th-gen part, BIOS update first); afterwards re-enable HEVC 10-bit hardware decoding.
- Check that Dan Da Dan has metadata in Jellyfin after the rename.
- DHCP reservations on the router and the endpoint-name switch.
- Post-cutover PRs #53 and #54: held on purpose.
- Temporary stopgaps from the mini01 install (see the memory note on temporary cleanup).
