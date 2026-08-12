#!/usr/bin/env bash
# Cuts a release: bumps VERSION, tags, and pushes.
#
#   ./scripts/release.sh 0.2.0
#
# Signing and notarisation are NOT here yet — they need an Apple Developer ID
# ($99/yr). Until that exists this produces a tag and an unsigned build, which
# macOS will warn about on other people's machines. See SPEC.md §9.
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: ./scripts/release.sh <version>   e.g. 0.2.0" >&2
  exit 1
fi
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "version must look like 1.2.3" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ -n "$(git status --porcelain)" ]; then
  echo "working tree is dirty — commit first" >&2
  exit 1
fi

# The changelog is part of the release, not an afterthought: refuse to tag
# without an entry, so no version can ship undocumented.
if ! grep -q "## \[$VERSION\]" CHANGELOG.md; then
  echo "CHANGELOG.md has no '## [$VERSION]' section — add one first" >&2
  exit 1
fi

echo "$VERSION" > VERSION
git add VERSION CHANGELOG.md
# VERSION and the changelog are often bumped as part of the feature commit, in
# which case there is nothing left to commit here — that's fine, not an error.
if git diff --cached --quiet; then
  echo "VERSION and CHANGELOG.md already committed — tagging that commit"
else
  git commit -m "Release $VERSION"
fi
git tag -a "v$VERSION" -m "Release $VERSION"

echo
echo "tagged v$VERSION. To publish:"
echo "  git push && git push --tags"
echo "  ./scripts/build-app.sh release"
echo "  gh release create v$VERSION --notes-from-tag"
