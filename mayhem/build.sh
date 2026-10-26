#!/usr/bin/env bash
#
# mayhem/build.sh — builds iSH twice (sanitized for fuzzing, plain for the oracle) and
# every harness, plus the guest programs the oracle runs. Re-runnable and offline: the
# only inputs are the source tree and apt packages already installed in the image.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
FUZZ_DIR="$SRC/mayhem/.build-fuzz"
TEST_DIR="$SRC/mayhem/.build-test"
LIBS=(libish.a libish_emu.a libfakefs.a)
SYSLIBS=(-lsqlite3 -lpthread -lm -ldl -lrt)

# 1) The project itself, instrumented. Unaligned access is how the emulator touches guest
#    memory (upstream's meson.build disables the same check), and the syscall table is
#    called through casted function pointers, so the `function` check is relaxed as well.
RELAX="-fno-sanitize=alignment,function"
# libFuzzer needs coverage feedback from the project's own code, not just the harness.
COVER="-fsanitize=fuzzer-no-link"
if [ ! -f "$FUZZ_DIR/build.ninja" ]; then
  CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $RELAX $COVER" LDFLAGS="$SANITIZER_FLAGS" \
    meson setup "$FUZZ_DIR" -Dwarning_level=0 >/dev/null
fi
ninja -C "$FUZZ_DIR" -j"$MAYHEM_JOBS" "${LIBS[@]}"
FUZZ_LIBS=(-Wl,--start-group "${LIBS[@]/#/$FUZZ_DIR/}" -Wl,--end-group "${SYSLIBS[@]}")

# 2) Harnesses. lsan_off disables LeakSanitizer in every ASan binary.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_DIR/lsan_off.o"
HFLAGS=(-I"$SRC" -I"$FUZZ_DIR" -w)

$CC $SANITIZER_FLAGS $DEBUG_FLAGS $RELAX "${HFLAGS[@]}" $LIB_FUZZING_ENGINE \
    "$SRC/mayhem/fuzz_emu.c" "$FUZZ_DIR/lsan_off.o" "${FUZZ_LIBS[@]}" -o /mayhem/fuzz_emu
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $RELAX "${HFLAGS[@]}" "$STANDALONE_FUZZ_MAIN" \
    "$SRC/mayhem/fuzz_emu.c" "$FUZZ_DIR/lsan_off.o" "${FUZZ_LIBS[@]}" -o /mayhem/fuzz_emu-standalone
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $RELAX "${HFLAGS[@]}" \
    "$SRC/mayhem/fuzz_ish.c" "$FUZZ_DIR/lsan_off.o" "${FUZZ_LIBS[@]}" -o /mayhem/fuzz_ish

# 3) The oracle: the same sources with the project's normal flags, plus upstream's own
#    float80 known-answer suite and the guest programs the oracle executes.
if [ ! -f "$TEST_DIR/build.ninja" ]; then
  CFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" meson setup "$TEST_DIR" -Dwarning_level=0 >/dev/null
fi
ninja -C "$TEST_DIR" -j"$MAYHEM_JOBS" "${LIBS[@]}" ish float80_test
TEST_LIBS=(-Wl,--start-group "${LIBS[@]/#/$TEST_DIR/}" -Wl,--end-group "${SYSLIBS[@]}")
$CC -O1 $COVERAGE_FLAGS -w -I"$SRC" -I"$TEST_DIR" "$SRC/mayhem/emu_oracle.c" "${TEST_LIBS[@]}" -o /mayhem/emu_oracle
cp "$TEST_DIR/ish" /mayhem/ish
cp "$TEST_DIR/float80_test" /mayhem/float80_test

mkdir -p /mayhem/guests
for src in "$SRC"/mayhem/guests/*.S; do
  $CC -target i386-linux -fuse-ld=lld -nostdlib -static -o "/mayhem/guests/$(basename "$src" .S)" "$src"
done
