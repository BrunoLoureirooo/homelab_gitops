# kiosk role (mini04)

Turns a plain Debian 13 box into a wall display: `cage` (a single-window
Wayland compositor) runs Chromium in kiosk mode on tty1 as an unprivileged
`kiosk` user (no sudo, no SSH keys, locked password, nologin shell, no
kubeconfig). It shows an anonymous, read-only Grafana dashboard over the
tailnet. Applied by `ansible/mini04.yml` together with `host_config`.
Untested on real hardware.

## Day 0 (by hand, once, on mini04)

```bash
su -
apt install sudo openssh-server
usermod -aG sudo <your-user>        # log out and back in afterwards
```

Then from your laptop: `ssh-copy-id <your-user>@<lan-ip>`.

## Set the variables

1. `ansible/inventory.yml`, host `mini04`: set `ansible_user` (the
   `TODO(user)` line) or pass `-e mini04_user=<your-user>`.
2. Add the two vault vars (examples are in `group_vars/all/vault.yml.example`):

   ```bash
   cd ansible
   ansible-vault edit group_vars/all/vault.yml
   # add:
   #   vault_become_password_mini04: "<mini04 sudo password>"
   #   vault_kiosk_url: "https://grafana.<tailnet-name>.ts.net/?kiosk"
   ```

## Run

```bash
cd ansible
# preview first; until mini04 is on the tailnet, point at its LAN address
ansible-playbook --check --diff --ask-become-pass --ask-vault-pass -e ansible_host=<lan-ip> mini04.yml
ansible-playbook --ask-become-pass --ask-vault-pass -e ansible_host=<lan-ip> mini04.yml

# join the tailnet (on mini04), then drop `-e ansible_host=...` from later runs
sudo tailscale up --hostname=mini04
```

## Change the dashboard

`kiosk_url` is `vault_kiosk_url` (the tailnet name stays out of git). Edit it
with `ansible-vault edit group_vars/all/vault.yml`, using the form
`https://grafana.<tailnet-name>.ts.net/d/<uid>/<slug>?kiosk&refresh=1m&theme=dark`,
and re-run `mini04.yml`. A changed URL rewrites `kiosk.service` and restarts it.
For a one-off, `-e kiosk_url=...` works too.

## Notes

- Grafana must allow anonymous Viewer access (see the monitoring manifests).
- `cage -s` allows Ctrl-Alt-F2 to reach a login prompt on a keyboard. That is
  the recovery path; SSH is the other.
- `kiosk.service` uses its own PAM service (`/etc/pam.d/kiosk`) as the cage
  wiki recommends.
- Defaults (user, groups, tty, packages, Chromium flags) are in
  `defaults/main.yml`. Sleep, suspend and hibernate targets are masked.
