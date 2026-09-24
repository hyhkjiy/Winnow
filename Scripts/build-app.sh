#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${CONFIGURATION:-debug}
output_root=${OUTPUT_DIR:-"$project_root/.build/app"}
app_bundle="$output_root/Winnow.app"
local_signing_identity="Winnow Local Development"
signing_identity=${WINNOW_CODE_SIGN_IDENTITY:-$local_signing_identity}
allow_adhoc=${WINNOW_ALLOW_ADHOC:-0}

if [ "$signing_identity" = "-" ]; then
    if [ "$allow_adhoc" != "1" ]; then
        echo "error: ad hoc signing requires WINNOW_ALLOW_ADHOC=1" >&2
        exit 1
    fi
elif ! security find-identity -v -p codesigning 2>/dev/null \
    | grep -F -- "$signing_identity" >/dev/null; then
    echo "error: required code-signing identity '$signing_identity' is unavailable" >&2
    echo "Set WINNOW_CODE_SIGN_IDENTITY to a valid identity from:" >&2
    echo "  security find-identity -v -p codesigning" >&2
    exit 1
fi

cd "$project_root"
swift build --configuration "$configuration"
binary_directory=$(swift build --configuration "$configuration" --show-bin-path)

mkdir -p "$output_root"
staging_root=$(mktemp -d "$output_root/.Winnow.app.staging.XXXXXX")
staged_app="$staging_root/Winnow.app"
backup_bundle="$output_root/.Winnow.app.previous.$$"
old_bundle_moved=0
new_bundle_installed=0

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM

    rm -rf "$staging_root"
    if [ "$status" -eq 0 ]; then
        rm -rf "$backup_bundle"
    elif [ "$old_bundle_moved" -eq 1 ] && [ -e "$backup_bundle" ]; then
        rm -rf "$app_bundle"
        if ! mv "$backup_bundle" "$app_bundle"; then
            echo "error: failed to restore previous app bundle: $backup_bundle" >&2
            status=1
        fi
    elif [ "$new_bundle_installed" -eq 1 ]; then
        rm -rf "$app_bundle"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$binary_directory/Winnow" "$staged_app/Contents/MacOS/Winnow"
cp "$project_root/Resources/Info.plist" "$staged_app/Contents/Info.plist"

codesign \
    --force \
    --sign "$signing_identity" \
    --entitlements "$project_root/Resources/Winnow.entitlements" \
    "$staged_app"

if [ "$allow_adhoc" = "1" ]; then
    verification_mode=--allow-adhoc
else
    verification_mode=--require-stable
fi

if [ -e "$app_bundle" ]; then
    "$project_root/Scripts/verify-signing.sh" \
        "$verification_mode" \
        --compare "$app_bundle" \
        "$staged_app"
else
    "$project_root/Scripts/verify-signing.sh" \
        "$verification_mode" \
        "$staged_app"
fi

if [ -e "$app_bundle" ]; then
    old_bundle_moved=1
    mv "$app_bundle" "$backup_bundle"
fi
new_bundle_installed=1
mv "$staged_app" "$app_bundle"

echo "Built $app_bundle (signing identity: $signing_identity)"
