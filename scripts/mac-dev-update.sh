#!/bin/bash
# Installs or updates "Clipperline" (formerly "ClipBoardLine Dev") from this fork's dev-latest
# pre-release without a Gatekeeper prompt and without losing privacy
# permissions on every update.
#
# - curl does not mark its download as coming from the internet, so macOS
#   does not ask to "Open Anyway".
# - Every build is re-signed with one signing identity that is created on
#   this Mac and never leaves it. macOS ties Accessibility and other
#   permissions to that identity, so they survive updates.
#
# First installation, from Terminal:
#   curl -fsSL https://raw.githubusercontent.com/madduck666/clipperline/main/scripts/mac-dev-update.sh | bash
# Later updates run from the app: Settings → Updates. The app bundles this
# script and runs "prepare", then "swap --wait-pid <its pid>" as it quits.
set -Eeuo pipefail
# Never stop silently: name the step that failed.
trap 'printf "\nHATA: Beklenmeyen bir sorun oldu (adım: %s, satır %s). Bu mesajın ekran görüntüsünü gönder.\n" "$BASH_COMMAND" "$LINENO" >&2' ERR

REPO="${CLIPBOARDLINE_DEV_REPOSITORY:-madduck666/clipperline}"
BASE="https://github.com/$REPO/releases/download/dev-latest"
APP_NAME="Clipperline"
# The name before the rename. Its folder is removed once Clipperline is in place.
LEGACY_TARGET="/Applications/ClipBoardLine Dev.app"
TARGET="/Applications/$APP_NAME.app"
# The updater folder, keychain and signing identity keep their first names:
# renaming them would make a new identity and macOS would ask for every
# permission again.
SUPPORT="$HOME/Library/Application Support/ClipBoardLine Dev Updater"
STAGED="$SUPPORT/staged/$APP_NAME.app"
KEYCHAIN="$HOME/Library/Keychains/clipboardline-dev-signing.keychain-db"
IDENTITY="ClipBoardLine Dev Local Signing"

say() { printf '\n==> %s\n' "$*" >&2; }
fail() { printf '\nHATA: %s\n' "$*" >&2; exit 1; }

has_identity() {
  local identities
  identities="$(security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null || true)"
  [[ "$identities" == *"\"$IDENTITY\""* ]]
}

# A private keychain with a random password keeps signing free of keychain
# prompts. It holds only the local signing key.
ensure_identity() {
  local password_file="$SUPPORT/keychain-password"
  if [ ! -f "$password_file" ]; then
    # openssl rand, not tr | head: head closing the pipe fails it under pipefail.
    /usr/bin/openssl rand -hex 16 >"$password_file"
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
  if has_identity; then
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
  p12pass="$(/usr/bin/openssl rand -hex 12)"
  /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$IDENTITY" -passout "pass:$p12pass" -out "$work/identity.p12" >/dev/null 2>&1
  security import "$work/identity.p12" -k "$KEYCHAIN" -P "$p12pass" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$KEYCHAIN" >/dev/null
  say "macOS şimdi bir kez Mac şifreni isteyecek: imzaya güvenmek için şifreni gir"
  security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$work/cert.pem"
  rm -rf "$work"
  has_identity || fail "Yerel imza oluşturulamadı."
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

latest_build() {
  curl -fsSL "$BASE/ClipBoardLine-Dev-build.txt" | tr -d '[:space:]'
}

# Downloads and signs the newest build into the staging folder. Nothing in
# Applications changes yet. The last line printed is the staged build.
prepare() {
  local latest
  latest="$(latest_build)" || fail "dev-latest sürümü indirilemedi. İnternet bağlantını kontrol et."
  [[ "$latest" =~ ^[0-9a-f]{40}$ ]] || fail "dev-latest sürüm bilgisi okunamadı."
  ensure_identity
  local work
  work="$(mktemp -d)"
  say "Yeni sürüm indiriliyor (${latest:0:7})"
  curl -fL --progress-bar "$BASE/$APP_NAME.zip" -o "$work/app.zip"
  ditto -x -k "$work/app.zip" "$work"
  [ -d "$work/$APP_NAME.app" ] || fail "İndirilen dosyada uygulama bulunamadı."
  say "Uygulama bu Mac'in imzasıyla imzalanıyor"
  sign_app "$work/$APP_NAME.app"
  xattr -dr com.apple.quarantine "$work/$APP_NAME.app" 2>/dev/null || true
  rm -rf "$(dirname "$STAGED")"
  mkdir -p "$(dirname "$STAGED")"
  ditto "$work/$APP_NAME.app" "$STAGED"
  printf '%s\n' "$latest" >"$SUPPORT/staged-build"
  rm -rf "$work"
  echo "$latest"
}

# Replaces the installed app with the staged one and opens it. With a PID,
# waits for that running app to quit first. If the replacement fails, the
# previous app stays in place and is reopened.
swap() {
  local pid="${1:-}"
  [ -d "$STAGED" ] || fail "Hazırlanmış bir güncelleme yok."
  if [ -n "$pid" ]; then
    for _ in $(seq 1 1200); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$pid" 2>/dev/null && fail "Uygulama kapanmadı; güncelleme ertelendi."
  fi
  say "Uygulamalar klasörüne kuruluyor"
  rm -rf "$TARGET.new" "$TARGET.old"
  if ditto "$STAGED" "$TARGET.new"; then
    if [ ! -e "$TARGET" ] || mv "$TARGET" "$TARGET.old"; then
      if mv "$TARGET.new" "$TARGET"; then
        rm -rf "$TARGET.old"
        if [ -d "$LEGACY_TARGET" ] && [ "$LEGACY_TARGET" != "$TARGET" ]; then rm -rf "$LEGACY_TARGET"; fi
        cp "$SUPPORT/staged-build" "$SUPPORT/installed-build"
        rm -rf "$(dirname "$STAGED")"
        open "$TARGET"
        say "Tamam. Clipperline güncellendi ve açıldı."
        return
      fi
      mv "$TARGET.old" "$TARGET" 2>/dev/null || true
    fi
  fi
  rm -rf "$TARGET.new"
  [ -d "$TARGET" ] && open "$TARGET"
  fail "Uygulama değiştirilemedi. Sistem Ayarları → Gizlilik ve Güvenlik → Uygulama Yönetimi'nde Clipperline'a (Terminal'den kurduysan Terminal'e) izin verip tekrar dene."
}

# Any running copy, wherever it runs from: macOS starts an app opened after
# "Open Anyway" from a hidden translocated path, not from Applications.
RUNNING_PATTERN="/(Clipperline|ClipBoardLine Dev)\.app/Contents/MacOS/"
running() { pgrep -f "$RUNNING_PATTERN" >/dev/null 2>&1; }
quit_running() {
  local attempt
  for attempt in $(seq 1 20); do
    running || return 0
    osascript -e 'tell application id "org.clipboardline.community" to quit' >/dev/null 2>&1 || true
    sleep 0.5
  done
  pkill -TERM -f "$RUNNING_PATTERN" 2>/dev/null || true
  sleep 1
}

main() {
  [ "$(uname -s)" = Darwin ] || fail "Bu betik yalnızca Mac'te çalışır."
  mkdir -p "$SUPPORT"
  chmod 700 "$SUPPORT"
  case "${1:-install}" in
    latest)
      latest_build
      ;;
    prepare)
      prepare
      ;;
    swap)
      [ "${2:-}" = --wait-pid ] && [ -n "${3:-}" ] || fail "Kullanım: swap --wait-pid <pid>"
      swap "$3"
      ;;
    install)
      say "En son sürüm kontrol ediliyor"
      local latest installed
      latest="$(latest_build)" || fail "dev-latest sürümü indirilemedi. İnternet bağlantını kontrol et."
      installed="$(cat "$SUPPORT/installed-build" 2>/dev/null || true)"
      if [ -n "$installed" ] && [ "$installed" = "$latest" ] && [ -d "$TARGET" ] && [ ! -d "$LEGACY_TARGET" ]; then
        say "Zaten en son sürüm kurulu (${latest:0:7}). Yapılacak bir şey yok."
        return
      fi
      prepare >/dev/null
      if running; then
        say "Çalışan Clipperline kapatılıyor"
        quit_running
      fi
      swap
      if [ -z "$installed" ]; then
        echo "İlk kurulum: Mac izin isterse bir kez 'İzin Ver' de. Sonraki güncellemelerde izinler korunur."
      fi
      echo "Sonraki güncellemeler: Clipperline → Ayarlar → Güncellemeler → Güncellemeleri kontrol et."
      ;;
    *)
      fail "Bilinmeyen komut: $1"
      ;;
  esac
}

# The whole script is read before anything runs, so nothing it starts can
# consume the rest of a piped "curl ... | bash".
main "$@" </dev/null
