#!/usr/bin/env bash
#
# mayhem/build.sh — build every BoringSSL fuzz harness (the 34 in fuzz/*.cc plus the three OSS-Fuzz
# libprotobuf-mutator ones in mayhem/lpm/) and the project's own gtest suites.
# Runs in the commit image as `mayhem` in /mayhem. Offline-safe and re-runnable: the only external
# inputs are apt packages baked into the image (libprotobuf-dev, protobuf-compiler) and sources vendored
# under mayhem/third_party.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
OUT="$SRC/out"                 # /out/ and /build/ are gitignored upstream
FZ="$SRC/build/fuzz"
TB="$SRC/build/tests"
# CMake wipes and re-seeds its cache (dropping our flags) when the compiler path it recorded differs, as it
# does when the image was built through the ccache masquerade and build.sh is re-run without it, so always
# configure from scratch.
rm -rf "$FZ" "$TB"
mkdir -p "$OUT" "$FZ/obj" "$FZ/lpm" "$TB"

# ---- 1) sanitized BoringSSL libs, in fuzzer mode (as upstream's -DFUZZ / OSS-Fuzz build them) ----
# FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION makes the TLS stack deterministic and skips signature/MAC
# checks so the TLS harnesses get past the handshake. -fsanitize=fuzzer-no-link adds libFuzzer coverage.
FUZZ_DEFS="-DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION"
COMMON_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link $FUZZ_DEFS"
cmake -S "$SRC" -B "$FZ/lib" -GNinja \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$COMMON_FLAGS" -DCMAKE_CXX_FLAGS="$COMMON_FLAGS -Wno-error" \
      -DBORINGSSL_ALLOW_CXX_RUNTIME=1 -DBUILD_TESTING=OFF
cmake --build "$FZ/lib" -j"$MAYHEM_JOBS" --target ssl pki crypto
LIBS="$FZ/lib/libssl.a $FZ/lib/libpki.a $FZ/lib/libcrypto.a"

# ---- 2) libprotobuf-mutator + ASN.1 PDU converter (vendored) for the structure-aware harnesses ----
TP="$SRC/mayhem/third_party"
PROTO_CXX="-std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -DNDEBUG"
protoc -I"$TP/asn1-pdu" --cpp_out="$FZ/lpm" "$TP/asn1-pdu/asn1_pdu.proto"
lpm_srcs=("$FZ/lpm/asn1_pdu.pb.cc" "$TP/asn1-pdu/asn1_pdu_to_der.cc" "$TP/asn1-pdu/common.cc"
          "$TP/libprotobuf-mutator/src/binary_format.cc" "$TP/libprotobuf-mutator/src/mutator.cc"
          "$TP/libprotobuf-mutator/src/text_format.cc" "$TP/libprotobuf-mutator/src/utf8_fix.cc"
          "$TP/libprotobuf-mutator/src/libfuzzer/libfuzzer_macro.cc"
          "$TP/libprotobuf-mutator/src/libfuzzer/libfuzzer_mutator.cc")
printf '%s\n' "${lpm_srcs[@]}" | xargs -P"$MAYHEM_JOBS" -I{} bash -c \
  '$CXX '"$PROTO_CXX"' -I"'"$FZ"'/lpm" -I"'"$TP"'/asn1-pdu" -I"'"$TP"'" -I"'"$TP"'/libprotobuf-mutator" -c "$1" -o "'"$FZ"'/lpm/$(basename "$1" .cc).o"' _ {}
LPM_OBJS="$(ls "$FZ"/lpm/*.o | tr '\n' ' ')"

# ---- 3) harnesses: one fuzzer binary + one run-once -standalone reproducer each ----
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FZ/obj/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FZ/obj/lsan_off.o"

build_one() {   # build_one <source.cc>
  local src="$1" name; name="$(basename "$src" .cc)"
  local extra=() link=()
  case "$src" in
    */mayhem/lpm/*) extra=(-std=c++17 -DNDEBUG -I"$FZ/lpm" -I"$TP/asn1-pdu" -I"$TP" -I"$TP/libprotobuf-mutator")
                    link=($LPM_OBJS -lprotobuf -lpthread) ;;
    *)              extra=(-std=c++17 -Wno-missing-prototypes) ;;
  esac
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link $FUZZ_DEFS "${extra[@]}" \
       -I"$SRC/include" -I"$SRC" -c "$src" -o "$FZ/obj/$name.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$FZ/obj/$name.o" "$FZ/obj/lsan_off.o" \
       "${link[@]}" $LIBS -lpthread -o "$OUT/$name"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$FZ/obj/$name.o" "$FZ/obj/standalone_main.o" "$FZ/obj/lsan_off.o" \
       "${link[@]}" $LIBS -lpthread -o "$OUT/$name-standalone"
}
export -f build_one
export FZ OUT TP LIBS LPM_OBJS SRC FUZZ_DEFS
{ ls "$SRC"/fuzz/*.cc; ls "$SRC"/mayhem/lpm/*.cc; } | xargs -P"$MAYHEM_JOBS" -I{} bash -c 'build_one "$1"' _ {}

# ---- 4) the project's own unit tests with NORMAL flags (clean, independent of the fuzz build) ----
cmake -S "$SRC" -B "$TB" -GNinja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build "$TB" -j"$MAYHEM_JOBS" --target crypto_test ssl_test pki_test decrepit_test
