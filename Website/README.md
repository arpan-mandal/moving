# Moving website

A compact product and download page for Moving, styled after the RPN Endec project page. The site uses plain HTML, CSS, and JavaScript with no external runtime dependencies. The distributable web root is `dist/`.

## Preview

To preview the local download, get the Moving 1.2.0 build 7 universal DMG and its checksum from the [GitHub prerelease](https://github.com/arpan-mandal/moving/releases/tag/v1.2.0-preview.7) or a local app build. Put both files in `installers/`. The prerelease has an ad hoc signature and is intended for local testing.

```sh
node build.mjs --preview
python3 -m http.server 8765 --bind 127.0.0.1 --directory preview
```

Open `http://127.0.0.1:8765/` to test the site and its local DMG download. The preview verifies the included checksum before copying the installer into its own web root.

## Deploy the website

Deploy the contents of `dist/` to any static host. It is already built and shows **Public download pending**. For a subdirectory such as `/moving/`, serve the site with a trailing slash and redirect `/moving` to `/moving/`. All asset and download links are relative. To regenerate the web root from source, run `node build.mjs`. Node 22 or later is sufficient.

## Enable the public download

1. Build, sign, and notarize the universal app and DMG. Staple and validate the final tickets, then test the downloadable DMG with Gatekeeper enabled on a clean Mac. The app repository has the full workflow in `Documentation/SIGNING.md` and `Scripts/notarize.sh`. [Apple’s packaging guide](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
2. Put the final DMG in `release-assets/` as `Moving-1.2.0-universal.dmg`. Compute its SHA-256 **after** stapling. Set `release.json` to `published` and fill `download.sha256` with that digest.
3. Run `node build.mjs`. The builder checks the artifact’s digest and writes the DMG and checksum under `dist/downloads/`. Confirm the signature and notarization before setting the release status. The checksum verifies the file bytes.
4. Deploy the rebuilt `dist/`. Verify the live download from the public URL and compare it with the checksum shown on the page.

The local `preview/` output and `installers/` folder are for testing. Use only `dist/` as the public web root. For a later release, also update the release notes and check the system requirements and product copy in `src/index.html`.

## Included assets

The mark, icon, screenshot and demo are from the Moving project. The demo uses the bundled Aurora Drift wallpaper. The page contains a copy of the MIT notice at `LICENSE.txt`.

The site bundles [Inter](https://rsms.me/inter/) under the SIL Open Font License. See `assets/inter-license.txt` in the generated site.
