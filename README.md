# BlueStacks Ad Blocker — `bluestacks-noad.sh`

Removes the ad sidebar from **BlueStacks 5 / BlueStacks Air** on macOS by applying three independent layers of blocking. Any one layer alone would reduce ads; all three together make them completely gone and resistant to server-side re-enabling.

Tested on **BlueStacks 5.21.755.7538 (ARM64, macOS)**.

---

## How it works

### Layer 1 — Binary patch

Three C++ functions inside the BlueStacks binary are replaced with an immediate ARM64 `ret` instruction so they return before doing anything:

| Function | What it does |
|---|---|
| `plrAdsInit` | Initialises the entire ad subsystem at startup |
| `cldGetCpmStarAds` | Fetches banner ads from the CpmStar ad network |
| `cldGetCpiAds` | Fetches CPI (cost-per-install) interstitial ads |

The binary is re-signed with an ad-hoc signature so macOS will still launch it.

### Layer 2 — Config file patch

`/Users/Shared/Library/Application Support/BlueStacks/bluestacks.conf` is edited to set every ad-related key to `"0"`:

```
bst.enable_programmatic_ads          → "0"
bst.feature.programmatic_ads         → "0"
bst.feature.show_gp_ads              → "0"
bst.feature.send_programmatic_ads_*  → "0"
bst.instance.<name>.split_ad_enabled → "0"
bst.instance.<name>.ads_screen_width → "0"
… and more
```

The file is then **locked** with `chflags uchg` so BlueStacks cannot overwrite it at runtime.

### Layer 3 — `/etc/hosts` block

Known ad-serving and telemetry domains are redirected to `127.0.0.1`:

| Domain | Purpose |
|---|---|
| `servedby.cpmstar.com` | CpmStar ad delivery |
| `static.cpmstar.com` | CpmStar static assets |
| `cdn.cpmstar.com` | CpmStar CDN |
| `media.cpmstar.com` | CpmStar media |
| `eb.bluestacks.com` | BlueStacks event-bus — pushes server-side feature flags that can re-enable ads |

---

## Requirements

- macOS (Apple Silicon or Intel)
- BlueStacks 5 installed at `/Applications/BlueStacks.app`
- Python 3 (pre-installed on macOS)
- `sudo` access

---

## Usage

### 1. Verify offsets (optional but recommended)

Run the verification script first — it confirms the patch offsets match your exact binary without modifying anything:

```sh
python3 verify_offsets.py
```

Expected output:

```
  0x0205bd0  plrAdsInit              [original code: ff8305d1]
  0x039f518  cldGetCpiAds            [original code: ffc304d1]
  0x039f72c  cldGetCpmStarAds        [original code: ff0307d1]

[✓] All offsets look valid — safe to run bluestacks-noad.sh
```

If any offset shows `[SUSPICIOUS]` or `[FAIL]`, **stop** — your BlueStacks version differs from the one this script was written for. See [Different BlueStacks version](#different-bluestacks-version) below.

### 2. Apply the patch

```sh
sudo bash bluestacks-noad.sh
```

BlueStacks must not be running when you do this (the script kills it automatically if it is).

### 3. Launch BlueStacks

Start BlueStacks normally. The left ad panel will be gone.

---

## Undo / restore

To completely revert all three layers:

```sh
sudo bash bluestacks-noad.sh --restore
```

This restores the original binary from backup, restores the original `bluestacks.conf`, and removes the `/etc/hosts` entries.

---

## Check current status

No `sudo` needed:

```sh
bash bluestacks-noad.sh --status
```

---

## Changing BlueStacks settings after patching

Because `bluestacks.conf` is locked, the BlueStacks settings UI may not save some preferences. Temporarily unlock it before opening Settings, then lock it again:

```sh
sudo chflags nouchg "/Users/Shared/Library/Application Support/BlueStacks/bluestacks.conf"
# … change your settings in BlueStacks …
sudo chflags uchg "/Users/Shared/Library/Application Support/BlueStacks/bluestacks.conf"
```

---

## Different BlueStacks version

The binary patch targets **specific byte offsets** that were extracted from BlueStacks `5.21.755.7538`. If you have a different build the offsets will be wrong.

To find the correct offsets for your version:

```sh
# 1. Get the virtual addresses
nm /Applications/BlueStacks.app/Contents/MacOS/BlueStacks 2>/dev/null \
  | grep -E 'plrAdsInit|cldGetCpmStar|cldGetCpi'

# Expected output looks like:
#   0000000100205bd0 T __Z10plrAdsInit...
#   000000010039f518 T __Z12cldGetCpiAds...
#   000000010039f72c T __Z16cldGetCpmStarAds...

# 2. Convert VA → file offset:
#    file_offset = VA - 0x100000000
#    e.g. 0x100205bd0 - 0x100000000 = 0x205bd0
```

Then update the `PATCH_OFFSETS` array and the `PATCHES` dict in `verify_offsets.py` accordingly.

---

## Backups

Everything is backed up before any modification:

| Backup location | Original file |
|---|---|
| `~/.bluestacks-noad-backup/BlueStacks.orig` | The unmodified binary |
| `~/.bluestacks-noad-backup/bluestacks.conf.orig` | The unmodified config |

These are created only once — subsequent runs of the script will not overwrite a clean backup with an already-patched copy.

---

## Files

| File | Description |
|---|---|
| `bluestacks-noad.sh` | Main script — apply / restore / status |
| `verify_offsets.py` | Read-only offset sanity checker |
| `README.md` | This file |