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
| `@hive` + `writer.pl` | `denisio/Dayz-Linux-Server` | exists; pairing unverified |
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

Two consequences you should plan around:

- **`@hive` must load before `@dayz`.** `CLIENT_MODS` defaults to `@hive;@dayz` and the order
  matters — the extension has to register before the mod queries it.
- **That layout targets DayZ Mod 1.8.0.3.** If you let the egg pull `@dayz` from Steam you get
  a much newer build against a 1.8.0.3-era Hive. That combination is untested and is the single
  most likely source of trouble. To control it, set `DAYZ_MOD_URL` to a matching 1.8.0.3
  package and leave `DAYZ_MOD_FROM_STEAM=0`.

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

Step 3 is the loosest end here. The egg exposes `HIVE_DB_*` variables, but **it does not yet
write them into the Hive's own config file** — the config's location and format inside `@hive`
were not confirmed. Until that is nailed down, set the credentials by hand after the first
install. This is the first thing to fix.

## Set `HIVE_ENABLED=0` to sidestep all of it

A non-persistent server needs no database at all. `boot.sh` then skips `writer.pl` entirely and
runs the engine directly. Good way to prove the OA + `@dayz` half works before taking on the
Hive.

## Known unknowns

- `config.startup.done` is a guess (`Dedicated host created.`) — same caveat as the OA egg.
- The mission is whatever `denisio/Dayz-Linux-Server` ships (`dayz_1.chernarus.pbo`). Any
  mission or mod you upload later **must** be lowercased; `boot.sh` re-runs `tolower` on every
  boot for exactly this reason.
- Steam Guard will break the install; there is no 2FA handling here.
- `-beta="expansion/beta;expansion/beta/expansion"` is required for DayZ Mod. If the mod fails
  to load at all, verify those directories actually exist after install.
