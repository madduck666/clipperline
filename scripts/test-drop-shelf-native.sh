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
import os, pathlib, subprocess, sys, tempfile
for origin in ['temporary', 'downloads']:
    # The second launch retains the normal first-launch choice made through UI
    # in the first trial. Do not demand an onboarding modal that no longer exists.
    environment = dict(os.environ, CLIPBOARDLINE_NATIVE_FIXTURE_ROOT=origin,
                       CLIPBOARDLINE_NATIVE_EXPECT_ONBOARDING='1' if origin == 'temporary' else '0')
    print(f'Native Finder fixture origin: {origin}', flush=True)
    process = subprocess.Popen(sys.argv[1:], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        stdout, stderr = process.communicate(timeout=100)
        print(stdout, end='')
        print(stderr, end='', file=sys.stderr)
        if process.returncode != 0:
            sys.exit(process.returncode)
        if '::notice title=Native shelf drag::All real Finder file, folder and application-bundle drops passed' not in stdout:
            print('::error title=Native shelf drag::The fixture exited before completing all native drop assertions.')
            sys.exit(1)
    except subprocess.TimeoutExpired as error:
        # Sample only this generated fixture, never another user's process.
        # Publish bounded function names, not sample headers or file paths.
        frames = []
        try:
            with tempfile.TemporaryDirectory(prefix='native-shelf-sample-') as directory:
                sample = pathlib.Path(directory) / 'sample.txt'
                subprocess.run(['/usr/bin/sample', str(process.pid), '1', '1', '-file', str(sample)],
                               capture_output=True, text=True, timeout=8)
                if sample.exists():
                    for line in sample.read_text(errors='replace').splitlines():
                        if '(in ' in line and not '/' in line:
                            frames.append(line.strip())
                        if len(frames) == 18:
                            break
        except (OSError, subprocess.SubprocessError):
            pass
        process.kill()
        stdout, stderr = process.communicate()
        stages = []
        for output in [stdout, stderr]:
            if output:
                decoded = output.decode(errors='replace') if isinstance(output, bytes) else output
                print(decoded)
                stages.extend(line for line in decoded.splitlines() if line.startswith(('Native shelf fixture:', 'Packaged launch:')))
        stage = stages[-1] if stages else 'No launch milestone reached'
        safe_stage = stage.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        print(f'::error title=Native shelf drag::The native fixture exceeded 100 seconds; origin={origin}; last stage={safe_stage}; no successful drag result is claimed.')
        for frame in frames:
            escaped = frame.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
            print('::error title=Native fixture sampled stack::' + escaped)
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
