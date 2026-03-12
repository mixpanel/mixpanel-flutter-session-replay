#!/bin/bash
set -euo pipefail

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 1.2.0"
  exit 1
fi

NEW_VERSION="$1"

if ! echo "$NEW_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$'; then
  echo "Error: Invalid version format '$NEW_VERSION'. Expected semver (e.g. 1.0.0 or 1.0.0-beta.1)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

PUBSPEC="$ROOT/pubspec.yaml"
README="$ROOT/README.md"
VERSION_DART="$ROOT/lib/src/version.dart"
CHANGELOG="$ROOT/CHANGELOG.md"

CURRENT=$(grep '^version:' "$PUBSPEC" | awk '{print $2}')

# Update version in source files (sed -i.bak is portable across GNU and BSD sed)
sed -i.bak "s/^version: .*/version: $NEW_VERSION/" "$PUBSPEC"
sed -i.bak "s/mixpanel_flutter_session_replay: .*/mixpanel_flutter_session_replay: $NEW_VERSION/" "$README"
sed -i.bak "s/sdkVersion = '.*-flutter'/sdkVersion = '$NEW_VERSION-flutter'/" "$VERSION_DART"
rm -f "$PUBSPEC.bak" "$README.bak" "$VERSION_DART.bak"

# ---------------------------------------------------------------------------
# Generate changelog entry from merged PRs since last tag.
#
# PR titles must use conventional prefixes:
#   feat: ...   -> Features
#   fix: ...    -> Bug Fixes
#   chore: ...  -> Other
#
# Requires: gh CLI (available in GitHub Actions runners by default)
# Falls back to commit messages when gh is unavailable or no tag exists.
# ---------------------------------------------------------------------------
LAST_TAG=$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || echo "")

if command -v gh &>/dev/null && [[ -n "$LAST_TAG" ]]; then
  TAG_DATE=$(git -C "$ROOT" log -1 --format=%aI "$LAST_TAG")

  # Fetch merged PRs since the last tag
  PRS=$(gh pr list \
    --state merged \
    --base main \
    --search "merged:>=$TAG_DATE" \
    --json number,title \
    --jq '.[] | "\(.number)\t\(.title)"' \
    --limit 200 2>/dev/null || echo "")

  if [[ -n "$PRS" ]]; then
    FEATURES=""
    FIXES=""
    OTHER=""

    while IFS=$'\t' read -r NUMBER TITLE; do
      # Use bash parameter expansion instead of sed to avoid shell
      # metacharacter injection from PR titles (e.g. / or & in sed).
      case "$TITLE" in
        feat:*)  DESC="${TITLE#feat: }"; FEATURES+="* $DESC (#$NUMBER)"$'\n' ;;
        fix:*)   DESC="${TITLE#fix: }"; FIXES+="* $DESC (#$NUMBER)"$'\n' ;;
        chore:*) DESC="${TITLE#chore: }"; OTHER+="* $DESC (#$NUMBER)"$'\n' ;;
        *)       OTHER+="* $TITLE (#$NUMBER)"$'\n' ;;
      esac
    done <<< "$PRS"

    ENTRY="## $NEW_VERSION"$'\n'
    if [[ -n "$FEATURES" ]]; then
      ENTRY+=$'\n'"### Features"$'\n'$'\n'"$FEATURES"
    fi
    if [[ -n "$FIXES" ]]; then
      ENTRY+=$'\n'"### Bug Fixes"$'\n'$'\n'"$FIXES"
    fi
    if [[ -n "$OTHER" ]]; then
      ENTRY+=$'\n'"### Other"$'\n'$'\n'"$OTHER"
    fi
  else
    # No PRs found — fall back to commit log
    COMMITS=$(git -C "$ROOT" log "$LAST_TAG"..HEAD --pretty=format:"* %s" --no-merges)
    ENTRY="## $NEW_VERSION"$'\n'$'\n'"$COMMITS"$'\n'
  fi
else
  # No gh CLI or no previous tag — fall back to commit log
  if [[ -n "$LAST_TAG" ]]; then
    COMMITS=$(git -C "$ROOT" log "$LAST_TAG"..HEAD --pretty=format:"* %s" --no-merges)
  else
    COMMITS=$(git -C "$ROOT" log --pretty=format:"* %s" --no-merges)
  fi
  ENTRY="## $NEW_VERSION"$'\n'$'\n'"$COMMITS"$'\n'
fi

# Prepend new changelog entry
printf '%s\n\n%s\n' "$ENTRY" "$(cat "$CHANGELOG")" > "$CHANGELOG"

echo "$CURRENT -> $NEW_VERSION"
echo "Updated: pubspec.yaml, README.md, lib/src/version.dart, CHANGELOG.md"
