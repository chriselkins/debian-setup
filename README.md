# debian-setup

Baseline provisioning for my Debian 13 servers. One script that is safe to run
on a fresh install and again at any time to bring a server up to the current
baseline.

## Usage

As root on the server:

    wget -nv -O - https://get.chriselkins.io/setup.sh | bash

That serves `setup.sh` from the latest signed release tag, pinned by commit
hash (see [Releases](#releases)). To run the tip of `main` instead:

    wget -nv -O - https://raw.githubusercontent.com/chriselkins/debian-setup/main/setup.sh | bash

It asks a few questions up front and then runs unattended:

- whether to download and install Comet Backup (the package then asks for the Comet
  username, password and server URL)
- the SSH public key to install (Enter keeps mine) and which users get it
  (defaults to the regular users on the box)
- whether to restrict SSH logins to the `ssh-users` group, listing who will be
  in it (default yes), and whether to allow SSH TCP port forwarding (default no)
- whether to enable the nftables firewall (default no; requires SSH on port 22)
- whether to harden the kernel command line (default no)
- whether unattended-upgrades may reboot automatically at 03:00
- journald `SystemMaxUse` and `MaxRetentionSec` (defaults 16G and 30day)
- whether to enable file integrity monitoring (default no)
- whether to set up outgoing mail (default yes), and if so where root's mail
  goes, the SMTP smarthost, port (default 465), username, password and the
  From address

## What it does

1. `apt-get update`, installs the baseline package set, then `apt-get full-upgrade`.
2. Enables `systemd-timesyncd`.
3. Optionally sets up outgoing mail: installs msmtp-mta and bsd-mailx, writes
   `/etc/msmtprc` (root:msmtp 0640, TLS with the smarthost certificate verified
   against the system CA store) and `/etc/aliases` (root and everything else
   local go to the given address), disables the unneeded `msmtpd` listener and
   sends a test mail. Also installs `/usr/local/sbin/check-disk-space` with a
   daily timer that mails root when a local filesystem is 90% full or more.
   msmtp has no queue: a message is sent immediately or fails with a syslog
   entry from `msmtp`.
4. Optionally downloads the Comet Backup client and installs it with apt.
5. Adds the SSH key to `~/.ssh/authorized_keys` for the chosen users.
6. Hardens sshd through `/etc/ssh/sshd_config.d/99-hardening.conf`: key-only
   authentication, no root login, no agent forwarding, TCP forwarding only if
   asked for, `LogLevel VERBOSE` (logs the key fingerprint used), sessions
   whose client stops answering are dropped after ten minutes, and, when
   confirmed, `AllowGroups ssh-users` with everyone who holds or receives the
   key added to that system group. If no non-root user holds the key this step
   warns and is skipped unless confirmed, so I cannot lock myself out.
7. Optionally installs nftables with `/etc/nftables.conf`: input and forward
   drop by default, established and related traffic, loopback, ICMP and ICMPv6
   are accepted, and new SSH connections are rate limited to 3 per minute per
   source address. `/etc/modules-load.d/firewall.conf` loads the nftables
   modules at boot so the ruleset can be reloaded after module loading is
   locked.
8. Optionally installs `/etc/default/grub.d/00-baseline.cfg`, which appends
   `mitigations=auto lockdown=confidentiality randomize_kstack_offset=on
   init_on_alloc=1 slab_nomerge apparmor=1 page_alloc.shuffle=1 debugfs=off`
   (plus `vsyscall=none` on x86-64) to `GRUB_CMDLINE_LINUX`, and runs
   `update-grub`. Takes effect from the next reboot.
9. Enables unattended-upgrades and installs `/etc/apt/apt.conf.d/52unattended-upgrades-local`,
   with error reports mailed to root when mail is set up. Configures
   needrestart (`/etc/needrestart/conf.d/50-debian-setup.conf`) to restart
   services that use an upgraded library without asking, so a libssl fix does
   not wait for the next reboot.
10. Installs `/etc/sysctl.d/00-baseline.conf` (BBR and fq, kernel hardening such
   as restricted ptrace, kptr, dmesg, BPF and kexec, ASLR maximums, redirect and
   source-route hardening, protected fifos, regular files and links) and
   `/etc/modules-load.d/network-performance.conf` so `tcp_bbr` and `sch_fq` are
   loaded at boot.
11. Installs and enables `disable-modules.service`, which sets
   `kernel.modules_disabled=1` three minutes after each boot. It takes effect
   from the next reboot; module loading is left alone on the running system.
12. Installs `/etc/systemd/journald.conf.d/10-retention.conf`.
13. Disables core dumps: `kernel.core_pattern` piped to `/bin/false`
   (`/etc/sysctl.d/60-coredump.conf`), a hard core limit of 0 for login
   sessions (`/etc/security/limits.d/10-core.conf`) and for services
   (`DefaultLimitCORE=0`), and `Storage=none` for systemd-coredump in case
   it is ever installed.
14. Optionally sets up file integrity monitoring: installs AIDE, auditd,
   debsums and systemd-cron (which replaces cron and enables `cron.target`),
   makes sure `/root/.ssh` (0700) and `/var/spool/cron` (0755) exist for the
   audit watches, adds `/etc/aide/aide.conf.d/99_local_fim` (SHA-512 and
   extended attributes for `/usr/local`, `/root/.ssh` and every user's
   `.ssh`), loads `/etc/audit/rules.d/40-fim.rules` (writes and attribute
   changes under `/etc`, `/boot`, `/usr/local`, `/var/spool/cron`,
   `/root/.ssh` and to the AIDE database), `50-events.rules` (any 32-bit
   syscall, module loading, commands run as root by logged-in users,
   privilege changes, mounts, ptrace and clock changes; daemons and timers
   are excluded through the login uid) and `99-finalize.rules` (`-e 2`, the
   rules are immutable until reboot; a re-run that changes them warns and
   leaves them for the next boot). Replaces `/etc/audit/auditd.conf` with
   Debian's defaults except 50 MB x 10 logs, a mail (or syslog entry) at 10%
   free disk and dropping the oldest log at 5% free or on a full disk. Sets
   `CRON_CHECK=weekly` in `/etc/default/debsums`, and adds `audit=1` to the
   kernel command line through `/etc/default/grub.d/00-audit.cfg`, which
   takes effect from the next reboot. The AIDE database is initialised when
   it is missing or the local rules changed, never on a plain re-run.

Managed files are only rewritten when their content changes, and the affected
service is reloaded when they are.

## Releases

`wget | bash` from `main` would make my GitHub account the trust anchor for
every server: whoever can push to it runs as root on the next install. So the
install URL does not follow `main`. `get.chriselkins.io` is a CloudFront
distribution in front of `raw.githubusercontent.com` whose CloudFront function
rewrites `/setup.sh` to the file at one pinned commit hash and answers every
other path itself. The pin lives in AWS (`infra/cloudfront.yaml`, stack
`debian-setup-get` in us-east-1, which also holds the ACM certificate and the
Route 53 records), and only `release.sh` moves it.

A release is one command, run on a clean checkout of `main` after the
changes are committed and their entries are written under Unreleased in
`CHANGELOG.md`:

    ./release.sh minor          # or major, patch, or an explicit X.Y.Z

It checks everything first (branch, tree, shellcheck, changelog, that gpg can
sign), then moves the Unreleased entries under the new version, sets
`VERSION` in `setup.sh`, makes a signed commit and a signed tag carrying the
entries, pushes both, deploys the stack with the tag's commit hash,
invalidates the cache and compares what the URL serves with
`git show vX.Y.Z:setup.sh`. Before deploying it re-checks that the tag has a
good signature from my key, by fingerprint, and is on GitHub. To serve an
earlier release again, or to finish a release whose deploy failed:

    ./release.sh pin v1.0.0

The `/release` skill in `.claude/skills/release` does the whole thing for me:
commits pending work, writes the changelog entries, picks the bump and runs
the script. What is being served shows in the response headers and at the
site root:

    curl -sI https://get.chriselkins.io/setup.sh | grep x-debian-setup

On GitHub, rulesets require signed commits on `main` and on `v*` tags and
block force pushes, tag updates and deletion. Nobody can bypass them, me
included; changing that means editing the ruleset. First-time setup of the
AWS side is one deploy with a commit hash, after which `release.sh` keeps the
other parameters as they are:

    aws cloudformation deploy --region us-east-1 --stack-name debian-setup-get \
      --template-file infra/cloudfront.yaml --parameter-overrides CommitSha=<full hash>
