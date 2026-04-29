#!/usr/bin/env bash
# test-network.sh — Verify PHI-safe network egress restrictions
#
# Tests that:
#   1. api.anthropic.com:443 is reachable (required for Claude Code)
#   2. Common sites that should be blocked ARE blocked
#   3. DNS resolution works
#
# Run as the 'developer' user to test iptables UID-based rules:
#   sudo -u developer bash test-network.sh
#
# Run as root to test without UID restrictions (baseline check):
#   sudo bash test-network.sh

set -uo pipefail

# ── helpers ─────────────────────────────────────────────────
PASS=0
FAIL=0
WARN=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $*"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; ((FAIL++)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; ((WARN++)); }
info() { echo "       $*"; }

# Try a TCP connection to host:port with a short timeout.
# Returns 0 if connection succeeds, 1 if refused/timed-out.
tcp_reachable() {
  local host="$1" port="$2" timeout="${3:-5}"
  timeout "$timeout" bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null
}

# Try an HTTPS GET with curl (no follow, just check HTTP response).
https_reachable() {
  local url="$1" timeout="${2:-8}"
  curl -sk --max-time "$timeout" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null
}

# ── preamble ────────────────────────────────────────────────
echo ""
echo "====================================================="
echo "  medimg-env Network Egress Verification"
echo "  Running as: $(id)"
echo "  Date: $(date)"
echo "====================================================="
echo ""

RUNNING_AS_DEVELOPER=0
if [[ "$(id -un)" == "developer" ]]; then
  RUNNING_AS_DEVELOPER=1
fi

if [[ $RUNNING_AS_DEVELOPER -eq 0 ]]; then
  warn "Not running as 'developer' — iptables UID rules will NOT be tested."
  info "To test UID-based egress restrictions, run:"
  info "  sudo -u developer bash test-network.sh"
  echo ""
fi

# ── Section 1: DNS resolution ───────────────────────────────
echo "--- DNS Resolution ---"

if dig +short api.anthropic.com | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  ANTHROPIC_IPS=$(dig +short api.anthropic.com | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
  pass "DNS: api.anthropic.com resolves to: $ANTHROPIC_IPS"
else
  fail "DNS: api.anthropic.com did not resolve to any IPv4 address"
  warn "Cannot test Anthropic connectivity without DNS. Check /etc/resolv.conf"
  ANTHROPIC_IPS=""
fi

# Check a blocked domain resolves (DNS should still work for developer uid)
if dig +short google.com | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  pass "DNS: google.com resolves (DNS itself is not blocked — correct)"
else
  warn "DNS: google.com did not resolve — DNS may be overly restricted"
fi

echo ""

# ── Section 2: Anthropic reachability ───────────────────────
echo "--- Anthropic API Reachability (MUST PASS) ---"

# TCP connect test on port 443
if tcp_reachable api.anthropic.com 443 8; then
  pass "TCP: api.anthropic.com:443 — connection established"
else
  fail "TCP: api.anthropic.com:443 — connection FAILED (Claude Code will not work)"
fi

# HTTPS GET test — Anthropic's API returns 4xx for unauthenticated requests,
# but a response means the connection itself is working.
HTTP_CODE=$(https_reachable "https://api.anthropic.com/" 10)
case "$HTTP_CODE" in
  2*|4*)
    pass "HTTPS: api.anthropic.com returned HTTP $HTTP_CODE (connection works)"
    ;;
  000)
    fail "HTTPS: api.anthropic.com — no response (curl returned 000 / timeout)"
    ;;
  *)
    warn "HTTPS: api.anthropic.com returned HTTP $HTTP_CODE (unexpected but connection reached server)"
    ;;
esac

echo ""

# ── Section 3: Blocked sites (MUST FAIL if iptables active) ─
echo "--- Outbound Block Verification (MUST BE BLOCKED if iptables rules are active) ---"

BLOCKED_SITES=(
  "google.com:443"
  "github.com:443"
  "pypi.org:443"
  "registry.npmjs.org:443"
  "8.8.8.8:443"
  "hub.docker.com:443"
)

for entry in "${BLOCKED_SITES[@]}"; do
  host="${entry%%:*}"
  port="${entry##*:}"
  if tcp_reachable "$host" "$port" 5; then
    if [[ $RUNNING_AS_DEVELOPER -eq 1 ]]; then
      fail "TCP: $host:$port — REACHABLE (should be blocked for developer uid)"
    else
      warn "TCP: $host:$port — reachable (expected; iptables rules only apply to developer uid)"
    fi
  else
    if [[ $RUNNING_AS_DEVELOPER -eq 1 ]]; then
      pass "TCP: $host:$port — BLOCKED (correct)"
    else
      warn "TCP: $host:$port — not reachable (may be firewall, network policy, or iptables rule applied to all users)"
    fi
  fi
done

echo ""

# ── Section 4: Exfiltration tool availability ───────────────
echo "--- Exfiltration Tool Check (settings.json deny-list) ---"
# These are blocked at the Claude Code settings.json level, not iptables.
# This section only checks whether the binaries exist on the system.
# Claude Code will refuse to run them even if they exist.

for tool in curl wget scp rsync nc ncat netcat; do
  if command -v "$tool" &>/dev/null; then
    warn "Binary '$tool' exists at $(command -v $tool) — blocked by settings.json deny-list, not by removal"
  else
    pass "Binary '$tool' is not installed"
  fi
done

echo ""

# ── Section 5: settings.json immutability ───────────────────
echo "--- settings.json Immutability Check ---"

SETTINGS_FILE=/home/developer/.claude/settings.json

if [[ -f "$SETTINGS_FILE" ]]; then
  PERMS=$(stat -c '%a' "$SETTINGS_FILE")
  OWNER=$(stat -c '%U:%G' "$SETTINGS_FILE")

  if [[ "$PERMS" == "444" ]]; then
    pass "Permissions: settings.json is 444 (read-only for all)"
  else
    fail "Permissions: settings.json has permissions $PERMS (expected 444)"
  fi

  if [[ "$OWNER" == "root:developer" ]]; then
    pass "Ownership: settings.json owned by root:developer (correct)"
  else
    fail "Ownership: settings.json owned by $OWNER (expected root:developer)"
  fi

  # Try to write to it — should fail
  if [[ "$(id -un)" == "developer" ]]; then
    if touch "$SETTINGS_FILE" 2>/dev/null; then
      fail "Write test: developer user CAN modify settings.json (should be impossible)"
    else
      pass "Write test: developer user cannot modify settings.json (correct)"
    fi
  else
    info "Skipping write test (not running as developer)"
  fi
else
  fail "settings.json not found at $SETTINGS_FILE"
fi

echo ""

# ── Section 6: Audit log ─────────────────────────────────────
echo "--- Audit Log Check ---"

AUDIT_LOG=/var/log/claude-audit.log

if [[ -f "$AUDIT_LOG" ]]; then
  PERMS=$(stat -c '%a' "$AUDIT_LOG")
  OWNER=$(stat -c '%U:%G' "$AUDIT_LOG")
  pass "Audit log exists: $AUDIT_LOG"
  info "Permissions: $PERMS  Owner: $OWNER"

  # Test that developer can append to it
  if [[ "$(id -un)" == "developer" ]]; then
    if echo "$(date) test-network.sh audit test" >> "$AUDIT_LOG" 2>/dev/null; then
      pass "Audit log: developer can append (correct)"
    else
      fail "Audit log: developer cannot append — check permissions (need group write)"
    fi
  fi
else
  fail "Audit log not found at $AUDIT_LOG"
fi

echo ""

# ── Summary ──────────────────────────────────────────────────
echo "====================================================="
echo "  Results: ${PASS} passed  |  ${FAIL} failed  |  ${WARN} warnings"
echo "====================================================="
echo ""

if [[ $FAIL -gt 0 ]]; then
  if [[ $RUNNING_AS_DEVELOPER -eq 0 ]]; then
    echo "Re-run as developer to test UID-based iptables restrictions:"
    echo "  sudo -u developer bash $(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo test-network.sh)"
    echo ""
  fi
  exit 1
else
  echo "All checks passed."
  if [[ $RUNNING_AS_DEVELOPER -eq 0 ]]; then
    echo ""
    echo "Re-run as developer to fully verify UID-based iptables restrictions:"
    echo "  sudo -u developer bash $(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo test-network.sh)"
  fi
  exit 0
fi
