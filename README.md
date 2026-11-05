# bar-rewind-worker

Parses [Beyond All Reason](https://www.beyondallreason.info/) replays into [BAR-Rewind](https://github.com/burnhamrobertp/BAR-Rewind)
`.curves` files for [bar-rewind-server](https://github.com/burnhamrobertp/bar-rewind-server), on volunteered machines.
It enrolls with the server once, then claims jobs, runs BAR-Rewind's parser, uploads the result and keeps itself
up to date, unattended.

## Running one

Needs BAR installed on the same machine: the worker seeds a BAR data folder of its own with an engine from it.

1. Download `bar-rewind-worker.exe` (Windows) or `bar-rewind-worker-linux` (Linux) from the
   [latest release](https://github.com/burnhamrobertp/bar-rewind-worker/releases/latest).
2. Run `bar-rewind-worker install`. It picks a random id (a UUID), shows a code and opens the server's site,
   where you sign in with Discord and approve it. The server lists it by that id and the Discord account that
   approved it. From then on it starts at logon (a scheduled task on Windows, a systemd user unit on Linux)
   and runs in the background; neither needs admin rights.
3. Pause, resume, limit or remove it on the site's Workers page.

`bar-rewind-worker uninstall` stops it running unattended. With no command it runs in the foreground until
stopped, which is handy for watching what it does.

| | |
|-|-|
| `--server <url>` | the server to work for (default `https://bar-rewind.robotofham.com`) |
| `--bake <path>` | parse with this `bake` instead of the release the server pins |

## Staying out of the way

- No new job while BAR is running, or while less than 4 GB of memory or 10 GB of disk is free.
- Parses run at below-normal priority, and on Windows a parse's whole process tree goes when the worker does.
- Engines no parse has used for 30 days are deleted, except the newest. Games and maps stay.
- The server hands it only replays that fit its memory, once a few parses have reported their peak memory.

## Files it keeps

In `%LOCALAPPDATA%\bar-rewind-worker` (Windows) or `~/.local/share/bar-rewind-worker` (Linux):

- `worker.json`: the server it enrolled with, its id and its token there (on Windows sealed with DPAPI, so
  only your account on this machine can read it)
- `bin/`: the installed copy; `parsers/`: the parser releases it downloaded
- `bar/`: its own BAR data folder, used only for parsing; `work/`: the job in progress
- `worker.log` and `worker.log.1`: the current and previous background run

## Updates

The server pins the worker and parser releases every worker runs. A release counts only when its
`manifest.json` is signed by the release key built into the worker, names the pinned version, and lists the
downloaded file's size and hash. An admin may pin an older release to roll back.

## Build from source

Needs [Zig](https://ziglang.org/) 0.17.

```sh
zig build                          # zig-out/bin/bar-rewind-worker
zig build run -- --server <url>    # run in the foreground
zig build test
zig build dist                     # Windows and Linux, in zig-out/dist
```

Pushing a version tag (like `0.1.0`) builds a release: GitHub Actions tests, builds `dist` with that version and the key in
`src/release-key.pub`, signs a `manifest.json` with BAR-Rewind's sign tool and publishes the release. The private
key lives in the repo's `release` environment and is the same one BAR-Rewind's releases are signed with.

AI disclosure: written with assistance from Claude Code.

## License

GPL-2.0 (see `LICENSE`), like BAR-Rewind.
