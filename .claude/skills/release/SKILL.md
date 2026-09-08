---
name: release
description: Cut a release of debian-setup - commit pending work, write the CHANGELOG entries, pick the semver bump, run release.sh (signed commit and tag, push, pin get.chriselkins.io) and report what is served; or roll back with release.sh pin. Use when Chris asks for a release, a new version, to ship or publish setup.sh, or to change what get.chriselkins.io serves.
---

# Release

Everything ends in ./release.sh, which refuses to run unless main is not
behind origin, the tree is clean apart from CHANGELOG.md, shellcheck passes,
Unreleased has entries and gpg can sign. Get the repo to that state, run it
once, report its last line. $ARGUMENTS may give the bump (major, minor,
patch or X.Y.Z) or "pin vX.Y.Z" for a rollback; a rollback is just step 4.

## 1. What changed

- git fetch, git status, then git log --oneline and git diff --stat from
  the latest tag (git tag -l 'v*' --sort=-v:refname | head -1) to HEAD.
  Uncommitted work counts too; read the diff, not just the stat.
- Commit uncommitted work first, one signed commit per logical change,
  message in my voice (commit.gpgsign is on). No blind git add -A: check
  nothing unrelated or secret is in the tree. setup.sh holds only my public
  SSH key; passwords, /etc/msmtprc contents and the like never go in.
- If setup.sh changed, shellcheck it and, for anything beyond docs or
  comments, test it in a Debian 13 container (the harness is in my project
  memory) before releasing; shellcheck alone is not a test.

## 2. CHANGELOG.md

- Keep a Changelog format: entries under ## [Unreleased], grouped as
  ### Added, ### Changed, ### Fixed, ### Removed, ### Security, in that
  order, only the groups that apply. Released sections are never edited.
- Write for the person running setup.sh on a server: what changes on the
  box, new or changed prompts and defaults, new managed files, and what a
  re-run does to servers set up with the previous version. Not code
  detail. One entry per change, plain English, wrapped at 80 columns.
- The changelog edit can stay uncommitted: release.sh puts it in the
  release commit.

## 3. Version

- major: a re-run changes an existing server in a way that needs
  attention (a changed default, a removed prompt or option, hardening that
  can lock something out) or the install URL changes incompatibly.
- minor: a new optional step, prompt, package or managed file; things
  existing servers gain on the next run without surprises.
- patch: fixes, docs, infra, hardening tweaks with no visible change.
- If $ARGUMENTS or Chris named the bump, use it. Otherwise pick one, say
  why in one line, and only ask if two readings lead to different majors.

## 4. Run

- ./release.sh <bump> in the foreground with a ten minute timeout; the
  CloudFront deploy takes a few minutes. Read all of the output.
- It fails before "Releasing": nothing changed, fix the cause and rerun.
- It fails after the push (deploy or the final check): the tag is on
  GitHub and immutable. Fix the cause and run ./release.sh pin vX.Y.Z.
  Never delete or move a tag, force push, amend a pushed commit or touch
  the GitHub rulesets.
- "gpg cannot sign": the passphrase is not cached and there is no
  terminal here for pinentry. Stop and ask Chris to run
  gpg --sign -o /dev/null </dev/null in his terminal, then rerun.

## 5. Report

The version, the changelog entries, the "serves" line from release.sh and
the output of curl -sI https://get.chriselkins.io/setup.sh | grep x-debian-setup.
