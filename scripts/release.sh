#!/bin/bash
# One-command release: builds, signs, publishes to GitHub, pushes the appcast
# and updates the Homebrew tap.
#
# Usage: scripts/release.sh <version> "<release notes>"
#        e.g. scripts/release.sh 1.2.1 "Fixed thumbnail flicker"

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: release.sh <version> "<release notes>"}
NOTES=${2:?usage: release.sh <version> "<release notes>"}
REPO=mirasvarc/KukImg
TAP_DIR=../homebrew-tap
ZIP="dist/Kuk-v$VERSION.zip"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# --- pre-flight -------------------------------------------------------------
step "Pre-flight checks"
[[ $(git branch --show-current) == main ]] || { echo "ERROR: not on main"; exit 1; }
git fetch -q origin
if ! git diff --quiet HEAD -- ':!appcast.xml' ':!packaging'; then
    echo "ERROR: uncommitted changes in tracked files — commit or stash first,"
    echo "so the released build matches what's on GitHub."
    exit 1
fi
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated"; exit 1; }
if gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1; then
    echo "ERROR: release v$VERSION already exists"; exit 1
fi
if [[ ! -d $TAP_DIR/.git ]]; then
    echo "Tap clone not found, cloning to $TAP_DIR…"
    gh repo clone mirasvarc/homebrew-tap "$TAP_DIR"
fi
mkdir -p "$TAP_DIR/Casks"

# --- push source, so the tag lands on what we build -------------------------
step "Pushing main"
git push origin main

# --- build, sign, update appcast + cask -------------------------------------
step "Building and signing $VERSION"
scripts/make-release.sh "$VERSION"

# --- publish (release first, so the appcast never points into the void) -----
step "Creating GitHub release v$VERSION"
gh release create "v$VERSION" "$ZIP" -R "$REPO" \
    --title "Kuk $VERSION" --notes "$NOTES"

step "Pushing appcast"
git add appcast.xml packaging/kuk.rb
git commit -m "release $VERSION"
git push origin main

step "Updating Homebrew tap"
cp packaging/kuk.rb "$TAP_DIR/Casks/kuk.rb"
git -C "$TAP_DIR" add Casks/kuk.rb
git -C "$TAP_DIR" commit -m "kuk $VERSION"
git -C "$TAP_DIR" push

# --- verify what the world actually sees ------------------------------------
step "Verifying"
FAIL=0

CODE=$(curl -sIL -o /dev/null -w '%{http_code}' \
    "https://github.com/$REPO/releases/download/v$VERSION/Kuk-v$VERSION.zip")
if [[ $CODE == 200 ]]; then
    echo "✓ release asset downloads anonymously (HTTP $CODE)"
else
    echo "✗ release asset returned HTTP $CODE"; FAIL=1
fi

if gh api "repos/$REPO/contents/appcast.xml" -q .content | base64 -d \
        | grep -q "<sparkle:version>$VERSION</sparkle:version>"; then
    echo "✓ appcast on main contains $VERSION"
else
    echo "✗ appcast on main does NOT contain $VERSION"; FAIL=1
fi

if gh api repos/mirasvarc/homebrew-tap/contents/Casks/kuk.rb -q .content | base64 -d \
        | grep -q "version \"$VERSION\""; then
    echo "✓ tap cask is at $VERSION"
else
    echo "✗ tap cask is NOT at $VERSION"; FAIL=1
fi

if [[ $FAIL == 0 ]]; then
    printf '\n\033[1;32mKuk %s is out.\033[0m Installed apps will pick it up via Sparkle\n' "$VERSION"
    echo "(raw.githubusercontent CDN can lag a few minutes); brew users: brew upgrade --cask kuk"
else
    printf '\n\033[1;31mRelease finished with problems — see ✗ above.\033[0m\n'
    exit 1
fi
