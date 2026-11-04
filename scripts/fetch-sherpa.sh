#!/bin/bash
# Скачивает статическую сборку sherpa-onnx (движок голосового ввода) и заголовок C API
# в Vendor/sherpa-onnx/. Хэши вшиты: несовпадение — ошибка, файл удаляется.
# Идемпотентно: если всё на месте и совпадает с .verified — ничего не делает.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="v2.0.1"
ARCHIVE="sherpa-onnx-$VERSION-osx-arm64-static-lib.tar.bz2"
ARCHIVE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/$VERSION/$ARCHIVE"
ARCHIVE_SHA="d7a9b14f337958e7373c8c650f046df33d210bbaff2f33cb8322dda663ee5e1c"
HEADER_URL="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$VERSION/sherpa-onnx/c-api/c-api.h"
HEADER_SHA="5698f38ba09ad2bdf085c56a6cbbd7741acf15e25f4ce5c7097b9702cadf437f"

DIR="Vendor/sherpa-onnx"
HEADER="$DIR/include/sherpa-onnx/c-api/c-api.h"
MARK="$DIR/.verified"
WANT="$VERSION $ARCHIVE_SHA $HEADER_SHA"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

if [ -f "$MARK" ] && [ "$(cat "$MARK")" = "$WANT" ] \
   && [ -f "$DIR/lib/libsherpa-onnx-c-api.a" ] && [ -f "$HEADER" ] \
   && [ "$(sha "$HEADER")" = "$HEADER_SHA" ]; then
  exit 0
fi

fail() { echo "❌ fetch-sherpa: $*" >&2; exit 1; }

# Скачать и сверить хэш; при несовпадении файл удаляется.
download() { # url dest sha
  local url="$1" dest="$2" want="$3"
  if [ -f "$dest" ] && [ "$(sha "$dest")" = "$want" ]; then return 0; fi
  rm -f "$dest"
  mkdir -p "$(dirname "$dest")"
  echo "⬇️  $url"
  curl -fL --proto '=https' --tlsv1.2 --retry 2 -o "$dest.part" "$url" \
    || { rm -f "$dest.part"; fail "не удалось скачать $url (нет интернета?). Для сборки голосового помощника нужен Vendor/sherpa-onnx — запустите scripts/fetch-sherpa.sh при подключении к сети."; }
  if [ "$(sha "$dest.part")" != "$want" ]; then
    rm -f "$dest.part"
    fail "SHA-256 $(basename "$dest") не совпал — файл удалён"
  fi
  mv "$dest.part" "$dest"
}

rm -f "$MARK"
download "$ARCHIVE_URL" "$DIR/$ARCHIVE" "$ARCHIVE_SHA"
download "$HEADER_URL" "$HEADER" "$HEADER_SHA"

rm -rf "$DIR/lib"
mkdir -p "$DIR/lib"
tar -xjf "$DIR/$ARCHIVE" -C "$DIR" --strip-components=1 "sherpa-onnx-$VERSION-osx-arm64-static-lib/lib"
[ -f "$DIR/lib/libsherpa-onnx-c-api.a" ] || fail "в архиве нет libsherpa-onnx-c-api.a"

echo "$WANT" > "$MARK"
echo "sherpa-onnx $VERSION готов: $DIR"
