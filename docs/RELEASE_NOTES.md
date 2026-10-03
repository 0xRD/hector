## Install

1. Download **Hector-{{VERSION}}-macOS.zip** below and open it.
2. Move **Hector.app** to your Applications folder.
3. Open it. Hector is not notarized by Apple (that needs a paid developer account), so macOS refuses the first launch:
   - open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the Hector message;
   - or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Hector.app`
4. To block destinations, open **Blocklists** and click **Install helper…**. macOS asks for an administrator password once.

Hector runs on macOS 15 or later, on Apple silicon and Intel.

The command-line tool ships inside the app. To use it from a terminal:

```
sudo mkdir -p /usr/local/bin && sudo ln -sf /Applications/Hector.app/Contents/Helpers/hector /usr/local/bin/hector
```

## Uninstall

Choose **Hector → Uninstall Hector…** in the menu bar. It removes every rule, the helper and its logs, your blocklist, the country database, preferences, caches and the VirusTotal key, then moves the app to the Trash. macOS asks for an administrator password once.

## Verify the download

SHA-256 of the zip: `{{SHA256}}`

```
shasum -a 256 Hector-{{VERSION}}-macOS.zip
```

The app is built by GitHub Actions from the tagged source, with the workflow in `.github/workflows/release.yml`.
