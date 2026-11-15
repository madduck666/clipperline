#!/usr/bin/env python3
"""Exercise the shipped update helpers against a local caching HTTP server."""
import http.server
import pathlib
import plistlib
import subprocess
import tempfile
import threading
import unittest

SCRIPT = pathlib.Path(__file__).resolve().with_name('mac-dev-update.sh')


class DeveloperUpdateTests(unittest.TestCase):
    def test_metadata_and_archive_urls_do_not_reuse_old_cached_assets(self):
        cache, seen = {}, []
        published = ['a' * 40]

        class CachedServer(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append(self.path)
                payload = cache.setdefault(self.path, published[0]).encode()
                self.send_response(200)
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), CachedServer)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = 'http://127.0.0.1:' + str(server.server_port)
            def invoke(command):
                return subprocess.check_output(['bash', '-c', 'source "$1"; BASE="$2"; ' + command,
                                                'update-fixture', str(SCRIPT), base], text=True).strip()
            self.assertEqual(invoke('latest_build'), 'a' * 40)
            published[0] = 'b' * 40
            self.assertEqual(invoke('latest_build'), 'b' * 40)
            self.assertNotEqual(seen[0], seen[1])
            published[0] = 'first archive'
            self.assertEqual(invoke('curl -fsSL "$(fresh_asset_url Clipperline.zip)"'), 'first archive')
            published[0] = 'second archive'
            self.assertEqual(invoke('curl -fsSL "$(fresh_asset_url Clipperline.zip)"'), 'second archive')
            self.assertNotEqual(seen[2], seen[3])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    @unittest.skipUnless(pathlib.Path('/usr/libexec/PlistBuddy').exists(), 'Requires the macOS plist reader')
    def test_downloaded_package_must_match_the_checked_commit_and_repository(self):
        with tempfile.TemporaryDirectory(prefix='dev-update-test-') as directory:
            app = pathlib.Path(directory) / 'Synthetic.app'
            (app / 'Contents').mkdir(parents=True)
            metadata = {'ClipBoardLineDevBuild': 'b' * 40, 'ClipBoardLineDevRepository': 'synthetic/fork'}
            def verify(expected):
                (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(metadata))
                return subprocess.run(['bash', '-c', 'source "$1"; REPO=synthetic/fork; verify_downloaded_build "$2" "$3"',
                                       'update-fixture', str(SCRIPT), str(app), expected], capture_output=True).returncode
            self.assertEqual(verify('b' * 40), 0)
            self.assertNotEqual(verify('a' * 40), 0)
            metadata['ClipBoardLineDevRepository'] = 'another/fork'
            self.assertNotEqual(verify('b' * 40), 0)
            self.assertTrue(app.exists(), 'Rejecting stale metadata must preserve the downloaded bundle')


if __name__ == '__main__':
    unittest.main()
