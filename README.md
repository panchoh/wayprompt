# wayprompt

A multi-purpose (password-)prompt tool for Wayland.
Also has a TUI fallback mode for when no wayland connection can be established,
like when invoked while using a TTY.

Installs multiple executables:

* `wayprompt`: CLI prompt tool.
* `pinentry-wayprompt`: drop-in pinentry replacement, for example for gpg.

All executables use the same configuration file.

Requires the compositor to support the layershell.
Depends on lib-wayland, xkbcommon and pixman.
Developed against zig version 10.1.

