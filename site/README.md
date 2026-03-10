# `site/` folder

This folder contains static files for GitHub Pages OTA install page:

- `index.html` - install page UI.
- `assets/icon57.png` and `assets/icon512.png` - public icons used in OTA manifest.
- `current.json` - current release metadata consumed by `index.html`.

`current.json` is replaced by the GitHub Actions workflow on each publish run, so the install page always points to the latest selected release.
