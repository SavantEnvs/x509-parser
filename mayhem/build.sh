#!/usr/bin/env bash
#
# mayhem/build.sh — build x509-parser's cargo-fuzz targets as sanitized libFuzzer binaries
# (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), then build (not run) the crate's own
# test suite with NORMAL flags so mayhem/test.sh only has to run it.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The Rust toolchain +
# cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo (pinned by the Dockerfile ENV —
# absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry (and the git-dependency
#     checkouts for asn1-rs/oid-registry, pinned via fuzz/Cargo.toml [patch.crates-io]) under
#     $CARGO_HOME, and resolves fuzz/Cargo.lock (not committed upstream).
#   - The PATCH re-run resolves everything from that cache + the now-resolved lockfile. The
#     rlenv runtime exports CARGO_NET_OFFLINE=true for the re-run so cargo won't try to refresh
#     the crates.io/git index over the (absent) network — so do NOT hard-code `--offline` here
#     (it would break this first, online build).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# Upstream's own fuzz/ crate pins asn1-rs/oid-registry via [patch.crates-io] git branches that no
# longer resolve (oid-registry@oid-registry-0.9 was deleted upstream), so it no longer builds.
# Rather than edit that upstream file, use the additive mayhem/fuzz/ crate (same 4 harnesses,
# against the root crate's published dependency versions).
FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# ── DWARF < 4 enforcement (§6.2 item 10) ────────────────────────────────────────────────────────
# Two separate DWARF-5 sources have to be neutralized, or whichever CU readelf sees first wins:
#  1. Our own rustc-compiled code: -Cdwarf-version=3 alone still emitted DWARF 4 on this
#     rustc/LLVM (the -C flag gets clamped); -C llvm-args=--dwarf-version=N reaches LLVM directly
#     and actually takes effect.
#  2. The Rust nightly's bundled ASan runtime (librustc-nightly_rt.asan.a) ships prebuilt, compiled
#     by the toolchain's own LLVM at DWARF 5, and gets linked in ahead of our code. Strip its debug
#     sections once (idempotent — a re-run's already-stripped copy is a no-op for objcopy) so it
#     contributes no .debug_info CUs at all.
# libfuzzer-sys also compiles libFuzzer's C++ runtime via the `cc` crate — force DWARF 3 there too
# via CFLAGS/CXXFLAGS so those CUs satisfy the check as well.
ASAN_RT="$(find "$RUSTUP_HOME/toolchains" -name 'librustc-nightly_rt.asan.a' 2>/dev/null | head -1)"
if [ -n "$ASAN_RT" ] && [ -f "$ASAN_RT" ]; then
  echo "stripping debug info from Rust ASan runtime to enforce DWARF < 4: $ASAN_RT"
  objcopy --strip-debug "$ASAN_RT"
fi
export CFLAGS="${CFLAGS:+$CFLAGS }-gdwarf-3"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-gdwarf-3"

# OSS-Fuzz Rust libFuzzer+ASan flags. cargo-fuzz sets the ASan flag itself, but we pin it
# explicitly. --cfg fuzzing matches libfuzzer-sys; force-frame-pointers aids ASan backtraces.
# NOTE: unlike the C/C++ recipe, we do NOT pass through $SANITIZER_FLAGS (a clang -fsanitize=...
# string) — rustc takes its sanitizer via the nightly-only -Zsanitizer=address flag instead, and
# there is no Rust UBSan equivalent to combine it with. ASan halts on error by default (matching
# the C/C++ SANITIZER_FLAGS contract's -fno-sanitize-recover intent).
RUST_DEBUG_FLAGS="${RUST_DEBUG_FLAGS:--Cdebuginfo=2 -C llvm-args=--dwarf-version=3}"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address $RUST_DEBUG_FLAGS -Cforce-frame-pointers"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# Build (do NOT run) the crate's own test suite, with its NORMAL flags — a separate, clean,
# unsanitized build so mayhem/test.sh only RUNS pre-built binaries. `--features` mirrors a subset
# of upstream's CI test matrix (validate+verify) that exercises real assertions without pulling in
# the heavier aws-lc backends. Unset the fuzz RUSTFLAGS for this build.
echo "=== cargo test --no-run (normal flags, for mayhem/test.sh) ==="
env -u RUSTFLAGS cargo test --locked --no-run --features=validate,verify \
  --message-format=json > "$SRC/mayhem/.cargo-test-build.json"

echo "build.sh complete"
