#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# Load definitions without the interactive entry point.
# shellcheck source=/dev/null
source <(sed '/^# When piped into bash/,$d' "$root/setup.sh")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

expect_rejected() {
  if validate_ssh_key "$1" 2>/dev/null; then
    printf 'FAIL: accepted %s\n' "$2" >&2
    exit 1
  fi
}

ssh-keygen -q -t ed25519 -N '' -f "$tmp/ed25519"
ssh-keygen -q -t ecdsa -N '' -f "$tmp/ecdsa"
ssh-keygen -q -t rsa -b 2048 -N '' -f "$tmp/rsa2048"
ssh-keygen -q -t rsa -b 3072 -N '' -f "$tmp/rsa3072"

validate_ssh_key "$DEFAULT_SSH_KEY"
validate_ssh_key "$(cat "$tmp/ed25519.pub")"
validate_ssh_key "$(cat "$tmp/rsa3072.pub")"
expect_rejected "$(cat "$tmp/ecdsa.pub")" ECDSA
expect_rejected "$(cat "$tmp/rsa2048.pub")" '2048-bit RSA'
expect_rejected 'ssh-ed25519 invalid' 'malformed key'
expect_rejected '' 'empty input'
expect_rejected 'not a key' 'non-key input'

ssh-keygen -q -s "$tmp/ed25519" -I review -n review "$tmp/rsa3072.pub"
expect_rejected "$(cat "$tmp/rsa3072-cert.pub")" 'certificate requiring separate trust validation'
echo 'SSH key validation tests passed'
