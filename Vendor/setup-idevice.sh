#!/bin/bash
set -euo pipefail

vendor_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(dirname "$vendor_dir")"
version="0.1.68"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/updater-idevice.XXXXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
archive="$work_dir/idevice.tar.gz"

if [[ "$#" -gt 0 ]]; then
    cp "$1" "$archive"
else
    curl -fLsS --retry 2 \
        "https://codeload.github.com/jkcoxson/idevice/tar.gz/refs/tags/v$version" \
        -o "$archive"
fi
echo "eb09df5481cc03bfd07e718c8e8fbebcf59bfb71d9ea12a78f7df9fdc37a2be6  $archive" |
    shasum -a 256 -c --status
tar -xzf "$archive" -C "$work_dir"

source_dir="$work_dir/idevice-$version"
patch -s -d "$source_dir" -p1 < "$project_dir/Bridge/require-pairing-consent.patch"
patch -s -d "$source_dir" -p1 < "$project_dir/Bridge/installation-proxy-attributes.patch"
cp "$project_dir/Bridge/inventory.rs" "$source_dir/ffi/src/updater_inventory.rs"
cp "$project_dir/Bridge/pairing_host.rs" "$source_dir/ffi/src/updater_pairing_host.rs"
cp "$project_dir/Bridge/Cargo.toml" "$source_dir/ffi/Cargo.toml"
mkdir "$work_dir/include"
cp "$project_dir/Bridge/"{DeviceInventory.h,module.modulemap} "$work_dir/include/"

cd "$source_dir"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export CARGO_PROFILE_RELEASE_LTO=false
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=8
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$source_dir/target}"
targets=(aarch64-apple-ios)
if [[ "${UPDATER_DEVICE_ONLY:-0}" != 1 ]]; then
    targets+=(aarch64-apple-ios-sim)
fi
libraries=()
for target in "${targets[@]}"; do
    sdk=iphonesimulator
    if [[ "$target" == "aarch64-apple-ios" ]]; then
        sdk=iphoneos
    fi
    SDKROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
        cargo build --quiet --release -p idevice-ffi --target "$target"
    libraries+=(-library "$CARGO_TARGET_DIR/$target/release/libidevice_ffi.a" -headers "$work_dir/include")
done

xcodebuild -create-xcframework "${libraries[@]}" \
    -output "$work_dir/IDevice.xcframework"
cp LICENSE.txt "$vendor_dir/IDevice-LICENSE.txt"
rm -rf "$vendor_dir/IDevice.xcframework"
mv "$work_dir/IDevice.xcframework" "$vendor_dir/IDevice.xcframework"
