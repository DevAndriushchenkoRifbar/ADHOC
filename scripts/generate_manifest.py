#!/usr/bin/env python3
"""Generate iOS OTA manifest.plist for an Ad Hoc IPA."""

from __future__ import annotations

import argparse
from pathlib import Path
from xml.sax.saxutils import escape


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate OTA manifest.plist")
    parser.add_argument("--app-name", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--bundle-version", required=True)
    parser.add_argument("--ipa-url", required=True)
    parser.add_argument("--icon57-url", required=True)
    parser.add_argument("--icon512-url", required=True)
    parser.add_argument("--output", required=True, help="Output plist file path")
    return parser.parse_args()


def validate_non_empty(name: str, value: str) -> None:
    if not value or not value.strip():
        raise ValueError(f"{name} must not be empty")


def validate_https(name: str, value: str) -> None:
    if not value.startswith("https://"):
        raise ValueError(f"{name} must start with https://")


def build_manifest(
    app_name: str,
    bundle_id: str,
    bundle_version: str,
    ipa_url: str,
    icon57_url: str,
    icon512_url: str,
) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>{escape(ipa_url)}</string>
        </dict>
        <dict>
          <key>kind</key>
          <string>display-image</string>
          <key>url</key>
          <string>{escape(icon57_url)}</string>
        </dict>
        <dict>
          <key>kind</key>
          <string>full-size-image</string>
          <key>url</key>
          <string>{escape(icon512_url)}</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>{escape(bundle_id)}</string>
        <key>bundle-version</key>
        <string>{escape(bundle_version)}</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>{escape(app_name)}</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
"""


def main() -> int:
    args = parse_args()

    validate_non_empty("app_name", args.app_name)
    validate_non_empty("bundle_id", args.bundle_id)
    validate_non_empty("bundle_version", args.bundle_version)

    validate_https("ipa_url", args.ipa_url)
    validate_https("icon57_url", args.icon57_url)
    validate_https("icon512_url", args.icon512_url)

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        build_manifest(
            app_name=args.app_name.strip(),
            bundle_id=args.bundle_id.strip(),
            bundle_version=args.bundle_version.strip(),
            ipa_url=args.ipa_url.strip(),
            icon57_url=args.icon57_url.strip(),
            icon512_url=args.icon512_url.strip(),
        ),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
