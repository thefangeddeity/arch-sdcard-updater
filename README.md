# arch-sdcard-updater

A space-aware incremental package updater for Arch Linux on SD cards and other space-constrained storage.

## Why

`pacman -Syu` fails with "not enough disk space" on small drives. This script updates packages one at a time, stopping gracefully when free space drops below a configurable threshold.

Works on any space-constrained drive — SD cards, USB sticks, external HDDs. Also useful when a neglected Arch install has a mess of stale keys causing PGP signature failures: the keyring is refreshed automatically at the start of every run.

## Features

- Updates packages one at a time — largest first by default, smallest-first in coverage mode
- Priority tiers: critical packages (glibc, systemd, pacman) always update first
- Adaptive sort: coverage mode (smallest-first) by default; survival mode (largest-first) when free space is critically low
- Per-package timeouts: 5 min for repo packages, 120 min for AUR builds
- SSH resilience: auto-relaunches inside a named tmux session when run over SSH; survives disconnects
- `--skip-heavy` flag: skips AUR packages above a configurable installed size threshold (default 500MB)
- Config backfill: missing config keys are added automatically on upgrade — no manual migration needed
- Detects and auto-removes orphaned packages with no dependents
- Flags orphans still required by other packages, with instructions
- Refreshes the keyring before every run to avoid PGP signature failures
- Logs successes, skips, and failures separately per run
- AUR support via yay, fully non-interactive

## Requirements

- `yay`
- `tmux`
- `bash` 4+

## Install

### Via AUR (recommended)

```bash
yay -S arch-sdcard-updater
```

Both `arch-sdcard-updater` and `sdupdate` are available immediately — no further setup needed.

### Manual (clone and install)

```bash
git clone https://github.com/thefangeddeity/arch-sdcard-updater.git
cd arch-sdcard-updater
install -Dm755 arch-sdcard-updater.sh ~/.local/bin/arch-sdcard-updater
```

## Usage

```bash
sdupdate                # update everything
sdupdate --skip-heavy  # skip AUR packages above HEAVY_THRESHOLD_MB
```

## Configuration

Config file is auto-created at `~/.config/arch-sdcard-updater/config` on first run.

- `SPACE_THRESHOLD_MB` — stop when free space drops below this (default: 200)
- `SURVIVAL_MARGIN` — switch to largest-first when free space < smallest package × this (default: 2)
- `TIMEOUT_REPO_MIN` — per-package timeout for repo installs in minutes (default: 5)
- `TIMEOUT_AUR_MIN` — per-package timeout for AUR builds in minutes (default: 120)
- `HEAVY_THRESHOLD_MB` — installed size threshold for `--skip-heavy` in MB (default: 500)

## License

GPL-3.0
