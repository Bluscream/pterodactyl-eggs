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
# Uses ADMIN_PASSWORD from egg config if set; otherwise auto-generates a clean, strong passphrase easy to type in chat (e.g. Wolf-Blue-772)
if [ -z "${ADMIN_PASSWORD}" ] || [ "${ADMIN_PASSWORD}" = "changeme" ] || [ "${ADMIN_PASSWORD}" = "default" ]; then
    WORDS=("Alpha" "Brave" "Delta" "Eagle" "Falcon" "Ghost" "Hunter" "Kodiak" "Nova" "Omega" "Phantom" "Shadow" "Tiger" "Viper" "Wolf")
    COLORS=("Blue" "Gold" "Iron" "Jade" "Onyx" "Ruby" "Silver" "Steel")
    R_W=${WORDS[$((RANDOM % ${#WORDS[@]}))]}
    R_C=${COLORS[$((RANDOM % ${#COLORS[@]}))]}
    R_N=$((RANDOM % 900 + 100))
    SECURE_PASS="${R_W}-${R_C}-${R_N}"
    export ADMIN_PASSWORD="${SECURE_PASS}"
    echo "[Security] Auto-generated Admin & RCON Passphrase: ${ADMIN_PASSWORD}"
else
    echo "[Security] Using Admin & RCON Passphrase configured in Egg."
fi

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

# 2.1 Sync Native MOTD in serverDZ.cfg
SERVER_CFG="${SERVER_ROOT}/serverDZ.cfg"
if [ -f "${SERVER_CFG}" ]; then
    if ! grep -q "motd\[\]" "${SERVER_CFG}"; then
        cat <<'EOF' >> "${SERVER_CFG}"

// Server Welcome & Automated Messages
motdInterval = 180;
motd[] = {
    "Welcome to Chernarus. Check chat commands: /help, /pos, /suicide",
    "Admin Tools: Press [Pause/Break] or open Pause Menu for VPPAdminTools.",
    "You hear faint whispers behind your back...",
    "Did you remember to check the backseat?",
    "A cold chill runs down your spine. You are not alone.",
    "Someone just chambered a round nearby.",
    "You feel like multiple pairs of eyes are watching you through the tree line...",
    "Was that twig snapping in the bushes behind you, or was it the wind?",
    "Your Geiger counter begins ticking faintly in the distance...",
    "You hear breathing right in your ear, but when you turn around, nothing is there.",
    "Check your pockets... did something just go missing?",
    "The crows suddenly went dead silent above the canopy.",
    "Type /admin <password> in chat to authenticate server-side admin sessions."
};
EOF
        echo "[Config] Added native MOTD announcements to serverDZ.cfg."
    fi
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

# 4. Server-Side Chat Logger & Slash Commands Auto-Installer (init.c)
if [ -f "${MISSION_INIT}" ]; then
    if ! grep -q "ChatMessageEventTypeID" "${MISSION_INIT}"; then
        echo "[Server-Scripts] Installing Server-Side Chat Logger & Slash Commands into init.c..."
        if [ -f "${SERVER_ROOT}/dayz_init_server.c" ]; then
            cp "${SERVER_ROOT}/dayz_init_server.c" "${MISSION_INIT}"
            echo "[Server-Scripts] Successfully applied custom init.c from dayz_init_server.c."
        fi
    else
        echo "[Server-Scripts] Chat Logger & Slash Commands already present in init.c."
    fi
fi
