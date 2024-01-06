# wayprompt

![wayprompt](.meta/wayprompt.png)

Wayprompt is a multi-purpose (password-)prompt tool for Wayland.
Also has a TUI fallback mode for when no wayland connection can be established,
like when invoked while using a TTY.

Requires the compositor to support the layershell.

Wayprompt ships multiple executables:

* `wayprompt`: CLI prompt tool.
* `pinentry-wayprompt`: drop-in pinentry replacement, for example for gpg.

All executables use the same configuration file, read `wayprompt.5` for details.

To use `pinentry-wayprompt` with gpg, you need to configure gpg-agent (read
`gpg-agent.1`).
Its configuration file is commonly found at `~/.gnupg/gpg-agent.conf`.
Inside this file, add the following line (actual path to executable will depend
on installation method):
```
pinentry-program ~/.local/bin/pinentry-wayprompt
```


## Building

Wayprompt is developed against zig version 0.11.0 and depends on lib-wayland,
xkbcommon and pixman.

```sh
git clone https://git.sr.ht/~leon_plickat/wayprompt
cd wayprompt
git submodule update --init
zig build -Doptimize=ReleaseSafe --prefix ~/.local/ install
```


## Bug Reports & Contributions

Please send all bug reports and patches to
[~leon_plickat/public-inbox@lists.sr.ht](mailto:~leon_plickat/public-inbox@lists.sr.ht).


## License

wayprompt is licensed under the GPLv3.
