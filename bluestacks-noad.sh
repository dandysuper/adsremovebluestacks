#!/usr/bin/env bash
# =============================================================================
#  bluestacks-noad.sh — BlueStacks 5 / Air Ad Remover for macOS
#  Tested on BlueStacks 5.21.755.7538 (ARM64)
#
#  What this script does:
#   1. Patches the BlueStacks binary — plrAdsInit(), cldGetCpmStarAds(),
#      cldGetCpiAds() are replaced with an immediate ARM64 ret so the ad
#      subsystem never initialises.
#   2. Edits bluestacks.conf — every ad-related config key is set to "0".
#      The file is then locked (chflags uchg) so BlueStacks cannot overwrite it.
#   3. Adds /etc/hosts entries — blocks the CpmStar ad-network and the
#      BlueStacks event-bus endpoint that pushes server-side ad feature flags.
#
#  Undo / restore:
#   Run:  sudo bash bluestacks-noad.sh --restore
#
#  Requirements: macOS, sudo, Python 3
# =============================================================================

set -euo pipefail

# ── paths ──────────────────────────────────────────────────────────────────────
BINARY="/Applications/BlueStacks.app/Contents/MacOS/BlueStacks"
CONF="/Users/Shared/Library/Application Support/BlueStacks/bluestacks.conf"
BACKUP_DIR="$HOME/.bluestacks-noad-backup"
BINARY_BACKUP="$BACKUP_DIR/BlueStacks.orig"
CONF_BACKUP="$BACKUP_DIR/bluestacks.conf.orig"
HOSTS_MARKER="# bluestacks-noad"
HOSTS="/etc/hosts"

# ── ARM64 file offsets (BlueStacks 5.21.755.7538) ─────────────────────────────
#   Derived from:  nm binary | grep <symbol>
#   Virtual address base for this Mach-O: 0x100000000
#   File offset = VA - 0x100000000
#
#   plrAdsInit        VA 0x100205bd0  →  offset 0x205bd0
#   initAdsWidth      VA 0x10000f8618 →  offset 0x0f8618  (not used — harmless)
#   cldGetCpmStarAds  VA 0x10039f72c  →  offset 0x039f72c
#   cldGetCpiAds      VA 0x10039f518  →  offset 0x039f518
PATCH_OFFSETS=(
    "0x205bd0:plrAdsInit"
    "0x39f72c:cldGetCpmStarAds"
    "0x39f518:cldGetCpiAds"
)

# ARM64 `ret` instruction  →  little-endian bytes: C0 03 5F D6
RET_BYTES='\xc0\x03\x5f\xd6'

# ── /etc/hosts entries to block ───────────────────────────────────────────────
HOSTS_ENTRIES=(
    "127.0.0.1  servedby.cpmstar.com"
    "127.0.0.1  static.cpmstar.com"
    "127.0.0.1  cdn.cpmstar.com"
    "127.0.0.1  media.cpmstar.com"
    # BlueStacks event-bus: pushes server-side feature flags that re-enable ads.
    # Blocking this keeps your local config in charge.
    "127.0.0.1  eb.bluestacks.com"
)

# ── ad-related keys in bluestacks.conf that must be zeroed ───────────────────
CONF_PATCHES=(
    "bst.enable_programmatic_ads"
    "bst.feature.programmatic_ads"
    "bst.feature.send_programmatic_ads_boot_stats"
    "bst.feature.send_programmatic_ads_click_stats"
    "bst.feature.send_programmatic_ads_fill_stats"
    "bst.feature.show_gp_ads"
    "bst.feature.show_programmatic_ads_preference"
    "bst.feature.send_offer_stats"
    "bst.feature.ipi"
)

# Per-instance keys (value appended after instance prefix, e.g. bst.instance.Tiramisu64.<key>)
CONF_INSTANCE_PATCHES=(
    "split_ad_enabled"
    "split_ad_show_times:-1"   # format  key:value  (default 0 unless overridden)
    "ads_screen_width:0"
    "ads_screen_width_percentage:0"
)

# ── colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; RST='\033[0m'
info()    { echo -e "${BLU}[*]${RST} $*"; }
ok()      { echo -e "${GRN}[✓]${RST} $*"; }
warn()    { echo -e "${YLW}[!]${RST} $*"; }
err()     { echo -e "${RED}[✗]${RST} $*" >&2; }
section() { echo -e "\n${CYN}── $* ──${RST}"; }

# =============================================================================
#  helpers
# =============================================================================

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run with sudo."
        echo "  sudo bash $0 ${1:-}"
        exit 1
    fi
}

bluestacks_running() {
    pgrep -x BlueStacks &>/dev/null
}

kill_bluestacks() {
    if bluestacks_running; then
        warn "BlueStacks is running — killing it now..."
        pkill -x BlueStacks || true
        sleep 2
        if bluestacks_running; then
            err "Could not stop BlueStacks. Please quit it manually and re-run."
            exit 1
        fi
        ok "BlueStacks stopped."
    fi
}

ensure_backup_dir() {
    mkdir -p "$BACKUP_DIR"
    # Owned by the calling user (SUDO_USER), not root
    local real_user="${SUDO_USER:-$USER}"
    chown "$real_user" "$BACKUP_DIR"
}

# =============================================================================
#  1. BINARY PATCHING
# =============================================================================

patch_binary() {
    section "Binary patching"

    if [[ ! -f "$BINARY" ]]; then
        err "Binary not found: $BINARY"
        exit 1
    fi

    # Backup (only once — never overwrite a clean backup with an already-patched copy)
    if [[ ! -f "$BINARY_BACKUP" ]]; then
        info "Backing up binary to $BINARY_BACKUP …"
        cp "$BINARY" "$BINARY_BACKUP"
        ok "Backup saved."
    else
        info "Binary backup already exists — skipping backup step."
    fi

    # Verify we are working on the right binary (size sanity check)
    local size
    size=$(stat -f%z "$BINARY")
    if (( size < 1000000 )); then
        err "Binary seems too small ($size bytes). Aborting to be safe."
        exit 1
    fi

    # Apply patches via Python (portable, no external deps)
    info "Applying ARM64 ret patches to ad functions…"

    python3 - "$BINARY" <<'PYEOF'
import sys, struct, os

binary_path = sys.argv[1]

# offset → label
patches = {
    0x205BD0: "plrAdsInit",
    0x39F72C: "cldGetCpmStarAds",
    0x39F518: "cldGetCpiAds",
}

# ARM64 ret = 0xD65F03C0, stored little-endian
RET = b'\xc0\x03\x5f\xd6'

with open(binary_path, 'r+b') as f:
    for offset, label in patches.items():
        f.seek(offset)
        original = f.read(4)
        if original == RET:
            print(f"  [already patched]  {label}  @ 0x{offset:x}")
            continue
        f.seek(offset)
        f.write(RET)
        print(f"  [patched]          {label}  @ 0x{offset:x}  "
              f"(was: {original.hex()} → {RET.hex()})")
PYEOF

    ok "Binary functions patched."

    # Remove old code signature (required after modifying the binary)
    info "Removing old code signature…"
    if codesign --remove-signature "$BINARY" 2>/dev/null; then
        ok "Old signature removed."
    else
        warn "codesign --remove-signature failed (may already be unsigned)."
    fi

    # Re-sign with an ad-hoc signature, always injecting the entitlements.plist
    # that ships alongside the binary.  Without com.apple.security.hypervisor
    # the virtualization engine cannot start and BlueStacks will crash on launch.
    local entitlements
    entitlements="$(dirname "$BINARY")/entitlements.plist"
    info "Re-signing with ad-hoc signature (entitlements: $entitlements)…"
    if [[ -f "$entitlements" ]]; then
        codesign -s - --force --entitlements "$entitlements" "$BINARY" || {
            err "Could not re-sign the binary. BlueStacks may refuse to launch."
            err "Restore with:  sudo bash $0 --restore"
            exit 1
        }
        ok "Binary re-signed (ad-hoc + entitlements)."
    else
        warn "entitlements.plist not found at $entitlements — signing without it."
        warn "BlueStacks may fail to start (missing hypervisor entitlement)."
        codesign -s - --force "$BINARY" || {
            err "Could not re-sign the binary."
            exit 1
        }
        ok "Binary re-signed (ad-hoc, no entitlements)."
    fi
}

restore_binary() {
    section "Restoring binary"

    if [[ ! -f "$BINARY_BACKUP" ]]; then
        err "No binary backup found at $BINARY_BACKUP"
        exit 1
    fi

    info "Restoring $BINARY from backup…"
    cp "$BINARY_BACKUP" "$BINARY"
    chown root:wheel "$BINARY"
    chmod 755 "$BINARY"

    info "Re-signing restored binary…"
    local entitlements
    entitlements="$(dirname "$BINARY")/entitlements.plist"
    if [[ -f "$entitlements" ]]; then
        codesign -s - --force --entitlements "$entitlements" "$BINARY" 2>/dev/null || true
    else
        codesign -s - --force "$BINARY" 2>/dev/null || true
    fi

    ok "Binary restored."
}

# =============================================================================
#  2. CONFIG FILE PATCHING
# =============================================================================

patch_conf() {
    section "Config file patching"

    if [[ ! -f "$CONF" ]]; then
        warn "bluestacks.conf not found at expected path:"
        warn "  $CONF"
        warn "Has BlueStacks been launched at least once? Skipping config patch."
        return 0
    fi

    # Unlock (in case we previously locked it)
    chflags nouchg "$CONF" 2>/dev/null || true

    # Backup
    if [[ ! -f "$CONF_BACKUP" ]]; then
        info "Backing up config to $CONF_BACKUP …"
        cp "$CONF" "$CONF_BACKUP"
        ok "Config backup saved."
    fi

    # Zero out top-level ad keys
    for key in "${CONF_PATCHES[@]}"; do
        if grep -q "^${key}=" "$CONF"; then
            sed -i '' "s|^${key}=.*|${key}=\"0\"|" "$CONF"
            info "  set  ${key}=\"0\""
        else
            # Key doesn't exist yet — add it
            echo "${key}=\"0\"" >> "$CONF"
            info "  added  ${key}=\"0\""
        fi
    done

    # Zero out per-instance ad keys for every instance that exists
    # Instance lines look like:  bst.instance.<name>.<key>="<value>"
    while IFS= read -r line; do
        # Extract instance name
        if [[ "$line" =~ ^bst\.instance\.([^.]+)\. ]]; then
            instance="${BASH_REMATCH[1]}"
            # Patch each instance-level ad key
            for entry in "${CONF_INSTANCE_PATCHES[@]}"; do
                key="${entry%%:*}"
                # Default replacement value is 0 unless a custom one is specified
                if [[ "$entry" == *":"* ]]; then
                    val="${entry##*:}"
                else
                    val="0"
                fi
                full_key="bst.instance.${instance}.${key}"
                if grep -q "^${full_key}=" "$CONF"; then
                    sed -i '' "s|^${full_key}=.*|${full_key}=\"${val}\"|" "$CONF"
                    info "  set  ${full_key}=\"${val}\""
                fi
            done
        fi
    done < <(grep "^bst\.instance\." "$CONF" | sort -u | sed 's/=.*//')

    # Lock the file so BlueStacks cannot overwrite our changes at runtime
    chflags uchg "$CONF"
    ok "Config patched and locked (chflags uchg)."
    warn "If you ever need to change BlueStacks settings, run:"
    warn "  sudo chflags nouchg \"$CONF\""
}

restore_conf() {
    section "Restoring config"

    if [[ ! -f "$CONF_BACKUP" ]]; then
        err "No config backup found at $CONF_BACKUP"
        exit 1
    fi

    chflags nouchg "$CONF" 2>/dev/null || true
    info "Restoring $CONF from backup…"
    cp "$CONF_BACKUP" "$CONF"
    ok "Config restored."
}

# =============================================================================
#  3. /etc/hosts PATCHING
# =============================================================================

patch_hosts() {
    section "/etc/hosts — blocking ad domains"

    # Remove any stale block we added before
    if grep -q "$HOSTS_MARKER" "$HOSTS"; then
        info "Removing existing bluestacks-noad hosts block…"
        sed -i '' "/$HOSTS_MARKER/,/$HOSTS_MARKER END/d" "$HOSTS"
    fi

    info "Adding host entries…"
    {
        echo ""
        echo "$HOSTS_MARKER — added by bluestacks-noad.sh — do not edit this block"
        for entry in "${HOSTS_ENTRIES[@]}"; do
            # Skip comment lines
            [[ "$entry" == \#* ]] && continue
            echo "$entry"
            info "  blocked  ${entry##* }"
        done
        echo "$HOSTS_MARKER END"
    } >> "$HOSTS"

    ok "/etc/hosts updated."

    # Flush DNS cache
    info "Flushing DNS cache…"
    dscacheutil -flushcache 2>/dev/null || true
    killall -HUP mDNSResponder 2>/dev/null || true
    ok "DNS cache flushed."
}

restore_hosts() {
    section "Restoring /etc/hosts"

    if grep -q "$HOSTS_MARKER" "$HOSTS"; then
        info "Removing bluestacks-noad hosts block…"
        sed -i '' "/$HOSTS_MARKER/,/$HOSTS_MARKER END/d" "$HOSTS"
        dscacheutil -flushcache 2>/dev/null || true
        killall -HUP mDNSResponder 2>/dev/null || true
        ok "/etc/hosts entries removed."
    else
        warn "No bluestacks-noad block found in /etc/hosts — nothing to remove."
    fi
}

# =============================================================================
#  APPLY / RESTORE dispatch
# =============================================================================

print_banner() {
    echo -e "${CYN}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║       BlueStacks Ad Blocker — noad.sh        ║"
    echo "  ║  binary patch + conf lock + hosts blocking   ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${RST}"
}

do_apply() {
    print_banner
    require_root "apply"
    kill_bluestacks
    ensure_backup_dir
    patch_binary
    patch_conf
    patch_hosts

    section "Done"
    ok "All three patches applied."
    echo ""
    echo -e "  ${GRN}You can now launch BlueStacks — ads will not be shown.${RST}"
    echo ""
    echo -e "  To revert everything:   ${YLW}sudo bash $0 --restore${RST}"
}

do_restore() {
    print_banner
    require_root "restore"
    kill_bluestacks
    restore_binary
    restore_conf
    restore_hosts

    section "Done"
    ok "All patches reverted. BlueStacks is back to its original state."
}

do_status() {
    echo -e "${CYN}── bluestacks-noad status ──${RST}"

    # Binary
    if [[ -f "$BINARY_BACKUP" ]]; then
        echo -e "  ${GRN}[✓]${RST} Binary backup present"
    else
        echo -e "  ${YLW}[-]${RST} Binary backup absent (patch not applied or already restored)"
    fi

    python3 - "$BINARY" 2>/dev/null <<'PYEOF'
import sys
RET = b'\xc0\x03\x5f\xd6'
patches = {0x205BD0: "plrAdsInit", 0x39F72C: "cldGetCpmStarAds", 0x39F518: "cldGetCpiAds"}
try:
    with open(sys.argv[1], 'rb') as f:
        for off, label in patches.items():
            f.seek(off)
            is_patched = f.read(4) == RET
            mark = "\033[0;32m[patched]\033[0m" if is_patched else "\033[0;33m[original]\033[0m"
            print(f"  {mark}  {label}")
except Exception as e:
    print(f"  [error reading binary: {e}]")
PYEOF

    # Config
    if [[ -f "$CONF" ]]; then
        if ls -lO "$CONF" 2>/dev/null | grep -q uchg; then
            echo -e "  ${GRN}[✓]${RST} bluestacks.conf is locked (uchg)"
        else
            echo -e "  ${YLW}[!]${RST} bluestacks.conf is not locked"
        fi
        local prog_val
        prog_val=$(grep "^bst.enable_programmatic_ads=" "$CONF" 2>/dev/null | cut -d= -f2 | tr -d '"')
        echo -e "  ${BLU}[i]${RST} bst.enable_programmatic_ads = ${prog_val:-<not found>}"
    else
        echo -e "  ${YLW}[-]${RST} bluestacks.conf not found"
    fi

    # Hosts
    if grep -q "$HOSTS_MARKER" "$HOSTS" 2>/dev/null; then
        echo -e "  ${GRN}[✓]${RST} /etc/hosts block present"
    else
        echo -e "  ${YLW}[-]${RST} /etc/hosts block absent"
    fi
}

# =============================================================================
#  Entry point
# =============================================================================

case "${1:-apply}" in
    --restore|-r|restore)
        do_restore
        ;;
    --status|-s|status)
        do_status
        ;;
    --apply|-a|apply|"")
        do_apply
        ;;
    --help|-h|help)
        echo "Usage:"
        echo "  sudo bash $0             # apply all patches (default)"
        echo "  sudo bash $0 --restore   # revert everything"
        echo "  bash $0 --status         # show patch status (no sudo needed)"
        ;;
    *)
        err "Unknown argument: $1"
        echo "Run:  bash $0 --help"
        exit 1
        ;;
esac
