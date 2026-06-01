#!/usr/bin/env zsh
set -euo pipefail

# Ensure Homebrew tools (xcodegen) and git resolve even when launched from Finder.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

PULL=false
RELAUNCH=false
DELAY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pull) PULL=true; shift ;;
    --relaunch) RELAUNCH=true; shift ;;
    --delay) DELAY="${2:-0}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ "$DELAY" != "0" ]] && sleep "$DELAY"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${MODEX_REPO_PATH:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DERIVED_DATA="$REPO_ROOT/macos/build/DerivedData"
PROJECT="$REPO_ROOT/macos/Modex.xcodeproj"
APP_SOURCE="$DERIVED_DATA/Build/Products/Debug/Modex.app"
INSTALL_DIR="${MODEX_INSTALL_DIR:-/Applications}"

stamp_source_commit() {
  local plist="$1"
  /usr/libexec/PlistBuddy -c "Set :ModexSourceCommit $BUILD_COMMIT" "$plist" >/dev/null 2>&1 ||
    /usr/libexec/PlistBuddy -c "Add :ModexSourceCommit string $BUILD_COMMIT" "$plist" >/dev/null
}

cd "$REPO_ROOT"

if [[ "$PULL" == "true" ]]; then
  git fetch origin
  git pull --ff-only
fi

BUILD_COMMIT="$(git rev-parse HEAD)"

# Regenerate the Xcode project from project.yml (the committed source of truth).
xcodegen generate --spec "$REPO_ROOT/macos/project.yml" --project "$REPO_ROOT/macos"

xcodebuild \
  -project "$PROJECT" \
  -scheme Modex \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  build \
  CODE_SIGNING_ALLOWED=NO

[[ -d "$APP_SOURCE" ]] || { echo "Built app not found at $APP_SOURCE" >&2; exit 1; }
stamp_source_commit "$APP_SOURCE/Contents/Info.plist"

mkdir -p "$INSTALL_DIR"
APP_DEST="$INSTALL_DIR/Modex.app"

osascript -e 'quit app "Modex"' >/dev/null 2>&1 || true
sleep 0.5
rm -rf "$APP_DEST"
ditto "$APP_SOURCE" "$APP_DEST"
stamp_source_commit "$APP_DEST/Contents/Info.plist"
xattr -dr com.apple.quarantine "$APP_DEST" >/dev/null 2>&1 || true

# Re-assert this copy as the canonical "Modex" so Spotlight / Finder / `open -a`
# don't launch a stale build-directory copy that shares the same bundle id.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$APP_DEST" >/dev/null 2>&1 || true

[[ "$RELAUNCH" == "true" ]] && open "$APP_DEST"

echo "$APP_DEST"
