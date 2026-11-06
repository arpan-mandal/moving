# Contributing to Moving

Open an issue for a reproducible bug or to discuss a change that affects the app’s behavior. For small fixes, a pull request with a short explanation and verification steps is enough.

## Development

1. Fork and clone the repository.
2. Open `Moving.xcodeproj` or build with `./Scripts/build.sh`. See the [README](README.md#build-from-source) for prerequisites.
3. Run `./Scripts/test.sh` in a graphical macOS session. Use `./Scripts/smoke-test.sh` for changes to the release bundle, desktop playback, or menu bar.
4. In the pull request, describe the behavior before and after the change and list the macOS versions, architectures, and display setups you tested.

Keep the sandbox entitlements narrow. For media tests, use bundled or generated fixtures. Keep app bundles, user media, bookmarks, build outputs, and signing credentials out of commits.

`Scripts/generate-project.py` regenerates the Xcode project when the app source list changes. The [architecture guide](Documentation/ARCHITECTURE.md) describes the ownership and lifecycle of playback sessions, local file access, and cached media.

## Bug reports

Include the Moving version and build, macOS version, Mac architecture, and steps to reproduce. For playback bugs, include the file format, codec, resolution, frame rate, and display setup if known. Share a minimal sample only if you have permission to distribute it. Remove personal paths and other private information from logs.

Report security issues through the private channel described in [SECURITY.md](SECURITY.md).
