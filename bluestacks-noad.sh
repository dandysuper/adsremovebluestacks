#!/usr/bin/env bash
# =============================================================================
#  bluestacks-noad.sh — BlueStacks 5 / Air Ad Remover for macOS
#  Tested on BlueStacks 5.21.755.7538
#
#  What this script does:
#   Edits bluestacks.conf — every ad-related config key is set to "0".
#   The file is then locked (chflags uchg) so BlueStacks cannot overwrite it.
#
#  Undo / restore:
#   Run:  sudo bash bluestacks-noad.sh --restore
#
#  Requirements: macOS, sudo
# =============================================================================

set -euo pipefail

# ── paths ─────────────────────────────────────────────────────────────────────
CONF="/Users/Shared/Library/Application Support/BlueStacks/bluestacks.conf"
BACKUP_DIR="$HOME/.bluestacks-noad-backup"
CONF_BACKUP="$BACKUP_DIR/bluestacks.conf.orig"

# ── ad-related top-level keys to zero out ─────────────────────────────────────
CONF_PATCHES=(
    "bst.enable_programmatic_ads"
    "bst.enable_android_ads_test_app"
    "bst.feature.programmatic_ads"
    "bst.feature.send_programmatic_ads_boot_stats"
    "bst.feature.send_programmatic_ads_click_stats"
    "bst.feature.send_programmatic_ads_fill_stats"
    "bst.feature.show_gp_ads"
    "bst.feature.show_programmatic_ads_preference"
    "bst.feature.send_offer_stats"
    "bst.feature.ipi"
    "bst.feature.nowbux"
    "bst.feature.nowgg_login_popup"
    "bst.programmatic_android_ads_count"
)

# ── per-instance ad keys to zero out ─────────────────────────────────────────
# Format: key[:value]  — value defaults to "0" if omitted
CONF_INSTANCE_PATCHES=(
    "split_ad_enabled"
    "ads_screen_width"
    "ads_screen_width_percentage"
    "split_ad_show_times:-1"
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

ensure_backup_dir() {
    mkdir -p "$BACKUP_DIR"
    local real_user="${SUDO_USER:-$USER}"
    chown "$real_user" "$BACKUP_DIR"
}

# =============================================================================
#  CONFIG FILE PATCHING
# =============================================================================

patch_conf() {
    section "Config file patching"

    if [[ ! -f "$CONF" ]]; then
        warn "bluestacks.conf not found at:"
        warn "  $CONF"
        warn "Has BlueStacks been launched at least once? Skipping."
        return 0
    fi

    # Unlock in case it was previously locked
    chflags nouchg "$CONF" 2>/dev/null || true

    # Backup (only once — never overwrite a clean backup)
    if [[ ! -f "$CONF_BACKUP" ]]; then
        info "Backing up config to $CONF_BACKUP …"
        cp "$CONF" "$CONF_BACKUP"
        ok "Config backup saved."
    else
        info "Config backup already exists — skipping backup step."
    fi

    # Zero out top-level ad keys
    for key in "${CONF_PATCHES[@]}"; do
        if grep -q "^${key}=" "$CONF"; then
            sed -i '' "s|^${key}=.*|${key}=\"0\"|" "$CONF"
            info "  set  ${key}=\"0\""
        else
            echo "${key}=\"0\"" >> "$CONF"
            info "  added  ${key}=\"0\""
        fi
    done

    # Zero out per-instance ad keys for every discovered instance
    local instances
    instances=$(grep "^bst\.instance\." "$CONF" | sed 's/^bst\.instance\.\([^.]*\)\..*/\1/' | sort -u)

    for instance in $instances; do
        for entry in "${CONF_INSTANCE_PATCHES[@]}"; do
            key="${entry%%:*}"
            val="0"
            [[ "$entry" == *":"* ]] && val="${entry##*:}"
            full_key="bst.instance.${instance}.${key}"
            if grep -q "^${full_key}=" "$CONF"; then
                sed -i '' "s|^${full_key}=.*|${full_key}=\"${val}\"|" "$CONF"
                info "  set  ${full_key}=\"${val}\""
            fi
        done
    done

    # Lock the file so BlueStacks cannot overwrite our changes at runtime
    chflags uchg "$CONF"
    ok "Config patched and locked (chflags uchg)."
    warn "To change BlueStacks settings later, temporarily unlock first:"
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
#  APPLY / RESTORE / STATUS
# =============================================================================

print_banner() {
    echo -e "${CYN}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║       BlueStacks Ad Blocker — noad.sh        ║"
    echo "  ║         config lock (Layer 2 only)           ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${RST}"
}

do_apply() {
    print_banner
    require_root "apply"
    ensure_backup_dir
    patch_conf

    section "Done"
    ok "Config patch applied."
    echo ""
    echo -e "  ${GRN}Launch BlueStacks — ads will not be shown.${RST}"
    echo ""
    echo -e "  To revert:  ${YLW}sudo bash $0 --restore${RST}"
}

do_restore() {
    print_banner
    require_root "restore"
    restore_conf

    section "Done"
    ok "Config restored. BlueStacks is back to its original state."
}

do_status() {
    echo -e "${CYN}── bluestacks-noad status ──${RST}"

    if [[ -f "$CONF" ]]; then
        if ls -lO "$CONF" 2>/dev/null | grep -q uchg; then
            echo -e "  ${GRN}[✓]${RST} bluestacks.conf is locked (uchg)"
        else
            echo -e "  ${YLW}[!]${RST} bluestacks.conf is NOT locked"
        fi

        for key in "${CONF_PATCHES[@]}"; do
            val=$(grep "^${key}=" "$CONF" 2>/dev/null | cut -d= -f2 | tr -d '"')
            if [[ "$val" == "0" ]]; then
                echo -e "  ${GRN}[✓]${RST} ${key} = 0"
            elif [[ -z "$val" ]]; then
                echo -e "  ${YLW}[-]${RST} ${key} not found in config"
            else
                echo -e "  ${RED}[✗]${RST} ${key} = ${val}  ← ads may be active"
            fi
        done

        # Per-instance check
        local instances
        instances=$(grep "^bst\.instance\." "$CONF" | sed 's/^bst\.instance\.\([^.]*\)\..*/\1/' | sort -u)
        for instance in $instances; do
            for entry in "${CONF_INSTANCE_PATCHES[@]}"; do
                key="${entry%%:*}"
                expected_val="0"
                [[ "$entry" == *":"* ]] && expected_val="${entry##*:}"
                full_key="bst.instance.${instance}.${key}"
                val=$(grep "^${full_key}=" "$CONF" 2>/dev/null | cut -d= -f2 | tr -d '"')
                if [[ "$val" == "$expected_val" ]]; then
                    echo -e "  ${GRN}[✓]${RST} ${full_key} = ${val}"
                elif [[ -z "$val" ]]; then
                    echo -e "  ${YLW}[-]${RST} ${full_key} not found"
                else
                    echo -e "  ${RED}[✗]${RST} ${full_key} = ${val}  ← ads may be active"
                fi
            done
        done

        if [[ -f "$CONF_BACKUP" ]]; then
            echo -e "  ${GRN}[✓]${RST} Backup exists at $CONF_BACKUP"
        else
            echo -e "  ${YLW}[-]${RST} No backup found (patch not yet applied)"
        fi
    else
        echo -e "  ${YLW}[-]${RST} bluestacks.conf not found"
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
        echo "  sudo bash $0             # apply config patch (default)"
        echo "  sudo bash $0 --restore   # revert to original config"
        echo "  bash $0 --status         # show patch status (no sudo needed)"
        ;;
    *)
        err "Unknown argument: $1"
        echo "Run:  bash $0 --help"
        exit 1
        ;;
esac
