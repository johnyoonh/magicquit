# Releasing MagicQuit

Releases must originate from `johnyoonh/magicquit`. The release script refuses to publish from another repository or a dirty working tree.

## One-time setup

1. Install a Developer ID Application certificate for team `4HMNGH59W8`.
2. Store notarization credentials:

   ```bash
   xcrun notarytool store-credentials magicquit-notary \
     --apple-id <apple-id> --team-id 4HMNGH59W8 --password <app-specific-password>
   ```

3. Generate a fork-owned Sparkle key pair:

   ```bash
   brew install --cask sparkle
   generate_keys
   generate_keys -x sparkle-private-key-backup.pem
   ```

   Store the backup outside the repository. Put the printed public key in `MagicQuit/Info.plist` as `SUPublicEDKey`. Do not reuse an upstream key unless the matching private key is controlled by this repository owner.

4. Authenticate GitHub CLI for `johnyoonh/magicquit`.

## Per release

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project.
2. Add the same version to `CHANGELOG.md` and commit it.
3. Confirm `main` is clean and current.
4. Run:

   ```bash
   ./scripts/release.sh
   ```

The script runs tests, validates property lists, archives, signs, notarizes, staples, validates the Sparkle feed owner, generates the appcast, updates Homebrew metadata, commits and pushes release metadata, and finally creates the GitHub release.

Sparkle is disabled in Debug builds. Release builds start it only when the public key is nonempty and the feed URL points to `johnyoonh/magicquit`.
