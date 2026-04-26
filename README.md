# arch-sdcard-updater

A space-aware incremental package updater for Arch Linux on SD cards and other space-constrained storage.

## Why

`pacman -Syu` fails with "not enough disk space" on small drives. This script updates packages one at a time, largest first, stopping gracefully when free space drops below a configurable threshold.

## Features

- Updates largest packages first to maximize gains before space runs out
- Priority tiers: critical packages (glibc, systemd, pacman) always update first
- Detects and auto-removes orphaned packages with no dependents
- Flags orphans that are still required by other packages, with instructions
- Refreshes the keyring before every run to avoid PGP signature failures
- Logs successes, skips, and failures separately per run
- AUR support via yay, fully non-interactive

## Requirements

- `yay`
- `bash` 4+
- 256-color terminal (optional, for output)

## Install

```bash
install -Dm755 arch-sdcard-updater.sh ~/.local/bin/arch-sdcard-updater
echo 'alias sdupdate="arch-sdcard-updater"' >> ~/.zshrc
source ~/.zshrc
```

## Usage

```bash
sdupdate
```

## Configuration

Edit the variables at the top of the script:

- `SPACE_THRESHOLD_MB` — stop when free space drops below this (default: 200)

## License

GPL-3.0
