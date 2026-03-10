# iOS Ad Hoc OTA via GitHub Pages + Releases

Minimal infrastructure for OTA distribution of already signed Ad Hoc iOS builds:

- GitHub Pages hosts a static install page.
- IPA is stored only as a GitHub Release asset (never in git history).
- `manifest.plist` is generated and uploaded as a Release asset.
- Install page always points to the latest release processed by workflow.

## Repository structure

- `.github/workflows/publish-ota.yml` - main OTA publishing workflow.
- `scripts/generate_manifest.py` - generates OTA-compatible `manifest.plist`.
- `site/index.html` - static install page.
- `site/assets/icon57.png`, `site/assets/icon512.png` - icons for manifest.
- `site/current.json` - metadata consumed by install page (overwritten by workflow).

## How it works

1. You create or open a GitHub Release and upload your `.ipa` as an asset.
2. You run `Publish OTA Install Page` workflow manually (`workflow_dispatch`) with inputs:
   - `app_name`
   - `bundle_id`
   - `bundle_version`
   - `build_number`
   - `release_tag`
   - `ipa_asset_name`
3. Workflow:
   - finds release by `release_tag`;
   - validates release is not `draft` and not `prerelease`;
   - finds IPA asset by exact `ipa_asset_name`;
   - generates `manifest.plist` with absolute HTTPS URLs;
   - uploads `manifest.plist` into same release (`--clobber`, predictable replacement);
   - updates GitHub Pages artifact (`index.html`, icons, `current.json`);
   - prints final install URL in job summary.

## One-command automation from local machine

You can use:

- `scripts/publish_ota.sh`

What it does:

1. Takes IPA path argument, or automatically picks newest `*.ipa` from `./drop/`.
2. Reads metadata from IPA (`app_name`, `bundle_id`, `bundle_version`, `build_number`).
3. Creates release (or updates existing) and uploads IPA asset.
4. Triggers `publish-ota.yml` workflow with required inputs.
5. Optionally watches the workflow run.

Prerequisites:

- `gh` CLI installed and authenticated (`gh auth login`)
- `unzip` available
- macOS tool `/usr/libexec/PlistBuddy` (used to read IPA metadata)

Minimal usage:

```bash
mkdir -p drop
# copy your exported Ad Hoc IPA into ./drop/
scripts/publish_ota.sh
```

Explicit IPA:

```bash
scripts/publish_ota.sh ./drop/MyApp.ipa
```

Useful options:

- `--tag v1.2.3` to force release tag
- `--no-watch` to only dispatch workflow and exit
- `--app-name`, `--bundle-id`, `--version`, `--build` to override values from IPA

## Manual setup in GitHub UI

1. Enable GitHub Pages:
   - `Settings -> Pages -> Build and deployment -> Source: GitHub Actions`.
2. Create first release:
   - `Releases -> Draft a new release` (or publish existing);
   - set tag (for example `v1.0.0`);
   - upload `MyApp.ipa` asset;
   - publish release (not draft/prerelease).
3. Run workflow:
   - `Actions -> Publish OTA Install Page -> Run workflow`;
   - fill all required inputs exactly (IPA asset name must match release asset).

## Where to get install URL

After workflow finishes, open job summary:

- `Install page URL` - public page on GitHub Pages.
- `Install URL` - direct `itms-services://` link for iPhone.

Example format:

```text
itms-services://?action=download-manifest&url=https%3A%2F%2Fgithub.com%2FOWNER%2FREPO%2Freleases%2Fdownload%2Fv1.0.0%2Fmanifest.plist
```

## Security and limitations

- GitHub Pages is public.
- Release assets in public repo are public.
- Do not upload sensitive data into release assets.
- This repository does not build or sign iOS binaries.
- Apple signing/provisioning requirements still apply (Ad Hoc profile and registered device UDIDs).

## What is not fully automatable here

- Initial GitHub Pages enablement in repository settings.
- Release creation and IPA upload (done manually in GitHub UI or your own release tooling).
