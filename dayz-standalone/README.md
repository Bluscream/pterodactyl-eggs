# DayZ Standalone Pterodactyl Egg

A Pterodactyl Egg for hosting DayZ Standalone Dedicated Servers, with BattlEye switchable
between a patched-out binary and the fully working stock one, and support for both Release and
Experimental builds.

## Features
- **Switchable BattlEye**: One variable, `DISABLE_BATTLEYE`, decides everything. Set to `1` it patches the server binary (`DayZServer` on Linux or `DayZServer_x64.exe` on Windows/Proton) before launch to suppress BattlEye master handshakes, global ban kicks (`0x000400F0`) and VAC verification loops. Set to `0` it restores the stock binary and BattlEye — including RCON — works normally. See [BattlEye, RCON, and admin access](#battleye-rcon-and-admin-access).
- **Dual AppID Support**:
  - `223350`: DayZ Standalone Release Dedicated Server (requires authenticated Steam account).
  - `1042420`: DayZ Experimental Dedicated Server (anonymous download).
- **Zero Manual Re-patching**: While `DISABLE_BATTLEYE=1`, the embedded `patch_be.pl` script automatically runs on every container startup and after SteamCMD updates/file validations. Flipping to `0` restores the stock binary from `DayZServer.orig` without a reinstall.

## BattlEye, RCON, and admin access

**`DISABLE_BATTLEYE` is the sole decider.** One variable controls the binary, the config and
the RCON file together, and nothing else influences BattlEye state:

| `DISABLE_BATTLEYE` | Binary | `serverDZ.cfg` | `BEServer_x64.cfg` | RCON |
| :--- | :--- | :--- | :--- | :--- |
| `1` (default) | patched by `patch_be.pl` | `battleye = 0` | **deleted** | unavailable |
| `0` | stock, restored from `.orig` | `battleye = 1` | written | works |

Anything other than an explicit `0` is treated as `1`, so an unset or malformed value leaves
the server patched rather than quietly shipping one that kicks on global bans.

Three other things used to be able to decide this, and were removed — disagreeing sources of
truth here produce a server that is patched but advertises RCON, or the reverse:

- `ENABLE_BATTLEYE`, an older inverted variable `setup_vpp.sh` fell back to.
- `patch_be.pl`'s own `serverDZ.cfg` rewriting.
- the egg's `config.files` entry for `battleye/BEServer_x64.cfg`, which made the **panel's**
  config parser rewrite that file on every boot no matter what this variable said. That one was
  the nastiest: it silently reintroduced an RCON password onto a patched server where BattlEye
  never loads. `setup_vpp.sh` now writes that file when `DISABLE_BATTLEYE=0` and deletes it
  when `1`.

When disabled (`1`):
- Global-ban and VAC kicks are gone — the point of the egg.
- **BattlEye RCON does not work.** Nothing binds the RCON port, so `bercon-cli` and every other
  BE RCON tool will time out. `-nobe` and `battleye = 0` are irrelevant to this; the binary
  patch alone is both sufficient to disable BattlEye and sufficient to break RCON.
- Admin access is VPPAdminTools in-game (`ENABLE_VPP_ADMIN=1`) plus the chat commands in
  `dayz_init_server.c`.

To get RCON back, set `DISABLE_BATTLEYE=0` and restart. `setup_vpp.sh` restores the stock
binary from `DayZServer.orig` — no reinstall needed.

## Files
- `egg-dayz-standalone.json`: Complete Pterodactyl v2 Egg ready for import.
- `patch_be.pl`: Binary patcher. Perl, not Python -- the runtime image `ghcr.io/parkervcp/games:dayz` ships `/usr/bin/perl` and has no `python3`.
- `setup_vpp.sh`: Automated mod keys installer, BattlEye RCON configuration, and SuperAdmin provisioning script.
- `dayz_init_server.c`: Custom mission init installed over `mpmissions/.../init.c` on first boot (guarded by the `DAYZ_NOBE_CUSTOM_INIT` marker; the original is backed up).
