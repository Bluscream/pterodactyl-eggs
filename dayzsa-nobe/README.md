# DayZ Standalone (No-BE Patched) Pterodactyl Egg

A Pterodactyl Egg for hosting DayZ Standalone Dedicated Servers with an automated BattlEye memory patcher, VAC bypass, and support for both Release and Experimental builds.

## Features
- **Automatic BattlEye Disabling**: Automatically patches the server binary (`DayZServer` on Linux or `DayZServer_x64.exe` on Windows/Proton) before launch to suppress BattlEye master handshakes, global ban kicks (`0x000400F0`), and VAC verification loops.
- **Dual AppID Support**:
  - `223350`: DayZ Standalone Release Dedicated Server (requires authenticated Steam account).
  - `1042420`: DayZ Experimental Dedicated Server (anonymous download).
- **Zero Manual Re-patching**: The embedded `patch_be.pl` script automatically runs on every container startup and after SteamCMD updates/file validations.

## BattlEye, RCON, and admin access
The binary patch prevents BattlEye from initializing at all -- it does not leave a
"declawed" BattlEye running. Consequences:
- Global-ban and VAC kicks are gone (the point of the egg).
- **BattlEye RCON does not work.** Nothing binds the RCON port for BE, so `bercon-cli`
  and any BE RCON tool will time out. `-nobe` and `battleye = 0` are irrelevant to this;
  the patch alone is sufficient and sufficient to break RCON.
- Admin instead via VPPAdminTools in-game (`ENABLE_VPP_ADMIN=1`) and the slash commands
  in `dayz_init_server.c`.
- To get RCON back, drop `patch_be.pl` from the startup command and run the stock binary.

## Files
- `egg-dayzsa-nobe.json`: Complete Pterodactyl v2 Egg ready for import.
- `patch_be.pl`: Binary patcher. Perl, not Python -- the runtime image `ghcr.io/parkervcp/games:dayz` ships `/usr/bin/perl` and has no `python3`.
- `setup_vpp.sh`: Automated mod keys installer, BattlEye RCON configuration, and SuperAdmin provisioning script.
- `dayz_init_server.c`: Custom mission init installed over `mpmissions/.../init.c` on first boot (guarded by the `DAYZ_NOBE_CUSTOM_INIT` marker; the original is backed up).
