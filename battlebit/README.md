# BattleBit Remastered Pterodactyl Egg

Dedicated server egg for BattleBit Remastered, running the Windows server build under Wine.

Originally created by [Destructor](https://discord.com/channels/@me/1145359600078573630); rewritten
since — see [What changed](#what-changed-in-the-rewrite), because the previous version did not
install at all.

## Requirements

- **A Steam account that owns BattleBit Remastered.** The server build is only published on *beta
  branches of the game appid* (`671860`) — there is no separate server appid and no anonymous
  download. If the account has Steam Guard, see [Steam Guard](#steam-guard--2fa).
- A Wine runtime image. `yolks:wine_staging` is the default; `wine_latest` and `wine_devel` are
  offered as alternates.

## Branches

| `STEAM_BRANCH` | What it is |
| :--- | :--- |
| `community-server` *(default)* | The live branch for public community servers. |
| `community-testing` | Test build and API test environment. Expect breakage. |

If the download finishes but `BattleBit.exe` is missing, the account almost certainly lacks access
to the chosen branch and Steam served the base game instead. The install detects this and fails
rather than leaving a broken server behind.

## Steam Guard / 2FA

One variable, **`STEAM_AUTH`**, accepting either form:

| Value | Behaviour |
| :--- | :--- |
| `K4J9P` | Literal code. Single-use, ~30 second lifetime. |
| `https://…` | Endpoint returning a code. Re-minted per attempt, and again after the retry wait. |

The mode is inferred from the value. A URL is strongly preferred — there's an `apt install` and a
steamcmd bootstrap ahead of the login, so a hand-pasted literal is a race against the clock. Any
ArchiSteamFarm endpoint works:

```
https://asf.host/api/bot/<bot>/twoFactorAuthentication/token?password=<ipc-password>
```

Both forms of ASF's IPC secret are sent (an `Authentication` header and `?password=`), so either
ASF vintage answers.

**If the URL embeds a secret, put it in `.steam_auth` in the server root instead of the panel
variable.** Panel variables are stored in the database as plain text and are readable by any panel
admin; that file can be `chmod 600` and never leaves the volume. A literal code there is consumed
and deleted after install; a URL is kept.

On failure the install waits 31 seconds before retrying a URL, because a TOTP only rolls over
every 30 — minting again immediately just returns the same rejected code.

`HOME` points at the persistent volume during install, so the Steam sentry from a successful Guard
login (`Steam/config/ssfn*`) survives the throwaway installer container. Later reinstalls can often
log in with no code at all.

## Launch arguments are built in `boot.sh`

The startup line is just `bash ./boot.sh`. Everything is assembled from environment variables
there, which is a deliberate departure from the usual convention of spelling arguments out in the
panel. Three reasons:

1. **Quoting.** The startup line is expanded and then `eval`-ed by the image entrypoint, so values
   with spaces must survive two rounds of word splitting. The old line wrote
   `"-Name="{{SERVER_NAME}}""`, which left the value *unquoted* after expansion — the default
   server name split into six arguments.
2. **Empty optionals.** `-Password=` and `-apitoken=` with nothing after them are not equivalent to
   omitting the flag. Built in a script, empty values drop out.
3. **`;` chaining.** The old line chained `cd`/`winetricks`/`export`/`wine` with semicolons. That
   works *only* because `wine/entrypoint.sh` expands with `$(echo …)`; the `games:*` images use
   `` `eval echo $(…)` ``, where every segment after the first executes during variable assignment.
   One command is immune either way.

`boot.sh` also creates `Permissions.txt` if absent, masks the password in the echoed command line,
and warns when an API endpoint is set with no token.

## Wine settings

`WINEARCH`, `WINEPREFIX`, `WINEDEBUG`, `WINEDLLOVERRIDES` and `WINETRICKS_RUN` are egg variables so
the **image entrypoint** sees them — it creates the prefix and runs `winetricks -q` over each verb
before the startup command executes.

This matters for two of them:

- **`WINEARCH` only takes effect when the prefix is created.** The old egg exported it in the
  startup line, which always ran *after* the entrypoint had already created the prefix. To change
  it now, delete `.wine` and restart.
- **`sound=disabled` belongs in `WINETRICKS_RUN`**, not in a per-boot `winetricks` call. The old
  startup line invoked `winetricks` on every single boot, without `-q`.

## What changed in the rewrite

The previous version **could not install** — its script had a bash syntax error (an empty `then`
branch, plus `${$STEAM_AUTH_URL}`), and bash parses a whole script before running any of it, so
nothing happened at all. Fixed along with:

- `config.stop` was `^^C` instead of `^C`, so stopping never sent SIGINT — Wings waited out the
  timeout and then SIGKILLed.
- The startup line referenced `{{SERVER_APITOCKEN}}` while the variable was `SERVER_APITOKEN`, so
  the API token was silently never passed.
- `STEAM_USER` was `required` with an empty default, making server creation impossible, while the
  script contained an anonymous fallback that could therefore never run — and which couldn't work
  anyway, since the branches need game ownership.
- 2FA was fetched once via `wget` (not guaranteed present in the installer image) with no retry,
  and `STEAM_AUTH_URL` was user-visible despite normally embedding an IPC password.
- `start-script.sh` was a JSON-escaped artifact, not a runnable script (`cd \/home\/container\/`,
  `export WINEARCH=\"win64\"`), and had drifted from the egg — it referenced a `SERVER_HZ`
  variable that didn't exist, hardcoded `VoxelMode=false`, and omitted the API token. Deleted.
- Source-engine leftovers from the egg's CS:S ancestry are gone: `SRCDS_APPID`, `SRCDS_BETAID`,
  `SRCDS_BETAPASS`, `INSTALL_FLAGS` and `WINDOWS_INSTALL`. The last two had **no variable
  definitions at all** and always expanded empty. Windows platform forcing is now unconditional,
  since the Windows build is the only one there is.
- Six variables had empty descriptions; `WINDOWS_INSTALL` was typed `string|max:20` for a boolean;
  `SRCDS_BETAID`'s `in:` rule had a trailing comma.
- Install now verifies `BattleBit.exe` exists, judges steamcmd success by the app manifest rather
  than its exit status (which is non-zero on good runs), and uses `curl --fail` throughout.

## Tested

`boot.sh` was exercised with a stub `wine`: a server name containing spaces staying one argument,
empty password/API values being omitted, the password masked in the echoed line but passed intact
to the game, the endpoint-without-token warning, `STARTUP_PARAMS` splitting, `Permissions.txt`
creation, and the missing-binary fatal path.

**Not tested:** any real Steam download, and no server has actually been started. Treat the first
install as the test run.
