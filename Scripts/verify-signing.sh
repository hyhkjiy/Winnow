#!/bin/sh

set -eu

expected_identifier=${WINNOW_BUNDLE_IDENTIFIER:-app.winnow.Winnow}
allow_adhoc=0
reference_bundle=

usage() {
    echo "usage: $0 [--require-stable|--allow-adhoc] [--compare APP] APP" >&2
    exit 64
}

fail() {
    echo "error: $*" >&2
    exit 1
}

signature_details() {
    codesign -d --verbose=4 "$1" 2>&1
}

designated_requirement() {
    codesign -d -r- "$1" 2>&1 \
        | sed -n 's/^designated => //p'
}

verify_bundle() {
    bundle=$1

    [ -d "$bundle" ] || fail "app bundle does not exist: $bundle"
    [ -f "$bundle/Contents/Info.plist" ] \
        || fail "Info.plist is missing: $bundle"

    codesign --verify --deep --strict --verbose=2 "$bundle"

    details=$(signature_details "$bundle") \
        || fail "cannot read signature details: $bundle"
    signed_identifier=$(printf '%s\n' "$details" \
        | sed -n 's/^Identifier=//p' \
        | head -n 1)
    plist_identifier=$(plutil -extract CFBundleIdentifier raw -o - \
        "$bundle/Contents/Info.plist") \
        || fail "cannot read CFBundleIdentifier: $bundle"
    requirement=$(designated_requirement "$bundle") \
        || fail "cannot read designated requirement: $bundle"

    [ "$signed_identifier" = "$expected_identifier" ] \
        || fail "signed identifier '$signed_identifier' is not '$expected_identifier'"
    [ "$plist_identifier" = "$expected_identifier" ] \
        || fail "Info.plist identifier '$plist_identifier' is not '$expected_identifier'"
    [ -n "$requirement" ] \
        || fail "designated requirement is empty: $bundle"

    case "$requirement" in
        *"identifier \"$expected_identifier\""*) ;;
        *) fail "designated requirement has the wrong identifier: $requirement" ;;
    esac

    if printf '%s\n' "$details" | grep -F 'Signature=adhoc' >/dev/null; then
        [ "$allow_adhoc" -eq 1 ] \
            || fail "ad hoc signature is not allowed for the runnable app"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --require-stable)
            allow_adhoc=0
            shift
            ;;
        --allow-adhoc)
            allow_adhoc=1
            shift
            ;;
        --compare)
            [ "$#" -ge 2 ] || usage
            reference_bundle=$2
            shift 2
            ;;
        --*) usage ;;
        *) break ;;
    esac
done

[ "$#" -eq 1 ] || usage
app_bundle=$1

verify_bundle "$app_bundle"
app_requirement=$(designated_requirement "$app_bundle")

if [ -n "$reference_bundle" ]; then
    verify_bundle "$reference_bundle"
    reference_requirement=$(designated_requirement "$reference_bundle")
    [ "$app_requirement" = "$reference_requirement" ] \
        || fail "designated requirement changed from the existing app"
fi

echo "Identifier: $expected_identifier"
echo "Designated requirement: $app_requirement"
