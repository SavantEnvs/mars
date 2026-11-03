#!/usr/bin/env bash
#
# mayhem/build.sh — build mars' fuzz targets with sanitizers + DWARF 3, plus the unsanitized test
# binaries mayhem/test.sh runs. Runs in /mayhem as `mayhem`. Idempotent and network-free: mars vendors
# zstd and a linux-x64 libcrypto.a, so nothing is fetched.
#
# Targets: the 11 zstd harnesses that ship in mars/zstd/tests/fuzz (vendored zstd 1.4.4), plus
# http_parser (mars/comm/http.cc, the HTTP request/response parser).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS SRC

cd "$SRC"

Z="$SRC/mars/zstd"
B="$SRC/build/mayhem"           # `build/` is gitignored upstream, so a `git clean -ffdX` removes it
rm -rf "$B"; mkdir -p "$B"

ZSTD_TARGETS="block_decompress block_round_trip dictionary_decompress dictionary_loader dictionary_round_trip
simple_compress simple_decompress simple_round_trip stream_decompress stream_round_trip zstd_frame_info"
ALL_TARGETS="$ZSTD_TARGETS http_parser"

# pointer-overflow is the one UBSan check upstream's own OSS-Fuzz build disables for zstd (known benign
# pointer arithmetic in the library); ASan and every other UBSan check stay on and halting.
SAN="$SANITIZER_FLAGS -fno-sanitize=pointer-overflow"

ZINC="-I$Z/lib -I$Z/lib/common -I$Z/lib/compress -I$Z/lib/decompress -I$Z/lib/dictBuilder -I$Z/lib/deprecated -I$Z/lib/legacy -I$Z/programs -I$Z/tests/fuzz"
ZDEF="-DZSTD_MULTITHREAD -DZSTD_LEGACY_SUPPORT=1 -DDEBUGLEVEL=1 -DMEM_FORCE_MEMORY_ACCESS=0 -DFUZZ_RNG_SEED_SIZE=4 -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION"
ZLIB_SRC="$(ls "$Z"/lib/common/*.c "$Z"/lib/compress/*.c "$Z"/lib/decompress/*.c "$Z"/lib/dictBuilder/*.c \
              "$Z"/lib/deprecated/*.c "$Z"/lib/legacy/*.c)"
ZFUZZ_SRC="$Z/programs/util.c $Z/tests/fuzz/zstd_helpers.c $Z/tests/fuzz/fuzz_data_producer.c"

# -include stdint.h: comm/http.h uses uint64_t without including <stdint.h>.
# mayhem/include supplies the Linux openssl/opensslconf.h that mars/openssl/include lacks.
MINC="-include stdint.h -I$SRC/mayhem/include -I$SRC -I$SRC/mars -I$SRC/mars/comm -I$SRC/mars/openssl/include"
HTTP_SRC="$SRC/mars/comm/http.cc $SRC/mars/comm/autobuffer.cc $SRC/mars/comm/strutil.cc $SRC/mars/comm/xlogger/xlogger.cc $SRC/mars/comm/unix/xlogger_threadinfo.cc"
HTTP_CSRC="$SRC/mars/comm/xlogger/xloggerbase.c $SRC/mars/comm/assert/__assert.c"
# the prebuilt libcrypto.a is non-PIC, so the programs that link it are linked -no-pie
CRYPTO="-no-pie $SRC/mars/openssl/openssl_lib_linux_x64/libcrypto.a -ldl -lpthread"

# compile_objs <dir> <compiler> <flags> <sources...>: one object per source, in parallel, named by path hash.
compile_objs() {
  local dir="$1" cc="$2" flags="$3"; shift 3
  mkdir -p "$dir"
  local f
  for f in "$@"; do
    local o="$dir/$(printf '%s' "$f" | sha1sum | cut -c1-12)-$(basename "$f").o"
    echo "$cc $flags -c $f -o $o"
  done | xargs -P "$MAYHEM_JOBS" -I{} sh -c '{}'
}

# build_all <outdir> <instrument flag> <engine>: every fuzz binary against the same objects.
build_all() {
  local out="$1" cov="$2" engine="$3"
  local d="$B/obj-$(basename "$out")"
  $CC $SAN $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o "$d.standalone_main.o"
  $CXX $SAN $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$d.lsan_off.o"
  local eng="$engine"; [ "$engine" = standalone ] && eng="$d.standalone_main.o"

  compile_objs "$d/zlib" "$CC" "-O1 $SAN $DEBUG_FLAGS $cov $ZINC $ZDEF" $ZLIB_SRC $ZFUZZ_SRC
  local t
  for t in $ZSTD_TARGETS; do
    $CC -O1 $SAN $DEBUG_FLAGS $cov $ZINC $ZDEF "$Z/tests/fuzz/$t.c" "$d"/zlib/*.o "$d.lsan_off.o" \
        $eng $SAN -lpthread -o "$out/$t"
  done

  compile_objs "$d/http" "$CXX" "-O1 $SAN $DEBUG_FLAGS $cov $MINC" $HTTP_SRC
  compile_objs "$d/http" "$CC" "-O1 $SAN $DEBUG_FLAGS $cov $MINC" $HTTP_CSRC
  $CXX -O1 $SAN $DEBUG_FLAGS $cov $MINC "$SRC/mayhem/harnesses/http_parser.cc" "$d"/http/*.o "$d.lsan_off.o" \
       $eng $SAN $CRYPTO -o "$out/http_parser"
}

# 1) standalone reproducers: no libFuzzer runtime, so no coverage instrumentation in the objects.
mkdir -p "$B/standalone"
build_all "$B/standalone" "" standalone
for t in $ALL_TARGETS; do cp -f "$B/standalone/$t" "$SRC/$t-standalone"; done

# 2) libFuzzer binaries: instrument the library too (fuzzer-no-link) so Mayhem sees its coverage.
mkdir -p "$B/fuzzer"
build_all "$B/fuzzer" "-fsanitize=fuzzer-no-link" "$LIB_FUZZING_ENGINE"
for t in $ALL_TARGETS; do cp -f "$B/fuzzer/$t" "$SRC/$t"; done

# 3) test suite with the project's NORMAL flags (no sanitizers, no -gdwarf-3, optimized).
T="$B/test"; mkdir -p "$T"
UNIT_CC="-O2 $COVERAGE_FLAGS $ZINC -DZSTD_MULTITHREAD -DZSTD_LEGACY_SUPPORT=1"
compile_objs "$T/zlib" "$CC" "$UNIT_CC" $ZLIB_SRC "$Z/programs/util.c" "$Z/programs/datagen.c" "$Z/programs/timefn.c"
$CC $UNIT_CC "$Z/tests/fuzzer.c" "$T"/zlib/*.o -lpthread -o "$T/zstd_unit"
compile_objs "$T/http" "$CXX" "-O2 $COVERAGE_FLAGS $MINC" $HTTP_SRC
compile_objs "$T/http" "$CC" "-O2 $COVERAGE_FLAGS $MINC" $HTTP_CSRC
$CXX -O2 $COVERAGE_FLAGS $MINC "$SRC/mayhem/tests/http_test.cc" "$T"/http/*.o $CRYPTO -o "$T/http_test"
