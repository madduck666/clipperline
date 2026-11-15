#!/bin/bash
# Run only in an isolated Mac desktop. Uses generated files and native mouse events.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/.build/drop-shelf-native"
mkdir -p "$OUT"
if ! swiftc -swift-version 5 -D DROP_SHELF_NATIVE_DIAGNOSTICS Sources/Tendedero/DropShelf.swift Tests/DropShelfNative/main.swift -o "$OUT/NativeDropTest" >"$OUT/build.log" 2>&1; then
  cat "$OUT/build.log"
  python3 - "$OUT/build.log" <<'PY'
import pathlib, sys
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if 'error:' in line:
        print('::error title=Native shelf fixture::' + line.replace('%', '%25'))
PY
  exit 1
fi
"$OUT/NativeDropTest"
