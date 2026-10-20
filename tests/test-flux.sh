#!/bin/bash
# Unit tests: the pure decisions in flux-lib.sh and fluxsotf.py's file handling. No Docker, no
# Steam, no Wine, no game. Run from the repository root.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
export TZ=UTC

# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source scripts/flux-lib.sh

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- Inputs ------------------------------------------------------------------------------------
check "8766 is a port" "8766" "$(flux_port 8766 1)"
check "empty takes the default" "27016" "$(flux_port '' 27016)"
check "a leading zero is not octal" "9700" "$(flux_port 09700 1)"
check "port 80 is refused" "1" "$(status flux_port 80 1)"
check "a word is not a port" "1" "$(status flux_port abc 1)"
check "distinct ports" "0" "$(status flux_ports_distinct 8766 27016 9700)"
check "a port used twice" "1" "$(status flux_ports_distinct 8766 8766 9700)"
check "restart time 5:00" "05:00" "$(flux_restart_time 5:00)"
check "restart time off" "" "$(flux_restart_time off)"
check "restart time 24:00 refused" "1" "$(status flux_restart_time 24:00)"
# 2026-10-11 12:00 UTC = 1791720000
check "next 05:00 after noon is tomorrow" "$((1791720000 - 43200 + 86400 + 18000))" "$(flux_next_daily 1791720000 05:00)"
check "next 13:30 after noon is today" "$((1791720000 + 5400))" "$(flux_next_daily 1791720000 13:30)"
check "the wine path of a folder" 'Z:\mnt\sotf\data\userdata' "$(flux_wine_path /mnt/sotf/data/userdata)"

# --- Restart budget ----------------------------------------------------------------------------
check "old restarts drop out of the window" "950 990" "$(flux_restarts_in_window 1000 100 800 950 990)"
check "a crash counts" "0" "$(status flux_restart_counts 'the server ended on its own (exit 139)')"
check "a game update does not count" "1" "$(status flux_restart_counts 'planned: game update 1 -> 2')"
check "a panel restart does not count" "1" "$(status flux_restart_counts 'requested: from the panel')"
check "prune keeps the newest" "c d" "$(flux_files_to_prune 2 a b c d | tr '\n' ' ' | sed 's/ $//')"
check "marker notbefore" "123" "$(printf 'x\nnotbefore=123\n' >"${tmp}/m"; flux_marker_not_before "${tmp}/m")"
check "marker without notbefore" "0" "$(printf 'x\n' >"${tmp}/m"; flux_marker_not_before "${tmp}/m")"

# --- Log noise ---------------------------------------------------------------------------------
check "shader warnings are noise" "0" "$(status flux_noise <<<"WARNING: Shader Unsupported: 'Hidden/X' - All subshaders removed")"
check "blank lines are noise" "0" "$(status flux_noise <<<"   ")"
check "the ready line is not noise" "1" "$(status flux_noise <<<"Dedicated server loaded.")"
check "a save is not noise" "1" "$(status flux_noise <<<"#DSL Autosave complete. Time: 2026-10-18 21:35:27 Slot: 2")"

# --- Steam builds ------------------------------------------------------------------------------
printf '"AppState"\n{\n\t"appid"\t\t"2465200"\n\t"buildid"\t\t"20228410"\n}\n' >"${tmp}/manifest.acf"
check "installed build" "20228410" "$(flux_installed_build "${tmp}/manifest.acf")"
check "public build from app_info" "20300000" "$(printf '%s\n' '"2465200"' '{' '"depots"' '{' '"branches"' '{' '"public"' '{' '"buildid"		"20300000"' '}' | flux_public_build)"

# --- fluxsotf.py -------------------------------------------------------------------------------
data="${tmp}/data"
server="${tmp}/server"
mkdir -p "${server}/steamapps"
cp "${tmp}/manifest.acf" "${server}/steamapps/appmanifest_2465200.acf"
sotf() { # VAR=value... command args: fluxsotf.py with exactly these variables
  local vars=()
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  env -i PATH="${PATH}" HOME="${tmp}" FLUX_DATA_DIR="${data}" FLUX_SERVER_DIR="${server}" \
    FLUX_RESTART_MARKER="${tmp}/restart-marker" "${vars[@]}" python3 scripts/fluxsotf.py "$@"
}
jget() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d=d[int(k)] if isinstance(d,list) else d[k]
print(d if not isinstance(d,(dict,list)) else json.dumps(d))' "$1"; }
cfg() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "${data}/userdata/dedicatedserver.cfg" "$1"; }

sotf apply >"${tmp}/apply.out"
check "apply writes a config the game accepts" "Sons Of The Forest Server (dedicated)" "$(cfg ServerName)"
check "with the network test skipped" "True" "$(cfg SkipNetworkAccessibilityTest)"
check "and the owners file" "0" "$(status test -f "${data}/userdata/ownerswhitelist.txt")"
check "and steam_appid.txt next to the exe" "1326470" "$(cat "${server}/steam_appid.txt")"
check "in the game's key order" "IpAddress" "$(python3 -c 'import json,sys;print(next(iter(json.load(open(sys.argv[1])))))' "${data}/userdata/dedicatedserver.cfg")"

sotf SOTF_SERVER_NAME="Forest One" SOTF_MAX_PLAYERS=4 SOTF_GAME_MODE=hard SOTF_PASSWORD=pw SOTF_GAME_PORT=31000 SOTF_QUERY_PORT=31001 SOTF_BLOBSYNC_PORT=31002 apply >/dev/null
check "env sets the name" "Forest One" "$(cfg ServerName)"
check "env sets max players" "4" "$(cfg MaxPlayers)"
check "env's mode is spelled as the game spells it" "Hard" "$(cfg GameMode)"
check "env sets the ports" "31000 31001 31002" "$(cfg GamePort) $(cfg QueryPort) $(cfg BlobSyncPort)"

sotf set-settings '{"ServerName": "Panel Name", "MaxPlayers": 6}' >/dev/null
sotf SOTF_SERVER_NAME="Forest One" SOTF_MAX_PLAYERS=4 SOTF_GAME_MODE=hard SOTF_PASSWORD=pw SOTF_GAME_PORT=31000 SOTF_QUERY_PORT=31001 SOTF_BLOBSYNC_PORT=31002 apply >/dev/null
check "the same env does not undo the panel" "Panel Name 6" "$(cfg ServerName) $(cfg MaxPlayers)"
sotf SOTF_SERVER_NAME="Forest Two" SOTF_MAX_PLAYERS=4 SOTF_GAME_PORT=31000 SOTF_QUERY_PORT=31001 SOTF_BLOBSYNC_PORT=31002 apply >/dev/null
check "a changed env value applies" "Forest Two" "$(cfg ServerName)"
check "an empty env value leaves the file" "Hard" "$(sotf SOTF_GAME_MODE= SOTF_GAME_PORT=31000 SOTF_QUERY_PORT=31001 SOTF_BLOBSYNC_PORT=31002 apply >/dev/null; cfg GameMode)"
check "ports that clash are refused" "2" "$(status sotf SOTF_GAME_PORT=31000 SOTF_QUERY_PORT=31000 apply)"
check "a port below 1024 is refused" "2" "$(status sotf SOTF_GAME_PORT=80 apply)"
sotf SOTF_GAME_PORT=31000 SOTF_QUERY_PORT=31001 SOTF_BLOBSYNC_PORT=31002 apply >/dev/null

# Settings, validated.
check "a bad max players is refused" "1" "$(status sotf set-settings '{"MaxPlayers": 9}')"
check "and says which" "must be from 1 to 8" "$(sotf set-settings '{"MaxPlayers": 9}' | jget fields.MaxPlayers)"
check "an unknown key is refused" "1" "$(status sotf set-settings '{"Foo": 1}')"
check "ports are not the panel's" "1" "$(status sotf set-settings '{"GamePort": 1234}')"
check "an unknown custom key is refused" "1" "$(status sotf set-settings '{"CustomGameModeSettings": {"GameSetting.Vail.Nope": true}}')"
sotf set-settings '{"GameMode": "custom", "CustomGameModeSettings": {"GameSetting.Vail.EnemySpawn": "false", "GameSetting.Environment.SeasonLength": "long"}, "GameSettings": {"Structure.Damage": false}}' >/dev/null
check "custom mode" "Custom" "$(cfg GameMode)"
check "custom booleans are booleans" "False" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["CustomGameModeSettings"]["GameSetting.Vail.EnemySpawn"])' "${data}/userdata/dedicatedserver.cfg")"
check "custom choices are spelled as the game spells them" "Long" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["CustomGameModeSettings"]["GameSetting.Environment.SeasonLength"])' "${data}/userdata/dedicatedserver.cfg")"
sotf set-settings '{"CustomGameModeSettings": {"GameSetting.Vail.EnemySpawn": null}}' >/dev/null
check "null removes a custom key (the game's default)" "False" "$(python3 -c 'import json,sys;print("GameSetting.Vail.EnemySpawn" in json.load(open(sys.argv[1]))["CustomGameModeSettings"])' "${data}/userdata/dedicatedserver.cfg")"
check "settings lists the rules" "8" "$(sotf settings | jget rules.top.MaxPlayers.max)"
check "a password stays text" "1234" "$(sotf set-settings '{"Password": "1234"}' >/dev/null; python3 -c 'import json,sys;v=json.load(open(sys.argv[1]))["Password"];print(v if isinstance(v,str) else "NOT TEXT")' "${data}/userdata/dedicatedserver.cfg")"

# A broken file is kept aside and replaced.
echo "{ not json" >"${data}/userdata/dedicatedserver.cfg"
sotf SOTF_GAME_PORT=31000 SOTF_QUERY_PORT=31001 SOTF_BLOBSYNC_PORT=31002 apply >/dev/null
check "a broken config is replaced" "31000" "$(cfg GamePort)"
check "and kept aside" "1" "$(find "${data}/userdata" -name 'dedicatedserver.cfg.broken-*' | wc -l)"

# Owners.
check "owners start empty" "[]" "$(sotf owners | jget owners)"
sotf set-owners '{"owners": [{"id": "https://steamcommunity.com/profiles/76561198000000001/", "name": "Bob"}, "76561198000000002"]}' >/dev/null
check "owners are written one per line, a profile link read" "2" "$(grep -c '^7656119' "${data}/userdata/ownerswhitelist.txt")"
check "names come back from the comment above" "Bob" "$(sotf owners | jget owners.0.name)"
check "a bad id is refused" "1" "$(status sotf set-owners '{"owners": ["123"]}')"
sotf SOTF_OWNERS="76561198000000003, 76561198000000001" SOTF_GAME_PORT=31000 SOTF_QUERY_PORT=31001 SOTF_BLOBSYNC_PORT=31002 apply >/dev/null
check "SOTF_OWNERS adds, without duplicates" "3" "$(grep -c '^7656119' "${data}/userdata/ownerswhitelist.txt")"
check "and says which come from env" "76561198000000003" "$(sotf SOTF_OWNERS=76561198000000003 owners | jget fromEnv.0)"

# Saves.
mkslot() { # slot, game type, hours
  local d
  d="${data}/userdata/Saves/DedicatedServer/Multiplayer/$(printf '%010d' "$1")"
  mkdir -p "${d}"
  python3 - "${d}/SaveData.zip" "$2" "$3" <<'PY'
import json, sys, zipfile
state = json.dumps({"Version": "1.0.0", "SaveTime": "2026-10-18T21:01:03Z", "GameType": sys.argv[2], "GameHours": int(sys.argv[3]), "CrashSite": "ocean"})
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("GameStateSaveData.json", json.dumps({"Version": "0.0.0", "Data": {"GameState": state}}))
    z.writestr("GameSetupSaveData.json", "{}")
PY
  : >"${d}/SaveDataThumbnail.png"
}
mkslot 1 Normal 30
mkslot 3 Hard 100
check "saves lists the slots" "1,3" "$(sotf saves | python3 -c 'import json,sys;print(",".join(str(s["slot"]) for s in json.load(sys.stdin)["slots"]))')"
check "with the game mode" "Hard" "$(sotf saves | jget slots.1.gameType)"
check "and the hours played" "100" "$(sotf saves | jget slots.1.gameHours)"
check "the active slot" "1" "$(sotf saves | jget active)"
check "a slot out of range is refused" "1" "$(status sotf use-slot 100)"
sotf use-slot 3 >/dev/null
check "use-slot moves the config" "3" "$(cfg SaveSlot)"
check "the active slot cannot be deleted" "1" "$(status sotf delete-slot 3)"
check "another can" "0" "$(status sotf delete-slot 1)"
check "and is gone" "1" "$(status test -d "${data}/userdata/Saves/DedicatedServer/Multiplayer/0000000001")"

# A new world: the slot's world is backed up, then cleared, on the next apply.
sotf new-world 3 Peaceful >/dev/null
check "new-world sets the mode now" "Peaceful" "$(cfg GameMode)"
check "but the world is still there until the next start" "0" "$(status test -f "${data}/userdata/Saves/DedicatedServer/Multiplayer/0000000003/SaveData.zip")"
sotf SOTF_GAME_PORT=31000 SOTF_QUERY_PORT=31001 SOTF_BLOBSYNC_PORT=31002 apply >"${tmp}/apply.out"
check "the next start clears the slot" "1" "$(status test -e "${data}/userdata/Saves/DedicatedServer/Multiplayer/0000000003")"
check "after a backup" "1" "$(grep -c 'before a new world in slot 3' "${data}/flux/backups/index.json")"
check "and the file says Continue" "Continue" "$(cfg SaveMode)"

# SaveMode New in the file is honoured once.
mkslot 3 Normal 5
sotf set-settings '{"SaveMode": "New"}' >/dev/null
sotf SOTF_GAME_PORT=31000 SOTF_QUERY_PORT=31001 SOTF_BLOBSYNC_PORT=31002 apply >/dev/null
check "SaveMode New clears the slot once" "1" "$(status test -e "${data}/userdata/Saves/DedicatedServer/Multiplayer/0000000003")"
check "and becomes Continue" "Continue" "$(cfg SaveMode)"

# Every key of the file from the environment: SOTF_SETTINGS_JSON, SOTF_SAVE_SLOT, SOTF_SAVE_MODE.
P=(SOTF_GAME_PORT=31000 SOTF_QUERY_PORT=31001 SOTF_BLOBSYNC_PORT=31002)
sotf "${P[@]}" SOTF_SAVE_SLOT=4 SOTF_SETTINGS_JSON='{"GameSettings":{"Structure.Damage":true},"CustomGameModeSettings":{"GameSetting.Vail.EnemyHealth":"high","GameSetting.Nope":1},"SaveInterval":300}' apply >"${tmp}/env.out"
check "env SaveSlot" "4" "$(cfg SaveSlot)"
check "env SaveInterval from the JSON" "300" "$(cfg SaveInterval)"
check "env GameSettings from the JSON" "True" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["GameSettings"]["Structure.Damage"])' "${data}/userdata/dedicatedserver.cfg")"
check "env CustomGameModeSettings are normalised" "High" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["CustomGameModeSettings"]["GameSetting.Vail.EnemyHealth"])' "${data}/userdata/dedicatedserver.cfg")"
check "an unknown key is skipped with a warning" "1" "$(grep -c 'GameSetting.Nope' "${tmp}/env.out")"
sotf set-settings '{"SaveInterval": 900}' >/dev/null
sotf "${P[@]}" SOTF_SAVE_SLOT=4 SOTF_SETTINGS_JSON='{"GameSettings":{"Structure.Damage":true},"CustomGameModeSettings":{"GameSetting.Vail.EnemyHealth":"high","GameSetting.Nope":1},"SaveInterval":300}' apply >/dev/null
check "an unchanged env does not undo the panel" "900" "$(cfg SaveInterval)"
sotf "${P[@]}" SOTF_SETTINGS_JSON='not json' apply >"${tmp}/env.out"
check "a broken SOTF_SETTINGS_JSON is a warning, not a stop" "1" "$(grep -c 'WARN SOTF_SETTINGS_JSON is not a JSON object' "${tmp}/env.out")"
check "a port outside the range is an error" "2" "$(status_code() { "$@" >/dev/null 2>&1; echo $?; }; status_code sotf SOTF_GAME_PORT=80 apply)"
sotf set-settings '{"SaveSlot": 3, "SaveInterval": 600}' >/dev/null

# Import and export.
mkslot 5 Hard 12
sotf export-save 5 "${tmp}/out/slot5.zip" >/dev/null
check "export makes a zip of the folder" "0000000005/SaveData.zip" "$(python3 -c 'import zipfile,sys;print(sorted(zipfile.ZipFile(sys.argv[1]).namelist())[0])' "${tmp}/out/slot5.zip")"
cp "${tmp}/out/slot5.zip" "${tmp}/up.zip"
check "import into a slot with a world is refused" "1" "$(status sotf import-save "${tmp}/up.zip" 5)"
check "a save folder imports into an empty slot" "save folder" "$(sotf import-save "${tmp}/up.zip" 7 | jget kind)"
check "and reads as the same world" "12" "$(sotf saves | python3 -c 'import json,sys;print([s for s in json.load(sys.stdin)["slots"] if s["slot"]==7][0]["gameHours"])')"
check "the upload is removed" "1" "$(status test -e "${tmp}/up.zip")"
cp "${data}/userdata/Saves/DedicatedServer/Multiplayer/0000000005/SaveData.zip" "${tmp}/SaveData.zip"
check "a bare SaveData.zip imports too" "SaveData.zip" "$(sotf import-save "${tmp}/SaveData.zip" 8 | jget kind)"
python3 -c 'import zipfile,sys
with zipfile.ZipFile(sys.argv[1],"w") as z: z.writestr("readme.txt","hi")' "${tmp}/junk.zip"
check "a zip with no save is refused" "1" "$(status sotf import-save "${tmp}/junk.zip" 9)"
check "and leaves the slot empty" "1" "$(status test -e "${data}/userdata/Saves/DedicatedServer/Multiplayer/0000000009")"
python3 -c 'import zipfile,sys
with zipfile.ZipFile(sys.argv[1],"w") as z: z.writestr("../../evil/SaveData.zip","x")' "${tmp}/evil.zip"
check "a path out of the folder is refused" "1" "$(status sotf import-save "${tmp}/evil.zip" 9)"

# State, status and restart.
sotf state starting
check "starting moves the generation" "1" "$(sotf status | jget generation)"
sotf state running
check "running is running" "running" "$(sotf status | jget state)"
check "no query answer means unknown players, not zero" "None" "$(sotf status | jget playerCount)"
check "status has the build" "20228410" "$(sotf status | jget build)"
check "restart leaves a marker" "True" "$(sotf restart | jget restarting)"
check "the marker waits for the world to settle" "1" "$(grep -c '^notbefore=[1-9]' "${tmp}/restart-marker")"
rm -f "${tmp}/restart-marker"
sotf state stopped
check "restart refuses a stopped server" "1" "$(status sotf restart)"

# Backups and restore.
sotf state running
rm -rf "${data}/flux/backups"
sotf backup "test" force >/dev/null
check "a backup is made" "1" "$(sotf backups | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["backups"]))')"
check "a second within the hour is skipped" "1" "$(sotf backup "again" >/dev/null; sotf backups | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["backups"]))')"
name="$(sotf backups | jget backups.0.name)"
check "the backup lists its slots" "5" "$(sotf backups | jget backups.0.slots.0)"
rm -rf "${data}/userdata/Saves/DedicatedServer/Multiplayer/0000000005"
check "restore of a running server asks for a restart" "True" "$(sotf restore "${name}" | jget restarting)"
rm -f "${tmp}/restart-marker"
sleep 1
sotf do-restore >/dev/null
check "do-restore brings the slot back" "0" "$(status test -f "${data}/userdata/Saves/DedicatedServer/Multiplayer/0000000005/SaveData.zip")"
check "after a safety backup" "1" "$(grep -c 'before restoring' "${data}/flux/backups/index.json")"
check "restore refuses a name that is not a backup" "1" "$(status sotf restore ../../etc/passwd)"

# Update bookkeeping.
sotf update-target 20300000
sotf update-check >/dev/null
check "a target not reached is remembered" "0" "$(status sotf update-skip 20300000)"
check "another build is not skipped" "1" "$(status sotf update-skip 20400000)"

# A2S parsing (replies as the server sends them).
check "A2S_INFO parses" "Forest|0|8|True" "$(python3 -c '
import sys; sys.path.insert(0, "scripts"); import fluxsotf
body = b"\x49\x11" + b"Forest\x00map\x00sotf\x00Sons Of The Forest\x00" + b"\x00\x00" + bytes([0, 8, 0]) + b"dw\x01\x00" + b"1.0\x00"
d = fluxsotf.parse_info(body); print("%s|%d|%d|%s" % (d["name"], d["players"], d["maxPlayers"], d["password"]))')"
check "A2S_PLAYER parses" "Ana:120" "$(python3 -c '
import sys, struct; sys.path.insert(0, "scripts"); import fluxsotf
body = b"\x44\x01" + b"\x00Ana\x00" + struct.pack("<lf", 0, 120.5)
print(",".join("%s:%d" % (p["name"], p["seconds"]) for p in fluxsotf.parse_players(body)))')"

# --- flux.log: local, rotated, migrated; the start-up banner -------------------------------------
lt="$(mktemp -d)"
rule='====================================================================='
want="$(printf '%s\n %s server image by FluxCloud - https://runonflux.com\n Host this and 30+ other games in one click: https://runonflux.com/games\n%s' "${rule}" "Test Game" "${rule}")"
banner_out="$(FLUX_LOG="${lt}/logs/flux.log" flux_banner "Test Game")"
check "the banner is exactly the FluxCloud text" "${want}" "${banner_out}"
check "the banner is ASCII only" "0" "$(printf '%s' "${banner_out}" | LC_ALL=C grep -c -P '[^\x00-\x7F]')"
check "the banner goes to flux.log too" "${want}" "$(cat "${lt}/logs/flux.log")"
# shellcheck source=scripts/flux-lib.sh
check "flux.log lives in flux-logs on the install volume by default" "/x/flux-logs/flux.log" "$(unset FLUX_LOG FLUX_LOG_DIR; FLUX_SERVER_DIR=/x; source scripts/flux-lib.sh; echo "${FLUX_LOG}")"
check "an empty FLUX_LOG writes no file" "" "$(FLUX_LOG="" flux_log hello >/dev/null; ls "${lt}/none" 2>/dev/null)"
for i in $(seq 1 40); do FLUX_LOG="${lt}/logs/flux.log" FLUX_LOG_MAX_BYTES=500 flux_log "line number ${i} padding padding padding" >/dev/null; done
check "flux.log rotates to one .1" "1" "$([ -s "${lt}/logs/flux.log.1" ] && echo 1 || echo 0)"
check "and the live file stays under the cap" "1" "$([ "$(stat -c %s "${lt}/logs/flux.log")" -le 600 ] && echo 1 || echo 0)"
check "no second rotated copy" "1" "$(status test -e "${lt}/logs/flux.log.2")"
printf 'old 1\nold 2\n' >"${lt}/old.log"
printf 'new 1\n' >"${lt}/mig.log"
FLUX_LOG="${lt}/mig.log" flux_log_migrate "${lt}/old.log" "${lt}/absent.log"
check "an old flux.log is appended to the new one" "new 1 old 1 old 2" "$(tr '\n' ' ' <"${lt}/mig.log" | sed 's/ $//')"
check "and deleted from the data volume" "1" "$(status test -e "${lt}/old.log")"
check "migrating with nothing to migrate is harmless" "0" "$(FLUX_LOG="${lt}/mig.log" status flux_log_migrate "${lt}/old.log")"
rm -rf "${lt}"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
