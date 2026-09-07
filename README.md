# debian-setup

Baseline provisioning for my Debian 13 servers. One script that is safe to run
on a fresh install and again at any time to bring a server up to the current
baseline.

## Usage

As root on the server:

    wget -nv -O - https://raw.githubusercontent.com/chriselkins/debian-setup/main/setup.sh | bash

It asks a few questions up front and then runs unattended:

- whether to download and install Comet Backup (the package then asks for the Comet
  username, password and server URL)
- which users get my SSH key (defaults to the regular users on the box)
- whether to enable the nftables firewall (default no)
- whether unattended-upgrades may reboot automatically at 03:00
- journald `SystemMaxUse` and `MaxRetentionSec` (defaults 16G and 30day)

## What it does

1. `apt-get update`, installs the baseline package set, then `apt-get full-upgrade`.
2. Enables `systemd-timesyncd`.
3. Optionally downloads the Comet Backup client and installs it with apt.
4. Adds my SSH key to `~/.ssh/authorized_keys` for the chosen users.
5. Hardens sshd through `/etc/ssh/sshd_config.d/00-hardening.conf`: key-only
   authentication, no root login. If no non-root user holds the key this step
   warns and is skipped unless confirmed, so I cannot lock myself out.
6. Optionally installs nftables with `/etc/nftables.conf`: input and forward
   drop by default, established and related traffic, loopback, ICMP and ICMPv6
   are accepted, and new SSH connections are rate limited to 3 per minute per
   source address. `/etc/modules-load.d/firewall.conf` loads the nftables
   modules at boot so the ruleset can be reloaded after module loading is
   locked.
7. Enables unattended-upgrades and installs `/etc/apt/apt.conf.d/52unattended-upgrades-local`.
8. Installs `/etc/sysctl.d/42-local.conf` (BBR and fq, kernel hardening such
   as restricted ptrace, kptr, dmesg, BPF and kexec, ASLR maximums, redirect and
   source-route hardening, protected fifos, regular files and links) and
   `/etc/modules-load.d/network-performance.conf` so `tcp_bbr` and `sch_fq` are
   loaded at boot.
9. Installs and enables `disable-modules.service`, which sets
   `kernel.modules_disabled=1` three minutes after each boot. It takes effect
   from the next reboot; module loading is left alone on the running system.
10. Installs `/etc/systemd/journald.conf.d/10-retention.conf`.

Managed files are only rewritten when their content changes, and the affected
service is reloaded when they are.
