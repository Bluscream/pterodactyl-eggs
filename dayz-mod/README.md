# DayZ Mod (Arma 2 OA, Linux) Pterodactyl Egg

> **Status: draft, never started on a real panel, and lower confidence than the `arma2-oa`
> egg.** The Arma 2 OA half is well-sourced. The DayZ Mod half depends on a Perl-based Hive
> path and a mod/Hive version pairing that nobody has verified in this combination. Expect to
> debug it.

Read [`../arma2-oa/README.md`](../arma2-oa/README.md) first — every OA constraint applies here
too (no Linux server on Steam, mandatory lowercase filenames, 32-bit engine). This egg is that
one plus the mod and persistence.

## What a working DayZ Mod server is made of

| Piece | Source | Confidence |
| :--- | :--- | :--- |
| Arma 2 OA game data | steamcmd appid `33930` | verified |
| Arma 2 base content | steamcmd appid `33900` | verified |
| Linux engine | 1.59.84216 BETA package (mirror) | verified — downloaded and inspected |
| `@dayz` | appid `224580`, or `DAYZ_MOD_URL` | **unverified** |
| `@hive` + `writer.pl` | `denisio/Dayz-Linux-Server` | exists; patched for env credentials; version pairing unverified |
| Perl modules | vendored into `./perl5` at install | verified to be required; vendoring untested against a real image |
| MySQL database | **you provide it** | see below |

## The Hive problem, stated plainly

The official DayZ Mod Hive — the thing that persists players, tents and vehicles — is a
**Windows DLL. There is no Linux build.** Searching for one (`libhive.so`) returns nothing.

The Linux workaround, and the only maintained one, is
[`denisio/Dayz-Linux-Server`](https://github.com/denisio/Dayz-Linux-Server): an `@hive` addon
plus a Perl script that the server's stdout is **piped into**, which performs the database
writes. Its actual launch line is:

```
./server -server -mod="@hive;@dayz" -config="cfgdayz/server.cfg" ... 2>&1 | ./writer.pl
```

That pipe is why this egg uses a `boot.sh` wrapper instead of a bare startup line — the same
reason `dayz-standalone` does, plus the `;`-in-`eval` trap documented in `dayz-standalone/boot.sh`.

It is wired through a **named pipe**, not `exec server | writer.pl`. In a pipeline each side runs in
its own subshell, so `exec` replaces the *subshell* and the script stays alive as PID 1 holding the
pipeline — signals from Wings then land on a shell that does not forward them, so a stop request is
ignored until Wings gives up and `SIGKILL`s, losing whatever the Hive had not flushed. Killing the
pipeline's `$!` is no better: that is `writer.pl`, not the engine. With a FIFO both processes are
addressable, so `SIGTERM`/`SIGINT` reach the engine and it shuts down cleanly.

Two consequences you should plan around:

- **`@hive` must load before `@dayz`.** `MODIFICATIONS` defaults to `@hive;@dayz` and the order
  matters — the extension has to register before the mod queries it.
- **That layout targets DayZ Mod 1.8.0.3, and no 1.8.0.3 package is still downloadable.** This was
  searched for: the old mirror (`se1.dayz.nu/latest/1.8.0.3/@Client-1.8.0.3-Full.rar`) is dead, and
  the canonical `DayZMod/DayZ` repo has tags for 1.8.4 through 1.8.9 but **no 1.8.0.3**, releases
  with **zero assets**, and **zero `.pbo` files** — it ships unpacked source that needs
  `BuildScript.bat` and the Windows BI Tools to produce a mod folder.

  So `DAYZ_MOD_FROM_STEAM=1` remains the default because it is the only source that works unattended,
  and it delivers a build several versions newer than this `@hive`. **Treat that mismatch as the
  first suspect if persistence misbehaves** — symptoms would be Hive writes failing or players
  loading with wrong/blank inventories, rather than an outright crash. If you find or build a
  matching package, point `DAYZ_MOD_URL` at it and set `DAYZ_MOD_FROM_STEAM=0`.

  One useful thing in that repo: `SQL/` holds the Hive schema for its version, which is a
  better-matched alternative to the `database.sql` shipped by the Linux layout.

## MySQL is not installed and cannot be

Pterodactyl runs one process per container, so the database has to live somewhere else — another
container, a panel-provided database, or a host MySQL. `HIVE_DB_HOST` must be reachable *from
the game container*; `127.0.0.1` will not work.

After install, three manual steps remain. **The server starts and is playable without them, but
nothing persists** — players respawn fresh on every join, which is a confusing thing to
diagnose from in-game, so `boot.sh` warns about it on startup instead:

1. Create the database and user, and load `/home/container/database.sql` into it.
2. Import `object_init_data.txt` into both `Object_DATA` and `Object_init_DATA`
   (the upstream README shows the `mysqlimport` invocation).
3. Point the Hive config at that database.

### Two upstream problems this egg now works around

Both were discovered by reading `writer.pl`, and either one alone meant persistence could never
work in a container:

**1. It could not reach a remote database at all.** Upstream connects with
`DBI->connect('dbi:mysql:'.DB_NAME, …)` — *no host parameter*, which means a local MySQL socket.
There is no local MySQL in a Pterodactyl container. Credentials were hardcoded Perl constants
(`DB_NAME`/`DB_LOGIN`/`DB_PASSWD`, all `dayz`). `boot.sh` therefore patches `writer.pl` on first
boot to read `HIVE_DB_*` from the environment **and** to put `host=` and `port=` in the DSN. The
patch is marker-guarded so restarts don't stack edits, and `perl -c`-verified — if upstream's
layout changes, the original is restored and the server starts without persistence rather than
silently half-broken.

**2. Its Perl modules were missing at runtime.** `writer.pl` needs `JSON::XS`, `DBI` and
`DBD::mysql`. None are in Debian's `perl-base`, and the install script `apt`-installed them into the
*throwaway installer container*, where they did nothing. They are now **vendored onto the volume**
into `./perl5` and reached via `PERL5LIB`. `boot.sh` verifies they actually load
(`perl -MJSON::XS -MDBI -MDBD::mysql -e1`) and disables the Hive with a specific message if not —
previously it only checked that `perl` existed, which always passes.

## Set `HIVE_ENABLED=0` to sidestep all of it

A non-persistent server needs no database at all. `boot.sh` then skips `writer.pl` entirely and
runs the engine directly. Good way to prove the OA + `@dayz` half works before taking on the
Hive.

## Also fixed in the audit pass

- **BattlEye** is now switchable via `DISABLE_BATTLEYE`, the same sole-decider shape as the sibling
  eggs, writing `BattlEye` in `server.cfg` and writing or deleting `battleye/beserver.cfg`.
- **Mod signature keys** are synced from each `@mod` folder into `keys/` on boot. With
  `verifySignatures = 2` and no keys, every client loading that mod is rejected.
- **`server.cfg` is shipped by this egg** rather than taken from the upstream tarball, which came
  with someone else's `passwordAdmin`, a dead GameSpy `reportingIP`, and a hardcoded
  `requiredBuild`. `requiredBuild` is now a variable.
- **2FA** is the unified single `STEAM_AUTH` (literal or URL). This egg performs **three**
  Steam logins, so per-login re-minting matters more here than anywhere else.
- `curl --fail` throughout, steamcmd success judged by app manifest rather than exit status, and a
  bare `-mod=` is no longer passed when every entry was dropped.

## Known unknowns

- `config.startup.done` is a guess (`Dedicated host created.`) — same caveat as the OA egg.
- The mission is whatever `denisio/Dayz-Linux-Server` ships (`dayz_1.chernarus.pbo`). Any
  mission or mod you upload later **must** be lowercased; `boot.sh` re-runs `tolower` on every
  boot for exactly this reason.
- Steam Guard will break the install; there is no 2FA handling here.
- `-beta="expansion/beta;expansion/beta/expansion"` is required for DayZ Mod. If the mod fails
  to load at all, verify those directories actually exist after install.
