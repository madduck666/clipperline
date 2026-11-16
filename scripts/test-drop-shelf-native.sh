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
python3 - "$OUT/NativeDropTest" "$@" <<'PYNATIVE'
import os, subprocess, sys
for origin in ['temporary', 'downloads']:
    # The second launch retains the normal first-launch choice made through UI
    # in the first trial. Do not demand an onboarding modal that no longer exists.
    environment = dict(os.environ, CLIPBOARDLINE_NATIVE_FIXTURE_ROOT=origin,
                       CLIPBOARDLINE_NATIVE_EXPECT_ONBOARDING='1' if origin == 'temporary' else '0')
    print(f'Native Finder fixture origin: {origin}', flush=True)
    try:
        result = subprocess.run(sys.argv[1:], env=environment, capture_output=True, text=True, timeout=60)
        print(result.stdout, end='')
        print(result.stderr, end='', file=sys.stderr)
        if result.returncode != 0:
            sys.exit(result.returncode)
        if '::notice title=Native shelf drag::All real Finder file, folder and application-bundle drops passed' not in result.stdout:
            print('::error title=Native shelf drag::The fixture exited before completing all native drop assertions.')
            sys.exit(1)
    except subprocess.TimeoutExpired as error:
        for output in [error.stdout, error.stderr]:
            if output:
                print(output.decode(errors='replace') if isinstance(output, bytes) else output)
        print('::error title=Native shelf drag::The native fixture exceeded 60 seconds; no successful drag result is claimed.')
        sys.exit(1)

PYNATIVE

if [ "$#" = 0 ]; then
  # A separate, unprivileged app isolates external drag observation from the
  # input-posting test process, before the full application is built.
  HOST_APP="$OUT/NativeShelfHost.app"
  mkdir -p "$HOST_APP/Contents/MacOS"
  swiftc -O -swift-version 5 Sources/Tendedero/DropShelf.swift Tests/DropShelfNativeHost/main.swift -o "$HOST_APP/Contents/MacOS/ShelfHost"
  python3 - "$HOST_APP/Contents/Info.plist" <<'PYHOST'
import pathlib, plistlib, sys
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'org.clipboardline.native-shelf-host',
    'CFBundleExecutable': 'ShelfHost', 'CFBundlePackageType': 'APPL',
    'CFBundleName': 'NativeShelfHost', 'CFBundleVersion': '1', 'LSUIElement': True
}))
PYHOST
  codesign --force --sign - "$HOST_APP"
  # Reuse the actual packaged-app path and its external drag-out assertions.
  bash "$0" "$HOST_APP"
fi
