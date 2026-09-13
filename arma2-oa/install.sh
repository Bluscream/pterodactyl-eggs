#!/bin/bash
# Pterodactyl install script -- Arma 2: Operation Arrowhead dedicated server (Linux)
#
# Bohemia never shipped an A2OA Linux server through Steam: appid 33935 is the Windows
# dedicated server. The Linux build is the 1.59.84216 BETA standalone package, mirrored at
# Bluscream/arma2-oa-linux-server. So this install does three things in order:
#
#   1. steamcmd the Windows game data (33930, plus 33900 for Arma 2 base content)
#   2. overlay the Linux server package (the `server` ELF + expansion/battleye/beserver.so)
#   3. run the package's own conversion, which lowercases every filename
#
# Step 3 is not optional. The engine resolves paths lowercase internally, and Steam delivers
# Windows-cased files (Addons/, Expansion/, Dta/). Without the conversion the server starts
# and then fails to find addons. The upstream `install` script compiles tolower.c with gcc and
# runs it; we do the same rather than reimplementing it, so the behaviour matches upstream.

set -e

apt -y update
apt -y --no-install-recommends install curl gcc ca-certificates bzip2 lib32gcc-s1 libstdc++6:i386 lib32z1 || \
  apt -y --no-install-recommends install curl gcc ca-certificates bzip2 lib32gcc-s1

# A2OA is not available to the anonymous Steam user -- ownership of Arma 2 and Operation
# Arrowhead is required on the account used here.
if [[ "${STEAM_USER}" == "" ]] || [[ "${STEAM_USER}" == "anonymous" ]] || [[ "${STEAM_PASS}" == "" ]]; then
    echo "INSTALLATION ERROR: a real Steam account that owns Arma 2 and Arma 2: Operation"
    echo "  Arrowhead is required. The anonymous account cannot download appid 33930."
    exit 1
fi

cd /tmp
mkdir -p /mnt/server/steamcmd /mnt/server/steamapps
curl -sSL -o steamcmd.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
tar -xzf steamcmd.tar.gz -C /mnt/server/steamcmd
cd /mnt/server/steamcmd

chown -R root:root /mnt
export HOME=/mnt/server

# 33930 = Arma 2: Operation Arrowhead (game data). 33900 = Arma 2 (base content), needed for
# Combined Operations and by every DayZ Mod build. DOWNLOAD_ARMA2_BASE=0 skips it for a
# standalone OA server that will never load A2 content.
./steamcmd.sh +force_install_dir /mnt/server "+login \"${STEAM_USER}\" \"${STEAM_PASS}\"" \
    +app_update 33930 ${STEAMCMD_EXTRA_FLAGS} validate +quit

if [[ "${DOWNLOAD_ARMA2_BASE}" == "1" ]]; then
    ./steamcmd.sh +force_install_dir /mnt/server "+login \"${STEAM_USER}\" \"${STEAM_PASS}\"" \
        +app_update 33900 ${STEAMCMD_EXTRA_FLAGS} validate +quit
fi

mkdir -p /mnt/server/.steam/sdk32
cp -v linux32/steamclient.so /mnt/server/.steam/sdk32/steamclient.so || true

# Linux server overlay.
cd /mnt/server
echo "Fetching the Linux server package from ${A2OA_SERVER_URL}..."
curl -sSL -o /tmp/a2oa-server.tar.bz2 "${A2OA_SERVER_URL}"
tar -xjf /tmp/a2oa-server.tar.bz2 -C /mnt/server
rm -f /tmp/a2oa-server.tar.bz2

# Lowercase conversion. Upstream `install` also deletes *.exe *.chm *.dll, which is correct
# here -- a 32-bit ELF cannot load a PE DLL, so the Windows leftovers are dead weight.
if [[ -f /mnt/server/install ]]; then
    chmod +x /mnt/server/install
    cd /mnt/server && ./install
else
    echo "WARNING: the server package contained no 'install' script -- filenames were NOT"
    echo "  lowercased. The server will very likely fail to load its addons."
fi

chmod +x /mnt/server/server 2>/dev/null || true

# Config templates. Only written when absent, so a reinstall never clobbers a live config.
cd /mnt/server
[[ -f server.cfg ]] || curl -sSL -o server.cfg "${SERVER_CFG_URL}"
[[ -f basic.cfg ]]  || curl -sSL -o basic.cfg  "${BASIC_CFG_URL}"
chmod 644 server.cfg basic.cfg

mkdir -p /mnt/server/A2Master /mnt/server/battleye

echo "-----------------------------------------"
echo "Installation completed."
echo "  server binary : ./server (32-bit i386)"
echo "  profiles      : ./A2Master"
echo "  configs       : server.cfg, basic.cfg"
echo "-----------------------------------------"
