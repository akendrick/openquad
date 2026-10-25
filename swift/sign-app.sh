#!/bin/sh
# Sign OpenQuad.app, and notarize it when a Developer ID and a notary profile are set.
#
#     swift/sign-app.sh                  ad-hoc signature: runs on this Mac (for testing)
#
#     OPENQUAD_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" \
#     OPENQUAD_NOTARY_PROFILE=openquad-notary swift/sign-app.sh
#                                        signed with the hardened runtime, notarized,
#                                        stapled, and packed as swift/build/OpenQuad-VERSION.dmg
#
# The identity and profile live only in your keychain and environment, never in the
# repository. Create the profile once (it asks for an app-specific password):
#
#     xcrun notarytool store-credentials openquad-notary --apple-id APPLE_ID --team-id TEAMID
set -eu
here=$(cd "$(dirname "$0")" && pwd)
app="$here/build/OpenQuad.app"
identity="${OPENQUAD_SIGN_IDENTITY:--}"
profile="${OPENQUAD_NOTARY_PROFILE:-}"

"$here/build-app.sh"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")

if [ "$identity" = "-" ]; then
    echo "signing ad hoc (set OPENQUAD_SIGN_IDENTITY to a Developer ID to distribute)"
    codesign --force --sign - --options runtime "$app"
else
    echo "signing with the identity from OPENQUAD_SIGN_IDENTITY"
    codesign --force --sign "$identity" --options runtime --timestamp "$app"
fi
codesign --verify --strict --verbose=2 "$app"

if [ -z "$profile" ]; then
    echo "not notarizing (set OPENQUAD_NOTARY_PROFILE, with a Developer ID identity, to notarize)"
    exit 0
fi
case "$identity" in
    "Developer ID Application:"*) ;;
    *) echo "notarizing needs a Developer ID Application identity" >&2; exit 1 ;;
esac

zip="$here/build/OpenQuad-$version.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
spctl --assess --type execute --verbose=2 "$app"

dmg="$here/build/OpenQuad-$version.dmg"
rm -f "$dmg"
hdiutil create -volname "OpenQuad $version" -srcfolder "$app" -ov -format UDZO "$dmg"
codesign --force --sign "$identity" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
rm -f "$zip"
echo "built $dmg"
