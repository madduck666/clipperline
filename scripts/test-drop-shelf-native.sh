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
python3 - "$OUT/NativeDropTest" <<'PYNATIVE'
import subprocess, sys
try:
    result = subprocess.run([sys.argv[1]], capture_output=True, text=True, timeout=60)
    print(result.stdout, end='')
    print(result.stderr, end='', file=sys.stderr)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired as error:
    for output in [error.stdout, error.stderr]:
        if output:
            print(output.decode(errors='replace') if isinstance(output, bytes) else output)
    print('::error title=Native shelf drag::The native fixture exceeded 60 seconds; no successful drag result is claimed.')
    sys.exit(1)
PYNATIVE
