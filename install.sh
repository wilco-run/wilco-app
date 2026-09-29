#!/bin/bash
# Installer for Wilco desktop app test builds (macOS on Apple silicon).
#
#   curl -fsSL https://wilco.run/download/app/install.sh | bash
#
# Test builds are not signed with an Apple Developer ID and not notarized. macOS marks every file a web
# browser downloads as quarantined, and then refuses to open such an app with the message
# "Wilco is damaged and can't be opened". The app is not damaged. This script downloads the app with
# curl, checks its SHA-256 checksum and its code signature, removes the quarantine mark and installs it.
#
# Where it downloads from: the current build is served at https://wilco.run/download/app/ (SHA256SUMS and
# Wilco-<version>-<build>-mac-arm64.zip). --version TAG installs an earlier build from the release archive
# on GitHub (https://github.com/<repository>/releases/download/TAG/), which holds the same files under the same
# names; the first test build there has its zip under the older name Wilco-mac-arm64.zip, which --version also
# accepts. Either way SHA256SUMS names the one zip to install and its checksum.
#
# Usage:
#   install.sh [--version TAG] [--dest DIR]  install or update Wilco (default: the current build from wilco.run)
#   install.sh --fix [PATH]                  make a Wilco.app you downloaded yourself open
#                                            (default: /Applications/Wilco.app, then ~/Applications/Wilco.app)
#   install.sh --uninstall [--dest DIR]      remove the app; your data is kept
#   install.sh --help
#
# With curl | bash, pass options after "bash -s --", for example:
#   curl -fsSL https://wilco.run/download/app/install.sh | bash -s -- --uninstall
#
# It never uses sudo, never quits a running Wilco and reads nothing from standard input.
# Environment (for mirrors and tests):
#   WILCO_APP_DOWNLOAD_BASE     replaces https://wilco.run/download/app (any folder with SHA256SUMS and the
#                               zip, such as one GitHub archive release: .../releases/download/TAG)
#   WILCO_APP_ARCHIVE_BASE      replaces https://github.com/<repository>/releases/download (for --version)
#   WILCO_APP_APPLICATIONS_DIR  replaces /Applications
set -euo pipefail

# The release archive; --version TAG downloads from it.
REPO="wilco-run/wilco-app"
# wilco.run serves the current build here (checked by the download tool that publishes this script).
DOWNLOAD_BASE_DEFAULT="https://wilco.run/download/app"
ARCHIVE_BASE_DEFAULT="https://github.com/$REPO/releases/download"
# The zip's name: Wilco-<version>-<build id>-mac-arm64.zip; the first test build used the fixed name.
ZIP_RE='^Wilco-(0|[1-9][0-9]{0,5})[.](0|[1-9][0-9]{0,5})[.](0|[1-9][0-9]{0,5})-[0-9]{8}T[0-9]{6}Z-mac-arm64[.]zip$'
LEGACY_ZIP="Wilco-mac-arm64.zip"
SUMS_NAME="SHA256SUMS"
MAX_SUMS_BYTES=65536
MAX_ZIP_BYTES=1073741824
APP_NAME="Wilco.app"
BUNDLE_ID="run.wilco.app"
EXECUTABLE="Wilco"
PLISTBUDDY="/usr/libexec/PlistBuddy"

TMP_DIR=""
STAGE_DIR=""
ASIDE=""
TARGET=""
SWAP_STATE="none"
ZIP_NAME=""
ZIP_SUM=""

say() { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Wilco desktop app installer (test builds, macOS on Apple silicon)

Usage:
  install.sh [--version TAG] [--dest DIR]  install or update Wilco (default: the current build from wilco.run)
  install.sh --fix [PATH]                  make a Wilco.app you downloaded yourself open
                                           (default: /Applications/Wilco.app, then ~/Applications/Wilco.app)
  install.sh --uninstall [--dest DIR]      remove the app; your data is kept
  install.sh --help                        show this help

Options:
  --version TAG  install this test build (for example v0.1.0-test.20260927.1) from the release archive
                 instead of the current build from wilco.run
  --dest DIR     install into (or uninstall from) DIR instead of /Applications

With curl | bash, pass options after "bash -s --":
  curl -fsSL https://wilco.run/download/app/install.sh | bash -s -- --fix

The installer never uses sudo and never quits a running Wilco. Your data is never removed.
EOF
}

# Runs on every exit. If the old app was moved aside and the new one is not in place, the old one is put back.
cleanup() {
  local rc=$?
  set +e
  if [ "$SWAP_STATE" = "aside" ] && [ -n "$ASIDE" ] && [ -d "$ASIDE" ]; then
    if [ ! -e "$TARGET" ] && mv "$ASIDE" "$TARGET" 2>/dev/null; then
      printf 'The previous Wilco was put back at %s.\n' "$TARGET" >&2
    else
      printf 'Error: the previous Wilco could not be put back. It is at: %s\n' "$ASIDE" >&2
      printf '       Move it back with: mv "%s" "%s"\n' "$ASIDE" "$TARGET" >&2
    fi
  fi
  if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then rm -rf "$STAGE_DIR"; fi
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
  return "$rc"
}

need_tools() {
  local t
  for t in uname sysctl sw_vers id curl shasum ditto codesign xattr pgrep mktemp awk sed grep tr sort; do
    command -v "$t" >/dev/null 2>&1 || die "the command '$t' is missing. It is part of macOS; is this a standard macOS shell?"
  done
  [ -x "$PLISTBUDDY" ] || die "$PLISTBUDDY is missing. It is part of macOS."
}

check_platform() {
  local os arm64 translated arch
  os="$(uname -s 2>/dev/null || echo unknown)"
  [ "$os" = "Darwin" ] || die "the Wilco desktop app is for macOS only (this system is $os)."
  arm64="$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)"
  [ "$arm64" = "1" ] || die "Wilco needs a Mac with Apple silicon (M1 or later). This Mac has an Intel processor."
  translated="$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  if [ "$translated" = "1" ] || [ "$arch" != "arm64" ]; then
    die "this shell runs as $arch (Rosetta), not arm64. Open a Terminal that is not set to \"Open using Rosetta\" and run the installer again."
  fi
}

check_not_root() {
  [ "$(id -u)" != "0" ] || die "do not run the installer as root or with sudo. Run it as yourself."
}

plist_get() {
  "$PLISTBUDDY" -c "Print :$2" "$1" 2>/dev/null
}

# 0 when $1 is a real (not symlinked) Wilco app bundle.
is_wilco_bundle() {
  local app="$1" id
  [ -d "$app" ] && [ ! -L "$app" ] || return 1
  [ -f "$app/Contents/Info.plist" ] || return 1
  id="$(plist_get "$app/Contents/Info.plist" CFBundleIdentifier || true)"
  [ "$id" = "$BUNDLE_ID" ] || return 1
  [ -f "$app/Contents/MacOS/$EXECUTABLE" ] && [ -x "$app/Contents/MacOS/$EXECUTABLE" ] || return 1
  return 0
}

app_version() {
  local v
  v="$(plist_get "$1/Contents/Info.plist" CFBundleShortVersionString || true)"
  [ -n "$v" ] || v="unknown"
  printf '%s' "$v"
}

# 0 when $1 < $2 (dotted numeric versions).
version_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, "."); k = (n > m) ? n : m
    for (i = 1; i <= k; i++) {
      xi = (i <= n) ? x[i] + 0 : 0; yi = (i <= m) ? y[i] + 0 : 0
      if (xi < yi) exit 0
      if (xi > yi) exit 1
    }
    exit 1
  }'
}

regex_escape() {
  printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'
}

# 0 when a Wilco process runs: any process named exactly Wilco, or any process started from inside $1.
wilco_running() {
  if pgrep -x "$EXECUTABLE" >/dev/null 2>&1; then return 0; fi
  if [ -n "${1:-}" ] && pgrep -f "^$(regex_escape "$1")/Contents/" >/dev/null 2>&1; then return 0; fi
  return 1
}

refuse_if_running() {
  if wilco_running "${1:-}"; then
    die "Wilco is running. Quit Wilco (Wilco > Quit Wilco, or Command-Q), then run this command again."
  fi
}

# Verifies the code signature of the whole bundle (test builds carry an ad hoc signature).
check_signature() {
  local app="$1" log
  log="$(codesign --verify --deep --strict "$app" 2>&1)" && return 0
  printf '%s\n' "$log" >&2
  return 1
}

# Removes com.apple.quarantine from every file in the bundle; 1 when some is left.
remove_quarantine() {
  local app="$1" list
  # -s: act on symbolic links themselves (never follow them out of the bundle).
  xattr -drs com.apple.quarantine "$app" 2>/dev/null || true
  list="$(xattr -rsl "$app" 2>/dev/null || true)"
  case "$list" in
    *": com.apple.quarantine:"*) return 1 ;;
  esac
  return 0
}

check_min_macos() {
  local app="$1" min os_ver
  min="$(plist_get "$app/Contents/Info.plist" LSMinimumSystemVersion || true)"
  os_ver="$(sw_vers -productVersion 2>/dev/null || echo 0)"
  if [ -n "$min" ] && version_lt "$os_ver" "$min"; then
    die "this build of Wilco needs macOS $min or later (this Mac runs macOS $os_ver)."
  fi
}

# check_base NAME VALUE: prints VALUE without a trailing slash when it is a plain https:// address (plain
# http only on this computer); stops otherwise.
check_base() {
  local name="$1" base="$2"
  while [ "${#base}" -gt 1 ] && [ "${base%/}" != "$base" ]; do base="${base%/}"; done
  # No user info, whitespace or control characters anywhere: "http://127.0.0.1:x@otherhost/" must not pass
  # as a local address.
  case "$base" in
    *@* | *[[:space:]]* | *[[:cntrl:]]*) die "$name is not a plain address: $base" ;;
  esac
  case "$base" in
    https://*) ;;
    http://127.0.0.1:* | http://127.0.0.1/* | http://localhost:* | http://localhost/* | "http://[::1]:"* | "http://[::1]/"*) ;;
    *) die "$name must be an https:// address (plain http only on this computer): $base" ;;
  esac
  printf '%s' "$base"
}

# Where the current build is served: https://wilco.run/download/app.
download_base() {
  check_base WILCO_APP_DOWNLOAD_BASE "${WILCO_APP_DOWNLOAD_BASE:-$DOWNLOAD_BASE_DEFAULT}"
}

# The release archive (--version TAG): https://github.com/<repository>/releases/download.
archive_base() {
  check_base WILCO_APP_ARCHIVE_BASE "${WILCO_APP_ARCHIVE_BASE:-$ARCHIVE_BASE_DEFAULT}"
}

# fetch URL OUT MAXBYTES [progress]: downloads URL to OUT; returns curl's exit code (22: an HTTP error such as
# 404). "progress": show a progress bar when stderr is a terminal.
fetch() {
  local url="$1" out="$2" max="$3" proto="=https"
  case "$url" in http://*) proto="=http,https" ;; esac
  if [ "${4:-}" = "progress" ] && [ -t 2 ]; then
    curl --fail --location --show-error --progress-bar --proto "$proto" --proto-redir "$proto" \
      --retry 3 --retry-delay 2 --connect-timeout 20 --max-filesize "$max" -o "$out" "$url"
  else
    curl --fail --location --silent --show-error --proto "$proto" --proto-redir "$proto" \
      --retry 3 --retry-delay 2 --connect-timeout 20 --max-filesize "$max" -o "$out" "$url"
  fi
}

# get_sums BASE OUT: downloads BASE/SHA256SUMS.
get_sums() {
  rm -f "$2"
  fetch "$1/$SUMS_NAME" "$2" "$MAX_SUMS_BYTES" \
    || die "could not download $SUMS_NAME from $1. Check your internet connection (and the version, if you gave one)."
  [ -s "$2" ] || die "$SUMS_NAME from $1 is empty; refusing to install an unverified download."
}

# pick_zip SUMS LEGACY_OK: sets ZIP_NAME and ZIP_SUM to the one Wilco app zip for macOS on Apple silicon that
# SHA256SUMS lists (Wilco-<version>-<build>-mac-arm64.zip). LEGACY_OK=1 (--version) also accepts the first
# test build's Wilco-mac-arm64.zip when no such name is listed.
pick_zip() {
  local sums="$1" legacy_ok="$2" names count expected
  names="$(tr -d '\r' <"$sums" | awk '{ n = $2; sub(/^\*/, "", n); print n }' | grep -E "$ZIP_RE" | LC_ALL=C sort -u || true)"
  count="$(printf '%s' "$names" | awk 'NF { c++ } END { print c + 0 }')"
  if [ "$count" = "0" ] && tr -d '\r' <"$sums" | awk -v f="$LEGACY_ZIP" '{ n = $2; sub(/^\*/, "", n); if (n == f) found = 1 } END { exit found ? 0 : 1 }'; then
    [ "$legacy_ok" = "1" ] || die "$SUMS_NAME lists only $LEGACY_ZIP, the name the first test build used; install such a build with --version TAG."
    names="$LEGACY_ZIP"
    count=1
  fi
  [ "$count" != "0" ] || die "$SUMS_NAME lists no Wilco app for macOS on Apple silicon (Wilco-<version>-<build>-mac-arm64.zip); refusing to install."
  [ "$count" = "1" ] || die "$SUMS_NAME lists more than one Wilco app for macOS on Apple silicon; refusing to install."
  ZIP_NAME="$names"
  expected="$(tr -d '\r' <"$sums" | awk -v f="$ZIP_NAME" '{ n = $2; sub(/^\*/, "", n); if (n == f) print tolower($1) }' | LC_ALL=C sort -u)"
  count="$(printf '%s' "$expected" | awk 'NF { c++ } END { print c + 0 }')"
  [ "$count" = "1" ] || die "$SUMS_NAME lists more than one checksum for $ZIP_NAME; refusing to install."
  printf '%s' "$expected" | grep -Eq '^[0-9a-f]{64}$' || die "$SUMS_NAME has a malformed checksum for $ZIP_NAME; refusing to install."
  ZIP_SUM="$expected"
}

verify_checksum() {
  local zip="$1" actual
  actual="$(shasum -a 256 "$zip" | awk '{ print tolower($1) }')"
  if [ "$actual" != "$ZIP_SUM" ]; then
    die "checksum mismatch for $ZIP_NAME (expected $ZIP_SUM, got $actual). The download is incomplete or was changed; nothing was installed."
  fi
}

# check_identity APP: the app must be the build the zip's name says (version, and the build id in Info.plist
# when the app carries one). The first test build's zip name says nothing, so it is not checked.
check_identity() {
  local app="$1" rest want_version want_build got
  [ "$ZIP_NAME" != "$LEGACY_ZIP" ] || return 0
  rest="${ZIP_NAME#Wilco-}"
  want_version="${rest%%-*}"
  want_build="${rest#"$want_version"-}"
  want_build="${want_build%-mac-arm64.zip}"
  got="$(app_version "$app")"
  [ "$got" = "$want_version" ] || die "$ZIP_NAME holds Wilco $got, not $want_version; refusing to install."
  got="$(plist_get "$app/Contents/Info.plist" WilcoBuildId || true)"
  if [ -n "$got" ] && [ "$got" != "$want_build" ]; then
    die "$ZIP_NAME holds build $got, not $want_build; refusing to install."
  fi
}

# Picks the folder to install into and prints it.
resolve_dest() {
  local dest="${1:-}" apps
  if [ -n "$dest" ]; then
    [ -d "$dest" ] || die "the folder $dest does not exist."
    dest="$(cd "$dest" && pwd -P)"
    [ -w "$dest" ] || die "the folder $dest is not writable for $(id -un). Choose another folder with --dest (the installer never uses sudo)."
    printf '%s' "$dest"
    return 0
  fi
  apps="${WILCO_APP_APPLICATIONS_DIR:-/Applications}"
  apps="${apps%/}"
  if [ -d "$apps" ] && [ -w "$apps" ]; then
    printf '%s' "$apps"
    return 0
  fi
  mkdir -p "$HOME/Applications" || die "could not create $HOME/Applications."
  [ -w "$HOME/Applications" ] || die "neither $apps nor $HOME/Applications is writable. Choose a folder with --dest."
  say "$apps is not writable for $(id -un), so Wilco goes to $HOME/Applications instead. (An administrator can move it to $apps later.)" >&2
  printf '%s' "$HOME/Applications"
}

cmd_install() {
  local version="$1" dest_arg="$2" base label legacy_ok dest zip sums unpacked version_new version_old rc first
  check_platform
  check_not_root
  need_tools

  if [ -z "$version" ] || [ "$version" = "latest" ]; then
    base="$(download_base)"
    label="the current test build"
    legacy_ok=0
  else
    base="$(archive_base)/$version"
    label="test build $version"
    legacy_ok=1
  fi

  dest="$(resolve_dest "$dest_arg")"
  TARGET="$dest/$APP_NAME"
  if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    [ ! -L "$TARGET" ] || die "$TARGET is a symbolic link. Remove it and run the installer again."
    is_wilco_bundle "$TARGET" || die "$TARGET exists but is not the Wilco app, so it was left alone. Move it away and run the installer again."
  fi
  refuse_if_running "$TARGET"

  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wilco-install.XXXXXX")"
  zip="$TMP_DIR/download.zip"
  sums="$TMP_DIR/$SUMS_NAME"

  say "Downloading $label of Wilco..."
  get_sums "$base" "$sums"
  pick_zip "$sums" "$legacy_ok"
  say "Downloading $ZIP_NAME..."
  rc=0
  fetch "$base/$ZIP_NAME" "$zip" "$MAX_ZIP_BYTES" progress || rc=$?
  if [ "$rc" = "22" ]; then
    # An HTTP error such as 404: a new build may have been published between the two downloads (the old zip is
    # then gone). Read SHA256SUMS once more; if it names another zip, download that one.
    first="$ZIP_NAME"
    get_sums "$base" "$sums"
    pick_zip "$sums" "$legacy_ok"
    if [ "$ZIP_NAME" != "$first" ]; then
      say "The build on offer changed meanwhile; downloading $ZIP_NAME..."
      rm -f "$zip"
      rc=0
      fetch "$base/$ZIP_NAME" "$zip" "$MAX_ZIP_BYTES" progress || rc=$?
    fi
  fi
  [ "$rc" = "0" ] || die "could not download $ZIP_NAME from $base. Check your internet connection and try again."

  say "Checking the SHA-256 checksum..."
  verify_checksum "$zip"

  say "Unpacking..."
  mkdir "$TMP_DIR/unpack"
  ditto -x -k "$zip" "$TMP_DIR/unpack" || die "could not unpack $ZIP_NAME."
  unpacked="$TMP_DIR/unpack/$APP_NAME"
  is_wilco_bundle "$unpacked" || die "the download does not contain a valid $APP_NAME (Contents/MacOS/$EXECUTABLE and the bundle identifier $BUNDLE_ID are required)."
  check_identity "$unpacked"
  check_min_macos "$unpacked"

  say "Checking the code signature..."
  check_signature "$unpacked" || die "the code signature of the downloaded app is not valid; nothing was installed."
  remove_quarantine "$unpacked" || die "could not remove the quarantine mark from the downloaded app."
  version_new="$(app_version "$unpacked")"

  # Stage the new copy in the destination folder (same volume), so putting it in place is a rename.
  STAGE_DIR="$(mktemp -d "$dest/.wilco-install.XXXXXX")" || die "could not create a temporary folder in $dest."
  ditto "$unpacked" "$STAGE_DIR/$APP_NAME" || die "could not copy Wilco into $dest (is the disk full?)."
  remove_quarantine "$STAGE_DIR/$APP_NAME" || die "could not remove the quarantine mark from the copied app."
  check_signature "$STAGE_DIR/$APP_NAME" || die "the copy in $dest failed its signature check; nothing was changed."

  refuse_if_running "$TARGET"
  version_old=""
  if [ -e "$TARGET" ]; then
    version_old="$(app_version "$TARGET")"
    ASIDE="$STAGE_DIR-previous"
    [ ! -e "$ASIDE" ] || die "$ASIDE already exists; remove it and run the installer again."
    # A rename inside the same folder: the old app is only moved aside, nothing is deleted yet.
    mv "$TARGET" "$ASIDE" || die "could not move the installed Wilco aside; nothing was changed. If macOS says Terminal was prevented from modifying apps, allow Terminal under System Settings > Privacy & Security > App Management (or move the old Wilco to the Trash yourself), then run this again."
    SWAP_STATE="aside"
  fi
  [ ! -e "$TARGET" ] || die "$TARGET appeared while installing; nothing was changed."
  mv "$STAGE_DIR/$APP_NAME" "$TARGET" || die "could not move the new Wilco into $dest."
  SWAP_STATE="done"
  if [ -n "$ASIDE" ] && [ -e "$ASIDE" ]; then
    rm -rf "$ASIDE" 2>/dev/null || warn "the previous version could not be removed completely. Remove it with: rm -rf \"$ASIDE\""
  fi
  ASIDE=""

  say ""
  if [ -n "$version_old" ]; then
    say "Wilco $version_new is installed at $TARGET (replaced $version_old)."
  else
    say "Wilco $version_new is installed at $TARGET."
  fi
  say "Open it from Launchpad or Spotlight, or run: open \"$TARGET\""
  say "Sign in with your Wilco account (https://wilco.run) when the app asks."
}

cmd_fix() {
  local app="$1" apps v
  check_platform
  check_not_root
  need_tools
  if [ -z "$app" ]; then
    apps="${WILCO_APP_APPLICATIONS_DIR:-/Applications}"
    if [ -e "${apps%/}/$APP_NAME" ]; then
      app="${apps%/}/$APP_NAME"
    elif [ -e "$HOME/Applications/$APP_NAME" ]; then
      app="$HOME/Applications/$APP_NAME"
    else
      die "Wilco.app is not in /Applications or ~/Applications. Pass its path, for example: install.sh --fix ~/Downloads/Wilco.app"
    fi
  fi
  while [ "${#app}" -gt 1 ] && [ "${app%/}" != "$app" ]; do app="${app%/}"; done
  case "$app" in
    *.zip) die "$app is the zip file. Open it in Finder to unzip it, then run --fix on the Wilco.app it contains." ;;
  esac
  [ -e "$app" ] || [ -L "$app" ] || die "$app does not exist."
  [ ! -L "$app" ] || die "$app is a symbolic link. Pass the app itself."
  is_wilco_bundle "$app" || die "$app is not the Wilco app (bundle identifier $BUNDLE_ID). The installer only fixes Wilco."
  say "Checking the code signature of $app..."
  check_signature "$app" || die "the code signature of $app is not valid, so the quarantine mark was left in place. Download Wilco again."
  remove_quarantine "$app" || die "could not remove the quarantine mark from $app (is it on a read-only disk?)."
  v="$(app_version "$app")"
  say "Done: macOS will now open Wilco $v at $app."
  say "Open it with: open \"$app\""
}

print_data_locations() {
  cat <<'EOF'

Your Wilco data was kept. To remove it as well, run these yourself:
  rm -rf ~/"Library/Application Support/Wilco"               # app settings, sign-in and logs
  security delete-generic-password -s "Wilco Safe Storage"   # the key that encrypts the saved sign-in
  rm -rf ~/.wilco                                            # sessions, settings, skills and extensions
The ~/.wilco folder is shared with the wilco command line tool: removing it also removes the tool's
sessions and sign-in. macOS may also keep ~/Library/Preferences/run.wilco.app.plist,
~/Library/Caches/run.wilco.app and ~/Library/Saved Application State/run.wilco.app.savedState.
EOF
}

cmd_uninstall() {
  local dest_arg="$1" candidates apps app removed=0
  check_platform
  check_not_root
  need_tools
  if [ -n "$dest_arg" ]; then
    [ -d "$dest_arg" ] || die "the folder $dest_arg does not exist."
    candidates="$(cd "$dest_arg" && pwd -P)/$APP_NAME"
  else
    apps="${WILCO_APP_APPLICATIONS_DIR:-/Applications}"
    candidates="${apps%/}/$APP_NAME
$HOME/Applications/$APP_NAME"
  fi
  # Check every candidate first, so nothing is removed when one of them cannot be.
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    if [ -e "$app" ] || [ -L "$app" ]; then
      [ ! -L "$app" ] || die "$app is a symbolic link, not the app; it was left alone."
      is_wilco_bundle "$app" || die "$app is not the Wilco app (bundle identifier $BUNDLE_ID); it was left alone."
      refuse_if_running "$app"
    fi
  done <<EOF
$candidates
EOF
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    if [ -d "$app" ]; then
      rm -rf "$app" || die "could not remove $app completely."
      say "Removed $app"
      removed=1
    fi
  done <<EOF
$candidates
EOF
  if [ "$removed" = "0" ]; then
    say "Wilco.app was not found in: $(printf '%s' "$candidates" | tr '\n' ' ')"
  fi
  print_data_locations
}

main() {
  # The system tools this script calls live in these folders; a trimmed PATH (a login shell without
  # /usr/sbin, for example) must not make an Apple silicon Mac look like an Intel one. Appended, so an
  # earlier entry still wins.
  PATH="${PATH:+$PATH:}/usr/bin:/bin:/usr/sbin:/sbin"
  export PATH
  local mode="install" version="" dest="" fix_path=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        usage
        exit 0
        ;;
      --version)
        [ "$#" -ge 2 ] || die "--version needs a release tag, for example --version v0.1.0-test.20260927.1"
        version="$2"
        shift 2
        ;;
      --version=*)
        version="${1#--version=}"
        shift
        ;;
      --dest)
        [ "$#" -ge 2 ] || die "--dest needs a folder."
        dest="$2"
        shift 2
        ;;
      --dest=*)
        dest="${1#--dest=}"
        shift
        ;;
      --fix)
        mode="fix"
        shift
        if [ "$#" -gt 0 ]; then
          case "$1" in
            -*) ;;
            *)
              fix_path="$1"
              shift
              ;;
          esac
        fi
        ;;
      --uninstall)
        mode="uninstall"
        shift
        ;;
      *)
        printf 'Error: unknown option: %s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
  [ -n "${HOME:-}" ] || die "HOME is not set."
  if [ -n "$version" ]; then
    # The whole value, not line by line (grep would accept a first line that is valid).
    case "$version" in
      [A-Za-z0-9]*) ;;
      *) die "not a release tag: $version" ;;
    esac
    case "$version" in
      *[!A-Za-z0-9._-]*) die "not a release tag: $version" ;;
    esac
  fi
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  case "$mode" in
    install) cmd_install "$version" "$dest" ;;
    fix)
      [ -z "$version" ] && [ -z "$dest" ] || die "--fix takes only the path of Wilco.app."
      cmd_fix "$fix_path"
      ;;
    uninstall)
      [ -z "$version" ] || die "--uninstall does not take --version."
      cmd_uninstall "$dest"
      ;;
  esac
}

# Everything above only defines functions, so a cut-off download (curl | bash) runs nothing.
main "$@"
