#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_DIR="$ROOT_DIR/rust"
OUT_DIR="$ROOT_DIR/ios/Frameworks"
XCFRAMEWORK="$OUT_DIR/QuackDeckCore.xcframework"
HEADERS_DIR="$RUST_DIR/quackdeck-core/include"

PROFILE="${1:-release}"
if [[ "$PROFILE" == "debug" ]]; then
    CARGO_FLAGS=()
    TARGET_SUBDIR="debug"
else
    CARGO_FLAGS=(--release)
    TARGET_SUBDIR="release"
fi

export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

echo "Building quackdeck-core ($TARGET_SUBDIR) for aarch64-apple-ios and aarch64-apple-ios-sim (iOS $IPHONEOS_DEPLOYMENT_TARGET)..."
pushd "$RUST_DIR" >/dev/null
cargo build -p quackdeck-core --target aarch64-apple-ios ${CARGO_FLAGS[@]+"${CARGO_FLAGS[@]}"}
cargo build -p quackdeck-core --target aarch64-apple-ios-sim ${CARGO_FLAGS[@]+"${CARGO_FLAGS[@]}"}
popd >/dev/null

rm -rf "$XCFRAMEWORK"
mkdir -p "$OUT_DIR"

xcodebuild -create-xcframework \
    -library "$RUST_DIR/target/aarch64-apple-ios/$TARGET_SUBDIR/libquackdeck_core.a" \
    -headers "$HEADERS_DIR" \
    -library "$RUST_DIR/target/aarch64-apple-ios-sim/$TARGET_SUBDIR/libquackdeck_core.a" \
    -headers "$HEADERS_DIR" \
    -output "$XCFRAMEWORK"

echo "Built $XCFRAMEWORK"
