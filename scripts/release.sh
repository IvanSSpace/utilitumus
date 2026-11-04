#!/bin/bash
# Релиз со своего Mac: собрать, подписать постоянным сертификатом и выложить
# в GitHub Releases. Без очереди на macOS-раннеры GitHub (там можно ждать
# десятки минут). Приложение у пользователей найдёт релиз само.
#   ./scripts/release.sh 0.2.2
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Укажи версию: ./scripts/release.sh 0.2.2}"
TAG="v$VERSION"
REPO="IvanSSpace/utilitumus"
export GH_TOKEN="${GH_TOKEN:-$(gh auth token --user IvanSSpace 2>/dev/null || true)}"

if [ -n "$(git status --porcelain)" ]; then
  echo "Есть незакоммиченные изменения — сначала закоммить их." >&2
  exit 1
fi
git fetch -q origin
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "Локальный main не совпадает с GitHub — сначала git push." >&2
  exit 1
fi
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "Релиз $TAG уже есть." >&2
  exit 1
fi

# Версия фиксируется в репозитории отдельным коммитом: иначе локальная сборка
# остаётся со старой версией и приложение предлагает «обновиться» назад.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" Info.plist
git add Info.plist
git commit -q -m "Версия $VERSION"
git push -q origin HEAD:main

NO_INSTALL=1 ./build.sh
# Без постоянного сертификата у пользователей после обновления слетят разрешения.
if ! codesign -d -r- build/Utilitumus.app 2>&1 | grep -q "certificate leaf"; then
  echo "Сборка не подписана сертификатом «Utilitumus Signing» — релиз не выкладываю." >&2
  exit 1
fi
ditto -c -k --keepParent build/Utilitumus.app build/Utilitumus.zip

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag "$TAG"
git push -q origin "$TAG"
gh release create "$TAG" build/Utilitumus.zip -R "$REPO" --title "Utilitumus $TAG" --generate-notes
echo "Выложено: https://github.com/$REPO/releases/tag/$TAG"
