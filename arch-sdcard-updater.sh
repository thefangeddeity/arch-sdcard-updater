#!/usr/bin/env bash
# arch-sdcard-update — space-aware incremental updater for Arch on SD card
# Updates packages one at a time: priority tiers first, then largest-first.
# Stops gracefully when free disk space drops below SPACE_THRESHOLD_MB.

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

SPACE_THRESHOLD_MB=200          # stop if free space drops below this
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/arch-sdcard-update"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_SUCCESS="$LOG_DIR/success-$TIMESTAMP.log"
LOG_SKIP="$LOG_DIR/skip-$TIMESTAMP.log"
LOG_FAIL="$LOG_DIR/fail-$TIMESTAMP.log"
LOG_ORPHAN="$LOG_DIR/orphaned.log"          # persistent across runs

# Tier 1: must update first or mid-session breakage is likely
TIER1=(pacman glibc systemd systemd-libs filesystem)

# Tier 2: high-risk if version-mismatched with rest of system
TIER2=(linux linux-lts linux-zen linux-hardened mkinitcpio openssl gcc-libs libgcc)

# ── Setup ────────────────────────────────────────────────────────────────────

mkdir -p "$LOG_DIR"

log_success() { echo "$1" | tee -a "$LOG_SUCCESS"; }
log_skip()    { echo "$1" | tee -a "$LOG_SKIP";    }
log_fail()    { echo "$1" | tee -a "$LOG_FAIL";    }
log_orphan()  {
    # Only append if not already in the persistent list
    if ! grep -qxF "$1" "$LOG_ORPHAN" 2>/dev/null; then
        echo "$1" >> "$LOG_ORPHAN"
    fi
}

count_lines() {
    [[ -f "$1" ]] && wc -l < "$1" || echo 0
}

free_mb() {
    df --output=avail -m / | tail -1 | tr -d ' '
}

check_space() {
    local free
    free=$(free_mb)
    if (( free < SPACE_THRESHOLD_MB )); then
        echo ""
        echo "==> STOPPING: free space ${free}MB is below threshold ${SPACE_THRESHOLD_MB}MB"
        echo "==> See logs in $LOG_DIR"
        show_orphan_summary
        exit 0
    fi
}

is_orphan() {
    # Orphaned = not findable in any sync db AND not in AUR
    ! pacman -Si "$1" &>/dev/null && ! yay -Si "$1" &>/dev/null
}

is_aur() {
    # AUR = not in any sync db (but findable via yay)
    ! pacman -Si "$1" &>/dev/null
}

do_update() {
    local pkg="$1"
    echo ""
    echo "==> [$( free_mb )MB free] Updating: $pkg"
    check_space

    if is_orphan "$pkg"; then
        echo "    ORPHAN: $pkg not found in repos or AUR — skipping"
        log_orphan "$pkg"
        return
    fi

    if is_aur "$pkg"; then
        if yay -S --noconfirm --needed \
               --answerdiff=None --answerclean=None \
               --removemake --cleanafter \
               "$pkg" 2>&1; then
            log_success "OK  [AUR] $pkg"
        else
            log_fail   "ERR [AUR] $pkg"
        fi
    else
        local output
        if output=$(sudo pacman -S --noconfirm --needed "$pkg" 2>&1); then
            if echo "$output" | grep -q "is up to date"; then
                log_skip "SKIP [repo] $pkg"
            else
                log_success "OK   [repo] $pkg"
            fi
        else
            log_fail "ERR  [repo] $pkg"
        fi
    fi
}

show_orphan_summary() {
    if [[ ! -f "$LOG_ORPHAN" ]] || [[ ! -s "$LOG_ORPHAN" ]]; then
        return
    fi

    declare -a SAFE=()
    declare -a BLOCKED=()

    while IFS= read -r pkg; do
        local required_by
        required_by=$(pacman -Qi "$pkg" 2>/dev/null | awk '/^Required By/{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | xargs)
        if [[ "$required_by" == "None" ]] || [[ -z "$required_by" ]]; then
            SAFE+=("$pkg")
        else
            BLOCKED+=("$pkg : required by $required_by")
        fi
    done < "$LOG_ORPHAN"

    echo ""
    echo "━━━ Orphaned packages ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ ${#SAFE[@]} -gt 0 ]]; then
        echo "    Removing safe orphans (no dependents)..."
        for pkg in "${SAFE[@]}"; do
            echo "      removing $pkg"
            if sudo pacman -Rns --noconfirm "$pkg" 2>&1; then
                sed -i "/^${pkg}$/d" "$LOG_ORPHAN"
            else
                echo "      WARNING: could not remove $pkg — left in orphan list"
            fi
        done
    fi

    if [[ ${#BLOCKED[@]} -gt 0 ]]; then
        echo ""
        echo "    Blocked orphans (still required by other packages):"
        echo "    Update or remove their dependents first, then re-run."
        echo ""
        for entry in "${BLOCKED[@]}"; do
            echo "    • $entry"
        done
        echo ""
        echo "    To investigate:"
        echo "      pacman -Qi <package-name>"
        echo "    To force-remove anyway (risky):"
        echo "      sudo pacman -Rns <package-name>"
    fi

    [[ -s "$LOG_ORPHAN" ]] || rm -f "$LOG_ORPHAN"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── Keyring refresh ───────────────────────────────────────────────────────────

echo "==> Refreshing keyring..."
sudo pacman -Sy --noconfirm archlinux-keyring
sudo pacman-key --populate archlinux

# ── Sync and collect updatable packages ──────────────────────────────────────

echo "==> Syncing package databases..."
sudo pacman -Syy --noconfirm

echo "==> Collecting updatable packages..."

mapfile -t UPDATABLE < <(yay -Qua 2>/dev/null | awk '{print $1}')

if [[ ${#UPDATABLE[@]} -eq 0 ]]; then
    echo "==> Nothing to update."
    show_orphan_summary
    exit 0
fi

echo "==> ${#UPDATABLE[@]} package(s) have updates."

declare -A UPDATABLE_SET
for p in "${UPDATABLE[@]}"; do
    UPDATABLE_SET["$p"]=1
done

# ── Build priority-ordered queue ─────────────────────────────────────────────

declare -a QUEUE=()
declare -A QUEUED=()

for pkg in "${TIER1[@]}"; do
    if [[ -n "${UPDATABLE_SET[$pkg]+_}" ]]; then
        QUEUE+=("$pkg")
        QUEUED["$pkg"]=1
    fi
done

for pkg in "${TIER2[@]}"; do
    if [[ -n "${UPDATABLE_SET[$pkg]+_}" ]] && [[ -z "${QUEUED[$pkg]+_}" ]]; then
        QUEUE+=("$pkg")
        QUEUED["$pkg"]=1
    fi
done

mapfile -t SIZED < <(
    LC_ALL=C yay -Qi "${!UPDATABLE_SET[@]}" 2>/dev/null \
    | awk '
        /^Name/          { name=$3 }
        /^Installed Size/ {
            val=$4; unit=$5
            if      (unit ~ /GiB/) kb = val * 1024 * 1024
            else if (unit ~ /MiB/) kb = val * 1024
            else if (unit ~ /KiB/) kb = val
            else                   kb = val / 1024
            print kb, name
        }
    ' \
    | sort -rn \
    | awk '{print $2}'
)

for pkg in "${SIZED[@]}"; do
    if [[ -n "${UPDATABLE_SET[$pkg]+_}" ]] && [[ -z "${QUEUED[$pkg]+_}" ]]; then
        QUEUE+=("$pkg")
        QUEUED["$pkg"]=1
    fi
done

# ── Run the queue ─────────────────────────────────────────────────────────────

echo ""
echo "==> Update queue (${#QUEUE[@]} packages):"
printf '    %s\n' "${QUEUE[@]}"
echo ""

for pkg in "${QUEUE[@]}"; do
    do_update "$pkg"
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "==> Done. Summary:"
echo "    Success : $(count_lines "$LOG_SUCCESS")"
echo "    Skipped : $(count_lines "$LOG_SKIP")"
echo "    Failed  : $(count_lines "$LOG_FAIL")"
echo "    Free now: $( free_mb )MB"
echo "    Logs    : $LOG_DIR"

show_orphan_summary
