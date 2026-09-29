# Homebrew distribution preparation

NetworkPortEval is a native macOS GUI application, so the intended Homebrew package is a **Cask**, not a Formula. The Cask is not publishable yet: this project currently has no public GitHub release URL, and the development app is ad-hoc signed. Homebrew's official Cask policy requires apps submitted to the official repository to pass Gatekeeper on a default macOS configuration; obtain Developer ID signing, hardened runtime and notarization first.

## Release requirements

1. Publish versioned arm64 and x86_64 release assets named `NetworkPortEval-arm64.zip` and `NetworkPortEval-x86_64.zip`, each containing `NetworkPortEval.app` at a stable HTTPS URL.
2. Build with the intended architecture(s), set the version consistently in `Info.plist`, sign with Developer ID, notarize, staple and verify Gatekeeper acceptance on a clean Mac.
3. Compute and record a SHA-256 checksum for each release asset using `shasum -a 256`.
4. Replace the marked placeholders in `networkporteval.rb` with the real GitHub owner, release URL, version, both checksums and verified homepage.
5. Run `brew audit --cask --strict --online` and test `brew install --cask`, `brew upgrade --cask`, and `brew uninstall --cask` on a clean macOS account before publishing.
6. Decide whether to submit to `homebrew/homebrew-cask` or distribute through an owner-maintained tap. An official Cask is publicly discoverable; a custom tap requires users to add that tap first.

The app stores user data in `~/Library/Application Support/NetworkPortEval`, outside the app bundle, so replacing the `.app` during an upgrade does not overwrite settings, templates or reports.

## Starter Cask

`networkporteval.rb` is a non-installable scaffold until every `REPLACE_*` value is filled with the real release data. Do not use an unversioned “latest” URL with `sha256 :no_check`; publish immutable, versioned release assets and pin each architecture-specific checksum.

## References

- [Homebrew Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)
- [Adding Software to Homebrew](https://docs.brew.sh/Adding-Software-to-Homebrew)
- [Acceptable Casks](https://docs.brew.sh/Acceptable-Casks)
