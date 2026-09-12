# DayZ Standalone (No-BE Patched) Pterodactyl Egg

A Pterodactyl Egg for hosting DayZ Standalone Dedicated Servers with an automated BattlEye memory patcher, VAC bypass, and support for both Release and Experimental builds.

## Features
- **Automatic BattlEye Disabling**: Automatically patches the server binary (`DayZServer` on Linux or `DayZServer_x64.exe` on Windows/Proton) before launch to suppress BattlEye master handshakes, global ban kicks (`0x000400F0`), and VAC verification loops.
- **Dual AppID Support**:
  - `223350`: DayZ Standalone Release Dedicated Server (requires authenticated Steam account).
  - `1042420`: DayZ Experimental Dedicated Server (anonymous download).
- **Zero Manual Re-patching**: The embedded `patch_be.py` script automatically runs on every container startup and after SteamCMD updates/file validations.

## Files
- `egg-dayz-nobe.json`: Complete Pterodactyl v2 Egg ready for import.
- `patch_be.py`: Universal standalone Linux/Windows binary patcher.
