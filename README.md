# arch-sdcard-updater

A space-aware incremental package updater for Arch Linux on SD cards and other space-constrained storage.

## Why

`pacman -Syu` fails with "not enough disk space" on small drives. This script updates packages one at a time, largest first, stopping gracefully when free space drops below a configurable threshold.

## Features

- Updates largest packages first to maximize gains before space runs out
- Priority tiers: critical packages (glibc, systemd, pacman) always update first
- Detects and auto-removes orphaned packages with no dependents
- Flags orphans still required by other packages, with instructions
- Refreshes the keyring before every run to avoid PGP signature failures
- Logs successes, skips, and failures separately per run
- AUR support via yay, fully non-interactive

## Requirements

- `yay`
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

# Add sdupdate alias to your shell rc
SHELL_RC=""
if [[ -f ~/.zshrc ]]; then
    SHELL_RC=~/.zshrc
elif [[ -f ~/.bashrc ]]; then
    SHELL_RC=~/.bashrc
fi

if [[ -n "$SHELL_RC" ]]; then
    echo 'alias sdupdate="arch-sdcard-updater"' >> "$SHELL_RC"
    echo "Added alias to $SHELL_RC — restart your shell or source it"
else
    echo "Could not detect shell rc — add alias manually"
fi
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
