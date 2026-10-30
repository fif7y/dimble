# Release runbook (M7)

The pipeline is `scripts/release.sh` (same steps as `.github/workflows/release.yml`).
Everything below the one-time setup is: bump version → run script → publish.

## One-time setup (on the dev Mac)

1. **Developer ID Application certificate** — currently the blocker; the keychain
   has none. In Xcode → Settings → Accounts → team `YW9UY68SQ7` → Manage
   Certificates → “+” → Developer ID Application (needs Account Holder role, or
   create at developer.apple.com/account/resources/certificates). Verify:
   `security find-identity -v -p codesigning` lists `Developer ID Application: …`.

2. **Notary credentials** — create an App Store Connect API key (Developer role
   is enough), then store it once:

   ```sh
   xcrun notarytool store-credentials nook-notary \
     --key ~/Downloads/AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
   ```

3. **Sparkle EdDSA keys** — after the first build fetches Sparkle via SPM:

   ```sh
   # find the tools in DerivedData
   find ~/Library/Developer/Xcode/DerivedData -path '*Sparkle/bin/generate_keys' -print -quit
   <that path>          # generates keys, stores private key in login keychain
   ```

   It prints the **public** key: paste it into `project.yml` as `SUPublicEDKey`
   (replacing the `REPLACE_WITH_…` placeholder) and re-run `xcodegen`. The
   updater code (`SparkleController`) stays disabled until this placeholder is
   replaced, so dev builds are unaffected either way.

   Back up the private key: `generate_keys -x sparkle_private_key` → store it
   somewhere safe (it is the only thing that can sign updates; losing it
   strands existing installs).

4. **Appcast hosting**: `SUFeedURL` is `https://fif7y.github.io/updates/pliss/appcast.xml`,
   served by GitHub Pages from the public repo `fif7y/updates` (branch `main`, root).
   Builds up to 0.3.2-beta.6 read `https://fif7y.github.io/pelmet/appcast.xml`. Since
   fif7y/pelmet became fif7y/pliss (2026-10-15), then fif7y/dimble, that path is served by the account
   Pages site `fif7y/fif7y.github.io` (folder `pelmet/`), because Pages paths don't
   redirect on a rename. Never create a repo named `pelmet`: it would take the path
   back and break github.com/fif7y/pelmet's redirect. Never give the account site a
   custom domain: every project Pages URL would move with it. DMGs are attached to
   GitHub Releases (the appcast's enclosure URLs point at
   `github.com/fif7y/dimble/releases/download/…`).

## Per-release

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION` — Sparkle compares
   `CFBundleVersion`, so it must strictly increase) in `project.yml`.
2. `scripts/release.sh` — archives, exports with Developer ID, notarizes +
   staples app and DMG, writes `build/releases/Dimble-<v>.dmg` + `appcast.xml`.
   Before reporting success, it verifies the DMG's Ed25519 signature and
   enclosure length against the public key in the exported app. Missing
   appcast tooling or a failed update-signature check stops the release.
   The existing nonfatal `spctl` assessment is unchanged: the stapled DMG is
   not code-signed and may report "no usable signature" (exit 3).
   Offline release tests: `python3 -m unittest discover -s scripts/tests`.
3. Tag and publish: create GitHub release `v<version>` with the DMG and the
   `*.delta` files attached (release.sh points each delta at its build's
   release tag, never at gh-pages).
4. Push `appcast.xml` to BOTH feeds, the new one first:
   `fif7y/updates` → `pliss/appcast.xml`, then `fif7y/fif7y.github.io` →
   `pelmet/appcast.xml` (older installs). The `gh-pages` branch of fif7y/dimble is no
   longer read by anything. Commit with the repo's own identity: a scratch clone
   picks up the global git config, and a push authored with the gmail address is
   rejected by the account's email-privacy setting:

   ```sh
   git -c user.name="Gab" -c user.email="16541220+fif7y@users.noreply.github.com" \
       commit -m "Dimble <version>"
   ```

   Don't trust the push's own output: `git push … | tail` reports the
   pipeline's status, not the push's, so a rejected push can read as success.
   Poll both live feeds instead (Pages lags 20–60s):

   ```sh
   for u in updates/pliss pelmet; do curl -s "https://fif7y.github.io/$u/appcast.xml?cb=$RANDOM" \
     | grep -o '<sparkle:shortVersionString>[^<]*' | head -1; done
   ```
5. **Legacy feed mirror: frozen at 0.3.1, don't push to it.** Nook-era
   installs (≤ 0.1.4) poll `https://fif7y.github.io/nook/appcast.xml`, served
   by the stub repo `fif7y/nook` (GitHub Pages paths don't redirect on repo
   rename). Every build since the 0.1.5 bridge points `SUFeedURL` at the
   Pelmet feed (now the account site's `pelmet/` copy), so one update from that feed is enough to cross over. It
   carries 0.3.1 for that, and nothing newer is needed.
6. Bump the Homebrew cask: `fif7y/homebrew-tap` → `Casks/dimble.rb` (`Casks/pelmet.rb` up to 0.3.1, renamed with the 0.3.2 stable), set
   `version` and the DMG's `sha256` (`shasum -a 256 build/releases/Dimble-<v>.dmg`),
   push with the same identity rule as step 4, then confirm the published DMG
   hashes to what the cask declares.
7. Sanity: install the previous DMG, let Sparkle offer the new version, update.

`SKIP_NOTARIZE=1 scripts/release.sh` smoke-tests the archive/export/DMG half
without credentials.

## Beta releases (opt-in channel, since 0.2.41)

Plan and rationale: `docs/BETA-CHANNEL-PLAN.md`. Mechanics:

- Version `X.Y.Z-beta.N` in `project.yml`, build number from the same
  counter as stable (Sparkle compares `CFBundleVersion` across channels).
- `CHANNEL=beta scripts/release.sh` — `generate_appcast --channel beta` tags
  the new items; stable items stay untagged in the same `appcast.xml`.
- GitHub release `vX.Y.Z-beta.N` with `--prerelease` (the download badge and
  "Latest" stay on stable). Push the appcast to gh-pages as usual (not the
  frozen nook mirror). Skip the Homebrew cask.
- Notes in `docs/release-notes/vX.Y.Z-beta.N.md`; the stable's notes are the
  roll-up.
- The notes file is also what users see in the app: `release.sh` renders it
  (`scripts/release-notes-html.py`) next to the DMG, `generate_appcast`
  embeds it in the item's description (Sparkle's update window, About's
  "What's new" for a waiting update), and every build bundles its own as
  `ReleaseNotes.html` (About's "What's new in this version"). Commit the
  notes with the version bump, before the build. A leading `>` quote becomes
  the tinted announcement box at the top; the beta opt-in sentence is
  dropped in-app.
- Stable roll-up every one or two weeks, Tuesdays: a fresh build from the
  last beta's commit with the plain version and the next build number.
- A build whose version carries `-beta.` turns "Get beta releases" on at
  first launch (`AppState.isPrereleaseBuild`, one-shot per store), so a beta
  taken straight from GitHub stays on the channel. The user's later choice
  stands.

## CI

`.github/workflows/release.yml` runs the same pipeline on `v*` tags, but needs a
runner image with the macOS 27 SDK — until GitHub ships one, release locally.
Secrets it expects are listed at the top of the workflow file.
