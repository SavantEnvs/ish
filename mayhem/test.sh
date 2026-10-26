#!/usr/bin/env bash
#
# mayhem/test.sh — known-answer checks of iSH, run against binaries built by mayhem/build.sh:
#   * hand-assembled x86 snippets through the emulator (registers, flags, memory, string ops,
#     x87, SSE, traps) via /mayhem/emu_oracle,
#   * i386 guest programs through the whole kernel via /mayhem/ish (stdout + exit status),
#   * upstream's own float80 suite.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

passed=0; failed=0

pass() { passed=$((passed + 1)); }
fail() { failed=$((failed + 1)); echo "FAIL: $1" >&2; }

for bin in emu_oracle ish float80_test; do
  [ -x "/mayhem/$bin" ] || { echo "missing /mayhem/$bin — mayhem/build.sh did not produce it" >&2; emit_ctrf "ish-known-answer" 0 1; exit 1; }
done

# emu <name> <hex code> <expected substring>...  — every substring must appear in the oracle output
emu() {
  local name="$1" code="$2" out; shift 2
  out="$(/mayhem/emu_oracle "$code" 2>&1)"
  for want in "$@"; do
    case "$out" in
      *"$want"*) ;;
      *) fail "$name: wanted '$want' in: $out"; return ;;
    esac
  done
  pass
}

emu add        "b80500000083c003cc"           "eax=00000008" "int=3" "eip=08048009"
emu sub-flags  "b80100000083e802cc"           "eax=ffffffff" "cf=1" "zf=0" "sf=1"
emu mul        "b800000100b900000100f7e1cc"   "eax=00000000" "edx=00000001" "cf=1" "of=1"
emu div        "b86400000031d2b907000000f7f1cc" "eax=0000000e" "edx=00000002"
emu loop-sum   "b90a00000031c001c84975fbcc"   "eax=00000037" "ecx=00000000"
emu push-pop   "68341200005bcc"           "ebx=00001234" "esp=10008000"
emu mem-rw     "c70500000010efbeaddea100000010cc" "eax=deadbeef"
emu rep-stosb  "bf00000010b904000000b041f3aa8b1d00000010cc" "ebx=41414141" "ecx=00000000" "edi=10000004"
emu x87-add    "d9e8d9e8dec1db1d00000010a100000010cc" "eax=00000002"
emu sse-paddd  "c7050000001007000000660f6e0500000010660ffec0660f7ec0cc" "eax=0000000e"
emu bswap      "b8443322110fc8cc"         "eax=44332211"
emu sar        "b800000080c1f81fcc"         "eax=ffffffff"
emu syscall    "b801000000cd80cc"               "syscalls=1" "eax=ffffffda"
emu undefined  "0f0b"                         "int=6" "eip=08048000"

guest() {
  local name="$1" want_out="$2" want_rc="$3" root out rc
  root="$(mktemp -d)"
  cp "/mayhem/guests/$name" "$root/$name"
  out="$(/mayhem/ish -r "$root" "/$name" 2>&1)"; rc=$?
  rm -rf "$root"
  if [ "$rc" -ne "$want_rc" ]; then fail "guest $name: exit $rc, wanted $want_rc"; return; fi
  case "$out" in
    *"$want_out"*) pass ;;
    *) fail "guest $name: wanted '$want_out' in: $out" ;;
  esac
}

guest hello    "hello from ish" 7
guest forkwait ""               3
guest procfs   "1 (procfs) R 0 1 1" 0

f80="$(/mayhem/float80_test 2>&1)"; rc=$?
total_line="$(printf '%s\n' "$f80" | grep -E '^[0-9]+/[0-9]+ passed' | tail -1)"
if [ "$rc" -eq 0 ] && [ -n "$total_line" ]; then
  f80_passed="${total_line%%/*}"; f80_total="${total_line#*/}"; f80_total="${f80_total%% *}"
  passed=$((passed + f80_passed)); failed=$((failed + f80_total - f80_passed))
else
  fail "float80_test: rc=$rc, no summary line"
fi

emit_ctrf "ish-known-answer" "$passed" "$failed"
