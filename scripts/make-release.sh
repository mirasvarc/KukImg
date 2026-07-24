#!/bin/bash
# Builds, zips and Sparkle-signs a Kuk release, then updates appcast.xml and
# the Homebrew cask template. Does NOT commit, tag or publish anything —
# it prints the follow-up commands instead.
#
# Usage: scripts/make-release.sh <version>      e.g. scripts/make-release.sh 1.1.0
#
# Requires: the Sparkle EdDSA private key in your login Keychain
# (created once with generate_keys).

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: make-release.sh <version>}
REPO_URL="https://github.com/mirasvarc/KukImg"
ZIP="Kuk-v$VERSION.zip"
DIST=dist
TOOLS=.sparkle-tools
SPARKLE_VERSION=2.9.4

# --- bootstrap Sparkle CLI tools (sign_update) ------------------------------
if [[ ! -x "$TOOLS/bin/sign_update" ]]; then
    echo "Downloading Sparkle $SPARKLE_VERSION tools…"
    mkdir -p "$TOOLS"
    curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
        | tar -xJ -C "$TOOLS"
fi

# --- build & zip ------------------------------------------------------------
echo "Building Kuk ${VERSION}…"
rm -rf "$DIST/build"
xcodebuild -project KukImg.xcodeproj -scheme KukImg -configuration Release \
    -derivedDataPath "$DIST/build" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" \
    build -quiet

mkdir -p "$DIST"
ditto -c -k --keepParent "$DIST/build/Build/Products/Release/Kuk.app" "$DIST/$ZIP"

# --- sign & append to appcast ----------------------------------------------
SIG=$("$TOOLS/bin/sign_update" "$DIST/$ZIP")    # sparkle:edSignature="…" length="…"
PUBDATE=$(LC_ALL=C date +"%a, %d %b %Y %H:%M:%S %z")

ITEM="        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$VERSION</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <enclosure url=\"$REPO_URL/releases/download/v$VERSION/$ZIP\" $SIG type=\"application/octet-stream\"/>
        </item>"

ITEM="$ITEM" python3 - <<'EOF'
import os
item = os.environ["ITEM"]
with open("appcast.xml") as f:
    xml = f.read()
marker = "<language>en</language>"
assert marker in xml, "appcast.xml: marker not found"
with open("appcast.xml", "w") as f:
    f.write(xml.replace(marker, marker + "\n" + item, 1))
EOF

# --- update Homebrew cask ---------------------------------------------------
SHA=$(shasum -a 256 "$DIST/$ZIP" | cut -d' ' -f1)
sed -i '' \
    -e "s|^  version \".*\"|  version \"$VERSION\"|" \
    -e "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" \
    packaging/kuk.rb

cat <<MSG

✓ built and signed   $DIST/$ZIP
✓ appcast.xml        new <item> for $VERSION
✓ packaging/kuk.rb   version + sha256 updated

Publish (in this order, so the appcast never points at a missing file):

  1. gh release create v$VERSION $DIST/$ZIP --title "Kuk $VERSION" --notes "…"
  2. git add appcast.xml packaging/kuk.rb
     git commit -m "release $VERSION" && git push origin main
  3. cp packaging/kuk.rb ../homebrew-tap/Casks/kuk.rb
     (cd ../homebrew-tap && git commit -am "kuk $VERSION" && git push)
MSG
