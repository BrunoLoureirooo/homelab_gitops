# mini03 finish line: smoke test, network check, victus reboot test, ISO detach

The operator runs these. Nothing here is run by automation. Order matters: 1, 2, 3, 4.
Plan reference: `docs/plans/mini03-vm.md` (WP8, WP10, WP11).

## 1. Smoke test (WP8)

Read-only first:

    bash talos/dr/mini03-smoke.sh --check

Then the real run (makes a scratch namespace, a pod on mini03, writes to the `data` volume, proves a pod
without the toleration stays Pending, and deletes the namespace and the leftover volume object):

    bash talos/dr/mini03-smoke.sh --run admin@<cluster> admin@<cluster>

Pass means the last line is `SMOKE PASS`.

## 2. Two-way network, MTU and time check (WP10)

Pass the context and the IP of each node (used only for `talosctl` reads; do not commit them):

    bash talos/dr/mini03-network-check.sh admin@<cluster> <mini01-ip> <mini02-ip> <mini03-ip>

Pass means `NETWORK PASS`: time synced on every node, and a 3 MB file moved both ways between a pod on
mini01 and a pod on mini03. Compare the printed pod MTU values with each other; they should match.

## 3. victus reboot test (WP11)

Do this when nobody is gaming. Before:

    kubectl --context admin@<cluster> get nodes

On victus: `sudo systemctl reboot`. After you log back in:

    virsh -c qemu:///system list --all           # mini03 should be "running" (autostart)
    systemctl is-active victus-vm-awake.service  # should print "active"
    systemd-inhibit --list                       # should show a "block" entry for mini03

From the Mac, watch the node return (a few minutes):

    kubectl --context admin@<cluster> get nodes -w

Graceful stop and start (on victus):

    virsh -c qemu:///system shutdown mini03      # "shut off" within a minute
    virsh -c qemu:///system start mini03

If it did not autostart: `virsh -c qemu:///system autostart mini03`.

## 4. Detach the install ISO

Once the node has joined and the reboot test passed, the ISO is no longer needed. In
`~/victus-vm.local.yml` set:

    victus_vm_install_iso: ""

Then re-run the host play (check mode first, then apply), and restart the VM so the empty CD drive takes
effect (use the graceful stop and start from step 3):

    ansible-playbook ansible/victus.yml --limit victus --check --diff
    ansible-playbook ansible/victus.yml --limit victus

The ISO file on victus can be deleted afterwards.
