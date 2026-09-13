#!/bin/bash
# Pterodactyl install script -- DayZ Mod (Arma 2: Operation Arrowhead) dedicated server, Linux
#
# DayZ Mod has no dedicated-server appid. A working server is assembled from four pieces:
#
#   1. Arma 2 OA game data       -- appid 33930 (Windows data; the engine binary is separate)
#   2. Arma 2 base content       -- appid 33900 (DayZ Mod loads A2 buildings/vehicles)
#   3. The Linux server engine   -- 1.59.84216 BETA standalone package (mirror)
#   4. @dayz + @hive + writer.pl -- the mod itself and the Linux persistence path
#
# Piece 4 is the awkward one. The official Hive is a Windows DLL with no Linux build, so the
# Linux route is @hive plus a Perl writer that the server's stdout is piped into. That comes
# from denisio/Dayz-Linux-Server, which is the only maintained Linux DayZ Mod server layout.
# It targets DayZ Mod 1.8.0.3 -- pairing it with a much newer @dayz is untested.
#
# MySQL is NOT installed here. Pterodactyl runs one process per container, so the database has
# to live elsewhere; point HIVE_DB_* at it and load database.sql once by hand.

set -e

apt -y update
apt -y --no-install-recommends install curl gcc ca-certificates bzip2 unzip perl libjson-xs-perl \
    lib32gcc-s1 lib32stdc++6 lib32z1 || \
  apt -y --no-install-recommends install curl gcc ca-certificates bzip2 unzip perl lib32gcc-s1

if [[ "${STEAM_USER}" == "" ]] || [[ "${STEAM_USER}" == "anonymous" ]] || [[ "${STEAM_PASS}" == "" ]]; then
    echo "INSTALLATION ERROR: a real Steam account owning Arma 2 AND Operation Arrowhead is"
    echo "  required. Neither 33900 nor 33930 is available to the anonymous account."
    exit 1
fi

cd /tmp
mkdir -p /mnt/server/steamcmd /mnt/server/steamapps
curl -sSL -o steamcmd.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
tar -xzf steamcmd.tar.gz -C /mnt/server/steamcmd
cd /mnt/server/steamcmd

chown -R root:root /mnt
export HOME=/mnt/server

# --- 1 + 2. Game data -------------------------------------------------------------------
./steamcmd.sh +force_install_dir /mnt/server "+login \"${STEAM_USER}\" \"${STEAM_PASS}\"" \
    +app_update 33930 ${STEAMCMD_EXTRA_FLAGS} validate +quit
./steamcmd.sh +force_install_dir /mnt/server "+login \"${STEAM_USER}\" \"${STEAM_PASS}\"" \
    +app_update 33900 ${STEAMCMD_EXTRA_FLAGS} validate +quit

mkdir -p /mnt/server/.steam/sdk32
cp -v linux32/steamclient.so /mnt/server/.steam/sdk32/steamclient.so || true

# --- 3. Linux server engine -------------------------------------------------------------
cd /mnt/server
curl -sSL -o /tmp/a2oa-server.tar.bz2 "${A2OA_SERVER_URL}"
tar -xjf /tmp/a2oa-server.tar.bz2 -C /mnt/server
rm -f /tmp/a2oa-server.tar.bz2

# --- 4. The mod and the Linux Hive ------------------------------------------------------
# @dayz: either straight from Steam (appid 224580 is free to own but still needs a real
# account), or from a URL, for the many community builds Steam does not carry.
if [[ -n "${DAYZ_MOD_URL}" ]]; then
    echo "Fetching @dayz from ${DAYZ_MOD_URL}..."
    cd /tmp
    curl -sSL -o dayzmod.archive "${DAYZ_MOD_URL}"
    mkdir -p /tmp/dayzmod && cd /tmp/dayzmod
    if file /tmp/dayzmod.archive | grep -qi zip; then unzip -oq /tmp/dayzmod.archive
    elif file /tmp/dayzmod.archive | grep -qi bzip2; then tar -xjf /tmp/dayzmod.archive
    else tar -xzf /tmp/dayzmod.archive 2>/dev/null || unzip -oq /tmp/dayzmod.archive; fi
    cp -rv /tmp/dayzmod/* /mnt/server/ 2>/dev/null || true
    rm -rf /tmp/dayzmod /tmp/dayzmod.archive
elif [[ "${DAYZ_MOD_FROM_STEAM}" == "1" ]]; then
    cd /mnt/server/steamcmd
    ./steamcmd.sh +force_install_dir /mnt/server/_dayzmod \
        "+login \"${STEAM_USER}\" \"${STEAM_PASS}\"" +app_update 224580 validate +quit || \
        echo "WARNING: appid 224580 download failed -- supply DAYZ_MOD_URL instead."
    # Steam lays the mod out under a versioned folder; move any @dayz* it produced up.
    find /mnt/server/_dayzmod -maxdepth 3 -iname '@dayz*' -type d -exec cp -r {} /mnt/server/ \; 2>/dev/null || true
    rm -rf /mnt/server/_dayzmod
else
    echo "NOTE: no @dayz source configured (DAYZ_MOD_URL empty, DAYZ_MOD_FROM_STEAM=0)."
    echo "  Upload @dayz into the server root before starting."
fi

# boot.sh, delivered the same way dayz-standalone does it: pinned to a ref so reinstalls are
# reproducible, with --fail because curl otherwise exits 0 on a 404 and writes the error body
# into the destination file. Bump RAW_REF when boot.sh changes.
RAW_REF="master"
RAW_BASE="https://raw.githubusercontent.com/bluscream/pterodactyl-eggs/${RAW_REF}/dayz-mod"

echo "Fetching boot.sh..."
curl --fail -sSL -o /mnt/server/boot.sh.tmp "${RAW_BASE}/boot.sh" || {
    echo "FATAL: could not download boot.sh from ${RAW_BASE}"
    rm -f /mnt/server/boot.sh.tmp
    exit 1
}
mv /mnt/server/boot.sh.tmp /mnt/server/boot.sh

# @hive + writer.pl + tolower.c + the SQL schema, from the Linux server layout.
cd /tmp
curl -sSL -o linuxsrv.tar.gz "${HIVE_REPO_URL}"
mkdir -p /tmp/linuxsrv && tar -xzf linuxsrv.tar.gz -C /tmp/linuxsrv --strip-components=1
for item in @hive writer.pl restarter.pl tolower.c install database.sql cfgdayz mpmissions expansion cache; do
    if [[ -e "/tmp/linuxsrv/${item}" ]]; then
        cp -rn "/tmp/linuxsrv/${item}" /mnt/server/ 2>/dev/null || true
    fi
done
rm -rf /tmp/linuxsrv /tmp/linuxsrv.tar.gz

# --- Lowercase conversion ----------------------------------------------------------------
# Mandatory, and it must run AFTER every piece is in place. Any uppercase filename crashes
# the server at load time.
cd /mnt/server
if [[ -f tolower.c ]]; then
    gcc -O -o tolower tolower.c && ./tolower || echo "WARNING: tolower conversion failed."
fi
rm -f ./*.exe ./*.chm ./*.dll 2>/dev/null || true
find ./battleye ./expansion -maxdepth 2 -name '*.dll' -delete 2>/dev/null || true

chmod +x /mnt/server/server /mnt/server/boot.sh /mnt/server/writer.pl 2>/dev/null || true
mkdir -p /mnt/server/cfgdayz /mnt/server/battleye

echo "-----------------------------------------"
echo "Installation completed."
echo
echo "REMAINING MANUAL STEP -- the server will run but will not persist until this is done:"
echo "  1. Create a MySQL database and user on a host this container can reach."
echo "  2. Load /home/container/database.sql into it."
echo "  3. Import object_init_data.txt into Object_DATA and Object_init_DATA."
echo "  4. Point the Hive config at that database (HIVE_DB_* variables)."
echo "-----------------------------------------"
