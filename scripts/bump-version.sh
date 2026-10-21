#!/bin/bash
# bump-version.sh — 升级版本号（VERSION / package.json / project.yml 三处同步）
# Usage: ./scripts/bump-version.sh [major|minor|patch]
set -e

TYPE=${1:-patch}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION_FILE="$PROJECT_DIR/VERSION"

if [ ! -f "$VERSION_FILE" ]; then
    echo "Error: VERSION file not found"
    exit 1
fi

CURRENT=$(tr -d '[:space:]' < "$VERSION_FILE")
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

case $TYPE in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
    *) echo "Usage: $0 [major|minor|patch]"; exit 1 ;;
esac

NEW_VERSION="$MAJOR.$MINOR.$PATCH"
echo "$NEW_VERSION" > "$VERSION_FILE"

# 同步 package.json 顶层 version（用 2 空格缩进锚定，避免误改 releaseHistory 里同版本号的条目）
if [ -f "$PROJECT_DIR/package.json" ]; then
    sed -i '' "s/^  \"version\": \"$CURRENT\"/  \"version\": \"$NEW_VERSION\"/" "$PROJECT_DIR/package.json"
fi

# 同步 project.yml
if [ -f "$PROJECT_DIR/project.yml" ]; then
    sed -i '' "s/MARKETING_VERSION: \"$CURRENT\"/MARKETING_VERSION: \"$NEW_VERSION\"/" "$PROJECT_DIR/project.yml"
fi

echo "Version bumped: $CURRENT -> $NEW_VERSION"
echo ""
echo "Next steps:"
echo "  git add -A && git commit -m 'chore: bump version to $NEW_VERSION'"
echo "  git tag v$NEW_VERSION"
echo "  git push origin main --tags"
