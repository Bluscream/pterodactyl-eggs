# Arma 2: Operation Arrowhead (Linux) Pterodactyl Egg

> **Status: draft, never started on a real panel.** Written from verified primary sources (see
> below), but not booted. Treat the first install as the test run.

No Pterodactyl egg for Arma 2 OA existed anywhere on GitHub when this was written — searching
for any egg JSON mentioning Arma 2 or appid `33930`/`33935` returns nothing. Egg coverage of
the Arma family stops at Arma 3 and Reforger. This fills that gap.

## Why this is not just "another steamcmd egg"

Three things make A2OA awkward on Linux, and all three are handled in `install.sh`:

1. **There is no Linux dedicated server on Steam.** Appid `33935` is the *Windows* dedicated
   server. The only Linux build Bohemia ever shipped is the 1.59.84216 BETA standalone
   package, which is no longer distributed and is mirrored at
   [`Bluscream/arma2-oa-linux-server`](https://github.com/Bluscream/arma2-oa-linux-server).
   So the install downloads Windows *game data* from `33930` and overlays the Linux *engine*
   from the mirror.

2. **Every filename must be lowercase.** The engine resolves paths lowercase internally while
   Steam delivers `Addons/`, `Expansion/`, `Dta/`. The server starts and then fails to find its
   addons. The server package ships `tolower.c`; its `install` script compiles it with gcc and
   runs it, which is why `gcc` is an install dependency. This is not optional and it must run
   *after* all content is in place.

3. **The engine is 32-bit.** `server` is `ELF 32-bit LSB executable, Intel i386`. The image
   needs i386 libs (`libstdc++6:i386`, `lib32z1`, `lib32gcc-s1`), which is why the default
   image is `games:source` — the 32-bit Source yolk — rather than a generic Debian one. **This
   is the most likely thing to fail.** If it does, the fix is an image with i386 multiarch
   enabled, not a change to this egg.

## The binary, and a trap worth knowing

The package contains two things that look like the server:

| File | What it actually is |
| :--- | :--- |
| `server` | The real 32-bit ELF engine. **This is what the egg runs.** |
| `arma2oaserver` | A 2010 BIS init script — `start\|stop\|restart\|status\|check` with a background watchdog and *unset* `ARMA_DIR`/`CONFIG` at the top. |

`arma2oaserver` cannot be used by Pterodactyl: it does not run in the foreground, and passing
it engine flags just prints its usage line. Worth flagging because the AMP template this egg
drew from sets `App.ExecutableLinux=33935/arma2oaserver` and then passes engine arguments to
it — that looks wrong, and if that AMP instance works, it works for some reason not visible in
the template.

## Sources

Everything here is derived from primary sources rather than guessed:

- `Bluscream/AMPTemplates` `arma2oa.kvp` — command line, profile/config layout, port
  assignments, `SteamAppId=33900`, appids (`arma2appids.txt`: a2 `33900`, a2 server `33905`,
  a2oa `33930`, a2oa server `33935`, dayz mod `224580`).
- The 1.59.84216 server package itself, downloaded and unpacked: `server`, `install`,
  `tolower.c`, `expansion/battleye/beserver.so`, `readme.txt`.
- `parkervcp/eggs` Arma 3 egg — egg schema, install-script conventions, variable style.

`server.cfg` and `basic.cfg` are fetched from `AMPTemplates@dev` on install, and only when
absent, so a reinstall never overwrites a live config.

## Ports

From `arma2oa-ports.json`. Only the game port is allocated by Pterodactyl; the rest must be
added as additional allocations if used.

| Port | Proto | Purpose |
| :--- | :--- | :--- |
| 2302 | UDP | Game |
| 2303 | UDP | Steam query |
| 2304 | UDP | Steam |
| 2305 | UDP | VON (reserved) |
| 2306 | UDP | BattlEye |
| 2307 | UDP | RCON |

## Known unknowns

- **`config.startup.done` is a guess.** It is set to `Dedicated host created.`. If the server
  installs and runs but the panel never marks it green, this string is why — check the console
  for the real ready line and correct it.
- **Steam Guard** will break the install non-interactively. Unlike `dayzsa-nobe`, this egg has no
  2FA handling; the account needs Guard off or an established sentry.
- `-cpuCount=2` is a conservative default. The 32-bit engine cannot address more than ~2 GB
  regardless of what `-maxMem` is set to.
