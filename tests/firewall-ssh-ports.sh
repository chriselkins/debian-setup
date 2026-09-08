#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# Load definitions without the interactive entry point.
# shellcheck source=/dev/null
source <(sed '/^# When piped into bash/,$d' "$root/setup.sh")

# Model sshd -T output, including ListenAddress port overrides.
sshd() { printf '%s\n' "$mock_sshd_config"; return "${sshd_status:-0}"; }
expect_rejected() {
  if sshd_listens_only_on_22 2>/dev/null; then
    printf 'FAIL: accepted %s\n' "$1" >&2
    exit 1
  fi
}

mock_sshd_config=$'port 22\nlistenaddress [::]:22\nlistenaddress 0.0.0.0:22'
sshd_listens_only_on_22
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
echo 'Firewall SSH port tests passed'
