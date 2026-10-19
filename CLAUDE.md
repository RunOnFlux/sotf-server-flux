# CLAUDE.md

Guidance for Claude Code in this repository.

## What this is

A **Docker image repo**, not an application: the Sons of the Forest dedicated server for Flux,
`runonflux/sotf-server-flux`. The server is **Windows-only** (Steam app 2465200, anonymous), so it runs
under Wine 10.0 staging-tkg (pinned by checksum) on Xvfb, like `~/work/vrising-server-flux` and
`~/work/enshrouded-server-flux`. Supervisor shape as `~/work/conanexiles-server-flux`.

**PID 1 is `flux-entrypoint.sh`, never the game.** The game is a child, so a stop reaches us first.

## Commands

```bash
./tests/test-flux.sh                                   # unit tests (flux-lib.sh, fluxsotf.py)
docker build --build-arg FLUX_IMAGE_VERSION=1.0.0 -t sotf-server-flux:local .
./tests/test-image.sh sotf-server-flux:local           # the scripts INSIDE the image, stand-in steamcmd + server
docker run --rm -v "$PWD:/m" -w /m koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh .github/ci/*.sh
```

A change to what the image does bumps `VERSION` and adds a line under "Versions" in the README.
A real-game test (heavy: ~7 GB RAM) needs the install volume: see README "Measured".

## The files

- `scripts/flux-entrypoint.sh`: per generation SteamCMD (Windows build), backup, `flux-sotf apply`, Xvfb,
  Wine prefix, server; watcher (ready line, Steam build follow, daily restart), backupper, log capper.
- `scripts/fluxsotf.py`: every rule about the server's files and the hub's commands. `merge_settings`
  is shared by the panel and `SOTF_SETTINGS_JSON`.
- `scripts/flux-lib.sh`: helpers; sourcing it must stay side-effect free.
- `tests/image/in-container.sh`: stand-in server (a Python script named `SonsOfTheForestDS.exe`; Python
  because bash cannot trap a SIGINT that is ignored on entry in a background job).

## Things that will bite you

- **The stop**: SIGINT to the game saves in ~1 s (log line `Autosave complete`); the teardown takes
  seconds more. We kill 2 s after the save line, 8 s at most (`FLUX_STOP_GRACE`). Do not make it longer
  than Docker's 10 s.
- **A first start without `dedicatedserver.cfg` makes the game write one and quit**: `apply` writes it first.
- **`SaveMode New` wipes the slot on every start**: apply honours it once (backup first), then Continue.
- **`CustomGameModeSettings` values**: PvpDamage is Off/Reduced/Normal (not Low/High); a value the
  game cannot read is logged "Using default value" and ignored. Only with GameMode Custom, only at creation.
- **SteamCMD "Missing configuration"** on a fresh install: `+app_info_update 1` and two `app_update`.
- **Xvfb is needed** even headless (world generation). Idle is ~55 % of a core: IdleTargetFramerate 5.
- **A state file left by a killed container** is reset to `updating` at the start of every generation.
- **No console, no RCON.** Players come from A2S on the query port (which answers with a challenge first).
- **Empty env = unset.** Flux stops a container with Docker's default 10 seconds.
