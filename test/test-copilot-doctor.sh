#!/usr/bin/env bash
# test-copilot-doctor.sh — regression test for copilot doctor and dispatch:
# verifies token detection, interactive login detection, quota-exceeded warning
# in pack_doctor, and early failure in pack_launch_headless when quota is exceeded.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$SELF_DIR/.."
PACK="$ROOT/packs/copilot/pack.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bin_dir="$tmp/bin"
fake_home="$tmp/home"
mkdir -p "$bin_dir" "$fake_home/.copilot"

# Mock copilot script
cat << 'EOF' > "$bin_dir/copilot"
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "GitHub Copilot CLI 1.0.88."
  exit 0
fi
if [ "${1:-}" = "-p" ]; then
  if [ -n "${MOCK_COPILOT_REC:-}" ]; then
    printf "%s" "$*" > "$MOCK_COPILOT_REC"
  fi
  exit 0
fi
exit 0
EOF
chmod +x "$bin_dir/copilot"

# 1. CLI not installed -> preamble reports NOT INSTALLED
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

# 2. No credentials -> reports 'no login found'
out="$(
  HOME="$fake_home" COPILOT_HOME="$fake_home/.copilot" PATH="$bin_dir:$PATH" bash <<EOS
set -euo pipefail
unset COPILOT_GITHUB_TOKEN GH_TOKEN GITHUB_TOKEN || true
source "$ROOT/bin/fleet-config.sh"
source "$PACK"
pack_doctor
EOS
)"
case "$out" in
  *"installed (1.0.88) — no login found (copilot login for interactive; COPILOT_GITHUB_TOKEN for headless)"*) ;;
  *) fail "expected 'no login found...', got: $out" ;;
esac
echo "PASS: no credentials -> reports 'no login found'"

# 3. Interactive login present (copilotTokens in config.json), no env token -> reports interactive login
cat << 'EOF' > "$fake_home/.copilot/config.json"
// User settings belong in settings.json.
// This file is managed automatically.
{
  "copilotTokens": {
    "https://github.com:example": "gho_test_token"
  },
  "loggedInUsers": [
    {
      "host": "https://github.com",
      "login": "example"
    }
  ]
}
EOF

out="$(
  HOME="$fake_home" COPILOT_HOME="$fake_home/.copilot" PATH="$bin_dir:$PATH" bash <<EOS
set -euo pipefail
unset COPILOT_GITHUB_TOKEN GH_TOKEN GITHUB_TOKEN || true
source "$ROOT/bin/fleet-config.sh"
source "$PACK"
pack_doctor
EOS
)"
case "$out" in
  *"installed (1.0.88) — interactive login (no env token — export COPILOT_GITHUB_TOKEN for headless dispatch)"*) ;;
  *) fail "expected 'interactive login...', got: $out" ;;
esac
echo "PASS: interactive login present -> reports 'interactive login (no env token...)'"

# 4. Token in env -> reports 'token in env (<var>)'
out="$(
  HOME="$fake_home" COPILOT_HOME="$fake_home/.copilot" PATH="$bin_dir:$PATH" \
  COPILOT_GITHUB_TOKEN="ghp_test1" bash <<EOS
set -euo pipefail
source "$ROOT/bin/fleet-config.sh"
source "$PACK"
pack_doctor
EOS
)"
case "$out" in
  *"installed (1.0.88) — token in env (COPILOT_GITHUB_TOKEN)"*) ;;
  *) fail "expected 'token in env (COPILOT_GITHUB_TOKEN)', got: $out" ;;
esac
echo "PASS: COPILOT_GITHUB_TOKEN set -> reports 'token in env (COPILOT_GITHUB_TOKEN)'"

out="$(
  HOME="$fake_home" COPILOT_HOME="$fake_home/.copilot" PATH="$bin_dir:$PATH" \
  GH_TOKEN="gho_test2" bash <<EOS
set -euo pipefail
unset COPILOT_GITHUB_TOKEN GITHUB_TOKEN || true
source "$ROOT/bin/fleet-config.sh"
source "$PACK"
pack_doctor
EOS
)"
case "$out" in
  *"installed (1.0.88) — token in env (GH_TOKEN)"*) ;;
  *) fail "expected 'token in env (GH_TOKEN)', got: $out" ;;
esac
echo "PASS: GH_TOKEN set -> reports 'token in env (GH_TOKEN)'"

# 5. Recent quota error in logs -> doctor reports quota exceeded
mkdir -p "$fake_home/.copilot/logs"
cat << 'EOF' > "$fake_home/.copilot/logs/process-1790000000000-111111.log"
2026-09-29T08:00:00.000Z [INFO] Starting Copilot CLI
2026-09-29T08:00:01.000Z [ERROR] Payment required error: 402 You have exceeded your monthly quota
EOF

out="$(
  HOME="$fake_home" COPILOT_HOME="$fake_home/.copilot" PATH="$bin_dir:$PATH" \
  COPILOT_GITHUB_TOKEN="ghp_test" bash <<EOS
set -euo pipefail
source "$ROOT/bin/fleet-config.sh"
source "$PACK"
pack_doctor
EOS
)"
case "$out" in
  *"quota exceeded (check GitHub billing; see ~/.copilot/logs)"*) ;;
  *) fail "expected 'quota exceeded', got: $out" ;;
esac
echo "PASS: recent quota error -> doctor reports 'quota exceeded'"

# 6. Headless dispatch fails early on recent quota error
rec_file="$tmp/rec"
set +e
err_out="$(
  HOME="$fake_home" COPILOT_HOME="$fake_home/.copilot" PATH="$bin_dir:$PATH" \
  MOCK_COPILOT_REC="$rec_file" bash <<EOS 2>&1
set -euo pipefail
source "$ROOT/bin/fleet-config.sh"
source "$PACK"
pack_launch_headless "some task"
EOS
)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "expected pack_launch_headless to fail on quota error, but exited 0"
case "$err_out" in
  *"error: copilot monthly quota exceeded"*) ;;
  *) fail "expected 'error: copilot monthly quota exceeded', got: $err_out" ;;
esac
[ ! -f "$rec_file" ] || fail "copilot CLI was invoked despite quota error"
echo "PASS: dispatch fails early on quota error and does not invoke copilot"

# 7. FLEET_COPILOT_IGNORE_QUOTA=1 bypasses early quota exit
rm -f "$rec_file"
HOME="$fake_home" COPILOT_HOME="$fake_home/.copilot" PATH="$bin_dir:$PATH" \
FLEET_COPILOT_IGNORE_QUOTA=1 MOCK_COPILOT_REC="$rec_file" bash <<EOS
set -euo pipefail
source "$ROOT/bin/fleet-config.sh"
source "$PACK"
pack_launch_headless "some task"
EOS
[ -f "$rec_file" ] || fail "expected copilot to be invoked when FLEET_COPILOT_IGNORE_QUOTA=1"
echo "PASS: FLEET_COPILOT_IGNORE_QUOTA=1 bypasses quota check and invokes copilot"

# 8. Dispatch succeeds normally when no quota error
rm -f "$fake_home/.copilot/logs"/* "$rec_file"
HOME="$fake_home" COPILOT_HOME="$fake_home/.copilot" PATH="$bin_dir:$PATH" \
MOCK_COPILOT_REC="$rec_file" bash <<EOS
set -euo pipefail
source "$ROOT/bin/fleet-config.sh"
source "$PACK"
pack_launch_headless "hello task"
EOS
[ -f "$rec_file" ] || fail "expected copilot to be invoked when no quota error"
rec_content="$(cat "$rec_file")"
case "$rec_content" in
  *"-p hello task --allow-all-tools"*) ;;
  *) fail "expected '-p hello task --allow-all-tools', got: $rec_content" ;;
esac
echo "PASS: dispatch succeeds with -p and --allow-all-tools when no quota error"

echo "test-copilot-doctor: all tests passed"
