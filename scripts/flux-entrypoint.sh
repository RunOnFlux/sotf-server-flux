#!/bin/bash
# PID 1, and the supervisor of the Sons of the Forest server.
#
# The game runs as a CHILD, never exec, so a stop reaches us first and becomes a save, and a
# server that ends on its own is followed by the next one in place:
#
#   - every start: SteamCMD update (the Windows build, anonymous), a backup of userdata/, then
#     dedicatedserver.cfg and ownerswhitelist.txt from the environment and the panel
#     (fluxsotf.py apply), then the server under Wine on a virtual display
#   - SIGTERM/SIGINT from Docker: SIGINT to the server, which reaches the Windows process as a
#     Ctrl+C: it saves at once ("Saved game successfully", measured) and then spends seconds
#     tearing down. Once the save is on disk the teardown is cut short, so a stop stays well
#     inside the 10 seconds Flux gives a container
#   - a new build on Steam: an outdated server refuses players on the new client, so it is
#     restarted onto it, as soon as nobody is playing or after FLUX_UPDATE_WAIT_MINUTES
#   - SOTF_RESTART_TIME: a daily restart at that time (in TZ, UTC when unset), on an empty server
#     if one comes within FLUX_RESTART_WAIT_MINUTES
#   - the server ending on its own: a new generation in the same container; FLUX_RESTART_MAX_ATTEMPTS
#     unplanned ones inside FLUX_RESTART_WINDOW seconds end the container with 42
#   - a backup of userdata/ on start (unless one is under an hour old) and every FLUX_BACKUP_HOURS,
#     kept on the data volume (flux/backups), and a backup restored when the panel asked for one
#   - the panel's restart (flux-sotf restart) is a marker: the supervisor stops the server for it
#
# Same shape as runonflux/corekeeper-server-flux; the Wine part as runonflux/vrising-server-flux.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
# How long a server asked to stop may take before it is killed. Docker's own deadline on Flux is
# ten seconds, so a stop from Docker (SIGTERM to us) gets FLUX_STOP_GRACE (8 s: it kills the game
# before Docker kills us, and the save has been on disk about 2 s after the signal, measured).
# A restart the panel or the daily timer asked for has nobody waiting on a deadline and gets
# FLUX_RESTART_GRACE, for a slow save of a big world.
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-8}"
FLUX_RESTART_GRACE="${FLUX_RESTART_GRACE:-60}"
# Once the save after a stop request is on disk, how long the game may go on tearing down.
FLUX_STOP_AFTER_SAVE="${FLUX_STOP_AFTER_SAVE:-2}"
FLUX_BACKUP_HOURS="${FLUX_BACKUP_HOURS:-6}"
export FLUX_BACKUP_KEEP="${FLUX_BACKUP_KEEP:-10}"
FLUX_UPDATE_CHECK_MINUTES="${FLUX_UPDATE_CHECK_MINUTES:-30}"
FLUX_UPDATE_WAIT_MINUTES="${FLUX_UPDATE_WAIT_MINUTES:-60}"
FLUX_RESTART_WAIT_MINUTES="${FLUX_RESTART_WAIT_MINUTES:-60}"
# The line the game prints once the world is up and players can join (build 20228410).
FLUX_READY_LINE="${FLUX_READY_LINE:-Dedicated server loaded.}"
# The line a save prints: "Autosave complete. Time: ... Slot: N" (and "Saved game successfully"
# with -verboseLogging). On SIGINT it comes about a second after the signal (measured).
FLUX_SAVED_LINE="${FLUX_SAVED_LINE:-Autosave complete|Saved game successfully}"

s="${FLUX_SERVER_DIR}"
sotf() { python3 /opt/flux/fluxsotf.py "$@"; }

rm -f "${FLUX_RESTART_MARKER}"
mkdir -p "${s}" "${FLUX_USERDATA}" "${FLUX_STATE_DIR}" "${FLUX_GAME_LOG_DIR}"
# An older image kept flux.log on the synced data volume: move it here, once.
flux_log_migrate "${FLUX_STATE_DIR}/flux.log"
flux_banner "Sons Of The Forest"

if ! restart_at="$(flux_restart_time "${SOTF_RESTART_TIME:-}")"; then
  flux_log "WARN SOTF_RESTART_TIME='${SOTF_RESTART_TIME}' is not HH:MM; no daily restart"
  restart_at=""
fi
flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev}, wine ${FLUX_WINE_VERSION:-unknown})"

game_pid=""
tail_pid=""
watch_pid=""
backup_pid=""
cap_pid=""
terminating=0
generation=0
restart_history=()
xvfb_pid=""
stop_saves=""

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested: saving the world and shutting down, no restart will follow"
  stop_game
}
trap term_handler TERM INT

# SIGINT to the game (a Ctrl+C under Wine: it saves, then quits), remembering how many saves the
# log had, so the wait below knows when the one it asked for is done.
stop_game() {
  local pid
  stop_saves="$(grep -c -E "${FLUX_SAVED_LINE}" "$(flux_game_log)" 2>/dev/null)"
  pid="$(flux_game_pid)"
  pid="${pid:-${game_pid}}"
  [ -n "${pid}" ] && kill -INT "${pid}" 2>/dev/null
}

# The virtual display. One for the container's life; started again if it died.
ensure_display() {
  if [ -n "${xvfb_pid}" ] && kill -0 "${xvfb_pid}" 2>/dev/null; then
    return 0
  fi
  rm -f "/tmp/.X${FLUX_DISPLAY#:}-lock"
  Xvfb "${FLUX_DISPLAY}" -screen 0 1024x768x24 -nolisten tcp >/dev/null 2>&1 &
  xvfb_pid=$!
  sleep 1
  kill -0 "${xvfb_pid}" 2>/dev/null
}

# The Wine prefix, on the install volume (local to the node, made again on a new one).
ensure_prefix() {
  [ -d "${WINEPREFIX}/drive_c" ] && return 0
  flux_log "creating the Wine prefix (once per node)"
  mkdir -p "${WINEPREFIX}"
  DISPLAY="${FLUX_DISPLAY}" wineboot --init >/dev/null 2>&1
  wineserver -w 2>/dev/null
  [ -d "${WINEPREFIX}/drive_c" ]
}

update_server() {
  local attempt validate
  if flux_truthy "${SKIP_UPDATE:-}" && [ -f "${s}/${FLUX_GAME_EXE}" ]; then
    flux_log "SKIP_UPDATE is set: not updating the server files"
    return 0
  fi
  sotf state updating "Downloading the server from Steam"
  flux_log "updating the server from Steam (app ${FLUX_STEAM_APP}, Windows build)"
  # No `validate` on the first attempt: it re-hashes the whole 3.4 GB install on every start. An
  # install that is actually broken fails the first attempt, and every retry validates.
  validate=""
  for attempt in 1 2 3 4 5; do
    # app_info_update + a second app_update: SteamCMD answers "Missing configuration" to a first
    # app_update of this app on a fresh SteamCMD (measured 2026-10-18), and stops there.
    # shellcheck disable=SC2086  # validate is "" or "validate"
    steamcmd +@sSteamCmdForcePlatformType windows +force_install_dir "${s}" +login anonymous \
      +app_info_update 1 +app_update "${FLUX_STEAM_APP}" +app_update "${FLUX_STEAM_APP}" ${validate} +quit \
      >/tmp/steamcmd.log 2>&1 &
    wait $!
    # "fully installed" after a download, "already up to date" otherwise.
    if [ -f "${s}/${FLUX_GAME_EXE}" ] && grep -qE "fully installed|already up to date" /tmp/steamcmd.log; then
      flux_log "server build $(flux_installed_build "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
      return 0
    fi
    [ "${terminating}" = "1" ] && return 1
    validate="validate"
    flux_log "WARN steamcmd failed (attempt ${attempt}/5): $(grep -aE 'ERROR|Error|error' /tmp/steamcmd.log | tail -2 | tr '\n' ' ')retrying in 5s with validate"
    sleep 5 &
    wait $!
  done
  if [ -f "${s}/${FLUX_GAME_EXE}" ]; then
    flux_log "WARN could not update from Steam; starting the build already installed"
    return 0
  fi
  flux_log "ERROR could not install the server from Steam"
  return 1
}

# A backup (fluxsotf.py backup: what goes in, what is skipped and what is kept). $2 = force.
backup_world() {
  local line
  while IFS= read -r line; do
    flux_log "${line#\# }"
  done < <(sotf backup "$1" ${2:+"$2"} 2>&1)
}

# shellcheck disable=SC2329  # run in the background below
backupper() {
  [ "${FLUX_BACKUP_HOURS}" -gt 0 ] 2>/dev/null || exit 0
  while true; do
    sleep $((FLUX_BACKUP_HOURS * 3600))
    backup_world "every ${FLUX_BACKUP_HOURS}h"
  done
}

request_restart() {
  [ -f "${FLUX_RESTART_MARKER}" ] && return 0
  printf '%s\nnotbefore=0\n' "$1" >"${FLUX_RESTART_MARKER}"
  flux_log "$1: restarting the server"
}

# shellcheck disable=SC2329  # run in the background below
# The current game log, capped at FLUX_GAME_LOG_MAX_BYTES: its last 5 MB go to a rotated file and
# the live one is emptied in place (the game keeps writing it).
log_capper() {
  local current size
  current="$(flux_game_log)"
  while true; do
    sleep 60
    size="$(stat -c %s "${current}" 2>/dev/null || echo 0)"
    if [ "${size}" -gt "${FLUX_GAME_LOG_MAX_BYTES}" ] 2>/dev/null; then
      tail -c 5242880 "${current}" >"${FLUX_GAME_LOG_DIR}/$(date -u +%Y%m%d-%H%M%S)-server.log" 2>/dev/null
      : >"${current}"
      flux_prune "${FLUX_GAME_LOG_DIR}" '*-server.log' "${FLUX_GAME_LOG_KEEP}"
      flux_log "the game log reached $((size / 1048576)) MB: rotated"
    fi
  done
}

# Waits for an empty server for up to $1 minutes, checking every minute.
wait_for_empty() {
  local until=$(($(date -u +%s) + $1 * 60)) n
  while [ "$(date -u +%s)" -lt "${until}" ]; do
    n="$(sotf players 2>/dev/null)"
    [ "${n}" = "0" ] && return 0
    sleep 60
  done
  return 0
}

# shellcheck disable=SC2329  # run in the background below
# Marks the server running once the world is up, then follows Steam for a newer build and keeps
# the daily restart.
watcher() {
  local line build public last_check now next_restart=""
  last_check="$(date -u +%s)"
  while IFS= read -r line; do
    if [[ "${line}" == *"${FLUX_READY_LINE}"* ]]; then
      sotf state running
      flux_log "the server is up (generation ${generation})"
      break
    fi
  done < <(tail -n +1 -F "$(flux_game_log)" 2>/dev/null)
  if [ -n "${restart_at}" ]; then
    next_restart="$(flux_next_daily "$(date -u +%s)" "${restart_at}")"
    sotf note nextRestart "${next_restart}"
  else
    sotf note nextRestart
  fi
  sotf note updateWaiting
  while true; do
    sleep 60
    now="$(date -u +%s)"
    if [ "${FLUX_UPDATE_CHECK_MINUTES}" -gt 0 ] 2>/dev/null && [ $((now - last_check)) -ge $((FLUX_UPDATE_CHECK_MINUTES * 60)) ]; then
      last_check="${now}"
      build="$(flux_installed_build "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
      public="$(steamcmd +login anonymous +app_info_update 1 +app_info_print "${FLUX_STEAM_APP}" +quit 2>/dev/null | flux_public_build)"
      if [ -n "${public}" ] && [ -n "${build}" ] && [ "${public}" != "${build}" ] && ! sotf update-skip "${public}"; then
        flux_log "a new server build is on Steam (${build} -> ${public}): restarting onto it when the server is empty, at most ${FLUX_UPDATE_WAIT_MINUTES} min from now"
        sotf note updateWaiting "${public}"
        wait_for_empty "${FLUX_UPDATE_WAIT_MINUTES}"
        sotf update-target "${public}"
        request_restart "planned: game update ${build} -> ${public}"
        exit 0
      fi
    fi
    if [ -n "${next_restart}" ] && [ "${now}" -ge "${next_restart}" ]; then
      flux_log "daily restart (${restart_at} ${TZ:-UTC}): waiting up to ${FLUX_RESTART_WAIT_MINUTES} min for an empty server"
      wait_for_empty "${FLUX_RESTART_WAIT_MINUTES}"
      request_restart "planned: the daily restart (${restart_at} ${TZ:-UTC})"
      exit 0
    fi
  done
}

# shellcheck disable=SC2329  # run in the background below
# The game's console onto the container's output, without the lines Unity prints for a GPU the
# server does not have (the full output stays in the game log).
log_follower() {
  local line
  while IFS= read -r line; do
    flux_noise <<<"${line}" || printf '%s\n' "${line}"
  done < <(tail -n 0 -F "$1" 2>/dev/null)
}

start_generation() {
  local line current userdata
  generation=$((generation + 1))
  rm -f "${FLUX_RESTART_MARKER}"
  # A state left by the container that was here before (a kill, a node reboot) is stale from now on.
  sotf state updating "Preparing the server"

  update_server || return 1
  while IFS= read -r line; do flux_log "${line#\# }"; done < <(sotf update-check 2>&1)
  [ "${terminating}" = "1" ] && return 2
  # A restore the panel asked for, before anything reads the server's files.
  while IFS= read -r line; do flux_log "restore: ${line#\# }"; done < <(sotf do-restore 2>&1)
  backup_world "start"

  local applied
  if applied="$(sotf apply 2>/tmp/flux-apply.err)"; then
    while IFS= read -r line; do [ -n "${line}" ] && flux_log "config: ${line#\# }"; done <<<"${applied}"
  else
    while IFS= read -r line; do [ -n "${line}" ] && flux_log "config: ${line#\# }"; done <<<"${applied}"
    printf '%s\n' "${applied}" >/tmp/flux-apply.out
    flux_log "ERROR the settings could not be applied: $(grep -h ERROR <<<"${applied}" | tr '\n' ' ')$(tail -3 /tmp/flux-apply.err | tr '\n' ' ')"
    return 3
  fi

  if ! ensure_display; then
    flux_log "ERROR the virtual display (Xvfb) did not start"
    return 1
  fi
  if ! ensure_prefix; then
    flux_log "ERROR the Wine prefix could not be created"
    return 1
  fi

  current="$(flux_game_log)"
  if [ -s "${current}" ]; then
    mv "${current}" "${FLUX_GAME_LOG_DIR}/$(date -u +%Y%m%d-%H%M%S)-server.log"
  fi
  : >"${current}"
  flux_prune "${FLUX_GAME_LOG_DIR}" '*-server.log' "${FLUX_GAME_LOG_KEEP}"
  [ "${terminating}" = "1" ] && return 2

  userdata="$(flux_wine_path "${FLUX_USERDATA}")"
  sotf state starting "Loading the world"
  flux_banner "Sons Of The Forest"
  flux_log "starting the server (generation ${generation})"

  log_follower "${current}" &
  tail_pid=$!

  (
    cd "${s}" || exit 1
    export DISPLAY="${FLUX_DISPLAY}" SteamAppId="${FLUX_GAME_APP_ID}" SteamGameId="${FLUX_GAME_APP_ID}"
    # stdin closed: the server has no console commands (it says "Failed to get input console mode").
    exec wine "${s}/${FLUX_GAME_EXE}" -userdatapath "${userdata}" </dev/null >>"${current}" 2>&1
  ) &
  game_pid=$!

  watcher &
  watch_pid=$!
  backupper &
  backup_pid=$!
  log_capper &
  cap_pid=$!
  return 0
}

sweep_generation() {
  local pid
  for pid in "${tail_pid}" "${watch_pid}" "${backup_pid}" "${cap_pid}"; do
    [ -n "${pid}" ] && kill "${pid}" 2>/dev/null
  done
  tail_pid="" watch_pid="" backup_pid="" cap_pid=""
  pkill -f "tail -n [0+1]* -F $(flux_game_log)" 2>/dev/null
  pkill -KILL -f "${FLUX_GAME_PATTERN}" 2>/dev/null
  # Whatever Wine left behind for this generation (services.exe, explorer.exe, the crash handler).
  wineserver -k 2>/dev/null
  game_pid=""
}

# Waits for the game to end. A stop or restart asked for is SIGINT (stop_game); once its save is
# in the log the game gets FLUX_STOP_AFTER_SAVE seconds to finish, and FLUX_STOP_GRACE (a stop) or FLUX_RESTART_GRACE (a restart) in all.
wait_for_generation() {
  local asked_at=0 saved_at=0 now signalled=0 saves grace
  while kill -0 "${game_pid}" 2>/dev/null; do
    sleep 0.5 &
    wait $!
    if [ "${signalled}" = "0" ] && [ "${terminating}" = "0" ] && [ -f "${FLUX_RESTART_MARKER}" ] \
      && [ "$(date -u +%s)" -ge "$(flux_marker_not_before "${FLUX_RESTART_MARKER}")" ]; then
      signalled=1
      stop_game
    fi
    if [ "${terminating}" = "1" ] || [ "${signalled}" = "1" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      if [ "${saved_at}" = "0" ]; then
        saves="$(grep -c -E "${FLUX_SAVED_LINE}" "$(flux_game_log)" 2>/dev/null)"
        if [ "${saves:-0}" -gt "${stop_saves:-0}" ] 2>/dev/null; then
          saved_at="${now}"
          flux_log "the world is saved ($((now - asked_at))s after the stop request)"
        fi
      fi
      if [ "${saved_at}" != "0" ] && [ $((now - saved_at)) -ge "${FLUX_STOP_AFTER_SAVE}" ]; then
        kill -KILL "${game_pid}" 2>/dev/null
        pkill -KILL -f "${FLUX_GAME_PATTERN}" 2>/dev/null
        break
      fi
      grace="${FLUX_RESTART_GRACE}"
      [ "${terminating}" = "1" ] && grace="${FLUX_STOP_GRACE}"
      if [ $((now - asked_at)) -ge "${grace}" ]; then
        flux_log "WARN the server was asked to stop ${grace}s ago and has not; ending it"
        kill -KILL "${game_pid}" 2>/dev/null
        pkill -KILL -f "${FLUX_GAME_PATTERN}" 2>/dev/null
        break
      fi
    fi
  done
  wait "${game_pid}" 2>/dev/null
}

# The environment holds a port the server cannot use: restarting cannot fix it and exiting would
# only make the platform restart the same container, so the state says what to change and the
# container waits (no restart budget used) for a stop or the panel's restart.
wait_for_fix() {
  local why
  why="$(grep -ah 'ERROR' /tmp/flux-apply.out 2>/dev/null | head -1 | sed 's/^# ERROR //')"
  sotf state needs-fix "${why:-The settings in the environment cannot be used}. Change it in the app's deployment settings; the server starts after a redeploy."
  flux_log "not restarting: ${why}. Waiting for a redeploy."
  while [ "${terminating}" = "0" ] && [ ! -f "${FLUX_RESTART_MARKER}" ]; do
    sleep 2 &
    wait $!
  done
  rm -f "${FLUX_RESTART_MARKER}"
}

while true; do
  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request before the server started"
    sotf state stopped
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "3" ]; then
    wait_for_fix
    continue
  fi
  if [ "${started}" = "2" ]; then
    flux_log "stopped on request before the server started"
    sotf state stopped
    exit 0
  elif [ "${started}" != "0" ]; then
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    sotf state crashed "The server could not be installed or started"
    exit 42
  fi
  wait_for_generation
  rc=$?

  reason=""
  if [ -f "${FLUX_RESTART_MARKER}" ]; then
    reason="$(head -1 "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  fi
  sweep_generation
  rm -f "${FLUX_RESTART_MARKER}"

  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request (server exited ${rc})"
    sotf state stopped
    exit 0
  fi

  [ -z "${reason}" ] && reason="the server ended on its own (exit ${rc})"

  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s, so restarting it here is not working. Ending the container so the platform can rebuild or move it (42)."
      sotf state crashed "The server keeps stopping: ${reason}"
      exit 42
    fi
  fi

  sotf state restarting "${reason}"
  flux_log "${reason}: restarting the server in place in ${FLUX_RESTART_BACKOFF}s"
  sleep "${FLUX_RESTART_BACKOFF}" &
  wait $!
done
