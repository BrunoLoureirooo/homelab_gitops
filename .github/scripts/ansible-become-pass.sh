#!/usr/bin/env bash
# ansible-playbook's --become-password-file, same mechanism as
# ansible-vault-pass.sh (an executable script instead of a file on disk) -
# see that script's header. The value comes from the ANSIBLE_BECOME_PASSWORD
# secret, scoped to the `victus` GitHub Actions Environment (deploy.yml's
# victus job). mini04 does not use this script: its sudo password comes
# from the vault (ansible_become_password in inventory.yml).
set -euo pipefail
echo "$ANSIBLE_BECOME_PASSWORD"
