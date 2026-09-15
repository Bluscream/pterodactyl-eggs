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

3. **The engine is 32-bit.** `server` is `ELF 32-bit LSB executable, Intel i386`, so the
   **runtime** image must provide i386 libraries. Verified against the yolk Dockerfiles:
   `games:dayz` and `games:source` both run `dpkg --add-architecture i386` and install
   `lib32stdc++6` / `lib32gcc-s1` / `lib32z1`; a generic Debian yolk does not. `games:dayz` is
   the default here because it additionally ships `bercon`, which is useful when BattlEye is
   enabled.

   Note the install script cannot help with this. It runs in a *throwaway installer container* —
   anything it `apt install`s is discarded. Only `curl`, `ca-certificates`, `bzip2` and `gcc`
   are installed there, because those are needed *during* install. **If the server exits with
   "No such file or directory" on a binary that plainly exists, that is the missing 32-bit
   loader, and the fix is the image, not this egg.**

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

### Configs are shipped by this egg, not fetched from AMPTemplates

An earlier revision pulled `server.cfg` and `basic.cfg` from `AMPTemplates@dev`. That was
**broken**: those files are AMP templates full of `{{placeholder}}` tokens that AMP substitutes
at runtime, so the engine would have read a literal `hostname = "{{hostname}}";` and
`maxPlayers = {{maxPlayers}};`. This egg now ships its own [`server.cfg`](./server.cfg) and
[`basic.cfg`](./basic.cfg), fetched from this repo on install and **only when absent**, so a
reinstall never overwrites a live config.

Comments in `server.cfg` sit on their own lines above the settings they describe, deliberately:
Pterodactyl's `file` parser replaces whole lines, so a trailing comment on a managed line would
vanish the first time the server started.

## What `boot.sh` does

The startup line runs `bash ./boot.sh`, not the engine directly — partly for the `;`-in-`eval`
reason documented in the sibling eggs, but mainly because four things must happen per boot that
a startup line cannot express:

1. **Re-lowercase.** Missions and mods uploaded through the file manager keep their casing, and
   any uppercase letter breaks loading. `tolower` runs every boot, not just at install.
2. **Sync mod signature keys.** `verifySignatures = 2` rejects any addon whose `.bikey` is not
   in `keys/`. Mods ship theirs in their own `keys/` (sometimes `key/`), so those are copied in
   and lowercased. Without this, adding a mod silently rejects every client that loads it.
   Disable with `SYNC_MOD_KEYS=0` if you manage `keys/` by hand.
3. **Apply the BattlEye switch** (below).
4. **Drop missing `-mod` entries**, and omit the flag entirely when nothing remains — a bare
   `-mod=""` makes the engine parse an empty modlist entry.

## BattlEye

`DISABLE_BATTLEYE` is the sole decider, matching `dayz-standalone`:

| `DISABLE_BATTLEYE` | `server.cfg` | `battleye/beserver.cfg` | RCON |
| :--- | :--- | :--- | :--- |
| `1` (default) | `BattlEye = 0` | **deleted** | unavailable |
| `0` | `BattlEye = 1` | written from `ADMIN_PASSWORD` + `RCON_PORT` | works |

Anything other than an explicit `0` counts as `1`. The file is deleted rather than skipped when
BattlEye is off, so a leftover never implies RCON works on a server where BattlEye isn't running.

Unlike `dayz-standalone`, **nothing is patched here.** A 2010 engine has no BattlEye global-ban
network to hide from; the switch exists because BattlEye on A2OA is an extra moving part that
often breaks modded servers. The `BattlEye` key is intentionally *not* in the egg's
`config.files` — if the panel parser also wrote it, there would be two disagreeing deciders,
which is the exact bug that was just removed from `dayz-standalone`.

## Steam Guard / 2FA

This egg **requires a real Steam account** — appids `33930` and `33900` are not available
anonymously — so if the account has Guard enabled, 2FA is not optional here the way it is for an
egg that can fall back to an anonymous download.

There is exactly one variable, **`STEAM_AUTH`**, and it takes either form:

| Value | Behaviour |
| :--- | :--- |
| `K4J9P` | Used as a literal code. Single-use, ~30 second lifetime. |
| `https://…` | Fetched as an endpoint returning a code. Re-minted before **every** login and again on retry. |

The mode is inferred from the value — there is no second variable and no precedence rule to
remember. A URL is strongly preferred, because there are two logins below an `apt install` and a
steamcmd bootstrap, so a hand-pasted literal is a race against the clock. Any ArchiSteamFarm
endpoint works:

```
https://asf.host/api/bot/<bot>/twoFactorAuthentication/token?password=<ipc-password>
```

Both forms of ASF's IPC secret are sent — an `Authentication` header and the `?password=` query —
so either ASF vintage answers.

`.steam_auth` in the server root works as well, and outlives the panel variable. A literal
code there is consumed and deleted after the install; a URL is kept, since it stays valid.

Two details worth knowing:

- **`HOME` is on the persistent volume during install**, so the Steam sentry a successful Guard
  login writes (`Steam/config/ssfn*`) survives the throwaway installer container. After one
  coded login, later reinstalls may need no code at all.
- **Retry waits out the TOTP window.** On failure the install sleeps 31 seconds before retrying a
  URL, because minting again immediately just returns the same rejected code.

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

Note the default `RCON_PORT` is `2306`, which is BattlEye's own port in the table above. A2OA's
BattlEye listens for RCON on its own UDP port and it needs a separate allocation in the panel.

## What has been tested, and what hasn't

The 2FA resolution was unit-tested against a mock endpoint: ASF JSON, ASF JSON where the bot name
is itself a 5-character uppercase token (it returns the code, not the bot name), a bare code, a
lowercase bare code, header-auth success and failure, empty responses, 404s and an unreachable
host. Literal and empty values too. The download verdict was tested with a stubbed steamcmd for
success, success-with-nonzero-exit, Guard rejection, rate limiting and a segfault.

`boot.sh` has been exercised against fixtures with a stub binary: key sync from both `keys/` and
`key/` with mixed-case filenames, dropping a missing mod, omitting empty `-mod`/`-serverMod`,
enabling and disabling BattlEye including cleanup of `beserver.cfg` on the way back down, a
malformed `DISABLE_BATTLEYE` falling safe to disabled, and the empty-`ADMIN_PASSWORD` warning.
The `server.cfg` rewrite path was simulated for all five managed keys — each matches exactly
once, `password` does not collide with `passwordAdmin`, and the comments survive.

**Not tested: anything involving the real engine.** No Steam download, no `tolower` run over real
game data, no server that has actually started.

## Known unknowns

- **`config.startup.done` is a guess.** It is set to `Dedicated host created.`. If the server
  installs and runs but the panel never marks it green, this string is why — check the console
  for the real ready line and correct it.
- **`SteamAppId` is not set.** The AMP template exports `SteamAppId=33900`, and it is unclear
  whether the 2010 BETA server — which predates Steam integration entirely — needs it. If Steam
  server-browser queries do not work, adding it as an egg variable is the first thing to try.
- `-cpuCount=2` is a conservative default. The 32-bit engine cannot address more than ~2 GB
  regardless of what `-maxMem` is set to.
