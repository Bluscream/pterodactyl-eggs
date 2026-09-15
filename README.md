# Pterodactyl Eggs Collection

Custom and maintained Pterodactyl / Pelican eggs by [Bluscream](https://github.com/Bluscream).

## Available Eggs

| Egg | Directory | Description |
| :--- | :--- | :--- |
| **DayZ Standalone** | [`dayz-standalone/`](./dayz-standalone) | DayZ server egg with switchable BattlEye — one variable either patches it out of the binary (no global-ban/VAC kicks, no RCON) or runs the stock binary with BattlEye and RCON working. Dual Release (`223350`) & Experimental (`1042420`) support. |
| **BattleBit Remastered** | [`battlebit/`](./battlebit) | Dedicated server egg for BattleBit Remastered with automated update and launch scripts. |
| **Arma 2: Operation Arrowhead** | [`arma2-oa/`](./arma2-oa) | A2OA dedicated server on Linux, using the 1.59.84216 BETA standalone server package (Steam ships no Linux server). **Draft — never booted.** |
| **DayZ Mod (Arma 2 OA)** | [`dayz-mod/`](./dayz-mod) | The original DayZ Mod on A2OA, with `@hive` + `writer.pl` persistence and an external MySQL database. **Draft — never booted.** |

## Variable naming

Names are harmonised across all eggs here, and checked against a survey of **466 unique eggs**
(the mirrors in `.references/`, deduplicated) so this repo doesn't invent its own dialect.

| Variable | Corpus usage | Note |
| :--- | :--- | :--- |
| `SERVER_NAME` | 133 (vs `SERVER_HOSTNAME` 8) | Renamed to the majority spelling. |
| `MAX_PLAYERS` | 139 (vs `SERVER_MAXPLAYERS` 2) | Renamed. |
| `SERVER_PASSWORD` | 86 | Already standard. |
| `STEAM_USER` / `STEAM_PASS` | 34 each | Already standard. |
| `STEAM_AUTH` | 24 (most common 2FA name) | Also what the `games:source` entrypoint reads natively. Ours additionally accepts a URL. |
| `STARTUP_PARAMS` | 5 — no clear winner | Corpus is split (`EXTRA_FLAGS` 5, `ARGS` 4, …), so internal consistency won. |
| `MODIFICATIONS` / `SERVERMODS` | 6 each | The DayZ/Arma lineage spelling. |
| `SERVER_BINARY` | 6 | No competing convention. |

Three deliberate deviations, all because the popular name is a Source-engine leftover that means
nothing for these games:

| Ours | Corpus favourite | Why |
| :--- | :--- | :--- |
| `STEAMCMD_APPID` | `SRCDS_APPID` (222) | "SRCDS" is the Source Dedicated Server. None of these games are Source. |
| `STEAM_BRANCH` | `SRCDS_BETAID` (50) | Same reason; also `BETAID` describes the mechanism, not the meaning. |
| `ADMIN_PASSWORD` | `RCON_PASSWORD` (30) | Ours is the in-game `#login` password, which RCON merely reuses. |

### Names that are NOT ours to choose

`MODIFICATIONS`, `SERVERMODS`, `MOD_FILE`, `MODS_LOWERCASE`, `UPDATE_SERVER`, `VALIDATE_SERVER`,
`STEAMCMD_APPID`, `STEAMCMD_ATTEMPTS`, `STEAMCMD_EXTRA_FLAGS` and `SERVER_BINARY` are read by the
`ghcr.io/parkervcp/games:dayz` entrypoint, which also **computes `CLIENT_MODS` itself** from
`MODIFICATIONS` + `MOD_FILE`. `dayz-standalone` therefore keeps the image's spelling exactly.

That is also why `arma2-oa` and `dayz-mod` offer **only `games:source`**, not `games:dayz`: the DayZ
entrypoint would auto-update via `STEAMCMD_APPID`, download workshop mods for DayZ appid `221100`,
and overwrite `CLIENT_MODS` — all wrong for an Arma 2 server. `games:source` only auto-updates when
`SRCDS_APPID` is set, which these eggs deliberately do not set.
