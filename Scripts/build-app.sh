#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${CONFIGURATION:-debug}
output_root=${OUTPUT_DIR:-"$project_root/.build/app"}
app_bundle="$output_root/Winnow.app"

cd "$project_root"
swift build --configuration "$configuration"
binary_directory=$(swift build --configuration "$configuration" --show-bin-path)

rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$binary_directory/Winnow" "$app_bundle/Contents/MacOS/Winnow"
cp "$project_root/Resources/Info.plist" "$app_bundle/Contents/Info.plist"

codesign \
    --force \
    --sign - \
    --entitlements "$project_root/Resources/Winnow.entitlements" \
    "$app_bundle"

echo "Built $app_bundle"
