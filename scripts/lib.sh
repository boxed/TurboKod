# Shared helpers for the build scripts (run.sh, run_swift.sh, scripts/*.sh).
# Source it from the repo root: ``. scripts/lib.sh``.

# Print the pixi env prefix. ``pixi info`` is the supported way to ask for
# it; fall back to the conventional location so this still works in CI /
# headless setups that pre-populate ``.pixi``.
resolve_env_prefix() {
  local prefix
  prefix="$(pixi info --json 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["environments_info"][0]["prefix"])' \
    2>/dev/null)"
  if [ -z "${prefix:-}" ]; then
    prefix="$(pwd)/.pixi/envs/default"
  fi
  printf '%s\n' "$prefix"
}

# The Rust shim staticlib every Mojo build links (pty spawn / non-blocking
# I/O / child registry / listdir / debug-log open / libonig handle registry).
SHIM_CRATE="app/turbokod-shim"
SHIM_LIB="$SHIM_CRATE/target/release/libturbokod_shim.a"

# Rebuild the shim when any of its sources is newer than the staticlib.
# Cargo would detect this on its own; the explicit check keeps a no-op run
# free of cargo's startup cost and lets us say what's being built. ``$1`` is
# the log tag (``run.sh`` / ``run_swift``). Returns non-zero on failure.
ensure_shim() {
  if [ -f "$SHIM_LIB" ] && ! find "$SHIM_CRATE/src" "$SHIM_CRATE/Cargo.toml" \
      -newer "$SHIM_LIB" -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi
  echo "[$1] building rust shim -> $SHIM_LIB" >&2
  if ! ( cd "$SHIM_CRATE" && cargo build --release ); then
    echo "[$1] rust shim build failed" >&2
    return 1
  fi
}

# Build one Mojo entry point with ``run.sh``, logging to ``$2/<name>$3``;
# on failure print the log tail and return non-zero. Used by the parallel
# builders in check_all.sh and run_tests.sh.
build_entry_logged() {
  local f="$1" logdir="$2" suffix="$3"
  local log
  log="$logdir/$(basename "$f" .mojo)$suffix"
  mkdir -p "$logdir"
  if ! TURBOKOD_BUILD_ONLY=1 ./run.sh "$f" > "$log" 2>&1; then
    echo "BUILD FAILED: $f" >&2
    tail -30 "$log" >&2
    return 1
  fi
}
