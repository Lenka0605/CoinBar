#!/bin/bash
# 用法：scripts/release.sh 1.0.0 "更新说明"
# 打包并发布到 GitHub Releases，App 内「立即更新」会读取这里的最新版本
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?需要版本号}"; NOTES="${2:-}"
scripts/bundle.sh "$VERSION"
REPO="$(grep -o 'githubOwner = "[^"]*"' Sources/CoinBar/Core/AppConfig.swift | cut -d'"' -f2)/$(grep -o 'githubRepo  = "[^"]*"' Sources/CoinBar/Core/AppConfig.swift | cut -d'"' -f2)"
gh release create "v${VERSION}" "dist/CoinBar-${VERSION}.zip" --repo "$REPO" --title "CoinBar ${VERSION}" --notes "${NOTES:-CoinBar ${VERSION}}"
