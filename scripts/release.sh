#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

EXPECTED_REPO="johnyoonh/magicquit"
ACTUAL_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
[[ "$ACTUAL_REPO" == "$EXPECTED_REPO" ]] || { echo "Expected $EXPECTED_REPO, found $ACTUAL_REPO" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree must be clean" >&2; exit 1; }

VERSION=$(xcodebuild -project MagicQuit.xcodeproj -scheme MagicQuit -showBuildSettings 2>/dev/null | awk '/MARKETING_VERSION/ {print $3; exit}')
BUILD=$(xcodebuild -project MagicQuit.xcodeproj -scheme MagicQuit -showBuildSettings 2>/dev/null | awk '/CURRENT_PROJECT_VERSION/ {print $3; exit}')
[[ -n "$VERSION" && -n "$BUILD" ]] || { echo "Could not read version/build" >&2; exit 1; }
grep -q "Version $VERSION" CHANGELOG.md || { echo "CHANGELOG.md is missing version $VERSION" >&2; exit 1; }
if gh release view "v$VERSION" >/dev/null 2>&1; then
  echo "Release v$VERSION already exists" >&2
  exit 1
fi

ARCHIVE=build/release/MagicQuit.xcarchive
EXPORT_DIR=build/release/export
RELEASES_DIR=build/release/releases
ZIP="MagicQuit-$VERSION.zip"
RELEASE_URL_PREFIX="https://github.com/$EXPECTED_REPO/releases/download/v$VERSION/"

echo "==> Releasing MagicQuit $VERSION ($BUILD)"
rm -rf build/release
mkdir -p "$RELEASES_DIR"

plutil -lint MagicQuit/Info.plist
shellcheck scripts/release.sh || true

echo "==> Building tests"
xcodebuild test -project MagicQuit.xcodeproj -scheme MagicQuit -destination 'platform=macOS'

echo "==> Archiving"
xcodebuild -project MagicQuit.xcodeproj -scheme MagicQuit -configuration Release \
  -archivePath "$ARCHIVE" archive

echo "==> Exporting with Developer ID signing"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$EXPORT_DIR"

APP="$EXPORT_DIR/MagicQuit.app"
codesign --verify --deep --strict --verbose=2 "$APP"

FEED=$(defaults read "$APP/Contents/Info" SUFeedURL)
[[ "$FEED" == *"$EXPECTED_REPO"* ]] || { echo "Sparkle feed points outside $EXPECTED_REPO" >&2; exit 1; }

echo "==> Notarizing"
ditto -c -k --keepParent "$APP" "$RELEASES_DIR/$ZIP"
xcrun notarytool submit "$RELEASES_DIR/$ZIP" --keychain-profile magicquit-notary --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Zipping stapled app"
rm "$RELEASES_DIR/$ZIP"
ditto -c -k --keepParent "$APP" "$RELEASES_DIR/$ZIP"

echo "==> Generating and validating appcast"
generate_appcast "$RELEASES_DIR" --download-url-prefix "$RELEASE_URL_PREFIX"
grep -q "$EXPECTED_REPO/releases/download/v$VERSION" "$RELEASES_DIR/appcast.xml" || {
  echo "Generated appcast contains an unexpected download URL" >&2
  exit 1
}
cp "$RELEASES_DIR/appcast.xml" appcast.xml

SHA=$(shasum -a 256 "$RELEASES_DIR/$ZIP" | awk '{print $1}')
python3 scripts/update_cask.py "$VERSION" "$SHA"

# Commit release metadata before publishing so the feed and cask cannot lag the release.
git add appcast.xml packaging/homebrew/magicquit.rb
git commit -m "release: prepare v$VERSION metadata"
git push origin HEAD

echo "==> Creating GitHub release v$VERSION"
gh release create "v$VERSION" "$RELEASES_DIR/$ZIP" \
  --title "MagicQuit $VERSION" \
  --generate-notes \
  --target "$(git rev-parse HEAD)"

echo "Released MagicQuit $VERSION from $EXPECTED_REPO"
