#!/usr/bin/env bash
#
# Release debian-setup and point https://get.chriselkins.io/setup.sh at it.
#
#   ./release.sh major|minor|patch   next version after the latest v* tag
#   ./release.sh X.Y.Z               exactly that version
#   ./release.sh pin vX.Y.Z          serve an existing release again (roll
#                                    back, or finish one whose deploy failed)
#
# A release moves the entries under "Unreleased" in CHANGELOG.md to a new
# version heading, sets VERSION in setup.sh, makes a signed commit and a
# signed tag, pushes both, deploys the CloudFormation stack in infra/ with
# the tag's commit as the pin, invalidates the CloudFront cache and checks
# what the URL serves against git. The working tree must be clean apart from
# CHANGELOG.md. Everything is checked before anything is changed.

set -euo pipefail

SIGNING_KEY=8D704BC74F88154263399870127C56EF4AF6881B
STACK=debian-setup-get
REGION=us-east-1
RAW=https://raw.githubusercontent.com/chriselkins/debian-setup

die()   { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log()   { printf '\n==> %s\n' "$*"; }
usage() { die "usage: $0 major|minor|patch|X.Y.Z, or $0 pin vX.Y.Z"; }

root=$(git rev-parse --show-toplevel)

output() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

# next_version CURRENT major|minor|patch|X.Y.Z
next_version() {
  local major minor patch
  IFS=. read -r major minor patch <<<"$1"
  case $2 in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    patch) echo "$major.$minor.$((patch + 1))" ;;
    *)     [[ $2 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage; echo "$2" ;;
  esac
}

# pin TAG: make the URL serve setup.sh from TAG, which must be on GitHub and
# carry a good signature from my key, by fingerprint rather than any key gpg
# happens to know.
pin() {
  local tag=$1 status remote sha url dist inv served expected
  status=$(git verify-tag --raw "$tag" 2>&1) || die "$tag does not verify"
  grep -q "^\[GNUPG:\] VALIDSIG .* $SIGNING_KEY\$" <<<"$status" || die "$tag is not signed by $SIGNING_KEY"
  remote=$(git ls-remote --tags origin "refs/tags/$tag" | cut -f1)
  [[ -n $remote && $remote == "$(git rev-parse "$tag")" ]] || die "$tag is not on origin: git push origin $tag"
  sha=$(git rev-parse "$tag^{commit}")
  # CloudFront would cache a 404 for a commit GitHub does not serve yet.
  curl -fsS -o /dev/null "$RAW/$sha/setup.sh" || die "GitHub does not serve commit $sha"

  log "Pinning $tag ($sha)"
  # Parameters not given here keep their current values.
  aws cloudformation deploy --region "$REGION" --stack-name "$STACK" \
    --template-file "$root/infra/cloudfront.yaml" \
    --parameter-overrides "CommitSha=$sha" "ReleaseTag=$tag" \
    --no-fail-on-empty-changeset
  url=$(output Url)
  dist=$(output DistributionId)

  # The rewritten path is the cache key, so a new pin is a new object; the
  # invalidation only guards against anything cached under the old one.
  log "Invalidating the CloudFront cache"
  inv=$(aws cloudfront create-invalidation --distribution-id "$dist" --paths '/*' --query Invalidation.Id --output text)
  aws cloudfront wait invalidation-completed --distribution-id "$dist" --id "$inv"

  log "Checking $url"
  served=$(curl -fsS "$url" | sha256sum | cut -d' ' -f1)
  expected=$(git show "$tag:setup.sh" | sha256sum | cut -d' ' -f1)
  [[ $served == "$expected" ]] || die "$url does not serve $tag: got $served, expected $expected"
  echo "$url serves $tag ($sha)"
}

release() {
  local last version tag notes dirty mode=error tmp
  [[ $(git branch --show-current) == main ]] || die "not on main"
  git fetch --quiet origin
  git merge-base --is-ancestor origin/main HEAD || die "main is behind origin/main"
  # Only the changelog may be modified: its Unreleased entries go into the
  # release commit. Anything else is committed on its own first.
  dirty=$(git status --porcelain | grep -v ' CHANGELOG.md$' || true)
  [[ -z $dirty ]] || die "the working tree is not clean (only CHANGELOG.md may be modified):"$'\n'"$dirty"
  shellcheck -s bash "$root/setup.sh" "$root/release.sh"
  grep -q '^VERSION=' "$root/setup.sh" || die "setup.sh has no VERSION line"

  last=$(git tag -l 'v*' --sort=-v:refname | head -1)
  version=$(next_version "${last#v}" "$1")
  tag=v$version
  [[ $(printf '%s\n%s\n' "${last:-v0.0.0}" "$tag" | sort -V | tail -1) == "$tag" && $tag != "$last" ]] || die "$tag is not newer than $last"
  ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "$tag exists"
  [[ -z $(git ls-remote --tags origin "refs/tags/$tag") ]] || die "$tag exists on origin"

  notes=$(awk '/^## \[Unreleased\]/ { on = 1; next } /^## \[/ { on = 0 } on' "$root/CHANGELOG.md")
  notes=${notes#"${notes%%[![:space:]]*}"}
  [[ -n $notes ]] || die "CHANGELOG.md has nothing under Unreleased"

  # Fail here, before anything changes, if gpg cannot sign. Without a
  # terminal there is no pinentry, so a passphrase that is not cached in
  # gpg-agent has to be entered in a terminal first.
  [[ -t 1 ]] && mode=ask
  gpg --pinentry-mode "$mode" --local-user "$SIGNING_KEY" --sign -o /dev/null </dev/null 2>/dev/null ||
    die "gpg cannot sign; run 'gpg --sign -o /dev/null </dev/null' in a terminal to unlock the key, then retry"

  log "Releasing $tag (after ${last:-nothing})"
  tmp=$(mktemp)
  awk -v ver="$version" -v date="$(date +%F)" '
    /^## \[Unreleased\]/ { print; print ""; print "## [" ver "] - " date; next }
    { print }
  ' "$root/CHANGELOG.md" >"$tmp" && mv "$tmp" "$root/CHANGELOG.md"
  sed -i "s/^VERSION=.*/VERSION=$version/" "$root/setup.sh"
  git add "$root/CHANGELOG.md" "$root/setup.sh"
  git commit --quiet --gpg-sign="$SIGNING_KEY" -m "Release $tag"
  git tag -u "$SIGNING_KEY" -m "$tag" -m "$notes" "$tag"
  git push origin main "$tag"
  pin "$tag"
}

case ${1:-} in
  pin) [[ $# -eq 2 && $2 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage; pin "$2" ;;
  '')  usage ;;
  *)   [[ $# -eq 1 ]] || usage; release "$1" ;;
esac
