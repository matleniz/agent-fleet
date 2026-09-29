#!/usr/bin/env bash
# test-antigravity-doctor.sh — regression test for MAT-124:
# fleet doctor must validate the Google OAuth session via `agy models`, not
# just check the existence of antigravity-oauth-token.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$SELF_DIR/.."
PACK="$ROOT/packs/antigravity/pack.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bin_dir="$tmp/bin"
fake_home="$tmp/home"
mkdir -p "$bin_dir" "$fake_home/.gemini/antigravity-cli"

# Mock agy script
cat << 'EOF' > "$bin_dir/agy"
#!/usr/bin/env bash
if [ "${1:-}" = "models" ]; then
  if [ -n "${MOCK_AGY_MODELS_SLEEP:-}" ]; then
    sleep "$MOCK_AGY_MODELS_SLEEP"
  fi
  if [ -n "${MOCK_AGY_MODELS_FAIL:-}" ]; then
    echo "Error: Please sign in to view available models." >&2
    exit 1
  fi
  echo "gemini-3.8-flash-high"
  exit 0
fi
exit 0
EOF
chmod +x "$bin_dir/agy"

# 1. No token file -> "no login found"
out="$(
  HOME="$fake_home" PATH="$bin_dir:$PATH" bash <<EOS
set -euo pipefail
source "$ROOT/bin/fleet-config.sh"
source "$PACK"
pack_doctor
EOS
)"
case "$out" in
  *"installed — no login found — "*) ;;
  *) fail "expected 'no login found', got: $out" ;;
esac
echo "PASS: no token file -> reports 'no login found'"

# 2. Token file present, but session expired (agy models fails) -> "session expired, run agy to log in"
touch "$fake_home/.gemini/antigravity-cli/antigravity-oauth-token"
out="$(
  HOME="$fake_home" PATH="$bin_dir:$PATH" MOCK_AGY_MODELS_FAIL=1 bash <<EOS
set -euo pipefail
source "$ROOT/bin/fleet-config.sh"
source "$PACK"
pack_doctor
EOS
)"
case "$out" in
  *"installed — session expired, run agy to log in — "*) ;;
  *) fail "expected 'session expired, run agy to log in', got: $out" ;;
esac
echo "PASS: expired session -> reports 'session expired, run agy to log in'"

# 3. Token file present, but check times out -> "auth check timed out (network?) — token present"
out="$(
  HOME="$fake_home" PATH="$bin_dir:$PATH" AGY_DOCTOR_TIMEOUT=1 MOCK_AGY_MODELS_SLEEP=2 bash <<EOS
set -euo pipefail
source "$ROOT/bin/fleet-config.sh"
source "$PACK"
pack_doctor
EOS
)"
case "$out" in
  *"installed — auth check timed out (network?) — token present — "*) ;;
  *) fail "expected 'auth check timed out (network?) — token present', got: $out" ;;
esac
echo "PASS: timeout -> reports 'auth check timed out (network?) — token present'"

# 4. Token file present and valid -> "logged in (Google OAuth)"
out="$(
  HOME="$fake_home" PATH="$bin_dir:$PATH" bash <<EOS
set -euo pipefail
source "$ROOT/bin/fleet-config.sh"
source "$PACK"
pack_doctor
EOS
)"
case "$out" in
  *"installed — logged in (Google OAuth) — "*) ;;
  *) fail "expected 'logged in (Google OAuth)', got: $out" ;;
esac
echo "PASS: valid session -> reports 'logged in (Google OAuth)'"

# 5. CLI not installed -> preamble reports NOT INSTALLED
out="$(
  HOME="$fake_home" PATH="/usr/bin:/bin" bash <<EOS || true
set -euo pipefail
source "$ROOT/bin/fleet-config.sh"
source "$PACK"
pack_doctor || true
EOS
)"
case "$out" in
  *"NOT INSTALLED"*) ;;
  *) fail "expected 'NOT INSTALLED', got: $out" ;;
esac
echo "PASS: CLI missing -> reports 'NOT INSTALLED'"

echo "test-antigravity-doctor: all tests passed"
