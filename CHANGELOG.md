# Changelog

Notable changes to setup.sh and to the install URL, newest first, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. Versions
follow semantic versioning: major when a re-run changes an existing server in
a way that needs attention, minor for new steps and options, patch for fixes.
release.sh turns the Unreleased section into the next version.

## [Unreleased]

## [1.0.0] - 2026-09-07

### Added
- setup.sh, the baseline for my Debian 13 servers: package set and full
  upgrade, time sync, optional outgoing mail through msmtp with a daily disk
  space alert, optional Comet Backup, my SSH key for chosen users, sshd
  hardening with an optional ssh-users group, optional nftables firewall,
  optional kernel command line hardening, unattended upgrades with
  needrestart, sysctl baseline, module loading locked after boot, journald
  retention, core dumps disabled, optional file integrity monitoring with
  AIDE, auditd and debsums. It prints its version when it starts.
- https://get.chriselkins.io/setup.sh, the install URL: CloudFront in front
  of GitHub, serving setup.sh from the commit of the signed release tag pinned
  by release.sh (infra/cloudfront.yaml).
- release.sh and the release skill: changelog, version, signed commit and
  tag, push, pin.

### Removed
- apt-transport-https from the package set; on Debian 13 it is a transitional
  package.
