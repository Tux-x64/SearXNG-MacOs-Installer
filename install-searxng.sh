#!/usr/bin/env bash
#
# install-searxng.sh
#
# One installer for a private, self-hosted SearXNG instance on macOS.
# No Docker. No sudo. Everything lives under your own home directory.
#
# Tested lineage: this script merges two proven, manually-tested install
# paths (a "classic" Homebrew Python 3.11 path, and a macOS Tahoe path that
# works around a system libexpat bug) into a single script that DETECTS
# which path a given Mac needs, instead of guessing from the OS version
# number. That makes it forward-compatible with macOS releases that don't
# exist yet (e.g. the one after Tahoe) without needing an update.
#
# Usage:
#   chmod +x install-searxng.sh
#   ./install-searxng.sh install      # install / update, then start at login (default)
#   ./install-searxng.sh start        # start the background service
#   ./install-searxng.sh stop         # stop the background service
#   ./install-searxng.sh restart      # restart the background service
#   ./install-searxng.sh status       # check whether it's loaded & responding
#   ./install-searxng.sh logs         # tail the log file
#   ./install-searxng.sh uninstall    # remove SearXNG (and optionally Redis)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SEARXNG_HOME="${SEARXNG_HOME:-$HOME/searxng}"
SEARXNG_SOURCE="$SEARXNG_HOME/source"
SEARXNG_VENV="$SEARXNG_HOME/searxng-ve"
SEARXNG_CONFIG_DIR="$SEARXNG_HOME/config"
SEARXNG_SETTINGS="$SEARXNG_CONFIG_DIR/settings.yml"
SEARXNG_LOG="$SEARXNG_HOME/searxng.log"
INSTALL_LOG="$SEARXNG_HOME/install.log"

PLIST_LABEL="local.searxng.$(id -un)"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

PORT="${SEARXNG_PORT:-8888}"
BIND_ADDR="127.0.0.1"          # localhost only — never exposed to your LAN
PY_CANDIDATES=(3.12 3.13 3.11) # tried in this order; first one that works wins

mkdir -p "$SEARXNG_HOME"

# ---------------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
  C_RED=$'\033[0;31m'; C_BLUE=$'\033[0;34m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_BOLD=""
fi
log()  { printf "%s[+]%s %s\n" "$C_BLUE"  "$C_RESET" "$1" >&2; }
ok()   { printf "%s[✓]%s %s\n" "$C_GREEN" "$C_RESET" "$1" >&2; }
warn() { printf "%s[!]%s %s\n" "$C_YELLOW" "$C_RESET" "$1" >&2; }
err()  { printf "%s[✗]%s %s\n" "$C_RED"   "$C_RESET" "$1" >&2; }
die()  { err "$1"; exit 1; }

# ---------------------------------------------------------------------------
# Guard rails
# ---------------------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "This installer only supports macOS."
[ "$EUID" -ne 0 ] || die "Don't run this with sudo/root. Run it as your normal user account — everything installs privately under your own home directory."

ARCH="$(uname -m)"
OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
OS_NAME="$(sw_vers -productName 2>/dev/null || echo macOS)"

ACTION="${1:-install}"

if [ "$ACTION" = "install" ]; then
  exec > >(tee -a "$INSTALL_LOG") 2>&1
  log "Detected ${OS_NAME} ${OS_VERSION} (${ARCH})"
fi

# ---------------------------------------------------------------------------
# Homebrew / Redis
# ---------------------------------------------------------------------------
BREW_PREFIX=""

ensure_command_line_tools() {
  # On a fresh or older Mac, `brew install` may need to compile something
  # (no prebuilt bottle for that macOS version) and reach for Apple's Xcode
  # Command Line Tools. If those aren't installed, macOS pops up a GUI
  # installer dialog rather than a text prompt — which would silently stall
  # this script waiting on a click nobody's watching for. Check up front and
  # fail with clear instructions instead.
  if ! xcode-select -p >/dev/null 2>&1; then
    die "Xcode Command Line Tools aren't installed yet (Homebrew needs them to build things on some Macs). Run: xcode-select --install , let that finish, then re-run this script."
  fi
  ok "Xcode Command Line Tools found"
}

ensure_homebrew() {
  command -v brew >/dev/null 2>&1 \
    || die "Homebrew not found. Install it from https://brew.sh, then re-run this script."
  BREW_PREFIX="$(brew --prefix)"
  ok "Homebrew found at $BREW_PREFIX"
}

ensure_redis() {
  if ! brew list redis >/dev/null 2>&1; then
    log "Installing Redis..."
    brew install redis
  else
    ok "Redis already installed"
  fi

  if ! brew services list | awk '$1=="redis"{print $2}' | grep -q started; then
    log "Starting Redis (background service)..."
    brew services start redis
  else
    ok "Redis already running"
  fi
}

# ---------------------------------------------------------------------------
# Python selection — probe for the real problem instead of hardcoding by OS
# version. macOS Tahoe shipped with a system libexpat missing a symbol that
# breaks venv/ensurepip for Homebrew Python; a future release could bring the
# same bug back (or a different one). Rather than branch on the OS version,
# we just try to create a venv, and if it fails in a way that the Homebrew
# `expat` fix resolves, we apply that fix and remember to bake it into the
# LaunchAgent. This is what makes one script work from Monterey through
# Tahoe and whatever comes next.
# ---------------------------------------------------------------------------
PY_BIN=""
DYLD_FIX_NEEDED=0
DYLD_FIX_PATH=""

python_venv_works() {
  local py_bin="$1" test_dir status=0
  test_dir="$(mktemp -d)"
  if ! "$py_bin" -m venv "$test_dir/venv" >/dev/null 2>&1; then
    status=1
  elif ! "$test_dir/venv/bin/python" -c "import ensurepip" >/dev/null 2>&1; then
    status=1
  fi
  rm -rf "$test_dir"
  return $status
}

find_working_python() {
  local ver py_bin expat_lib
  for ver in "${PY_CANDIDATES[@]}"; do
    log "Trying Python $ver..."
    if ! brew list "python@$ver" >/dev/null 2>&1; then
      log "Downloading/installing python@$ver via Homebrew (first run — this can take a minute, progress below)..."
      brew install "python@$ver" || true
    fi
    py_bin="$BREW_PREFIX/opt/python@$ver/bin/python$ver"
    [ -x "$py_bin" ] || continue

    log "Checking python$ver for the known macOS venv issue (right after an OS update, the first launch of a new binary can be held up a minute or two by macOS's background security scan — that's expected, not a hang)..."
    if python_venv_works "$py_bin"; then
      ok "Python $ver works out of the box"
      # Report as: <python_bin>\t<fix_needed 0|1>\t<expat_lib_dir or empty>
      # NOTE: this function is invoked via $(...) command substitution, which
      # runs in a subshell — any `export` done in here would vanish the
      # moment the subshell exits. So the DYLD fix decision is relayed back
      # to the caller as plain text on stdout instead, and the caller is
      # responsible for actually exporting it in the real shell.
      printf '%s\t0\t\n' "$py_bin"
      return 0
    fi

    warn "Python $ver hit the known macOS libexpat/venv issue — applying the Homebrew expat workaround"
    brew install expat >/dev/null 2>&1 || true
    expat_lib="$BREW_PREFIX/opt/expat/lib"
    if [ -d "$expat_lib" ]; then
      # Scoped to this one test command only — never touches the outer shell.
      if DYLD_LIBRARY_PATH="$expat_lib:${DYLD_LIBRARY_PATH:-}" python_venv_works "$py_bin"; then
        ok "Python $ver works once the expat workaround is applied"
        printf '%s\t1\t%s\n' "$py_bin" "$expat_lib"
        return 0
      fi
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Source / venv / dependencies
# ---------------------------------------------------------------------------
clone_or_update_source() {
  if [ -d "$SEARXNG_SOURCE/.git" ]; then
    log "Updating existing SearXNG source..."
    git -C "$SEARXNG_SOURCE" pull --ff-only || warn "Couldn't fast-forward the source checkout — leaving it as-is."
  else
    log "Cloning SearXNG source..."
    git clone https://github.com/searxng/searxng.git "$SEARXNG_SOURCE"
  fi
}

setup_venv() {
  if [ ! -x "$SEARXNG_VENV/bin/python" ]; then
    log "Creating virtual environment..."
    "$PY_BIN" -m venv "$SEARXNG_VENV"
  else
    ok "Virtual environment already exists"
  fi

  log "Installing Python dependencies (this can take a minute)..."
  "$SEARXNG_VENV/bin/pip" install --upgrade pip >/dev/null
  # Note: never "pip install searxng" — that's an unrelated PyPI package.
  "$SEARXNG_VENV/bin/pip" install -r "$SEARXNG_SOURCE/requirements.txt"
}

# ---------------------------------------------------------------------------
# Configuration — locked to localhost, locked to your user
# ---------------------------------------------------------------------------
configure_settings() {
  mkdir -p "$SEARXNG_CONFIG_DIR"
  chmod 700 "$SEARXNG_HOME" "$SEARXNG_CONFIG_DIR"

  if [ ! -f "$SEARXNG_SETTINGS" ]; then
    cp "$SEARXNG_SOURCE/searx/settings.yml" "$SEARXNG_SETTINGS"
  fi

  "$SEARXNG_VENV/bin/python" - "$SEARXNG_SETTINGS" "$BIND_ADDR" "$PORT" <<'PYEOF'
import sys, secrets, yaml

path, bind_addr, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(path) as f:
    data = yaml.safe_load(f) or {}

server = data.setdefault("server", {})
# Only mint a new secret key the first time (or if it's still the template
# placeholder) so re-running this script doesn't invalidate existing sessions.
if not server.get("secret_key") or server.get("secret_key") == "ultrasecretkey":
    server["secret_key"] = secrets.token_hex(32)
server["bind_address"] = bind_addr
server["port"] = port
server["limiter"] = False  # local single-user instance, no need to rate-limit yourself

with open(path, "w") as f:
    yaml.safe_dump(data, f, sort_keys=False)
PYEOF

  chmod 600 "$SEARXNG_SETTINGS"
  ok "Configured $SEARXNG_SETTINGS — bound to $BIND_ADDR only, permissions locked to your account"
}

# ---------------------------------------------------------------------------
# LaunchAgent — built from $HOME / $(id -un), never hardcoded to one machine
# ---------------------------------------------------------------------------
write_launch_agent() {
  mkdir -p "$HOME/Library/LaunchAgents"

  local dyld_block=""
  if [ "$DYLD_FIX_NEEDED" -eq 1 ]; then
    dyld_block="        <key>DYLD_LIBRARY_PATH</key>
        <string>${DYLD_FIX_PATH}</string>
"
  fi

  cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SEARXNG_VENV}/bin/python</string>
        <string>-m</string>
        <string>searx.webapp</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${SEARXNG_HOME}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PYTHONPATH</key>
        <string>${SEARXNG_SOURCE}</string>
        <key>SEARXNG_SETTINGS_PATH</key>
        <string>${SEARXNG_SETTINGS}</string>
${dyld_block}    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${SEARXNG_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${SEARXNG_LOG}</string>
</dict>
</plist>
EOF
  chmod 600 "$PLIST_PATH"
  ok "LaunchAgent written to $PLIST_PATH"
}

# ---------------------------------------------------------------------------
# Service control
# ---------------------------------------------------------------------------
launch_start() {
  [ -f "$PLIST_PATH" ] || die "Not installed yet. Run: $0 install"
  launchctl load "$PLIST_PATH" 2>/dev/null || true
  ok "Start requested"
}

launch_stop() {
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  ok "Stop requested"
}

verify_running() {
  log "Waiting for SearXNG at http://127.0.0.1:${PORT} ..."
  local i
  for i in $(seq 1 15); do
    if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}" 2>/dev/null | grep -q "200"; then
      ok "SearXNG is up: http://127.0.0.1:${PORT}"
      return 0
    fi
    sleep 1
  done
  warn "No response yet after 15s. Check logs with: $0 logs"
  return 1
}

show_status() {
  if launchctl list 2>/dev/null | grep -q "$PLIST_LABEL"; then
    ok "LaunchAgent is loaded ($PLIST_LABEL)"
  else
    warn "LaunchAgent is not loaded"
  fi
  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}" 2>/dev/null || echo "000")"
  if [ "$code" = "200" ]; then
    ok "Responding at http://127.0.0.1:${PORT} (HTTP $code)"
  else
    warn "Not responding at http://127.0.0.1:${PORT} (HTTP $code)"
  fi
}

uninstall_all() {
  warn "This removes SearXNG and its LaunchAgent from this Mac."
  read -r -p "Also stop and remove Redis via Homebrew? [y/N] " remove_redis
  launch_stop
  rm -f "$PLIST_PATH"
  rm -rf "$SEARXNG_HOME"
  if [[ "${remove_redis:-}" =~ ^[Yy]$ ]]; then
    brew services stop redis || true
    brew uninstall redis || true
  fi
  ok "SearXNG removed."
}

print_help() {
  cat <<EOF
Usage: $0 [command]

Commands:
  install     Install (or update) SearXNG and start it at login  [default]
  start       Start the background service
  stop        Stop the background service
  restart     Restart the background service
  status      Check whether it's loaded and responding
  logs        Tail the log file
  uninstall   Remove SearXNG, its LaunchAgent, and (optionally) Redis

Everything lives under: $SEARXNG_HOME
Bound to: http://127.0.0.1:${PORT}  (localhost only — never on your network)
EOF
}

# ---------------------------------------------------------------------------
# Install flow
# ---------------------------------------------------------------------------
run_install() {
  ensure_command_line_tools
  ensure_homebrew
  ensure_redis

  log "Looking for a Python setup that works cleanly on this Mac..."
  local py_result
  py_result="$(find_working_python)" || die "Couldn't get a working Python venv going after trying: ${PY_CANDIDATES[*]}. See $INSTALL_LOG for details."
  IFS=$'\t' read -r PY_BIN DYLD_FIX_NEEDED DYLD_FIX_PATH <<< "$py_result"
  ok "Using $PY_BIN"

  if [ "$DYLD_FIX_NEEDED" -eq 1 ]; then
    # This is the actual fix taking effect — exported here, in the real
    # shell, so every command below (pip install, the venv itself, etc.)
    # inherits it. It also gets baked into the LaunchAgent further down.
    export DYLD_LIBRARY_PATH="$DYLD_FIX_PATH:${DYLD_LIBRARY_PATH:-}"
    log "Exported DYLD_LIBRARY_PATH=$DYLD_FIX_PATH for the rest of this install"
  fi

  clone_or_update_source
  setup_venv
  configure_settings
  write_launch_agent

  launch_stop
  launchctl load "$PLIST_PATH"
  verify_running || true

  echo >&2
  ok "${C_BOLD}Done.${C_RESET} SearXNG is running privately at http://127.0.0.1:${PORT}"
  echo "   Starts automatically at login, restarts if it crashes, and is only reachable from this Mac." >&2
  echo "   Manage it with: $0 {start|stop|restart|status|logs|uninstall}" >&2
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$ACTION" in
  install)        run_install ;;
  start)          launch_start; verify_running || true ;;
  stop)           launch_stop ;;
  restart)        launch_stop; launchctl load "$PLIST_PATH"; verify_running || true ;;
  status)         show_status ;;
  logs)           exec tail -f "$SEARXNG_LOG" ;;
  uninstall)      uninstall_all ;;
  -h|--help|help) print_help ;;
  *)              err "Unknown command: $ACTION"; print_help; exit 1 ;;
esac
