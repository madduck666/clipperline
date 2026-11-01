#!/bin/bash
# Installs or updates "ClipBoardLine Dev" from this fork's dev-latest
# pre-release without a Gatekeeper prompt and without losing privacy
# permissions on every update.
#
# - curl does not mark its download as coming from the internet, so macOS
#   does not ask to "Open Anyway".
# - Every build is re-signed with one signing identity that is created on
#   this Mac and never leaves it. macOS ties Accessibility and other
#   permissions to that identity, so they survive updates.
#
# Run it with:
#   curl -fsSL https://raw.githubusercontent.com/madduck666/clipperline/main/scripts/mac-dev-update.sh | bash
set -euo pipefail

REPO="madduck666/clipperline"
BASE="https://github.com/$REPO/releases/download/dev-latest"
APP_NAME="ClipBoardLine Dev"
TARGET="/Applications/$APP_NAME.app"
SUPPORT="$HOME/Library/Application Support/ClipBoardLine Dev Updater"
KEYCHAIN="$HOME/Library/Keychains/clipboardline-dev-signing.keychain-db"
IDENTITY="ClipBoardLine Dev Local Signing"
LAUNCHER="/Applications/$APP_NAME Güncelle.command"

say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nHATA: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "Bu betik yalnızca Mac'te çalışır."
mkdir -p "$SUPPORT"
chmod 700 "$SUPPORT"

# A private keychain with a random password keeps signing free of keychain
# prompts. It holds only the local signing key.
ensure_identity() {
  local password_file="$SUPPORT/keychain-password"
  if [ ! -f "$password_file" ]; then
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 >"$password_file"
    chmod 600 "$password_file"
  fi
  local password
  password="$(cat "$password_file")"
  if [ ! -f "$KEYCHAIN" ]; then
    security create-keychain -p "$password" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"
  fi
  security unlock-keychain -p "$password" "$KEYCHAIN"
  # Keep the private keychain in the search list so codesign can find it,
  # after every keychain already there.
  local existing=() entry found=false
  while IFS= read -r entry; do
    entry="${entry#"${entry%%[![:space:]]*}"}"; entry="${entry%\"}"; entry="${entry#\"}"
    [ -n "$entry" ] || continue
    existing+=("$entry")
    [ "$entry" = "$KEYCHAIN" ] && found=true
  done < <(security list-keychains -d user)
  if [ "$found" = false ]; then
    security list-keychains -d user -s "${existing[@]}" "$KEYCHAIN"
  fi
  if security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "\"$IDENTITY\""; then
    return
  fi
  say "Bu Mac'e özel imza oluşturuluyor (yalnızca ilk seferde)"
  local work
  work="$(mktemp -d)"
  cat >"$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
    -config "$work/cert.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null 2>&1
  local p12pass
  p12pass="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$IDENTITY" -passout "pass:$p12pass" -out "$work/identity.p12" >/dev/null 2>&1
  security import "$work/identity.p12" -k "$KEYCHAIN" -P "$p12pass" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$KEYCHAIN" >/dev/null
  say "macOS şimdi bir kez Mac şifreni isteyecek: imzaya güvenmek için 'İzin Ver' / şifre gir"
  security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$work/cert.pem"
  rm -rf "$work"
  security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "\"$IDENTITY\"" \
    || fail "Yerel imza oluşturulamadı."
}

sign_app() {
  local app="$1" sparkle="$1/Contents/Frameworks/Sparkle.framework/Versions/B"
  local args=(--force --sign "$IDENTITY" --keychain "$KEYCHAIN" --options 0 --timestamp=none)
  # Inner code first, the application last, as the build script does.
  codesign "${args[@]}" "$sparkle/XPCServices/Installer.xpc"
  codesign "${args[@]}" --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
  codesign "${args[@]}" "$sparkle/Autoupdate"
  codesign "${args[@]}" "$sparkle/Updater.app"
  codesign "${args[@]}" "$app/Contents/Frameworks/Sparkle.framework"
  codesign "${args[@]}" "$app"
  codesign --verify --deep --strict "$app"
}

install_launcher() {
  [ -f "$LAUNCHER" ] && return
  cat >"$LAUNCHER" <<EOF
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/mac-dev-update.sh | bash
echo
read -r -p "Bitti. Kapatmak için Enter'a bas. " _
EOF
  chmod +x "$LAUNCHER" 2>/dev/null || true
}

main() {
running() { pgrep -f "$TARGET/Contents/MacOS/" >/dev/null 2>&1; }

say "En son sürüm kontrol ediliyor"
latest="$(curl -fsSL "$BASE/ClipBoardLine-Dev-build.txt" | tr -d '[:space:]')" \
  || fail "dev-latest sürümü indirilemedi. İnternet bağlantını kontrol et."
installed="$(cat "$SUPPORT/installed-build" 2>/dev/null || true)"
if [ -n "$installed" ] && [ "$installed" = "$latest" ] && [ -d "$TARGET" ]; then
  install_launcher
  say "Zaten en son sürüm kurulu (${latest:0:7}). Yapılacak bir şey yok."
  exit 0
fi

ensure_identity

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
say "Yeni sürüm indiriliyor (${latest:0:7})"
curl -fL --progress-bar "$BASE/ClipBoardLine-Dev.zip" -o "$work/app.zip"
ditto -x -k "$work/app.zip" "$work"
[ -d "$work/$APP_NAME.app" ] || fail "İndirilen dosyada uygulama bulunamadı."

say "Uygulama bu Mac'in imzasıyla imzalanıyor"
sign_app "$work/$APP_NAME.app"
xattr -dr com.apple.quarantine "$work/$APP_NAME.app" 2>/dev/null || true

was_running=false
if running; then
  was_running=true
  say "Çalışan ClipBoardLine Dev kapatılıyor"
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do running || break; sleep 0.5; done
fi

say "Uygulamalar klasörüne kuruluyor"
if ! { rm -rf "$TARGET" && ditto "$work/$APP_NAME.app" "$TARGET"; }; then
  fail "Uygulama değiştirilemedi. Sistem Ayarları → Gizlilik ve Güvenlik → Uygulama Yönetimi'nde Terminal'i açıp tekrar dene."
fi
printf '%s\n' "$latest" >"$SUPPORT/installed-build"
install_launcher

open "$TARGET"
say "Tamam. ClipBoardLine Dev ${latest:0:7} kuruldu ve açıldı."
if [ "$was_running" = false ] && [ -z "$installed" ]; then
  echo "İlk kurulum: Mac izin isterse bir kez 'İzin Ver' de. Sonraki güncellemelerde izinler korunur."
fi
echo "Sonraki güncellemeler için Uygulamalar klasöründeki '$APP_NAME Güncelle' dosyasına çift tıklaman yeterli."
}

# The whole script is read before anything runs, so nothing it starts can
# consume the rest of a piped "curl ... | bash".
main "$@" </dev/null
