#!/usr/bin/env bash
# Cleanup script for DayZ server to purge stale logs, temporary crash reports, and superfluous doc files.
set -u

PROFILE_DIR="/home/container/serverprofile"
STEAM_LOGS="/home/container/Steam/logs"
ROOT_DIR="/home/container"

echo "[cleanup] Starting server cleanup..."

# 1. Clean up old DayZ server crash dumps, engine logs, and script logs from serverprofile
if [ -d "${PROFILE_DIR}" ]; then
    # Remove all past .RPT and .ADM files (the upcoming DayZServer process will generate fresh ones for the new session)
    deleted_rpt=$(find "${PROFILE_DIR}" -maxdepth 1 -type f \( -name "DayZServer_*.RPT" -o -name "DayZServer_*.ADM" -o -name "crash_*.log" -o -name "script_*.log" -o -name "error.log" \) -delete -print 2>/dev/null | wc -l)
    echo "[cleanup] Removed ${deleted_rpt} old session/crash/script log files from ${PROFILE_DIR}."

    # Remove old VPPAdminTools logs
    if [ -d "${PROFILE_DIR}/VPPAdminTools/Logging" ]; then
        deleted_vpp=$(find "${PROFILE_DIR}/VPPAdminTools/Logging" -type f -name "Log_*.txt" -delete -print 2>/dev/null | wc -l)
        echo "[cleanup] Removed ${deleted_vpp} VPPAdminTools log files."
    fi

    # Clean up empty or stale logs in WebApiLog and EventManagerLog
    if [ -d "${PROFILE_DIR}/WebApiLog" ]; then
        find "${PROFILE_DIR}/WebApiLog" -type f -name "*.log" -delete 2>/dev/null
    fi
    if [ -d "${PROFILE_DIR}/EventManagerLog" ]; then
        find "${PROFILE_DIR}/EventManagerLog" -type f -name "*.log" -delete 2>/dev/null
    fi
fi

# 2. Clean up SteamCMD log files
if [ -d "${STEAM_LOGS}" ]; then
    deleted_steam=$(find "${STEAM_LOGS}" -type f -delete -print 2>/dev/null | wc -l)
    echo "[cleanup] Removed ${deleted_steam} SteamCMD log files from ${STEAM_LOGS}."
fi

# 3. Clean up root temporary logs
if [ -f "${ROOT_DIR}/.steamcmd_mods.log" ]; then
    rm -f "${ROOT_DIR}/.steamcmd_mods.log"
    echo "[cleanup] Removed .steamcmd_mods.log."
fi

# 4. Clean up documentation / license / readme files from workshop/mod content
deleted_docs=$(find "${ROOT_DIR}/steamapps/workshop/content" -type f \( -iname "*readme*" -o -iname "*license*" -o -iname "*changelog*" \) -delete -print 2>/dev/null | wc -l)
if [ "${deleted_docs}" -gt 0 ]; then
    echo "[cleanup] Removed ${deleted_docs} documentation/readme files from workshop directory."
fi

# Remove redundant license files in mod symlink/folders if present
find "${ROOT_DIR}" -maxdepth 2 -type f \( -name "license" -o -name "LICENSE" -o -name "README.md" \) -not -path "${ROOT_DIR}/.git/*" -delete 2>/dev/null

echo "[cleanup] Server cleanup completed."
