#!/usr/bin/env bash
# bootstrap_alt_tab.sh
# One-shot bootstrap for alt-tab-macos:
#   1. clone the repo (skip if already present; pulls latest by default)
#   2. generate & trust the "Local Self-Signed" certificate the Debug xcconfig needs
#   2.5 ensure config/local.xcconfig has CURRENT_PROJECT_VERSION + APPCENTER_SECRET
#       (Info.plist references both; missing values crash the app at launch)
#   3. xcodebuild the Debug scheme into <repo>/DerivedData
#   3.5 if a previous AltTab install is detected, prompt the user (y/N)
#       to wipe the old .app and its TCC permissions so the new locally-
#       signed build starts clean. Non-interactive runs default to KEEP
#       unless --force-reset is passed.
#   4. install the resulting AltTab.app into /Applications (fallback: ~/Applications)
#   4.5 write the same keychain + UserDefaults entries the in-app Debug "Pro" QA
#       button creates, so the locally-built Debug binary boots straight into
#       Pro state without ever showing the activation window. Only meaningful
#       for Debug builds — `mockProUser()` is #if DEBUG.
#
# Usage:
#   ./bootstrap_alt_tab.sh
#   ./bootstrap_alt_tab.sh --repo-dir ~/code/alt-tab-macos
#   ./bootstrap_alt_tab.sh --no-update               # reuse current HEAD, skip git pull
#   ./bootstrap_alt_tab.sh --skip-codesign           # reuse existing identity
#   ./bootstrap_alt_tab.sh --dest ~/Applications     # custom install dir
#   ./bootstrap_alt_tab.sh --force-reset             # auto-wipe prior install (skip prompt)
#   ./bootstrap_alt_tab.sh --keep-permissions        # auto-keep prior install (skip prompt)
#
# Defaults:
#   REPO_URL  = https://github.com/lwouis/alt-tab-macos.git
#   REPO_DIR  = ${HOME}/AppCodeProjects/alt-tab-macos
#   DEST_DIR  = /Applications  (falls back to ~/Applications if not writable)
#
# Behavior on re-run:
#   - If REPO_DIR is already a git checkout, the script will fetch + fast-forward
#     pull the current branch by default, so a re-run always builds the latest
#     code. Pass --no-update to skip this and build whatever HEAD currently points
#     at. If the working tree has uncommitted changes, the pull is skipped with
#     a warning (your local changes are never touched).

set -euo pipefail

# ----- defaults -----
REPO_URL="https://github.com/lwouis/alt-tab-macos.git"
REPO_DIR="${HOME}/alt-tab-macos"
DEST_DIR="/Applications"
DO_UPDATE=1
SKIP_CODESIGN=0
# Tri-state for "what to do with a previous AltTab install we may find":
#   "ask"   = prompt the user on a TTY, default to keep when non-interactive
#   "force" = always wipe (set by --force-reset)
#   "keep"  = never wipe (set by --keep-permissions)
CLEANUP_DECISION="ask"
APP_NAME="AltTab"
BUNDLE_ID="com.lwouis.alt-tab-macos"
SCHEME="Debug"
CONFIG="Debug"
SIGNING_IDENTITY="Local Self-Signed"

log()  { printf "\033[1;34m[bootstrap]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[bootstrap]\033[0m %s\n" "$*" >&2; }
die()  { printf "\033[1;31m[bootstrap]\033[0m %s\n" "$*" >&2; exit 1; }

usage() {
  sed -n '2,38p' "$0"
  exit 0
}

# ----- arg parsing -----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url)      REPO_URL="$2"; shift 2 ;;
    --repo-dir)      REPO_DIR="$2"; shift 2 ;;
    --dest)          DEST_DIR="$2"; shift 2 ;;
    --no-update)     DO_UPDATE=0; shift ;;
    --update)        DO_UPDATE=1; shift ;;       # back-compat no-op; pull is now the default
    --skip-codesign) SKIP_CODESIGN=1; shift ;;
    --force-reset)      CLEANUP_DECISION="force"; shift ;;
    --keep-permissions) CLEANUP_DECISION="keep";  shift ;;
    -h|--help)       usage ;;
    *)               die "Unknown option: $1 (use --help)" ;;
  esac
done

# ----- pre-flight checks -----
# Show a multi-line, actionable hint instead of a one-liner error before exiting.
hint_exit() {
  printf "\n\033[1;31m[bootstrap]\033[0m %s\n" "$1" >&2
  shift
  for line in "$@"; do
    printf "  %s\n" "$line" >&2
  done
  printf "\n" >&2
  exit 1
}

# Prompt y/N on an interactive TTY. Returns 0 on yes, 1 otherwise. Always
# returns non-yes when stdin isn't a TTY (CI / piped invocation) to avoid
# silently hanging waiting for input.
confirm() {
  local prompt="$1"
  if [[ ! -t 0 ]]; then return 1; fi
  local reply
  printf "\033[1;36m[bootstrap]\033[0m %s [y/N] " "$prompt" >&2
  read -r reply || return 1
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

[[ "$(uname -s)" == "Darwin" ]] || hint_exit \
  "This script only runs on macOS." \
  "You're on $(uname -s) — AltTab itself is a macOS-only app."

# git: ships with Xcode Command Line Tools (CLT). Try to be helpful if missing.
if ! command -v git >/dev/null; then
  printf "\n\033[1;31m[bootstrap]\033[0m %s\n" "git not found." >&2
  printf "  It ships with the Xcode Command Line Tools. The standard install is:\n" >&2
  printf "      xcode-select --install\n" >&2
  printf "    (macOS pops up a GUI installer; download is ~500 MB and can take a while.)\n" >&2
  if confirm "Trigger 'xcode-select --install' now to open the installer dialog?"; then
    xcode-select --install || true
    hint_exit \
      "Installer dialog launched (or already in progress)." \
      "Wait for it to finish, then re-run this script."
  fi
  hint_exit \
    "Aborted — install the Command Line Tools and re-run this script."
fi

# xcodebuild: needs the FULL Xcode app, not just CLT. Most likely real blocker.
if ! command -v xcodebuild >/dev/null; then
  printf "\n\033[1;31m[bootstrap]\033[0m %s\n" \
    "xcodebuild not found — full Xcode is required (Command Line Tools alone aren't enough)." >&2
  printf "  Steps:\n" >&2
  printf "    1) Install Xcode from the Mac App Store (free; ~10 GB).\n" >&2
  printf "    2) Launch Xcode once to accept the license agreement.\n" >&2
  printf "    3) Point the toolchain at it:\n" >&2
  printf "         sudo xcode-select -s /Applications/Xcode.app/Contents/Developer\n" >&2
  printf "    4) Verify:  xcodebuild -version\n" >&2
  if confirm "Open the Xcode page in the App Store now?"; then
    open 'macappstore://apps.apple.com/app/xcode/id497799835' >/dev/null 2>&1 || true
    hint_exit \
      "App Store opened. Install Xcode, run it once to accept the license, then re-run this script."
  fi
  hint_exit \
    "Aborted — install Xcode and re-run this script."
fi

# Detect the common "Xcode is installed but xcode-select still points at CLT"
# trap. Symptom downstream: xcrun can't find tools, builds fail confusingly.
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV_DIR" == *"CommandLineTools"* ]]; then
  warn "xcode-select is pointing at the Command Line Tools, not Xcode:"
  warn "    $DEV_DIR"
  warn "  If the build later fails with 'xcrun: error: unable to find utility', run:"
  warn "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

# security / ditto / xattr ship with every macOS install. If any is missing,
# something is very wrong with PATH or the OS itself — point that out.
for tool in security ditto xattr; do
  if ! command -v "$tool" >/dev/null; then
    hint_exit \
      "'$tool' not found in PATH." \
      "This tool ships with macOS by default, so the most likely cause is a broken PATH." \
      "Current PATH: $PATH" \
      "Try running this script from a fresh Terminal window."
  fi
done

log "Repo URL : $REPO_URL"
log "Repo dir : $REPO_DIR"
log "Dest dir : $DEST_DIR"

# ----- step 1: clone or update -----
if [[ -d "$REPO_DIR/.git" ]]; then
  if [[ "$DO_UPDATE" -eq 0 ]]; then
    log "Existing clone detected; --no-update set, building current HEAD."
  else
    # Refuse to touch a dirty tree to avoid surprising the user. `git status
    # --porcelain` is empty exactly when the working tree + index are clean.
    DIRTY="$(git -C "$REPO_DIR" status --porcelain)"
    if [[ -n "$DIRTY" ]]; then
      warn "Working tree has uncommitted changes; skipping git pull. Building current HEAD."
      warn "  Files blocking the pull (top 5):"
      while IFS= read -r line; do warn "    $line"; done < <(printf "%s\n" "$DIRTY" | head -5)
      [[ "$(printf "%s\n" "$DIRTY" | wc -l)" -gt 5 ]] && warn "    … (more)"
      warn "  Commit/stash them and re-run, or pass --no-update to silence this."
    else
      branch="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
      log "Existing clone detected; updating branch '$branch' (fetch + ff-only pull)…"
      # fetch/pull failures should NOT abort the script — offline builds and
      # diverged branches are both legitimate workflows. Just warn + continue.
      if ! git -C "$REPO_DIR" fetch --prune 2>/tmp/bootstrap_git.err; then
        warn "git fetch failed; using current HEAD for the build."
        while IFS= read -r line; do warn "  $line"; done < /tmp/bootstrap_git.err
        warn "  Common causes: no network, proxy required, or auth needed for $REPO_URL."
      elif ! git -C "$REPO_DIR" pull --ff-only 2>/tmp/bootstrap_git.err; then
        warn "Fast-forward pull failed; using current HEAD for the build."
        while IFS= read -r line; do warn "  $line"; done < /tmp/bootstrap_git.err
        warn "  Inspect with:  git -C \"$REPO_DIR\" log --oneline --graph -5"
      fi
      rm -f /tmp/bootstrap_git.err
    fi
  fi
else
  log "Cloning $REPO_URL → $REPO_DIR"
  mkdir -p "$(dirname "$REPO_DIR")"
  if ! git clone "$REPO_URL" "$REPO_DIR"; then
    hint_exit \
      "git clone failed for $REPO_URL" \
      "Likely causes:" \
      "  • No network connection / firewall blocking github.com" \
      "  • Behind a corporate proxy — try:  git config --global http.proxy http://...:port" \
      "  • Auth required — try a mirror, e.g.:" \
      "      ./bootstrap_alt_tab.sh --repo-url git@github.com:lwouis/alt-tab-macos.git" \
      "Then re-run this script."
  fi
fi

cd "$REPO_DIR"

# ----- step 2: ensure "Local Self-Signed" identity exists -----
have_identity() {
  security find-identity -p codesigning -v 2>/dev/null \
    | grep -q "\"${SIGNING_IDENTITY}\""
}

if [[ "$SKIP_CODESIGN" -eq 1 ]]; then
  log "Skipping codesign setup (--skip-codesign)."
elif have_identity; then
  log "Codesign identity \"${SIGNING_IDENTITY}\" already trusted; skipping."
else
  log "Generating & trusting \"${SIGNING_IDENTITY}\" certificate…"
  if [[ ! -x scripts/codesign/setup_local.sh ]]; then
    die "scripts/codesign/setup_local.sh missing or not executable in $REPO_DIR"
  fi
  # Heads-up: macOS will pop up one or more Keychain dialogs during this step.
  # Make sure the user understands they're real, not phishing.
  warn "macOS will now prompt for your login Keychain password (1–2 dialogs) so it can:"
  warn "    • import the freshly generated self-signed certificate, and"
  warn "    • mark it as trusted for code signing."
  warn "  This is unavoidable — Apple's 'security' tool requires it. Just enter your Mac login password."
  # setup_local.sh writes codesign.{conf,crt,key,p12} to the CWD (repo root).
  # They are gitignored, but the private key (.key/.p12) shouldn't linger.
  scripts/codesign/setup_local.sh
  if ! have_identity; then
    die "Codesign identity still not visible after setup; check Keychain Access."
  fi
  log "Cleaning up local codesign.{conf,crt,key,p12} (cert is already in Keychain)."
  rm -f codesign.conf codesign.crt codesign.key codesign.p12
fi

# ----- step 2.5: ensure config/local.xcconfig has the build-time substitutions -----
# Info.plist references $(CURRENT_PROJECT_VERSION) and $(APPCENTER_SECRET).
# If either is empty, Xcode drops the key from Info.plist and the app crashes
# at launch in `Bundle.main.object(forInfoDictionaryKey:) as! String` (see
# App.swift / Secrets.swift). CI sets these via
# scripts/replace_environment_variables_in_app.sh; locally we generate a stub.
LOCAL_XCCONFIG="config/local.xcconfig"
ensure_kv() {
  local key="$1" default_value="$2"
  if [[ -f "$LOCAL_XCCONFIG" ]] && grep -qE "^\s*${key}\s*=" "$LOCAL_XCCONFIG"; then
    return 0
  fi
  log "Adding ${key} to $LOCAL_XCCONFIG (was missing; required for Info.plist substitution)."
  printf '%s = %s\n' "$key" "$default_value" >> "$LOCAL_XCCONFIG"
}
if [[ ! -f "$LOCAL_XCCONFIG" ]]; then
  log "Creating $LOCAL_XCCONFIG for local Debug build-time substitutions."
  cat > "$LOCAL_XCCONFIG" <<'EOF'
// Auto-generated by scripts/bootstrap_alt_tab.sh for local Debug builds.
// CI overwrites this file via scripts/replace_environment_variables_in_app.sh.
EOF
fi
ensure_kv "CURRENT_PROJECT_VERSION" "0.0.0-local"
ensure_kv "APPCENTER_SECRET"        "00000000-0000-0000-0000-000000000000"

# ----- step 3: build the Debug scheme -----
DERIVED_DATA="$REPO_DIR/DerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIG/${APP_NAME}.app"

log "Building scheme=$SCHEME configuration=$CONFIG → $DERIVED_DATA"

# xcbeautify is a vendored Mach-O binary at scripts/xcbeautify (universal arm64+x86_64).
# It ships with the repo (no separate install), so missing/non-executable here means
# the working copy is incomplete — not that the user needs to install Xcode.
XCBEAUTIFY_BIN=""
if [[ -e scripts/xcbeautify ]]; then
  if [[ ! -x scripts/xcbeautify ]]; then
    warn "scripts/xcbeautify is not executable; running 'chmod +x' to repair."
    chmod +x scripts/xcbeautify || true
  fi
  if [[ -x scripts/xcbeautify ]]; then
    XCBEAUTIFY_BIN="scripts/xcbeautify"
  else
    warn "scripts/xcbeautify exists but couldn't be made executable; falling back to raw xcodebuild output."
  fi
else
  warn "scripts/xcbeautify not found (the repo ships it at scripts/xcbeautify)."
  warn "  This is a log-prettifier, NOT a build dependency. The build will still work."
  warn "  To restore it: git -C \"$REPO_DIR\" checkout -- scripts/xcbeautify"
fi

if [[ -n "$XCBEAUTIFY_BIN" ]]; then
  set -o pipefail
  xcodebuild \
    -project alt-tab-macos.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED_DATA" \
    | "$XCBEAUTIFY_BIN"
else
  xcodebuild \
    -project alt-tab-macos.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED_DATA"
fi

[[ -d "$BUILT_APP" ]] || die "Build finished but $BUILT_APP not found."
log "Build OK: $BUILT_APP"

# ----- step 3.5: detect previous install, optionally wipe -----
# Why this exists:
#   • A previously-installed AltTab.app may have been signed with a different
#     identity (e.g. lwouis' Developer ID vs. our "Local Self-Signed"). macOS
#     keys TCC (Accessibility / Screen Recording / Input Monitoring) entries
#     not just by bundle id but also by code-signing identity, so the old
#     grants don't transfer — they sit in System Settings looking valid but
#     silently do nothing. Wiping them forces a clean re-grant after install.
#   • Running instances will hold AltTab.app open and break ditto/rm. We quit
#     them whether the user wipes or not (the new bundle has to overwrite the
#     old file either way).
#   • All cleanup steps are best-effort: never abort the whole script just
#     because, say, tccutil is unavailable on this macOS version.

# Print every previously-installed AltTab.app we can find. One path per line.
# Stays silent (and exits 1) if nothing is found.
find_previous_installs() {
  local found=()
  local p
  for p in \
    "/Applications/${APP_NAME}.app" \
    "${HOME}/Applications/${APP_NAME}.app"; do
    [[ -e "$p" ]] && found+=("$p")
  done
  if [[ "${#found[@]}" -eq 0 ]]; then return 1; fi
  printf "%s\n" "${found[@]}"
}

# Quit running AltTab so we can replace the bundle. Always safe to call.
quit_running_alttab() {
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    log "Quitting running ${APP_NAME} process(es)…"
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1
    pkill -9 -x "$APP_NAME" 2>/dev/null || true
  fi
}

# Remove the listed .app bundles, escalating to sudo only if needed.
remove_app_bundles() {
  local old
  for old in "$@"; do
    [[ -e "$old" ]] || continue
    log "Removing previous install: $old"
    if ! rm -rf "$old" 2>/dev/null; then
      warn "Need elevated privileges to remove $old (sudo)."
      sudo rm -rf "$old" || warn "Failed to remove $old; continuing anyway."
    fi
  done
}

# Reset every TCC service AltTab might have been granted. Per-service reset
# is more reliable than `tccutil reset All <bundle-id>` on older macOS.
reset_tcc_permissions() {
  if ! command -v tccutil >/dev/null 2>&1; then
    warn "tccutil not available; skipping TCC reset."
    return 0
  fi
  log "Resetting TCC permissions for ${BUNDLE_ID}…"
  local svc
  for svc in Accessibility ScreenCapture ListenEvent PostEvent \
             AppleEvents Microphone Camera SystemPolicyAllFiles; do
    tccutil reset "$svc" "$BUNDLE_ID" >/dev/null 2>&1 \
      && log "  reset $svc" \
      || true
  done
}

# Decide what to do about a previous install. Returns:
#   0 = wipe (caller should remove + reset TCC)
#   1 = keep (caller leaves old grants in place; ditto will still overwrite
#       the .app contents during install)
should_wipe_previous() {
  case "$CLEANUP_DECISION" in
    force) log "Previous AltTab install will be wiped (--force-reset).";        return 0 ;;
    keep)  log "Previous AltTab install will be kept (--keep-permissions).";    return 1 ;;
  esac
  # ask: prompt the user on a TTY; default to keep when non-interactive.
  if [[ ! -t 0 ]]; then
    warn "Previous AltTab install detected but stdin is not a TTY; keeping it."
    warn "  Pass --force-reset to wipe, or --keep-permissions to silence this."
    return 1
  fi
  if confirm "Remove the previous install AND reset its system permissions (Accessibility, Screen Recording, …)?"; then
    return 0
  fi
  log "Keeping previous install and its system permissions."
  return 1
}

handle_previous_install() {
  local prev=""
  prev="$(find_previous_installs)" || true
  if [[ -z "$prev" ]]; then
    return 0   # nothing to do
  fi

  log "Found previous AltTab install(s):"
  while IFS= read -r line; do log "  $line"; done <<< "$prev"

  # Always quit the running app — we can't ditto over a live bundle.
  quit_running_alttab

  if should_wipe_previous; then
    local paths=()
    while IFS= read -r line; do paths+=("$line"); done <<< "$prev"
    remove_app_bundles "${paths[@]}"
    reset_tcc_permissions
  fi
}

handle_previous_install

# ----- step 4: install into /Applications (or fallback) -----
install_app() {
  local target_dir="$1"
  local target_app="$target_dir/${APP_NAME}.app"
  mkdir -p "$target_dir" 2>/dev/null || return 1
  # writability probe
  [[ -w "$target_dir" ]] || return 1
  # Replace cleanly; ditto preserves resource forks / symlinks.
  rm -rf "$target_app"
  ditto "$BUILT_APP" "$target_app"
  # Remove Gatekeeper quarantine attr (best-effort).
  xattr -dr com.apple.quarantine "$target_app" 2>/dev/null || true
  echo "$target_app"
}

INSTALLED_APP=""
if INSTALLED_APP=$(install_app "$DEST_DIR"); then
  log "Installed: $INSTALLED_APP"
else
  warn "Cannot write to $DEST_DIR (permission denied?). Falling back to ~/Applications."
  FALLBACK="${HOME}/Applications"
  if INSTALLED_APP=$(install_app "$FALLBACK"); then
    log "Installed: $INSTALLED_APP"
  else
    die "Failed to install to $DEST_DIR and $FALLBACK."
  fi
fi

# ----- step 4.5 (optional): flip Debug build to mock-Pro state -----
# Background: AltTab's #if DEBUG QA menu has a "Pro" button that calls
# LicenseManager.mockProUser() — see src/pro/license/LicenseManager.swift.
# That function writes:
#   • Keychain (service = "<bundle-id>.license"):
#       account=licenseKey  → "MOCK-PRO-LICENSE-KEY"
#       account=instanceId  → "mock-instance-id"
#   • UserDefaults suite "<bundle-id>.license":
#       lastValidation        = <now epoch>
#       lastValidationResult  = true (BOOL)
#       customerEmail         = "john@cool-software.com"
#
# On next launch, LicenseManager.computeState() sees licenseKey present +
# lastValidationResult==true → state = .pro → no activation window.
#
# Notes:
#   • Only meaningful for Debug builds. Release strips the entire #if DEBUG
#     code path; the flags would still set state=.pro at startup, but there
#     is no QA menu / paywall flow to begin with on Release in this repo.
#   • Idempotent: re-running just refreshes the timestamp.
#   • To remove an already-applied mock-Pro state, see the cleanup commands
#     printed in the final notes (security delete-generic-password +
#     defaults delete).
mock_pro_license() {
  local svc="${BUNDLE_ID}.license"
  local suite="${BUNDLE_ID}.license"

  log "Applying mock-Pro state (matches the Debug QA menu's 'Pro' button)…"

  # Keychain entries. -U updates if the item already exists. -A would allow
  # any app to read it without prompting; we omit it on purpose so only
  # AltTab itself (running as the same user) can read these — same security
  # posture as the in-app code path.
  if ! security add-generic-password \
        -U \
        -s "$svc" \
        -a "licenseKey" \
        -w "MOCK-PRO-LICENSE-KEY" \
        2>/dev/null; then
    warn "Failed to write keychain item licenseKey for $svc."
    warn "  You may need to unlock the login keychain and retry, or run:"
    warn "    security unlock-keychain ~/Library/Keychains/login.keychain-db"
    return 1
  fi
  if ! security add-generic-password \
        -U \
        -s "$svc" \
        -a "instanceId" \
        -w "mock-instance-id" \
        2>/dev/null; then
    warn "Failed to write keychain item instanceId for $svc."
    return 1
  fi

  # UserDefaults entries (the suite is a separate plist under
  # ~/Library/Preferences/<suite>.plist).
  defaults write "$suite" lastValidation       -float "$(date +%s)"
  defaults write "$suite" lastValidationResult -bool  YES
  defaults write "$suite" customerEmail        -string "john@cool-software.com"

  log "  keychain[licenseKey]   = MOCK-PRO-LICENSE-KEY"
  log "  keychain[instanceId]   = mock-instance-id"
  log "  defaults[lastValidationResult] = YES"
  log "Mock-Pro applied. AltTab will boot straight into Pro state."
}

if [[ "$CONFIG" != "Debug" ]]; then
  warn "Auto-Pro is unconditional but build configuration is '$CONFIG' (not Debug)."
  warn "  mockProUser() is wrapped in #if DEBUG; flags will be set anyway,"
  warn "  but Release binaries don't show the activation flow this targets."
fi
mock_pro_license || warn "Auto-Pro setup hit an error; falling back to normal trial flow."

# ----- final notes -----
cat <<EOF

──────────────────────────────────────────────
  Done.

  Source     : $REPO_DIR
  Built .app : $BUILT_APP
  Installed  : $INSTALLED_APP

  First launch tips:
    • macOS will ask for Accessibility permission (and possibly Screen
      Recording / Input Monitoring). If you wiped the previous install
      above, you'll need to grant them again from scratch.
    • Open it once via: open "$INSTALLED_APP"
    • Or run headless to see logs:
        "$INSTALLED_APP/Contents/MacOS/${APP_NAME}" --logs=info

  Notes:
    • Debug build uses the local "Local Self-Signed" identity,
      so the binary is NOT notarized — Gatekeeper may still warn
      on the very first launch. That's expected for local builds.
    • Re-run this script anytime to fetch latest code and rebuild.
      Pass --no-update to skip the git pull and build current HEAD.
──────────────────────────────────────────────
EOF

if [[ "$CONFIG" == "Debug" ]]; then
  cat <<EOF
  Pro state was activated automatically. The activation window will not appear.
  To revert to the normal trial flow on this machine:
    security delete-generic-password -s "${BUNDLE_ID}.license" -a licenseKey
    security delete-generic-password -s "${BUNDLE_ID}.license" -a instanceId
    defaults delete "${BUNDLE_ID}.license"
EOF
fi
