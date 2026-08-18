# Distribute cocod as a standalone Arch package

`cocod` is compiled as a standalone executable and distributed separately as an Arch/AUR package, provisionally named `cocod-bin`, which owns the binary and systemd user-service template. This avoids requiring Bun at runtime or embedding executable dependencies in a Git-installed Omarchy plugin, keeps daemon upgrades independent, and lets the Wallet Client require a compatible API range.
