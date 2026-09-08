#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# Load definitions without the interactive entry point.
# shellcheck source=/dev/null
source <(sed '/^# When piped into bash/,$d' "$root/setup.sh")

# ask_ports reads its answers from stdin, one attempt per line.
expect_ports() {
  local got
  got=$(printf '%s\n' "$1" | ask_ports 'Ports' 2>/dev/null)
  if [[ $got != "$2" ]]; then
    printf 'FAIL: ask_ports gave "%s" for %s\n' "$got" "$3" >&2
    exit 1
  fi
}
expect_ports '80 443 8080' '80 443 8080' 'a list of ports'
expect_ports '  80,443   8080 ' '80 443 8080' 'commas and extra spaces'
expect_ports '' '' 'an empty answer'
expect_ports $'80 abc\n0\n65536\n080\n-1\n3478' '3478' 'rejected attempts before a valid one'

# ruleset SSH TCP-PORTS UDP-PORTS: the ruleset built from those answers.
ruleset() {
  # shellcheck disable=SC2034  # read by firewall_ruleset
  FIREWALL_SSH=$1 FIREWALL_TCP_PORTS=$2 FIREWALL_UDP_PORTS=$3
  firewall_ruleset
}

# The accept rules after the ICMP rules in the input chain, for the answers
# SSH TCP-PORTS UDP-PORTS, compared with the lines expected on stdin.
expect_rules() {
  if ! diff <(ruleset "$1" "$2" "$3" | sed -n '/ipv6-icmp accept$/,/^\t}$/p' | sed '1d;$d') -; then
    printf 'FAIL: rules for %s\n' "$4" >&2
    exit 1
  fi
}
expect_rules y '' '' 'the defaults' <<'EOF'

		tcp dport 22 ct state new update @ssh_ratelimit { ip saddr limit rate 3/minute } accept
		tcp dport 22 ct state new update @ssh_ratelimit6 { ip6 saddr limit rate 3/minute } accept
EOF
expect_rules y '80 443 8080' 3478 'extra ports above the SSH rules' <<'EOF'

		tcp dport { 80, 443, 8080 } ct state new accept
		udp dport 3478 accept
		tcp dport 22 ct state new update @ssh_ratelimit { ip saddr limit rate 3/minute } accept
		tcp dport 22 ct state new update @ssh_ratelimit6 { ip6 saddr limit rate 3/minute } accept
EOF
expect_rules n 8080 '3478 5349' 'no SSH' <<'EOF'

		tcp dport 8080 ct state new accept
		udp dport { 3478, 5349 } accept
EOF

# The rate limit sets exist only together with the SSH rules that use them.
if [[ $(ruleset y '' '' | grep -c 'set ssh_ratelimit') -ne 2 ]]; then
  echo 'FAIL: SSH rate limit sets missing' >&2
  exit 1
fi
if ruleset n '' '' | grep -q 'ssh_ratelimit\|dport'; then
  echo 'FAIL: SSH sets or accept rules without SSH' >&2
  exit 1
fi
echo 'Firewall ruleset tests passed'
