# Signing and notarization

Moving 1.2.0 is built and packaged for local verification with an **ad-hoc signature**. Public downloads require a Developer ID Application certificate and Apple notarization. The build host has no valid signing identity. [Apple’s distribution requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## Xcode

Open Moving.xcodeproj, select Moving → Signing & Capabilities, choose your team, and change the bundle ID if needed. Keep App Sandbox, read-only user-selected files, app-scoped bookmarks and Hardened Runtime. Use a Developer ID Application identity for external distribution. If changing the identifier, update Info.plist and the command-line build configuration consistently; the data container will change.

## Command line

With a Developer ID Application certificate in your keychain:

```sh
export SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
./Scripts/build.sh
codesign --verify --deep --strict --verbose=2 Artifacts/Release/Moving.app
codesign -d --verbose=4 Artifacts/Release/Moving.app
```

The script enables Hardened Runtime and secure timestamping for this identity. Local builds without SIGNING_IDENTITY use an explicit ad-hoc signature and retain sandbox entitlements.

Store notarization credentials once using Apple's interactive keychain command, or use App Store Connect API-key arguments. Do not put passwords in repository files:

```sh
xcrun notarytool store-credentials MovingNotary
```

Then notarize the signed app, staple it, package and notarize the installer:

```sh
ditto -c -k --keepParent Artifacts/Release/Moving.app Artifacts/Release/Moving-notarization.zip
xcrun notarytool submit Artifacts/Release/Moving-notarization.zip --keychain-profile MovingNotary --wait
xcrun stapler staple Artifacts/Release/Moving.app
./Scripts/package-dmg.sh
xcrun notarytool submit Artifacts/Release/Moving-1.2.0-universal.dmg --keychain-profile MovingNotary --wait
xcrun stapler staple Artifacts/Release/Moving-1.2.0-universal.dmg
xcrun stapler validate Artifacts/Release/Moving-1.2.0-universal.dmg
spctl --assess --type execute --verbose=2 Artifacts/Release/Moving.app
(cd Artifacts/Release && shasum -a 256 Moving-1.2.0-universal.dmg > Moving-1.2.0-universal.dmg.sha256)
```

Leave SIGNING_IDENTITY exported for packaging so the DMG is signed too. Only distribute after Apple returns Accepted and stapling/assessment succeed. If rejected, inspect `xcrun notarytool log <submission-id> --keychain-profile MovingNotary` and fix the actual finding. These commands upload the application/installer to Apple's notarization service; no user wallpaper library is part of the build.

Use `Scripts/notarize.sh` to run the same workflow once SIGNING_IDENTITY and NOTARY_PROFILE are configured. This workflow has not been executed here.
