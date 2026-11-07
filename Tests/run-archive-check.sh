#!/bin/bash
# Распаковка архивов обновления (KitArchive, install.sh): ссылки и пути за пределы папки отвергаются до записи на диск.
# Архивы составлены вручную из python3 zipfile; подписи не нужны, настоящие приложения и launchd не затрагиваются.
# Папка стенда: ARCHIVE_CHECK_DIR, иначе $TMPDIR/archive-check.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${ARCHIVE_CHECK_DIR:-${TMPDIR:-/tmp}/archive-check}"
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
rm -rf "$OUT"
mkdir -p "$OUT/victim" "$OUT/bin"
OUT="$(cd "$OUT" && pwd -P)"
fail() { echo "ПРОВАЛ: $1"; exit 1; }

python3 -I - "$OUT" <<'PY'
import sys, zipfile
out = sys.argv[1]
def entry(z, name, data=b"x", mode=0o100644):
    info = zipfile.ZipInfo(name)
    info.create_system = 3
    info.external_attr = mode << 16
    z.writestr(info, data)
with zipfile.ZipFile(out + "/good.zip", "w") as z:
    entry(z, "X.app/", b"", 0o040755)
    entry(z, "X.app/Contents/", b"", 0o040755)
    entry(z, "X.app/Contents/Info.plist")
with zipfile.ZipFile(out + "/symlink-write.zip", "w") as z:
    entry(z, "X.app/a", out + "/victim", 0o120777)
    entry(z, "X.app/a/evil.txt")
with zipfile.ZipFile(out + "/symlink-up.zip", "w") as z:
    entry(z, "X.app/Contents/link", "../../../../etc", 0o120777)
with zipfile.ZipFile(out + "/dotdot.zip", "w") as z:
    entry(z, "X.app/../../evil.txt")
with zipfile.ZipFile(out + "/absolute.zip", "w") as z:
    entry(z, "/tmp/evil.txt")
with zipfile.ZipFile(out + "/backslash.zip", "w") as z:
    entry(z, "X.app\\..\\evil.txt")
open(out + "/notzip.zip", "w").write("это не zip")
PY
# Ссылку, настоящую для ditto, собирает сам ditto.
mkdir -p "$OUT/real/X.app/Contents"
echo x >"$OUT/real/X.app/Contents/Info.plist"
ln -s "$OUT/victim" "$OUT/real/X.app/Contents/link"
(cd "$OUT/real" && ditto -c -k --keepParent X.app "$OUT/symlink-ditto.zip")

mkdir -p "$OUT/src"
cp Tests/ArchiveCheck.swift "$OUT/src/main.swift"
swiftc -target "$TARGET" -o "$OUT/check" "$OUT/src/main.swift" Sources/Kit/KitArchive.swift Sources/Kit/KitSigning.swift
"$OUT/check" "$OUT" || fail "KitArchive"
[ ! -e /tmp/evil.txt ] || fail "абсолютный путь записал /tmp/evil.txt"

# install.sh: основной путь, архив подставляет curl-заглушка. Отказ до распаковки: ни папки установки, ни .app.
cat >"$OUT/bin/curl" <<'STUB'
#!/bin/bash
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then cp "$FAKE_ZIP" "$2"; exit 0; fi
  shift
done
exit 1
STUB
chmod +x "$OUT/bin/curl"
for name in symlink-write symlink-up symlink-ditto dotdot absolute; do
  mkdir -p "$OUT/inst-$name"
  if PATH="$OUT/bin:$PATH" FAKE_ZIP="$OUT/$name.zip" INSTALL_DIR="$OUT/inst-$name" NO_OPEN=1 bash install.sh >"$OUT/install.log" 2>&1; then
    fail "install.sh поставил архив $name"
  fi
  grep -qE 'ссылк|за пределы' "$OUT/install.log" || { cat "$OUT/install.log"; fail "install.sh: нет отказа по составу архива ($name)"; }
  [ -z "$(ls -A "$OUT/inst-$name")" ] || fail "install.sh: что-то записано ($name)"
done
[ -z "$(ls -A "$OUT/victim")" ] || fail "install.sh записал за пределы папки"
echo "ok   install.sh (основной путь) отвергает ссылки и пути за пределы папки до распаковки"
echo "ВСЁ ОК"
