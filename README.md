# sotf-server-flux

Sons of the Forest dedicated server for Flux: `runonflux/sotf-server-flux`.

Endnight ships the dedicated server for Windows only (Steam app 2465200, anonymous download), so the
image runs it under Wine 10.0 staging-tkg (the Wine of our V Rising and Enshrouded images) on a
virtual display (Xvfb: the world generation needs one). Base `steamcmd/steamcmd:ubuntu-24`. PID 1 is a
bash supervisor (`flux-entrypoint.sh`); `flux-sotf` (`fluxsotf.py`) holds every decision about the
game's files and is the hub's CLI.

- SteamCMD update of the Windows build on every start (anonymous), retried with `validate`.
- `dedicatedserver.cfg` and `ownerswhitelist.txt` written from the environment and the hub's panel.
- **Saves on stop inside Docker's 10 s** (see "The stop"), and every `SaveInterval` seconds.
- Crash restart in place (5 in an hour, then exit 42), game-update following, optional daily restart.
- Backups of `userdata/` (start, every 6 h, before a restore / new world), restore, save slots,
  import/export of a save, A2S status and players, a JSON status for the hub.
- **Settings the environment cannot fix are not a crash**: state `needs-fix`, nothing restarts.

## Volumes

| Path | What | Flux mount |
|---|---|---|
| `/mnt/sotf/server` | game install (3.2 GB), Wine prefix (`flux-wine`), game logs | `ml:` (local, never synced) Also `flux-logs/flux.log` (our supervisor log, 5 MB then one `.1`): local, never synced. |
| `/mnt/sotf/data` | `userdata/` (saves, `dedicatedserver.cfg`, `ownerswhitelist.txt`), `flux/` (state, backups) | `g:` primary |

## Ports (UDP)

GamePort 8766, QueryPort 27016 (Steam A2S), BlobSyncPort 9700. Each can be changed with
`SOTF_GAME_PORT`, `SOTF_QUERY_PORT`, `SOTF_BLOBSYNC_PORT` (1024-65535, all different).

## Environment

Empty = unset. A value is written to the file when the file is new or the value changed since the last
start, so the hub's panel edits survive restarts.

| Variable | Writes | Default |
|---|---|---|
| `SOTF_SERVER_NAME` | ServerName | `Sons Of The Forest Server (dedicated)` |
| `SOTF_PASSWORD` | Password (<= 40 chars) | none |
| `SOTF_MAX_PLAYERS` | MaxPlayers 1-8 | 8 |
| `SOTF_GAME_MODE` | GameMode Normal/Hard/HardSurvival/Peaceful/Creative/Custom | Normal |
| `SOTF_SAVE_SLOT`, `SOTF_SAVE_MODE` | SaveSlot 1-99, SaveMode Continue/New (New is honoured **once**, the slot is backed up first) | 1, Continue |
| `SOTF_SAVE_INTERVAL` | SaveInterval 60-3600 s | 600 |
| `SOTF_SKIP_NETWORK_TEST` | SkipNetworkAccessibilityTest | true |
| `SOTF_OWNERS` | ownerswhitelist.txt: SteamID64s, comma separated | none |
| `SOTF_SETTINGS_JSON` | any other key, one JSON object: top-level keys, `GameSettings`, `CustomGameModeSettings`, validated like the panel | none |
| `SOTF_RESTART_TIME` | daily restart `HH:MM` (TZ, UTC if unset) | none |
| `SKIP_UPDATE` | do not run SteamCMD (an install must exist) | off |
| `FLUX_STOP_GRACE` / `FLUX_RESTART_GRACE` | seconds a stop / a planned restart may take | 8 / 60 |
| `FLUX_BACKUP_HOURS`, `FLUX_BACKUP_KEEP` | backup cadence and count | 6, 10 |
| `FLUX_RESTART_MAX_ATTEMPTS`, `FLUX_RESTART_WINDOW` | crash budget | 5 per 3600 s |

`CustomGameModeSettings` only apply with GameMode Custom and only when a world is created.

## The stop

Docker (and FluxOS) give a container 10 s. On SIGTERM the supervisor sends SIGINT to the server,
which under Wine is a Ctrl+C: the game writes a save at once (`Autosave complete`, in the log within
about a second), then spends several seconds tearing down. The supervisor waits for that line
(`FLUX_SAVED_LINE`), gives the game 2 s more, and kills it; if the line does not come in 8 s it kills
anyway. Measured: `docker stop` 2.8-3.2 s, exit 0, save file rewritten. A `kill -9` of the container
loses at most `SaveInterval` seconds: the next start loads the last autosave.

## For the hub

`flux-sotf status` (state, generation, slot, ports, build, players via A2S, pending restart/restore),
`settings` / `set-settings '<json>'`, `saves`, `use-slot`, `new-world <slot> [mode]`, `delete-slot`,
`import-save <file> <slot>`, `export-save <slot> <file>`, `owners` / `set-owners`, `players`,
`backups`, `backup`, `restore <name>`, `restart`. States: `updating`, `starting`, `running`,
`restarting`, `needs-fix` (message names the variable), `crashed`, `stopped`. The game log is
`/mnt/sotf/server/flux-logs/current.log`; the container's stdout carries it too. The game has no
console commands and no RCON.

## Measured (build 20228410, Wine 10.0, 2026-10-19, 20-core host)

First start with download and Wine prefix ~178 s; later starts 50-60 s to `Dedicated server loaded.`
Idle empty server 6.4-6.6 GiB RAM, ~55 % of one core (docker stats); 7.6 GiB with a custom-mode
world loaded. Install 3.2 GB + 0.6 GB prefix. Image 1.37 GB.

## Versions

- 1.0.0: first release.
- 1.0.1 (2026-10-20): `flux.log` moved off the synced data volume to `/mnt/sotf/server/flux-logs/flux.log` (5 MB, one `.1`; an old one is moved there once); start-up banner; the weekly rebuild only when it has something to apply.
