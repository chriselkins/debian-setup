#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# Load definitions without the interactive entry point.
# shellcheck source=/dev/null
source <(sed '/^# When piped into bash/,$d' "$root/setup.sh")

# Model sshd -T output, including ListenAddress port overrides.
sshd() { printf '%s\n' "$mock_sshd_config"; return "${sshd_status:-0}"; }
expect_rejected() {
  if check_firewall_ssh_ports 2>/dev/null; then
    printf 'FAIL: accepted %s\n' "$1" >&2
    exit 1
  fi
}

mock_sshd_config=$'port 22\nlistenaddress [::]:22\nlistenaddress 0.0.0.0:22'
check_firewall_ssh_ports
mock_sshd_config=$'port 2222\nlistenaddress 0.0.0.0:2222'
expect_rejected 'custom port'
mock_sshd_config=$'port 22\nport 2222\nlistenaddress 0.0.0.0:22'
expect_rejected 'additional custom port'
mock_sshd_config=$'port 22\nlistenaddress 0.0.0.0:2222'
expect_rejected 'IPv4 ListenAddress override'
mock_sshd_config=$'port 22\nlistenaddress [::1]:2222'
expect_rejected 'IPv6 ListenAddress override'
mock_sshd_config=''
expect_rejected 'missing port information'
mock_sshd_config='port 22'
sshd_status=1
expect_rejected 'sshd configuration error'
sshd_status=0

# Refusal must precede package installation, file writes and service changes.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
apt-get() { touch "$tmp/mutated"; }
install_file() { touch "$tmp/mutated"; cat >/dev/null; }
systemctl() { touch "$tmp/mutated"; }
mock_sshd_config='port 2222'
if (step_firewall) >/dev/null 2>&1; then
  echo 'FAIL: firewall step did not abort' >&2
  exit 1
fi
[[ ! -e $tmp/mutated ]]
echo 'Firewall SSH port tests passed'
