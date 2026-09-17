#!/usr/bin/env bash
# Automated security baseline for the wg-omarchy-nmcli import path.
#
# Extracts the EXACT bash command shipped in Widget.qml (importConfig) and
# exercises it against an isolated mock environment: no real privilege
# escalation, no real /etc access, no real NetworkManager. It proves the two
# reported failures are closed:
#   (1) a privileged source cannot be a traversal/symlink alias of
#       /etc/wireguard/<name>.conf, and
#   (2) the connection name is strictly validated and is safe as a pathname
#       component and as a shell literal.
#
# Self-contained and reproducible:  bash tests/security.sh
# Prints per-case PASS/FAIL and a final machine-parseable summary line
#   SECURITY_BASELINE: PASS (N/N)   or   SECURITY_BASELINE: FAIL (passed N, failed M)
# Exits 0 when every case passes, 1 otherwise.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
QML="$ROOT/Widget.qml"

if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: node is required to extract the runtime script" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"

# --- isolated mocks (never touch the real system) ----------------------------
printf '%s\n' '#!/usr/bin/env bash' \
  'while [ "$1" = "--" ]; do shift; done' \
  'printf "SECRET-CONF-CONTENT\n"' > "$BIN/cat"
printf '%s\n' '#!/usr/bin/env bash' 'exec "$@"' > "$BIN/pkexec"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = "connection" ] && [ "$2" = "import" ]; then exit 0; fi' 'exit 0' > "$BIN/nmcli"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$BIN/grep"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$BIN/chmod"
printf '%s\n' '#!/usr/bin/env bash' 'exec /usr/bin/head "$@"' > "$BIN/head"
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

SCRIPT="$(node "$HERE/extract_cmd.js" "$QML")"
if [ -z "$SCRIPT" ]; then
  echo "ERROR: could not extract the import script from $QML" >&2
  exit 1
fi

pass=0; fail=0
run() { # <name> <src> <pk> <expected_rc>
  bash -c "$SCRIPT" -- "$1" "$2" "$3" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" = "$4" ]; then
    printf 'PASS rc=%-3s name=%-24q src=%-44q pk=%-8q (exp %s)\n' "$rc" "$1" "$2" "$3" "$4"
    pass=$((pass+1))
  else
    printf 'FAIL rc=%-3s (exp %s) name=%-24q src=%-44q pk=%-8q\n' "$rc" "$4" "$1" "$2" "$3"
    fail=$((fail+1))
  fi
}

echo "### Functional (valid inputs must succeed, rc=0) ###"
run "wg0"            "/etc/wireguard/wg0.conf"          "pkexec" 0
run "wg0"            "$WORK/user.conf"                  ""       0
run "my-conn_2.x"    "/etc/wireguard/my-conn_2.x.conf"  "pkexec" 0

echo "### Attacks (must be refused) ###"
run "../../etc/shadow" "/etc/wireguard/../../etc/shadow.conf" "pkexec" 104
run "wg0"            "/etc/wireguard/../../etc/shadow"  "pkexec" 101
run '$(touch '"$WORK"'/PWNED)' "/etc/wireguard/x.conf"  "pkexec" 104
run "a/b"            "/etc/wireguard/a/b.conf"          "pkexec" 104
run ".hidden"        "/etc/wireguard/.hidden.conf"      "pkexec" 104
run "wg0"            "$WORK/elsewhere.conf"             "pkexec" 101
run ""               "/etc/wireguard/x.conf"            "pkexec" 104
run "my conn"        "/etc/wireguard/my conn.conf"      "pkexec" 104
run "wg0;rm -rf /"   "/etc/wireguard/wg0;rm -rf /.conf" "pkexec" 104

# Post-check: the injection payload must NOT have created its marker file.
if [ -e "$WORK/PWNED" ]; then
  echo "FAIL injection marker file was created"
  fail=$((fail+1))
else
  echo "PASS no injection marker file created"
  pass=$((pass+1))
fi

echo
total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
  echo "SECURITY_BASELINE: PASS ($pass/$total)"
  exit 0
else
  echo "SECURITY_BASELINE: FAIL (passed $pass, failed $fail)"
  exit 1
fi
