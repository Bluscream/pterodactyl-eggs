#!/usr/bin/env bash
# VPP Admin Tools, Community Framework (CF), Server-Side Admin Commands & BattlEye RCON Setup Script
# Automatically manages keys, provisions SuperAdmin permissions, and syncs shared passwords

set -e

SERVER_ROOT="/home/container"
SERVER_PROFILE="${SERVER_ROOT}/serverprofile"
KEYS_DIR="${SERVER_ROOT}/keys"
BATTLEYE_DIR="${SERVER_ROOT}/battleye"
VPP_BASE="${SERVER_PROFILE}/VPPAdminTools"
VPP_SUPERADMINS_DIR="${VPP_BASE}/Permissions/SuperAdmins"
MISSION_INIT="${SERVER_ROOT}/mpmissions/dayzOffline.chernarusplus/init.c"

# 1. Password Auto-Resolution / Generation
# Uses ADMIN_PASSWORD from egg config if set; otherwise uses/generates a persistent secret in .admin_secret
PASS_FILE="${SERVER_ROOT}/.admin_secret"
if [ -n "${ADMIN_PASSWORD}" ] && [ "${ADMIN_PASSWORD}" != "changeme" ] && [ "${ADMIN_PASSWORD}" != "default" ]; then
    echo "[Security] Using Admin & RCON Passphrase configured in Egg."
    echo -n "${ADMIN_PASSWORD}" > "${PASS_FILE}"
elif [ -f "${PASS_FILE}" ] && [ -s "${PASS_FILE}" ]; then
    export ADMIN_PASSWORD="$(cat "${PASS_FILE}" | tr -d '\r\n')"
    echo "[Security] Loaded persistent Admin & RCON Passphrase from .admin_secret."
else
    WORDS=("Alpha" "Brave" "Delta" "Eagle" "Falcon" "Ghost" "Hunter" "Kodiak" "Nova" "Omega" "Phantom" "Shadow" "Tiger" "Viper" "Wolf")
    COLORS=("Blue" "Gold" "Iron" "Jade" "Onyx" "Ruby" "Silver" "Steel")
    R_W=${WORDS[$((RANDOM % ${#WORDS[@]}))]}
    R_C=${COLORS[$((RANDOM % ${#COLORS[@]}))]}
    R_N=$((RANDOM % 900 + 100))
    SECURE_PASS="${R_W}-${R_C}-${R_N}"
    export ADMIN_PASSWORD="${SECURE_PASS}"
    echo -n "${ADMIN_PASSWORD}" > "${PASS_FILE}"
    echo "[Security] Generated persistent Admin & RCON Passphrase: ${ADMIN_PASSWORD}"
fi
chmod 600 "${PASS_FILE}" 2>/dev/null || true

# 2. Sync BattlEye RCON Configuration (BEServer_x64.cfg)
mkdir -p "${BATTLEYE_DIR}"
RCON_FILE="${BATTLEYE_DIR}/BEServer_x64.cfg"
RCON_PORT="${RCON_PORT:-2304}"
cat <<EOF > "${RCON_FILE}"
// BattlEye Server Configuration
RConPassword ${ADMIN_PASSWORD}
RestrictRCon 0
RConPort ${RCON_PORT}
EOF
echo "[RCON] Configured BattlEye RCON on port ${RCON_PORT} (RestrictRCon 0)."

# 2.1 Make the resolved passphrase authoritative in serverDZ.cfg
# The panel's config parser rewrites passwordAdmin from the (possibly empty) ADMIN_PASSWORD
# egg variable before every boot. This runs after the parser, so the value written here wins
# and serverDZ.cfg, BEServer_x64.cfg and the VPP credentials all agree.
SERVER_CFG="${SERVER_ROOT}/serverDZ.cfg"
if [ -f "${SERVER_CFG}" ]; then
    if grep -q '^[[:space:]]*passwordAdmin[[:space:]]*=' "${SERVER_CFG}"; then
        sed -i "s|^[[:space:]]*passwordAdmin[[:space:]]*=.*|passwordAdmin = \"${ADMIN_PASSWORD}\";|" "${SERVER_CFG}"
    else
        echo "passwordAdmin = \"${ADMIN_PASSWORD}\";" >> "${SERVER_CFG}"
    fi
    echo "[Config] Synced passwordAdmin in serverDZ.cfg with the resolved passphrase."
fi

# 3. VPP Admin Tools Setup
if [ "${ENABLE_VPP_ADMIN}" = "1" ]; then
    echo "[VPP-Setup] Initializing VanillaPlusPlus Admin Tools & Community Framework Setup..."

    # Sync bikeys from all downloaded mods
    mkdir -p "${KEYS_DIR}"
    count=0
    for key in $(find "${SERVER_ROOT}" -maxdepth 4 -name "*.bikey" 2>/dev/null); do
        keyname=$(basename "${key}")
        if [ ! -f "${KEYS_DIR}/${keyname}" ]; then
            cp "${key}" "${KEYS_DIR}/${keyname}"
            echo "[VPP-Setup] Installed key: ${keyname}"
            count=$((count+1))
        fi
    done
    if [ $count -gt 0 ]; then
        echo "[VPP-Setup] Installed ${count} mod key(s)."
    fi

    # Provision SuperAdmins (Default: 76561198022446661 - bluscream)
    mkdir -p "${VPP_SUPERADMINS_DIR}"
    SUPERADMIN_IDS="${VPP_SUPERADMINS:-76561198022446661}"
    superadmins_main="${VPP_SUPERADMINS_DIR}/SuperAdmins.txt"
    > "${superadmins_main}"

    for sid in $(echo "${SUPERADMIN_IDS}" | tr ',' ' '); do
        if [ -n "${sid}" ]; then
            admin_file="${VPP_SUPERADMINS_DIR}/${sid}.txt"
            echo "${sid}" > "${admin_file}"
            echo "${sid}" >> "${superadmins_main}"
            echo "[VPP-Setup] Provisioned SuperAdmin for SteamID: ${sid}"
        fi
    done

    # Sync VPP credentials with shared admin password
    mkdir -p "${VPP_BASE}/Permissions"
    echo "${ADMIN_PASSWORD}" > "${VPP_BASE}/Permissions/credentials.txt"
    echo "${ADMIN_PASSWORD}" > "${VPP_BASE}/credentials.txt"
    echo "[VPP-Setup] VPPAdminTools credentials synced with ADMIN_PASSWORD."
fi

# 4. Server-Side Custom Init Auto-Installer (init.c)
if [ -f "${MISSION_INIT}" ]; then
    if [ -f "${SERVER_ROOT}/dayz_init_server.c" ]; then
        # Marker must be unique to dayz_init_server.c. Do NOT grep for "CustomMission" --
        # vanilla mpmissions init.c already declares "class CustomMission: MissionServer",
        # so that guard matches on an untouched install and the custom init never lands.
        if ! grep -q "DAYZ_NOBE_CUSTOM_INIT" "${MISSION_INIT}"; then
            echo "[Server-Scripts] Installing custom server-side init.c..."
            cp "${MISSION_INIT}" "${MISSION_INIT}.bak.$(date +%Y%m%d%H%M%S)"
            cp "${SERVER_ROOT}/dayz_init_server.c" "${MISSION_INIT}"
            echo "[Server-Scripts] Applied dayz_init_server.c (previous init.c backed up alongside it)."
        else
            echo "[Server-Scripts] Custom init.c already installed."
        fi
    fi
fi

