#!/bin/bash
# shellcheck disable=SC2016  # wait_for conditions are single-quoted and eval-ed later, on purpose
# Runs INSIDE the image (tests/test-image.sh). The repository's tests/ folder is mounted at /t
# and scripts/ at /s.
set -uo pipefail
export LC_ALL=C

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
wait_for() {
  local _
  for _ in $(seq 1 $(($2 * 5))); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}

# --- What the scripts need is in the image -----------------------------------------------------
for tool in steamcmd python3 Xvfb wine wineboot wineserver pgrep pkill tail tar; do
  check "${tool} is installed" "0" "$(status command -v "${tool}")"
done
check "wine is the pinned build" "0" "$(status bash -c 'wine --version | grep -q "wine-10.0"')"
check "flux-sotf is on the PATH" "0" "$(status command -v flux-sotf)"
check "flux-sotf starts (usage)" "64" "$(status flux-sotf)"
for script in flux-entrypoint.sh flux-lib.sh; do
  check "${script} parses" "0" "$(status bash -n "/opt/flux/${script}")"
done
check "the image's scripts are the repository's" "0" "$(status diff -r --exclude=__pycache__ /s /opt/flux)"
check "the unit tests pass with the image's Python" "0" "$(status bash -c 'cd /tmp && rm -rf repo && mkdir repo && cp -r /s repo/scripts && cp -r /t repo/tests && cd repo && ./tests/test-flux.sh')"

# --- The supervisor, around a stand-in Steam and a stand-in server -----------------------------
# steamcmd "installs" the exe; wine runs a stand-in that behaves like the server where it matters:
# it reads dedicatedserver.cfg, prints the ready line, saves on SIGINT and then takes its time.
mkdir -p /usr/local/bin /opt/standin
cat >/usr/local/bin/steamcmd <<'STUB'
#!/bin/bash
dir=""
while [ $# -gt 0 ]; do
  [ "$1" = "+force_install_dir" ] && dir="$2"
  shift
done
[ -n "${dir}" ] || exit 0
mkdir -p "${dir}/steamapps"
: >"${dir}/SonsOfTheForestDS.exe"
printf '"AppState"\n{\n\t"buildid"\t\t"100"\n}\n' >"${dir}/steamapps/appmanifest_2465200.acf"
if [ -f /tmp/.installed ]; then echo "Success! App '2465200' already up to date."; else touch /tmp/.installed; echo "Success! App '2465200' fully installed."; fi
STUB
cat >/opt/standin/SonsOfTheForestDS.exe <<'GAME'
#!/usr/bin/env python3
# Named like the server so the supervisor finds it by `SonsOfTheForestDS.exe -userdatapath`.
# Python, not bash: a job started with & from a script has SIGINT ignored, and bash cannot trap a
# signal ignored on entry. Wine sets its own handler, as this does (signal.signal resets it).
import json, os, signal, sys, time
ud = sys.argv[2].replace("Z:", "", 1).replace("\\", "/")
slot = json.load(open(os.path.join(ud, "dedicatedserver.cfg")))["SaveSlot"]
d = os.path.join(ud, "Saves", "DedicatedServer", "Multiplayer", "%010d" % slot)
def save(what):
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "SaveData.zip"), "w") as f:
        f.write("save %s\n" % what)
    print("#DSL Autosave complete. Time: 2026-10-18 21:35:27 Slot: %d" % slot, flush=True)
def on_int(*_):
    save("quit")
    time.sleep(6)
    sys.exit(0)
signal.signal(signal.SIGINT, on_int)
print("WARNING: Shader Unsupported: 'Hidden/Noise' - All subshaders removed", flush=True)
print("[Dedicated] Starting Sons of the Forest Dedicated Server...", flush=True)
if not os.environ.get("DISPLAY") or os.environ.get("SteamAppId") != "1326470":
    print("no display or app id", flush=True)
    sys.exit(1)
save("start")
print("Dedicated server loaded.", flush=True)
while True:
    time.sleep(0.2)
GAME
chmod +x /usr/local/bin/steamcmd /opt/standin/SonsOfTheForestDS.exe
cat >/usr/local/bin/wine <<'STUB'
#!/bin/bash
shift
exec /opt/standin/SonsOfTheForestDS.exe "$@"
STUB
chmod +x /usr/local/bin/wine
export PATH="/usr/local/bin:${PATH}"
mkdir -p "${WINEPREFIX}/drive_c"

data=/mnt/sotf/data
export FLUX_RESTART_BACKOFF=1 FLUX_UPDATE_CHECK_MINUTES=0 SOTF_SERVER_NAME="Image Test" SOTF_MAX_PLAYERS=4 \
  SOTF_GAME_PORT=31000 SOTF_QUERY_PORT=31001 SOTF_BLOBSYNC_PORT=31002
/opt/flux/flux-entrypoint.sh >/tmp/entry.log 2>&1 &
entry=$!
check "the server comes up" "0" "$(status wait_for 'grep -q "\"running\"" ${data}/flux/state.json 2>/dev/null' 30)"
check "on the virtual display" "0" "$(status pgrep -x Xvfb)"
check "the config has the name" "Image Test" "$(python3 -c 'import json;print(json.load(open("'"${data}"'/userdata/dedicatedserver.cfg"))["ServerName"])')"
check "and the ports" "31001" "$(python3 -c 'import json;print(json.load(open("'"${data}"'/userdata/dedicatedserver.cfg"))["QueryPort"])')"
check "shader noise stays out of the container log" "0" "$(grep -c 'Shader Unsupported' /tmp/entry.log)"
check "but the game's lines reach it" "1" "$(grep -c 'Dedicated server loaded' /tmp/entry.log)"
check "the game log is on the install volume" "0" "$(status test -s /mnt/sotf/server/flux-logs/current.log)"

flux-sotf new-world 2 Peaceful >/dev/null
flux-sotf restart >/dev/null
check "a panel restart saves the world" "0" "$(status wait_for 'grep -q "save quit" ${data}/userdata/Saves/DedicatedServer/Multiplayer/0000000001/SaveData.zip' 20)"
check "and starts again on the new slot" "0" "$(status wait_for '[ "$(flux-sotf status | python3 -c "import json,sys;d=json.load(sys.stdin);print(d[\"state\"],d[\"generation\"],d[\"slot\"])")" = "running 2 2" ]' 30)"
check "the save cut the teardown short" "1" "$(grep -c 'the world is saved' /tmp/entry.log)"
check "the restart was not counted as a crash" "0" "$(grep -c 'restarts within' /tmp/entry.log)"
check "an up-to-date install is not retried" "0" "$(grep -c 'steamcmd failed' /tmp/entry.log)"
check "the new world's mode is in the config" "Peaceful" "$(python3 -c 'import json;print(json.load(open("'"${data}"'/userdata/dedicatedserver.cfg"))["GameMode"])')"

# A restore through the panel's command.
wait_for 'grep -q "\"running\"" ${data}/flux/state.json' 20
flux-sotf backup "test" force >/dev/null
backup="$(flux-sotf backups | python3 -c 'import json,sys;print(json.load(sys.stdin)["backups"][0]["name"])')"
rm -rf "${data}/userdata/Saves/DedicatedServer/Multiplayer/0000000001"
check "restore restarts the running server" "True" "$(flux-sotf restore "${backup}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["restarting"])')"
check "and the third start has slot 1 back" "0" "$(status wait_for '[ "$(flux-sotf status | python3 -c "import json,sys;print(json.load(sys.stdin)[\"generation\"])")" = 3 ] && test -f ${data}/userdata/Saves/DedicatedServer/Multiplayer/0000000001/SaveData.zip' 30)"

# A crash: restarted in place.
wait_for 'grep -q "\"running\"" ${data}/flux/state.json' 20
pkill -KILL -f '[S]onsOfTheForestDS\.exe -userdatapath'
check "a crashed server is started again" "0" "$(status wait_for '[ "$(flux-sotf status | python3 -c "import json,sys;d=json.load(sys.stdin);print(d[\"state\"],d[\"generation\"])")" = "running 4" ]' 30)"

start="$(date +%s)"
kill -TERM "${entry}"
check "a stop ends the supervisor" "0" "$(status wait_for '! kill -0 ${entry} 2>/dev/null' 20)"
check "inside Docker's 10 seconds although the game takes 6 after its save" "0" "$(status test $(($(date +%s) - start)) -le 5)"
check "and saves the world" "0" "$(status grep -q 'save quit' ${data}/userdata/Saves/DedicatedServer/Multiplayer/0000000002/SaveData.zip)"
check "and says stopped" "stopped" "$(python3 -c 'import json;print(json.load(open("'"${data}"'/flux/state.json"))["state"])')"

# A port the server cannot use is not a crash: the state says what to change and nothing restarts.
SOTF_GAME_PORT=80 /opt/flux/flux-entrypoint.sh >/tmp/entry2.log 2>&1 &
entry2=$!
check "a bad port gives the needs-fix state" "0" "$(status wait_for 'grep -q "needs-fix" ${data}/flux/state.json 2>/dev/null' 20)"
check "that names the variable" "1" "$(grep -c 'SOTF_GAME_PORT=80' ${data}/flux/state.json)"
check "and keeps the supervisor alive" "0" "$(status kill -0 ${entry2})"
kill -TERM "${entry2}"
check "a stop ends it" "0" "$(status wait_for '! kill -0 ${entry2} 2>/dev/null' 10)"

# --- flux.log is local; the banner ----------------------------------------------------------------
fl_srv=/mnt/sotf/server
fl_data=/mnt/sotf/data
check "flux.log is on the install volume" "0" "$(status test -s "${fl_srv}/flux-logs/flux.log")"
check "and not on the synced data volume" "1" "$(status test -e "${fl_data}/flux/flux.log")"
check "the banner is in the container output" "0" "$(status grep -q 'Sons Of The Forest server image by FluxCloud - https://runonflux.com' /tmp/entry.log)"
check "and in flux.log" "0" "$(status grep -q 'Host this and 30+ other games in one click: https://runonflux.com/games' "${fl_srv}/flux-logs/flux.log")"
check "at the container start and again for each generation" "1" "$([ "$(grep -c 'server image by FluxCloud' /tmp/entry.log)" -ge 2 ] && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ] || { echo '--- entrypoint log'; cat /tmp/entry.log; exit 1; }
