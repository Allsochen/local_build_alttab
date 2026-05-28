# local_build_alttab

**English** | [简体中文](./README.zh-CN.md)

A one-shot script that builds and installs [AltTab](https://github.com/lwouis/alt-tab-macos) (a Windows-style switcher for macOS) from source.

The script automatically:

1. Clones (or updates) the `lwouis/alt-tab-macos` repository
2. Generates and trusts a local `Local Self-Signed` code-signing certificate
3. Fills in the Info.plist placeholders required by `config/local.xcconfig`
4. Builds the Debug configuration with `xcodebuild`
5. If a previous `AltTab.app` is detected, prompts you (y/N) to remove it and reset its TCC permissions (Accessibility / Screen Recording / Input Monitoring, …). On non-interactive runs the previous install is kept by default — pass `--force-reset` to wipe without prompting.
6. Installs to `/Applications` (falls back to `~/Applications` if not writable)
7. **Automatically flips the Debug binary into Pro state** (mirrors the in-app Debug "Pro" QA button), so the activation window never shows up.

---

## Requirements

- macOS
- Full **Xcode** installed (Command Line Tools alone are not enough), launched at least once to accept the license
- Network access to GitHub

### If Xcode is not installed yet

The script detects Xcode at runtime and prompts you if it's missing. You can also install it manually:

1. **Install Xcode from the Mac App Store** (free, ~10 GB):

   ```bash
   open 'macappstore://apps.apple.com/app/xcode/id497799835'
   ```

2. **Launch Xcode once** and accept the license agreement (a dialog appears on first launch). Wait for the additional components to finish installing.

3. **Point the command-line toolchain at Xcode** (important, otherwise `xcodebuild` cannot find the tools):

   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   ```

4. **Verify the installation**:

   ```bash
   xcodebuild -version
   # Expected output, similar to:
   # Xcode 15.x
   # Build version ...
   ```

> If only the Command Line Tools are installed, `xcodebuild` will be missing or point to the wrong path. The script's preflight check reports the issue and suggests the fix.

### If `git` is also missing

`git` ships with the Xcode Command Line Tools. When the script detects it is missing, it offers to trigger:

```bash
xcode-select --install
```
After the GUI installer finishes, re-run the script.

---

## One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/Allsochen/local_build_alttab/main/build.sh | bash
```

During execution macOS may show 1–2 Keychain password prompts to import and trust the local self-signed certificate. Just enter your login password.

> If a previous `AltTab.app` is detected, the script will ask whether to remove it and reset its system permissions. Note that `curl … | bash` is **not** an interactive TTY, so the prompt would be skipped. To make sure the prompt appears, download the script first (see [Common options](#common-options)) or use:
>
> ```bash
> bash -c "$(curl -fsSL https://raw.githubusercontent.com/Allsochen/local_build_alttab/main/build.sh)"
> ```
>
> The first time you launch a freshly-wiped AltTab, macOS asks for the **Accessibility** permission (and possibly Screen Recording / Input Monitoring) — grant them as prompted.

---

## Common options

To customize behavior, download the script first and then run it:

```bash
curl -fsSLO https://raw.githubusercontent.com/Allsochen/local_build_alttab/main/build.sh
chmod +x build.sh

./build.sh                                  # Default: clone/update + build + install + auto-Pro
./build.sh --no-update                      # Skip git pull, build current HEAD
./build.sh --skip-codesign                  # Reuse an existing signing identity
./build.sh --force-reset                    # Auto-wipe previous install + TCC permissions (no prompt)
./build.sh --keep-permissions               # Auto-keep previous install + permissions (no prompt)
./build.sh --repo-dir ~/code/alt-tab-macos  # Custom source directory
./build.sh --dest ~/Applications            # Custom install directory
./build.sh --help                           # Full help
```

Default parameters:

| Parameter   | Default                                                          |
| ----------- | ---------------------------------------------------------------- |
| `REPO_URL`  | `https://github.com/lwouis/alt-tab-macos.git`                    |
| `REPO_DIR`  | `~/alt-tab-macos`                                                |
| `DEST_DIR`  | `/Applications` (falls back to `~/Applications` if not writable) |

---

## Auto-activated Pro on Debug builds

AltTab ships with a paid **Pro** tier. On a freshly-built Debug binary the in-app QA menu has a "Pro" button that flips the local license state to Pro for development purposes. The script performs the exact same operation from the command line right after install, so the app boots straight into Pro state — no activation window pops up.

What it writes (mirrors `LicenseManager.mockProUser()` in [`src/pro/license/LicenseManager.swift`](https://github.com/lwouis/alt-tab-macos/blob/master/src/pro/license/LicenseManager.swift)):

| Storage                              | Key / account          | Value                            |
| ------------------------------------ | ---------------------- | -------------------------------- |
| Keychain (`com.lwouis.alt-tab-macos.license`) | `licenseKey`   | `MOCK-PRO-LICENSE-KEY`           |
| Keychain                             | `instanceId`           | `mock-instance-id`               |
| UserDefaults (`com.lwouis.alt-tab-macos.license`) | `lastValidation`       | current epoch                    |
| UserDefaults                         | `lastValidationResult` | `true`                           |
| UserDefaults                         | `customerEmail`        | `john@cool-software.com`         |

> **Important — this only makes sense for local Debug builds.** The `mockProUser()` code path is wrapped in `#if DEBUG`. Do not use this against a release/distributed binary; if you want Pro on a Release build, [buy a license](https://alt-tab-macos.netlify.app/) and let the script's normal flow activate it.

To revert to the normal trial flow:

```bash
security delete-generic-password -s com.lwouis.alt-tab-macos.license -a licenseKey
security delete-generic-password -s com.lwouis.alt-tab-macos.license -a instanceId
defaults delete com.lwouis.alt-tab-macos.license
```

---

## Uninstall

```bash
# Remove the app bundle(s)
rm -rf /Applications/AltTab.app ~/Applications/AltTab.app

# Revoke previously-granted system permissions (best-effort; ignore errors)
for svc in Accessibility ScreenCapture ListenEvent PostEvent \
           AppleEvents Microphone Camera SystemPolicyAllFiles; do
  tccutil reset "$svc" com.lwouis.alt-tab-macos 2>/dev/null || true
done
```

To also clean up the source and build artifacts:

```bash
rm -rf ~/alt-tab-macos
```
