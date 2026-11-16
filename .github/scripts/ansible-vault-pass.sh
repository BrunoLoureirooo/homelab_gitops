#!/usr/bin/env bash
# ansible-playbook's --vault-password-file accepts an executable script:
# it runs this and reads the password from stdout, instead of a plaintext
# password file sitting on disk. Used by .github/workflows/deploy.yml on
# the GitHub-hosted runners - the real value lives only in the
# ANSIBLE_VAULT_PASSWORD GitHub Actions secret (repo-level, since it's the
# same group_vars/all/vault.yml everywhere), which GitHub Actions
# automatically masks in all logs regardless. This script itself never
# writes the value to disk.
set -euo pipefail
echo "$ANSIBLE_VAULT_PASSWORD"
