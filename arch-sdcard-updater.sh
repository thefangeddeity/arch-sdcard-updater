#!/usr/bin/env bash
# arch-sdcard-updater — space-aware incremental updater for Arch on SD cards
# Updates packages one at a time with adaptive sort and per-package timeouts.

set -euo pipefail

# ── Config file ───────────────────────────────────────────────────────────────

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/arch-sdcard-updater"
CONFIG_FILE="$CONFIG_DIR/config"

if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << 'EOF'
# arch-sdcard-updater configuration
# All changes take effect on next run.

# Stop updating when free space drops below this (MB)
SPACE_THRESHOLD_MB=200

# Survival mode: if free_space < smallest_package * SURVIVAL_MARGIN,
# switch to largest-first sort to maximize space recovered per install.
# Otherwise smallest-first to maximize number of packages updated.
SURVIVAL_MARGIN=2

# Timeout for repo package installs (minutes). Repo packages only download
# and install pre-built binaries — 5 min is generous.
TIMEOUT_REPO_MIN=5

# Timeout for AUR package builds (minutes). AUR packages may compile from
# source. webkit2gtk, chromium etc. can take 1-2h on slow hardware.
TIMEOUT_AUR_MIN=120
EOF
    echo "==> Config created at $CONFIG_FILE — edit to customize."
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# ── Logging setup ─────────────────────────────────────────────────────────────

LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/arch-sdcard-updater"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_SUCCESS="$LOG_DIR/success-$TIMESTAMP.log"
LOG_SKIP="$LOG_DIR/skip-$TIMESTAMP.log"
LOG_FAIL="$LOG_DIR/fail-$TIMESTAMP.log"
LOG_ORPHAN="$LOG_DIR/orphaned.log"

mkdir -p "$LOG_DIR"

# Packages that timed out — tracked for end-of-run advice
TIMED_OUT_PKGS=()
TIMED_OUT_TYPES=()

# ── Priority tiers ────────────────────────────────────────────────────────────

TIER1=(pacman glibc systemd systemd-libs filesystem)
TIER2=(linux linux-lts linux-zen linux-hardened mkinitcpio openssl gcc-libs libgcc)

# ── Helpers ───────────────────────────────────────────────────────────────────

log_success() { echo "$1" | tee -a "$LOG_SUCCESS"; }
log_skip()    { echo "$1" | tee -a "$LOG_SKIP";    }
log_fail()    { echo "$1" | tee -a "$LOG_FAIL";    }
log_orphan()  {
    if ! grep -qxF "$1" "$LOG_ORPHAN" 2>/dev/null; then
        echo "$1" >> "$LOG_ORPHAN"
    fi
}

count_lines() { [[ -f "$1" ]] && wc -l < "$1" || echo 0; }

free_mb() { df --output=avail -m / | tail -1 | tr -d ' '; }

check_space() {
    local free
    free=$(free_mb)
    if (( free < SPACE_THRESHOLD_MB )); then
        echo ""
        echo "==> STOPPING: free space ${free}MB below threshold ${SPACE_THRESHOLD_MB}MB"
        show_orphan_summary
        show_timeout_summary
        echo "==> Logs: $LOG_DIR"
        exit 0
    fi
}

is_orphan() { ! pacman -Si "$1" &>/dev/null && ! yay -Si "$1" &>/dev/null; }
is_aur()    { ! pacman -Si "$1" &>/dev/null; }

# ── Timed installer ───────────────────────────────────────────────────────────

run_with_timeout() {
    local pkg="$1"
    local timeout_min="$2"
    local is_aur_pkg="$3"
    local timeout_sec=$(( timeout_min * 60 ))

    if [[ "$is_aur_pkg" == "true" ]]; then
        yay -S --noconfirm --needed \
            --answerdiff=None --answerclean=None \
            --removemake --cleanafter \
            "$pkg" &
    else
        sudo pacman -S --noconfirm --needed "$pkg" &
    fi

    local child_pid=$!
    local elapsed=0

    while kill -0 "$child_pid" 2>/dev/null; do
        sleep 10
        elapsed=$(( elapsed + 10 ))
        if (( elapsed >= timeout_sec )); then
            echo ""
            echo "    TIMEOUT: $pkg exceeded ${timeout_min}min — killing"
            kill "$child_pid" 2>/dev/null
            wait "$child_pid" 2>/dev/null || true
            return 2
        fi
    done

    wait "$child_pid"
    return $?
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
        local rc
        run_with_timeout "$pkg" "$TIMEOUT_AUR_MIN" "true" && rc=$? || rc=$?
        if [[ $rc -eq 2 ]]; then
            log_fail "TIMEOUT [AUR] $pkg"
            TIMED_OUT_PKGS+=("$pkg")
            TIMED_OUT_TYPES+=("AUR")
        elif [[ $rc -eq 0 ]]; then
            log_success "OK [AUR] $pkg"
        else
            log_fail "ERR [AUR] $pkg"
        fi
    else
        local rc
        run_with_timeout "$pkg" "$TIMEOUT_REPO_MIN" "false" && rc=$? || rc=$?
        if [[ $rc -eq 2 ]]; then
            log_fail "TIMEOUT [repo] $pkg"
            TIMED_OUT_PKGS+=("$pkg")
            TIMED_OUT_TYPES+=("repo")
        elif [[ $rc -eq 0 ]]; then
            log_success "OK [repo] $pkg"
        else
            log_fail "ERR [repo] $pkg"
        fi
    fi
}

# ── Orphan summary ────────────────────────────────────────────────────────────

show_orphan_summary() {
    if [[ ! -f "$LOG_ORPHAN" ]] || [[ ! -s "$LOG_ORPHAN" ]]; then return; fi

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
        echo "    To investigate:          pacman -Qi <package-name>"
        echo "    To force-remove (risky): sudo pacman -Rns <package-name>"
    fi

    [[ -s "$LOG_ORPHAN" ]] || rm -f "$LOG_ORPHAN"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── Timeout summary ───────────────────────────────────────────────────────────

show_timeout_summary() {
    if [[ ${#TIMED_OUT_PKGS[@]} -eq 0 ]]; then return; fi

    echo ""
    echo "━━━ Timed-out packages ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "    These packages exceeded their timeout and were skipped."
    echo "    Run them alone when you have time:"
    echo ""
    for i in "${!TIMED_OUT_PKGS[@]}"; do
        local pkg="${TIMED_OUT_PKGS[$i]}"
        local type="${TIMED_OUT_TYPES[$i]}"
        if [[ "$type" == "AUR" ]]; then
            echo "      yay -S $pkg"
        else
            echo "      sudo pacman -S $pkg"
        fi
    done
    echo ""
    echo "    To increase timeout, edit $CONFIG_FILE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── Sync databases ───────────────────────────────────────────────────────────

echo "==> Syncing package databases..."
sudo pacman -Syy --noconfirm

# ── Keyring refresh (only if archlinux-keyring has an update) ────────────────

echo "==> Checking keyring..."
if pacman -Qu archlinux-keyring 2>/dev/null | grep -q archlinux-keyring; then
    echo "==> Keyring update available — refreshing..."
    sudo pacman -S --noconfirm archlinux-keyring
    sudo pacman-key --populate archlinux
else
    echo "==> Keyring up to date — skipping."
fi
echo "==> Collecting updatable packages..."
mapfile -t UPDATABLE < <({ pacman -Qu 2>/dev/null; yay -Qua --aur 2>/dev/null; } | awk '{print $1}' | sort -u)

if [[ ${#UPDATABLE[@]} -eq 0 ]]; then
    echo "==> Nothing to update."
    show_orphan_summary
    exit 0
fi

echo "==> ${#UPDATABLE[@]} package(s) have updates."

declare -A UPDATABLE_SET
for p in "${UPDATABLE[@]}"; do UPDATABLE_SET["$p"]=1; done

# ── Build queue: repo first (smallest to largest), then AUR (smallest to largest)
# Uses expac local db for sizes — covers both repo and AUR installed packages

UPDATABLE_LIST=" ${!UPDATABLE_SET[@]} "

# Get sizes for all updatable packages
SIZED_DATA=$(expac -Q '%m	%n' 2>/dev/null     | awk -v pkgs="$UPDATABLE_LIST" '{if (index(pkgs, " "$2" ")) print $1, $2}')

# Adaptive sort: survival mode if free space < smallest package * SURVIVAL_MARGIN
smallest_bytes=$(echo "$SIZED_DATA" | awk 'BEGIN{m=99999999999} $1+0>0 && $1+0<m {m=$1+0} END{print m+0}')
free_bytes=$(( $(free_mb) * 1024 * 1024 ))
survival_threshold=$(( smallest_bytes * SURVIVAL_MARGIN ))

if (( smallest_bytes > 0 && free_bytes < survival_threshold )); then
    SORT_FLAG="-rn"
    echo "==> SURVIVAL MODE: free space below ${SURVIVAL_MARGIN}x smallest package — sorting largest-first"
else
    SORT_FLAG="-n"
    echo "==> Coverage mode: sorting smallest-first for maximum package count"
fi

declare -a QUEUE=()
declare -A QUEUED=()

# Tier 1 first
for pkg in "${TIER1[@]}"; do
    if [[ -n "${UPDATABLE_SET[$pkg]+_}" ]]; then
        QUEUE+=("$pkg"); QUEUED["$pkg"]=1
    fi
done

# Tier 2 next
for pkg in "${TIER2[@]}"; do
    if [[ -n "${UPDATABLE_SET[$pkg]+_}" ]] && [[ -z "${QUEUED[$pkg]+_}" ]]; then
        QUEUE+=("$pkg"); QUEUED["$pkg"]=1
    fi
done

# Repo packages: smallest first, skip already queued
while IFS= read -r pkg; do
    if [[ -n "${UPDATABLE_SET[$pkg]+_}" ]] && [[ -z "${QUEUED[$pkg]+_}" ]] && pacman -Si "$pkg" &>/dev/null; then
        QUEUE+=("$pkg"); QUEUED["$pkg"]=1
    fi
done < <(echo "$SIZED_DATA" | sort $SORT_FLAG | awk '{print $2}')

# AUR packages: smallest first, skip already queued
while IFS= read -r pkg; do
    if [[ -n "${UPDATABLE_SET[$pkg]+_}" ]] && [[ -z "${QUEUED[$pkg]+_}" ]]; then
        QUEUE+=("$pkg"); QUEUED["$pkg"]=1
    fi
done < <(echo "$SIZED_DATA" | sort $SORT_FLAG | awk '{print $2}')

# ── Run the queue ─────────────────────────────────────────────────────────────

echo ""
echo "==> Update queue (${#QUEUE[@]} packages: repo first, then AUR, smallest-first within each):"
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
show_timeout_summary
