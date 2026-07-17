# Publishing Sparkle updates

Favenio embeds the exactly pinned Sparkle 2.9.4 framework in both macOS apps.
Each app checks the signed feed at
`https://danielmuellerir.github.io/favenio/appcast.xml` and updates its own
bundle from the same GitHub Release DMG. Updates are installed only after
explicit user approval, and no hardware or system profile is sent with checks.

Version 0.14.0 is the one-time bootstrap: older versions contain no updater and
must install 0.14.0 manually from the DMG. Later releases can be installed from
inside either app.

Two independent protections are required:

- Developer ID signing and Apple notarization for both apps and the DMG.
- A project-specific Sparkle Ed25519 signature for the update archive and feed.

The private Sparkle key must never enter Git, logs or command arguments. Only
its public counterpart is embedded as `SUPublicEDKey`.

## One-time GitHub setup

1. Configure GitHub Pages to use **GitHub Actions** as its source.
2. Store the private key as the Actions secret `SPARKLE_PRIVATE_KEY`. Export it
   temporarily with Sparkle's `generate_keys -x`, pass the file to
   `gh secret set SPARKLE_PRIVATE_KEY` through stdin, and securely remove the
   temporary file.
3. Keep a separate encrypted backup. Losing the key requires a controlled key
   rotation delivered in a Developer ID-signed DMG.

## Release procedure

1. Update `favenio.py::__version__`, its ISO-8601 date, tests and both READMEs.
   `CFBundleVersion` is derived from that version and must increase
   monotonically.
2. Build the release from the repository root:

   ```bash
   NOTARY_PROFILE=<profile> ./release.sh
   ```

   The script signs Sparkle's nested helpers from the inside out, builds the
   DMG, notarizes it and staples the ticket.
3. Verify tests, signatures, the stapled ticket, Gatekeeper assessment and the
   DMG contents.
4. Create a draft GitHub Release with exactly one DMG and complete release
   notes, then publish it.
5. `.github/workflows/publish-appcast.yml` signs the archive for Sparkle and
   deploys `appcast.xml` through GitHub Pages.
6. Verify the workflow, feed and a real update from an older notarized,
   Sparkle-enabled test build. Use `FAVENIO_SPARKLE_TEST_VERSION` only for this
   test; `release.sh` refuses to publish such a build.

The workflow can be rerun manually for an existing tag. The feed intentionally
contains only the latest full update; delta updates are disabled.
