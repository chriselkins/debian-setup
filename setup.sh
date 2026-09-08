#!/usr/bin/env bash
#
# Baseline provisioning for my Debian 13 servers.
#
# Bootstrap on a fresh install, as root:
#
#   wget -nv -O - https://raw.githubusercontent.com/chriselkins/debian-setup/main/setup.sh | bash
#
# Every step is idempotent, so re-run it at any time to check a server against
# the current baseline or to apply additions made to this script.

set -euo pipefail

SSH_KEY='sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIFY06TgZyT7svTpIbitLw9x/1Dq85m58jDfwsbsN9wzlAAAABHNzaDo= xinix-yubikey'

COMET_URL='https://comet.adcmsp.com/api/v1/admin/branding/generate-client/by-platform'
COMET_POST_DATA='SelfAddress=https%3A%2F%2Fcomet.adcmsp.com%2F&Platform=21'

PACKAGES=(
  bash-completion bat bind9-dnsutils bind9-host bsdextrautils
  build-essential ca-certificates curl entr fd-find file fzf gh git git-lfs gnupg
  jq lsb-release moreutils ncdu needrestart openssh-server openssl p7zip-full
  pipx pkg-config python3-pip python3-venv ripgrep rsync shellcheck sqlite3 sudo
  systemd-timesyncd tmux tree unattended-upgrades unzip vim whois xxd yq zip zstd
  apparmor apparmor-utils apparmor-profiles
)

# --- helpers -----------------------------------------------------------------

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ask PROMPT DEFAULT: print the answer, or DEFAULT if the user just hits Enter.
ask() {
  local reply hint=''
  [[ -n $2 ]] && hint=" [$2]"
  read -r -p "$1$hint: " reply || true
  printf '%s\n' "${reply:-$2}"
}

# ask_yn PROMPT DEFAULT(y|n): print y or n.
ask_yn() {
  local hint reply
  if [[ $2 == y ]]; then hint='Y/n'; else hint='y/N'; fi
  while true; do
    read -r -p "$1 [$hint]: " reply || true
    case ${reply:-$2} in
      [Yy]|[Yy][Ee][Ss]) echo y; return ;;
      [Nn]|[Nn][Oo])     echo n; return ;;
    esac
  done
}

# install_file PATH MODE, with the content on stdin. Writes the file only when
# its content differs. Returns 0 if written and 1 if it was already up to date,
# so the caller can decide whether a service needs reloading.
install_file() {
  local path=$1 mode=$2 tmp
  mkdir -p "$(dirname "$path")"
  tmp=$(mktemp "$path.XXXXXX")
  cat >"$tmp"
  if cmp -s "$tmp" "$path" 2>/dev/null; then
    rm -f "$tmp"
    chmod "$mode" "$path"
    echo "$path is up to date"
    return 1
  fi
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$path"
  echo "wrote $path"
}

# grub_cmdline NAME PARAMS: install /etc/default/grub.d/NAME.cfg, which appends
# PARAMS to the kernel command line, and run update-grub when it changed.
grub_cmdline() {
  local name=$1 params=$2
  if ! command -v update-grub >/dev/null; then
    warn "update-grub not found, skipped adding '$params' to the kernel command line"
    return 0
  fi
  # grub-mkconfig sources /etc/default/grub and then /etc/default/grub.d/*.cfg,
  # so this appends to whatever the installer put in GRUB_CMDLINE_LINUX.
  if install_file "/etc/default/grub.d/$name.cfg" 0644 <<EOF
# Managed by debian-setup; local edits are overwritten on the next run.
GRUB_CMDLINE_LINUX="\$GRUB_CMDLINE_LINUX $params"
EOF
  then
    update-grub
    BOOTLINE_CHANGED=y
  fi
}

# Non-root users whose authorized_keys already contains the key.
key_holders() {
  local name home
  while IFS=: read -r name _ _ _ _ home _; do
    [[ $name != root && -f $home/.ssh/authorized_keys ]] || continue
    grep -qxF "$SSH_KEY" "$home/.ssh/authorized_keys" && echo "$name"
  done </etc/passwd
  return 0
}

# --- preflight and questions -------------------------------------------------

preflight() {
  [[ $EUID -eq 0 ]] || die "this script must run as root"
  # shellcheck source=/dev/null
  . /etc/os-release
  [[ ${ID:-} == debian ]] || die "this script is for Debian, detected: ${PRETTY_NAME:-unknown}"
  if [[ ${VERSION_ID:-} != 13 ]]; then
    warn "this script targets Debian 13, detected: ${PRETTY_NAME:-unknown}"
    [[ $(ask_yn "Continue anyway?" n) == y ]] || exit 1
  fi
}

# Everything is asked up front so the rest of the run needs no attention.
gather_answers() {
  local default_users answer user holders holder='' default_from

  INSTALL_COMET=$(ask_yn "Download and install Comet Backup?" n)

  default_users=$(awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)$/ { print $1 }' /etc/passwd | paste -sd ' ')
  while true; do
    answer=$(ask "Install the SSH key for which users? (space-separated, 'none' to skip)" "${default_users:-none}")
    [[ $answer == none ]] && answer=''
    read -r -a KEY_USERS <<<"${answer//,/ }"
    for user in "${KEY_USERS[@]}"; do
      if ! getent passwd "$user" >/dev/null; then
        warn "user '$user' does not exist"
        continue 2
      fi
    done
    break
  done

  # Hardening sshd while no non-root user holds the key would lock me out.
  mapfile -t holders < <(key_holders)
  for user in "${holders[@]}" "${KEY_USERS[@]}"; do
    [[ $user == root ]] || holder=$user
  done
  APPLY_SSHD=y
  if [[ -z $holder ]]; then
    warn "no non-root user will have the SSH key; hardening sshd now (no root login, no passwords) would lock you out"
    APPLY_SSHD=$(ask_yn "Apply the sshd hardening anyway?" n)
  fi

  INSTALL_FIREWALL=$(ask_yn "Enable the nftables firewall? (allows SSH and ICMP in, drops everything else)" n)

  HARDEN_BOOTLINE=$(ask_yn "Harden the kernel command line? (lockdown=confidentiality, init_on_alloc, slab_nomerge, ...)" n)

  AUTO_REBOOT=$(ask_yn "Let unattended-upgrades reboot automatically at 03:00 when needed?" y)

  while true; do
    JOURNAL_MAX_USE=$(ask "journald SystemMaxUse" 16G)
    [[ $JOURNAL_MAX_USE =~ ^[0-9]+[KMGT]?$ ]] && break
    warn "expected a size such as 16G or 500M"
  done
  while true; do
    JOURNAL_RETENTION=$(ask "journald MaxRetentionSec" 30day)
    [[ $JOURNAL_RETENTION =~ ^[0-9]+[[:space:]]*[a-z]*$ ]] && break
    warn "expected a time span such as 30day, 2week or 12h"
  done

  ENABLE_FIM=$(ask_yn "Enable file integrity monitoring? (AIDE, auditd watches, weekly debsums checks)" n)

  # AIDE, debsums, auditd, unattended-upgrades and the disk space check all
  # report to root by mail, which goes nowhere without a smarthost.
  ENABLE_MAIL=$(ask_yn "Set up outgoing mail so alerts (AIDE, debsums, auditd, upgrades, low disk space) reach you?" y)
  if [[ $ENABLE_MAIL == y ]]; then
    while true; do
      MAIL_TO=$(ask "Deliver root's mail to" '')
      [[ $MAIL_TO == *@* ]] && break
      warn "expected an email address"
    done
    while true; do
      MAIL_HOST=$(ask "SMTP smarthost" '')
      [[ -n $MAIL_HOST ]] && break
    done
    while true; do
      MAIL_PORT=$(ask "SMTP port (465 is TLS, anything else STARTTLS)" 465)
      [[ $MAIL_PORT =~ ^[0-9]+$ && $MAIL_PORT -ge 1 && $MAIL_PORT -le 65535 ]] && break
      warn "expected a port number"
    done
    MAIL_USER=$(ask "SMTP username ('none' for no authentication)" none)
    [[ $MAIL_USER == none ]] && MAIL_USER=''
    MAIL_PASSWORD=''
    if [[ -n $MAIL_USER ]]; then
      while true; do
        read -r -s -p "SMTP password: " MAIL_PASSWORD || true
        echo
        [[ -n $MAIL_PASSWORD && $MAIL_PASSWORD != *\"* ]] && break
        warn "the password must not be empty or contain a double quote"
      done
    fi
    default_from=root@$(hostname -f 2>/dev/null || hostname)
    [[ $MAIL_USER == *@* ]] && default_from=$MAIL_USER
    while true; do
      MAIL_FROM=$(ask "From address for outgoing mail" "$default_from")
      [[ $MAIL_FROM == *@* ]] && break
      warn "expected an email address"
    done
  fi
}

# --- steps -------------------------------------------------------------------

step_packages() {
  log "Installing baseline packages"
  apt-get update
  # Installed before the upgrade: unattended-upgrades ships the kernel hook
  # that creates /run/reboot-required, which finish() checks.
  apt-get install -y "${PACKAGES[@]}"
  log "Upgrading installed packages"
  apt-get full-upgrade -y
}

step_timesync() {
  log "Enabling time synchronisation"
  systemctl enable --now systemd-timesyncd
}

step_mail() {
  local changed=n fqdn starttls=on
  log "Configuring outgoing mail"
  # msmtp verifies the smarthost certificate against the system CA store (dma
  # cannot). bsd-mailx provides mail(1), which aide and unattended-upgrades use.
  # msmtp asks whether to enable its AppArmor profile (default no); answer yes
  # up front so the install does not stop at a prompt.
  echo 'msmtp msmtp/apparmor boolean true' | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive apt-get install -y msmtp-mta bsd-mailx
  # msmtp-mta also ships msmtpd, a local SMTP listener that nothing here needs.
  systemctl disable --now msmtpd.service
  [[ $MAIL_PORT == 465 ]] && starttls=off
  fqdn=$(hostname -f 2>/dev/null || hostname)
  {
    cat <<EOF
# Managed by debian-setup; local edits are overwritten on the next run.
defaults
syslog on
aliases /etc/aliases
tls on
tls_trust_file system
tls_starttls $starttls
# Every message leaves from the same address, with the host as display name.
set_from_header on
from_full_name $fqdn

account default
host $MAIL_HOST
port $MAIL_PORT
from $MAIL_FROM
EOF
    if [[ -n $MAIL_USER ]]; then
      cat <<EOF
auth on
user $MAIL_USER
password "$MAIL_PASSWORD"
EOF
    fi
  } | install_file /etc/msmtprc 0640 && changed=y
  # The file holds the SMTP password; root:msmtp is what Debian recommends.
  chgrp msmtp /etc/msmtprc
  install_file /etc/aliases 0644 <<EOF && changed=y
# Managed by debian-setup; local edits are overwritten on the next run.
root: $MAIL_TO
default: $MAIL_TO
EOF
  # systemd-cron's generator only mails job output when it finds an MTA.
  systemctl daemon-reload
  if [[ $changed == y ]]; then
    if printf 'Subject: [%s] outgoing mail is configured\n\nSent by debian-setup on %s.\n' "$fqdn" "$fqdn" | sendmail root; then
      echo "sent a test mail to $MAIL_TO"
    else
      warn "the test mail could not be sent, see 'journalctl -t msmtp'"
    fi
  fi
}

step_disk_alert() {
  local changed=n
  log "Installing the daily disk space check"
  install_file /usr/local/sbin/check-disk-space 0755 <<'EOF' || true
#!/bin/bash
# Managed by debian-setup; local edits are overwritten on the next run.
# Mail root when a local filesystem is at or above the threshold.
set -euo pipefail
threshold=90
report=$(df -h --local --output=target,size,used,avail,pcent -x tmpfs -x devtmpfs -x squashfs -x overlay |
  awk -v t="$threshold" 'NR == 1 || $NF + 0 >= t')
[[ $(wc -l <<<"$report") -gt 1 ]] || exit 0
printf 'Subject: [%s] disk space low\n\n%s\n' "$(hostname -f 2>/dev/null || hostname)" "$report" | sendmail root
EOF
  install_file /etc/systemd/system/check-disk-space.service 0644 <<'EOF' && changed=y
# Managed by debian-setup; local edits are overwritten on the next run.
[Unit]
Description=Mail root when disk space is low

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/check-disk-space
EOF
  install_file /etc/systemd/system/check-disk-space.timer 0644 <<'EOF' && changed=y
# Managed by debian-setup; local edits are overwritten on the next run.
[Unit]
Description=Daily disk space check

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
  if [[ $changed == y ]]; then
    systemctl daemon-reload
  fi
  systemctl enable --now check-disk-space.timer
}

step_comet() {
  local tmp deb name
  log "Installing Comet Backup"
  # The package prompts for the Comet username, password and server URL (debconf).
  tmp=$(mktemp -d)
  (cd "$tmp" && curl -f --progress-bar -O -J -d "$COMET_POST_DATA" -X POST "$COMET_URL")
  deb=$(find "$tmp" -maxdepth 1 -type f -name '*.deb' -print -quit)
  [[ -n $deb ]] || die "the Comet download did not produce a .deb in $tmp"
  name=$(basename "$deb")
  mv -f "$deb" "/$name"
  chmod 0644 "/$name"
  rmdir "$tmp"
  apt-get install -y "/$name"
  rm -f "/$name"
}

step_ssh_keys() {
  local user home ak
  [[ ${#KEY_USERS[@]} -gt 0 ]] || return 0
  log "Installing the SSH key"
  for user in "${KEY_USERS[@]}"; do
    home=$(getent passwd "$user" | cut -d: -f6)
    [[ -d $home ]] || die "home directory $home of $user does not exist"
    install -d -m 0700 -o "$user" -g "$(id -gn "$user")" "$home/.ssh"
    ak=$home/.ssh/authorized_keys
    touch "$ak"
    chown "$user:" "$ak"
    chmod 0600 "$ak"
    if grep -qxF "$SSH_KEY" "$ak"; then
      echo "$user already has the key"
    else
      # A missing trailing newline would glue the key onto the last line.
      [[ -s $ak && -n $(tail -c1 "$ak") ]] && echo >>"$ak"
      printf '%s\n' "$SSH_KEY" >>"$ak"
      echo "added the key for $user"
    fi
  done
}

step_sshd() {
  log "Hardening sshd"
  if [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
    ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""
  fi
  # sshd keeps the first value it reads, so a lower-numbered file can override
  # this baseline.
  if install_file /etc/ssh/sshd_config.d/99-hardening.conf 0644 <<'EOF'
# Managed by debian-setup; local edits are overwritten on the next run.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
X11Forwarding no
PermitTunnel no
PubkeyAuthentication yes
AuthenticationMethods publickey
LoginGraceTime 30
MaxAuthTries 3
KexAlgorithms mlkem768x25519-sha256,sntrup761x25519-sha512,sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,gss-curve25519-sha256-
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com
HostKeyAlgorithms sk-ssh-ed25519-cert-v01@openssh.com,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512-cert-v01@openssh.com,rsa-sha2-256-cert-v01@openssh.com,sk-ssh-ed25519@openssh.com,ssh-ed25519,rsa-sha2-512,rsa-sha2-256
RequiredRSASize 3072
CASignatureAlgorithms sk-ssh-ed25519@openssh.com,ssh-ed25519,rsa-sha2-512,rsa-sha2-256
GSSAPIKexAlgorithms gss-curve25519-sha256-
HostbasedAcceptedAlgorithms sk-ssh-ed25519-cert-v01@openssh.com,ssh-ed25519-cert-v01@openssh.com,sk-ssh-ed25519@openssh.com,ssh-ed25519,rsa-sha2-512-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256-cert-v01@openssh.com,rsa-sha2-256
PubkeyAcceptedAlgorithms sk-ssh-ed25519-cert-v01@openssh.com,ssh-ed25519-cert-v01@openssh.com,sk-ssh-ed25519@openssh.com,ssh-ed25519,rsa-sha2-512-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256-cert-v01@openssh.com,rsa-sha2-256
EOF
  then
    if ! sshd -t; then
      rm -f /etc/ssh/sshd_config.d/99-hardening.conf
      die "sshd rejected the new configuration, so it was removed again"
    fi
    systemctl try-reload-or-restart ssh
  fi
}

step_firewall() {
  local changed=n
  log "Configuring the nftables firewall"
  apt-get install -y nftables
  # Loaded at boot before disable-modules.service locks module loading, so the
  # ruleset can still be reloaded afterwards.
  install_file /etc/modules-load.d/firewall.conf 0644 <<'EOF' || true
# Managed by debian-setup; local edits are overwritten on the next run.
nf_tables
nf_conntrack
nft_ct
nft_limit
EOF
  install_file /etc/nftables.conf 0755 <<'EOF' && changed=y
#!/usr/sbin/nft -f
# Managed by debian-setup; local edits are overwritten on the next run.

flush ruleset

table inet filter {
	# New SSH connections per source address, refreshed on every attempt.
	set ssh_ratelimit {
		type ipv4_addr
		flags dynamic
		timeout 60s
	}
	set ssh_ratelimit6 {
		type ipv6_addr
		flags dynamic
		timeout 60s
	}

	chain input {
		type filter hook input priority filter; policy drop;

		ct state vmap { established : accept, related : accept, invalid : drop }
		iifname "lo" accept

		ip protocol icmp accept
		meta l4proto ipv6-icmp accept

		tcp dport 22 ct state new update @ssh_ratelimit { ip saddr limit rate 3/minute } accept
		tcp dport 22 ct state new update @ssh_ratelimit6 { ip6 saddr limit rate 3/minute } accept
	}

	chain forward {
		type filter hook forward priority filter; policy drop;
	}

	chain output {
		type filter hook output priority filter; policy accept;
	}
}
EOF
  systemctl enable --now nftables
  if [[ $changed == y ]]; then
    systemctl reload nftables
  fi
}

step_bootline() {
  log "Hardening the kernel command line"
  grub_cmdline 00-baseline 'mitigations=auto lockdown=confidentiality randomize_kstack_offset=on init_on_alloc=1 slab_nomerge apparmor=1'
}

step_unattended_upgrades() {
  log "Configuring unattended upgrades"
  install_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF' || true
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  {
    cat <<'EOF'
// Managed by debian-setup; local edits are overwritten on the next run.
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename}-updates";
        "origin=Debian,codename=${distro_codename},label=Debian";
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
EOF
    if [[ $AUTO_REBOOT == y ]]; then
      cat <<'EOF'

Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF
    fi
    if [[ $ENABLE_MAIL == y ]]; then
      cat <<'EOF'

Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailReport "only-on-error";
EOF
    fi
  } | install_file /etc/apt/apt.conf.d/52unattended-upgrades-local 0644 || true
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
  # needrestart's apt hook restarts the services that use an upgraded library,
  # so an openssl fix takes effect without the reboot only kernel and libc
  # updates trigger. 'a' restarts without asking, also in unattended runs.
  install_file /etc/needrestart/conf.d/50-debian-setup.conf 0644 <<'EOF' || true
# Managed by debian-setup; local edits are overwritten on the next run.
$nrconf{restart} = 'a';
EOF
}

step_sysctl() {
  log "Configuring sysctl"
  # sysctl.d applies files in order and later ones win, so a higher-numbered
  # file can override this baseline.
  install_file /etc/sysctl.d/00-baseline.conf 0644 <<'EOF' || true
# Managed by debian-setup; local edits are overwritten on the next run.
# kernel.modules_disabled=1 is set via systemd unit
net.ipv4.tcp_ecn=1
net.ipv4.tcp_ecn_fallback=1
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
net.core.bpf_jit_harden=2
kernel.yama.ptrace_scope=3
kernel.kexec_load_disabled=1
#kernel.unprivileged_userns_clone=0
#user.max_user_namespaces=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_timestamps=1
kernel.randomize_va_space=2
dev.tty.ldisc_autoload=0
kernel.perf_event_paranoid=3
vm.unprivileged_userfaultfd=0
kernel.sysrq=4
fs.suid_dumpable=0
kernel.unprivileged_bpf_disabled=1
fs.protected_fifos=2
fs.protected_hardlinks=1
fs.protected_regular=2
fs.protected_symlinks=1
# https://gitlab.tails.boum.org/tails/tails/-/blob/master/config/chroot_local-includes/etc/sysctl.d/mmap_aslr.conf
# These settings are set to the maximum supported value in order to improve ASLR effectiveness for mmap, at the cost of increased address-space fragmentation.
vm.mmap_rnd_bits=32
vm.mmap_rnd_compat_bits=16
# Uncomment the next two lines to enable Spoof protection (reverse-path filter)
# Turn on Source Address Verification in all interfaces to
# prevent some spoofing attacks
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.all.rp_filter=2
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.secure_redirects=0
net.ipv4.conf.default.secure_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv6.conf.all.accept_source_route=-1
net.ipv4.conf.default.accept_source_route=0
net.ipv6.conf.default.accept_source_route=-1
net.ipv4.conf.all.log_martians=0
net.ipv4.conf.default.log_martians=0
net.ipv4.icmp_echo_ignore_broadcasts=1
EOF
  # Loaded at boot before disable-modules.service locks module loading, so the
  # bbr and fq sysctls above keep working.
  install_file /etc/modules-load.d/network-performance.conf 0644 <<'EOF' || true
# Managed by debian-setup; local edits are overwritten on the next run.
tcp_bbr
sch_fq
EOF
  sysctl --system >/dev/null || warn "some sysctl settings could not be applied (expected inside a container)"
}

step_disable_modules() {
  log "Installing the kernel module loading lock"
  install_file /usr/local/sbin/disable-modules.sh 0755 <<'EOF' || true
#!/bin/bash
# Managed by debian-setup; local edits are overwritten on the next run.
set -euo pipefail
/usr/sbin/sysctl -w kernel.modules_disabled=1
EOF
  if install_file /etc/systemd/system/disable-modules.service 0644 <<'EOF'
# Managed by debian-setup; local edits are overwritten on the next run.
[Unit]
Description=Disable Kernel Module Loading
After=multi-user.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 180
ExecStart=/usr/local/sbin/disable-modules.sh

[Install]
WantedBy=multi-user.target
EOF
  then
    systemctl daemon-reload
  fi
  # Enabled for the next boot only: locking modules on the running system
  # would get in the way of anything else being installed today.
  systemctl enable disable-modules.service
}

step_journald() {
  log "Configuring journald retention"
  if install_file /etc/systemd/journald.conf.d/10-retention.conf 0644 <<EOF
# Managed by debian-setup; local edits are overwritten on the next run.
[Journal]
Storage=persistent
SplitMode=uid
SystemMaxUse=$JOURNAL_MAX_USE
SystemMaxFiles=2000
MaxRetentionSec=$JOURNAL_RETENTION
EOF
  then
    systemctl restart systemd-journald
  fi
}

step_fim() {
  local init_db=n
  log "Configuring file integrity monitoring"
  # auditd refuses dir= rules for directories that do not exist, and the AIDE
  # baseline should include them from the start.
  install -d -m 0700 /root/.ssh
  install -d -m 0755 /var/spool/cron
  # systemd-cron replaces cron and runs the cron.weekly debsums job from a timer.
  apt-get install -y debsums aide aide-common auditd systemd-cron
  systemctl enable --now cron.target
  # Debian's aide.conf includes the files in aide.conf.d whose names match
  # ^[a-zA-Z0-9_-]+$ and runs the executable ones, hence no extension.
  if install_file /etc/aide/aide.conf.d/99_local_fim 0644 <<'EOF'
# Managed by debian-setup; local edits are overwritten on the next run.
# Local File Integrity Monitoring rules
#
# Debian's aide-common package already supplies extensive Debian-aware
# rules. These rules add stronger coverage for locally managed software,
# administrator SSH configuration, and other local content.
#
# X includes supported extended security metadata such as ACLs, xattrs,
# filesystem attributes, SELinux labels (when applicable), and capabilities.
#
# A single SHA-512 hash is sufficient here and avoids calculating every
# hash algorithm in AIDE's H/Checksums group.

LocalFIM = p+ftype+i+l+n+u+g+s+b+m+c+sha512+X


# Locally installed software and administrator-managed binaries.
/usr/local LocalFIM


# Root SSH credentials and authorized keys.
/root/.ssh LocalFIM


# SSH credentials for normal users.
# This matches /home/<username>/.ssh and everything below it.
/home/[^/]+/\.ssh LocalFIM


# ----------------------------------------------------------------------
# OPTIONAL APPLICATION-SPECIFIC STATIC TREES
# ----------------------------------------------------------------------
#
# Add directories here ONLY if their contents are expected to remain
# unchanged between legitimate deployments.
#
# Examples:
#
# /opt/myapp/bin LocalFIM
# /opt/myapp/config LocalFIM
# /apps/scripts LocalFIM
#
# Do NOT blindly add database directories, logs, caches, uploads,
# PHP sessions, Redis data, MySQL data, or other frequently changing data.
#
# Examples that normally should NOT be added wholesale:
#
# /var/log
# /var/lib/mysql
# /var/lib/redis
# /tmp
# /run
EOF
  then
    if ! aide --config=/etc/aide/aide.conf --config-check; then
      rm -f /etc/aide/aide.conf.d/99_local_fim
      die "aide rejected the new rules, so they were removed again"
    fi
    init_db=y
  fi
  if install_file /etc/audit/rules.d/40-fim.rules 0640 <<'EOF'
# Managed by debian-setup; local edits are overwritten on the next run.
# File Integrity Monitoring - auditd
#
# Record writes and metadata changes to security-sensitive areas.
#
# w = write operations
# a = attribute/metadata changes
#
# b64 selects the native 64-bit syscall ABI.

# ----------------------------------------------------------------------
# System configuration
# ----------------------------------------------------------------------

-a always,exit -F arch=b64 -F dir=/etc/ -F perm=wa -F key=fim_etc


# ----------------------------------------------------------------------
# Boot configuration and bootloader files
# ----------------------------------------------------------------------

-a always,exit -F arch=b64 -F dir=/boot/ -F perm=wa -F key=fim_boot


# ----------------------------------------------------------------------
# Locally installed executables, libraries, and administrator software
# ----------------------------------------------------------------------

-a always,exit -F arch=b64 -F dir=/usr/local/ -F perm=wa -F key=fim_usrlocal


# ----------------------------------------------------------------------
# Cron user crontabs
# ----------------------------------------------------------------------

-a always,exit -F arch=b64 -F dir=/var/spool/cron/ -F perm=wa -F key=fim_cron


# ----------------------------------------------------------------------
# Root SSH keys and authorized_keys
# ----------------------------------------------------------------------

-a always,exit -F arch=b64 -F dir=/root/.ssh/ -F perm=wa -F key=fim_rootssh


# ----------------------------------------------------------------------
# AIDE reference database
# ----------------------------------------------------------------------

-a always,exit -F arch=b64 -F path=/var/lib/aide/aide.db -F perm=wa -F key=fim_aidedb
EOF
  then
    # augenrules merges rules.d into /etc/audit/audit.rules and loads it with
    # auditctl, whose exit status is the only syntax check there is. Rules
    # that do not load would also stop auditd from starting at boot.
    if ! augenrules --load; then
      rm -f /etc/audit/rules.d/40-fim.rules
      augenrules --load || true
      die "auditd could not load the new rules, so they were removed again"
    fi
  fi
  install_file /etc/default/debsums 0644 <<'EOF' || true
# Managed by debian-setup; local edits are overwritten on the next run.
# Defaults for debsums cron jobs
# sourced by the debsums cron scripts

#
# This is a POSIX shell fragment
#

# Perform Debian package checksum verification weekly.
CRON_CHECK=weekly
EOF
  grub_cmdline 00-audit audit=1
  # Last, so the baseline includes the files written above. Only when the
  # database is missing or the rules changed: re-running the script must not
  # silently re-baseline a server.
  if [[ $init_db == y || ! -f /var/lib/aide/aide.db ]]; then
    log "Initialising the AIDE database (this walks the whole filesystem)"
    aideinit -y -f
  fi
}

finish() {
  log "Done"
  if [[ -f /run/reboot-required ]]; then
    warn "a reboot is required to finish applying updates"
  fi
  if [[ ${BOOTLINE_CHANGED:-n} == y ]]; then
    warn "a reboot is required to apply the new kernel command line"
  fi
}

main() {
  preflight
  gather_answers
  step_packages
  step_timesync
  if [[ $ENABLE_MAIL == y ]]; then
    step_mail
    step_disk_alert
  fi
  if [[ $INSTALL_COMET == y ]]; then
    step_comet
  fi
  step_ssh_keys
  if [[ $APPLY_SSHD == y ]]; then
    step_sshd
  else
    warn "skipped the sshd hardening"
  fi
  if [[ $INSTALL_FIREWALL == y ]]; then
    step_firewall
  fi
  if [[ $HARDEN_BOOTLINE == y ]]; then
    step_bootline
  fi
  step_unattended_upgrades
  step_sysctl
  step_disable_modules
  step_journald
  if [[ $ENABLE_FIM == y ]]; then
    step_fim
  fi
  finish
}

# When piped into bash, stdin is the script itself. Point main at the terminal
# so the prompts (and anything else that reads stdin, such as apt) work.
if ! { : </dev/tty; } 2>/dev/null; then
  die "no terminal available, run this from an interactive shell"
fi
main "$@" </dev/tty
