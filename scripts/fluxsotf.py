#!/usr/bin/env python3
"""Every decision about the Sons of the Forest server's files, and the hub's commands.

    fluxsotf.py apply                write dedicatedserver.cfg and ownerswhitelist.txt from the
                                     environment and the panel, carry out a pending new world;
                                     "# " notes on stdout (the entrypoint logs them)
    fluxsotf.py state <state> [msg]  record what the supervisor is doing (flux/state.json)

    flux-sotf status                 state, players (A2S), the save slot, build (one JSON document)
    flux-sotf settings               dedicatedserver.cfg as the panel edits it, with the defaults
    flux-sotf set-settings '<json>'  {"ServerName": "...", "GameMode": "Custom",
                                     "CustomGameModeSettings": {"GameSetting.Vail.EnemySpawn": false}, ...}
                                     validated key by key; written at once, read on the next start
    flux-sotf saves                  the save slots: which exist, game mode, days, size, age
    flux-sotf use-slot <n>           play slot n from the next start (it is made if it is empty)
    flux-sotf new-world <n> [mode]   a NEW world in slot n on the next start (whatever is in that
                                     slot is backed up first, then cleared)
    flux-sotf delete-slot <n>        delete a slot that is not the one being played
    flux-sotf import-save <zip> <n>  a save brought from elsewhere (a co-op host's save folder,
                                     zipped, or its SaveData.zip) into an EMPTY slot n
    flux-sotf export-save <n> <out>  slot n as one .zip (what import-save takes back)
    flux-sotf owners                 the SteamID64s in ownerswhitelist.txt (the server's admins)
    flux-sotf set-owners '<json>'    {"owners": [{"id": "7656...", "name": "Bob"}, ...]}
    flux-sotf restart                save, stop and start the server again (applies the above)
    flux-sotf backups                the backups in flux/backups (name, size, date, why, slots)
    flux-sotf restore <backup>       restore one on the next start (the server is restarted now),
                                     after a safety backup of what is there

    fluxsotf.py backup <why> [force] make a backup (the supervisor); skipped when the newest is
                                     younger than FLUX_BACKUP_MIN_AGE_MINUTES unless forced
    fluxsotf.py do-restore           apply a pending restore (the supervisor, before a start)
    fluxsotf.py note <key> [value]   a field of flux/state.json (nextRestart, updateWaiting)
    fluxsotf.py update-target <b>    remember the build a planned update restart is for
    fluxsotf.py update-check         after the update step: a target not reached is remembered
    fluxsotf.py update-skip <b>      exit 0 when that build failed less than 6 hours ago
    fluxsotf.py players              the A2S player count, or nothing when the server is silent

The game reads dedicatedserver.cfg and ownerswhitelist.txt once, as it starts, and never writes
them back (measured, build 20228410: the cfg is byte-identical after a run and a stop). So the
panel writes them directly and a restart applies them.

ENVIRONMENT APPLIES WHEN IT CHANGES. A deploy's SOTF_* value is written into the file on the
first start, and again whenever it is DIFFERENT from the value last applied (flux/env-applied.json):
a redeploy with a new name renames the server, while a name changed in the panel afterwards is
not undone by the same old env on every restart. The ports are the exception: they are written
on every start, because the server must bind exactly the ports Flux publishes.
"""

import json
import os
import re
import shutil
import socket
import struct
import sys
import tarfile
import tempfile
import time
import zipfile

SERVER_DIR = os.environ.get("FLUX_SERVER_DIR", "/mnt/sotf/server")
DATA_DIR = os.environ.get("FLUX_DATA_DIR", "/mnt/sotf/data")
USERDATA = os.environ.get("FLUX_USERDATA", os.path.join(DATA_DIR, "userdata"))
CONFIG_FILE = os.path.join(USERDATA, "dedicatedserver.cfg")
OWNERS_FILE = os.path.join(USERDATA, "ownerswhitelist.txt")
SAVES_DIR = os.path.join(USERDATA, "Saves", "DedicatedServer", "Multiplayer")
STATE_DIR = os.environ.get("FLUX_STATE_DIR", os.path.join(DATA_DIR, "flux"))
STATE_FILE = os.path.join(STATE_DIR, "state.json")
ENV_APPLIED_FILE = os.path.join(STATE_DIR, "env-applied.json")
NEW_WORLD_FILE = os.path.join(STATE_DIR, "new-world.json")
BACKUP_DIR = os.environ.get("FLUX_BACKUP_DIR", os.path.join(STATE_DIR, "backups"))
BACKUP_INDEX = os.path.join(BACKUP_DIR, "index.json")
RESTORE_FILE = os.path.join(STATE_DIR, "restore-pending.json")
UPDATE_TARGET_FILE = os.path.join(STATE_DIR, "update-target.json")
UPDATE_FAILED_FILE = os.path.join(STATE_DIR, "update-failed.json")
UPDATE_FAILED_SKIP = 6 * 3600
RESTART_MARKER = os.environ.get("FLUX_RESTART_MARKER", "/tmp/flux-restart-requested")
GAME_LOG = os.environ.get("FLUX_GAME_LOG", os.path.join(SERVER_DIR, "flux-logs", "current.log"))
STEAM_APP = os.environ.get("FLUX_STEAM_APP", "2465200")
BACKUP_NAME_RE = re.compile(r"^\d{8}-\d{6}-sotf\.tar\.gz$")
# A save archive bigger than this, once unpacked, is refused (a real one is a few MB).
IMPORT_MAX_BYTES = int(os.environ.get("FLUX_IMPORT_MAX_BYTES", str(512 * 1024 * 1024)))

# Slots are folders named by the slot number, ten digits ("0000000001"). The game takes any
# positive number; the panel offers 1 to MAX_SLOT.
MAX_SLOT = 99
# How long after the world loads the server needs before a quit is worth asking for: a stop
# straight after "Dedicated server loaded." still saves (measured), so only a few seconds.
SETTLE_SECONDS = 5

GAME_MODES = ["Normal", "Hard", "HardSurvival", "Peaceful", "Creative", "Custom"]
SAVE_MODES = ["Continue", "New"]
LOW_NORMAL_HIGH = ["Low", "Normal", "High"]
LENGTHS = ["Short", "Default", "Long", "Realistic"]
OFF_NORMAL_HARD = ["Off", "Normal", "Hard"]

# What the game writes into a dedicatedserver.cfg it creates (build 20228410, first start), in its
# order. It then STOPS ("Please restart the server"), so the image writes this itself first.
CONFIG_DEFAULTS = {
    "IpAddress": "0.0.0.0",
    "GamePort": 8766,
    "QueryPort": 27016,
    "BlobSyncPort": 9700,
    "ServerName": "Sons Of The Forest Server (dedicated)",
    "MaxPlayers": 8,
    "Password": "",
    "LanOnly": False,
    "SaveSlot": 1,
    "SaveMode": "Continue",
    "GameMode": "Normal",
    "SaveInterval": 600,
    "IdleDayCycleSpeed": 0.0,
    "IdleTargetFramerate": 5,
    "ActiveTargetFramerate": 60,
    "LogFilesEnabled": False,
    "TimestampLogFilenames": True,
    "TimestampLogEntries": True,
    # The game's default is false. Its test asks Endnight's service to reach the ports from the
    # internet; on Flux the ports are published by the node, and a test that cannot get through
    # (a firewall on the probe's side, a node behind UPnP) must not keep a working server down.
    "SkipNetworkAccessibilityTest": True,
    "GameSettings": {},
    "CustomGameModeSettings": {},
}

# The top-level keys the panel may set, with their rules: (type, choices or (min, max)).
TOP_RULES = {
    "ServerName": ("text", 100),
    "Password": ("text", 40),
    "MaxPlayers": ("int", (1, 8)),
    "LanOnly": ("bool", None),
    "SaveSlot": ("int", (1, MAX_SLOT)),
    "SaveMode": ("choice", SAVE_MODES),
    "GameMode": ("choice", GAME_MODES),
    "SaveInterval": ("int", (60, 3600)),
    "IdleDayCycleSpeed": ("float", (0.0, 1.0)),
    "IdleTargetFramerate": ("int", (1, 60)),
    "ActiveTargetFramerate": ("int", (10, 120)),
    "LogFilesEnabled": ("bool", None),
    "TimestampLogFilenames": ("bool", None),
    "TimestampLogEntries": ("bool", None),
    "SkipNetworkAccessibilityTest": ("bool", None),
}

# GameSettings: read whatever the game mode (the log: "no value found for Gameplay.TreeRegrowth.
# Using default value", build 20228410).
GAME_SETTINGS_RULES = {
    "Gameplay.TreeRegrowth": ("bool", None),
    "Structure.Damage": ("bool", None),
}

# CustomGameModeSettings: read only with GameMode Custom, and only when a world is CREATED (a
# world keeps the settings it was made with). Exactly the keys the server reads: it logs each one
# as it loads a new Custom world ("CustomGameModeSettings: <key> set to <value>", or "no value
# found" / "cannot read value"), measured on build 20228410. PausedInInventory, PlayersTriggerTraps
# and SleepingDelay are in the game's metadata (the single-player menu) but the server never reads
# them, so they are not offered.
CUSTOM_RULES = {
    "GameSetting.Multiplayer.Cheats": ("bool", None),
    # Off / Reduced / Normal, NOT Low / Normal / High as hosts' guides say: "Low", "High", "Full"
    # and "On" are refused ("cannot read value ... Using default value"), measured 2026-10-18.
    "GameSetting.Multiplayer.PvpDamage": ("choice", ["Off", "Reduced", "Normal"]),
    "GameSetting.Vail.EnemySpawn": ("bool", None),
    "GameSetting.Vail.EnemyHealth": ("choice", LOW_NORMAL_HIGH),
    "GameSetting.Vail.EnemyDamage": ("choice", LOW_NORMAL_HIGH),
    "GameSetting.Vail.EnemyArmour": ("choice", LOW_NORMAL_HIGH),
    "GameSetting.Vail.EnemyAggression": ("choice", LOW_NORMAL_HIGH),
    "GameSetting.Vail.AnimalSpawnRate": ("choice", LOW_NORMAL_HIGH),
    "GameSetting.Vail.EnemySearchParties": ("choice", LOW_NORMAL_HIGH),
    "GameSetting.Environment.StartingSeason": ("choice", ["Spring", "Summer", "Autumn", "Winter"]),
    "GameSetting.Environment.SeasonLength": ("choice", LENGTHS),
    "GameSetting.Environment.DayLength": ("choice", LENGTHS),
    "GameSetting.Environment.PrecipitationFrequency": ("choice", ["Low", "Default", "High"]),
    # In no guide; the server reads it (it logs "no value found" without it, "set to True" with it).
    "GameSetting.Environment.InstantSleepSeasonSwitch": ("bool", None),
    "GameSetting.Survival.ConsumableEffects": ("choice", ["Normal", "Hard"]),
    "GameSetting.Survival.PlayerStatsDamage": ("choice", OFF_NORMAL_HARD),
    "GameSetting.Survival.ColdPenalties": ("choice", OFF_NORMAL_HARD),
    "GameSetting.Survival.StatRegenerationPenalty": ("choice", OFF_NORMAL_HARD),
    "GameSetting.Survival.ReducedFoodInContainers": ("bool", None),
    "GameSetting.Survival.ReducedAmmoInContainers": ("bool", None),
    "GameSetting.Survival.SingleUseContainers": ("bool", None),
    "GameSetting.Survival.BuildingResistance": ("choice", LOW_NORMAL_HIGH),
    "GameSetting.Survival.CreativeMode": ("bool", None),
    "GameSetting.Survival.PlayersImmortalMode": ("bool", None),
    "GameSetting.Survival.OneHitToCutTrees": ("bool", None),
    "GameSetting.Construction.NoCuttingsSpawn": ("bool", None),
    "GameSetting.FreeForm.ForcePlaceFullLoad": ("bool", None),
}

SAVE_RE = re.compile(r"^\d{10}$")
STEAM_ID_RE = re.compile(r"^7656119\d{10}$")


# ------------------------------------------------------------------------------------------------
# Files
# ------------------------------------------------------------------------------------------------

def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data, indent=2):
    """Written beside and renamed, so a cut-off write never leaves half a file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".flux-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=indent, ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp, 0o666)
    os.replace(tmp, path)


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".flux-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, 0o666)
    os.replace(tmp, path)


def out(data):
    print(json.dumps(data, ensure_ascii=False))


def fail(message, code=1):
    out({"ok": False, "error": message})
    sys.exit(code)


def env_set(name):
    """A variable counts only with a value: the marketplace writes every declared parameter, the
    ones left blank as NAME=, and a blank one must not wipe what the panel set."""
    return str(os.environ.get(name, "")).strip() != ""


def truthy(value):
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def clean_text(value, limit):
    """One line of printable text."""
    return re.sub(r"[\x00-\x1f\x7f]", " ", str(value)).strip()[:limit]


# ------------------------------------------------------------------------------------------------
# Values
# ------------------------------------------------------------------------------------------------

def coerce(rule, value):
    """(value, None) in the type the file holds, or (None, why)."""
    kind, arg = rule
    if kind == "text":
        if not isinstance(value, (str, int, float)) or isinstance(value, bool):
            return None, "must be text"
        return clean_text(value, arg), None
    if kind == "bool":
        if isinstance(value, bool):
            return value, None
        if str(value).strip().lower() in ("true", "1", "yes", "on"):
            return True, None
        if str(value).strip().lower() in ("false", "0", "no", "off"):
            return False, None
        return None, "must be true or false"
    if kind == "int":
        try:
            n = int(str(value).strip())
        except ValueError:
            return None, "must be a whole number"
        lo, hi = arg
        if not lo <= n <= hi:
            return None, f"must be from {lo} to {hi}"
        return n, None
    if kind == "float":
        try:
            n = float(str(value).strip())
        except ValueError:
            return None, "must be a number"
        lo, hi = arg
        if not lo <= n <= hi:
            return None, f"must be from {lo} to {hi}"
        return n, None
    if kind == "choice":
        for choice in arg:
            if str(value).strip().lower() == choice.lower():
                return choice, None
        return None, f"must be one of {', '.join(arg)}"
    return None, "unknown rule"


def slot_dir(slot):
    return os.path.join(SAVES_DIR, f"{int(slot):010d}")


def slot_number(value):
    try:
        n = int(str(value).strip())
    except ValueError:
        return None
    return n if 1 <= n <= MAX_SLOT else None


def steam_id(value):
    """A SteamID64 from what was typed or pasted (a profile link too), or None."""
    value = str(value).strip()
    m = re.search(r"(?:^|/profiles/)(7656119\d{10})/?$", value)
    return m.group(1) if m else None


# ------------------------------------------------------------------------------------------------
# dedicatedserver.cfg
# ------------------------------------------------------------------------------------------------

def load_config():
    """The file as the game reads it, or the defaults when there is none (or it is not JSON: the
    game would refuse it and stop, so a broken file is replaced, after it is kept aside)."""
    data = read_json(CONFIG_FILE)
    if isinstance(data, dict):
        return data, True
    if os.path.exists(CONFIG_FILE):
        try:
            shutil.copy2(CONFIG_FILE, CONFIG_FILE + f".broken-{int(time.time())}")
        except OSError:
            pass
    return json.loads(json.dumps(CONFIG_DEFAULTS)), False


def save_config(config):
    """In the game's own key order, keys we do not know kept as they are."""
    ordered = {}
    for key in CONFIG_DEFAULTS:
        if key in config:
            ordered[key] = config[key]
    for key, value in config.items():
        if key not in ordered:
            ordered[key] = value
    write_json(CONFIG_FILE, ordered)


def env_ports(notes):
    """The three ports from the environment, or None (with a note) when they cannot be used."""
    ports = {}
    for key, name, default in (("GamePort", "SOTF_GAME_PORT", 8766), ("QueryPort", "SOTF_QUERY_PORT", 27016),
                               ("BlobSyncPort", "SOTF_BLOBSYNC_PORT", 9700)):
        raw = os.environ.get(name, "").strip() or str(default)
        try:
            n = int(raw)
        except ValueError:
            notes.append(f"ERROR {name}={raw!r} is not a port")
            return None
        if not 1024 <= n <= 65535:
            notes.append(f"ERROR {name}={n} is not a port from 1024 to 65535")
            return None
        ports[key] = n
    if len(set(ports.values())) != 3:
        notes.append(f"ERROR the game, query and blob sync ports must differ: {ports}")
        return None
    return ports


# The SOTF_* variables that seed the file, and the key each one writes.
ENV_KEYS = {
    "SOTF_SERVER_NAME": "ServerName",
    "SOTF_PASSWORD": "Password",
    "SOTF_MAX_PLAYERS": "MaxPlayers",
    "SOTF_GAME_MODE": "GameMode",
    "SOTF_SAVE_INTERVAL": "SaveInterval",
    "SOTF_SKIP_NETWORK_TEST": "SkipNetworkAccessibilityTest",
    "SOTF_SAVE_SLOT": "SaveSlot",
    "SOTF_SAVE_MODE": "SaveMode",
}


def apply_env(config, notes, created):
    """Each SOTF_* value that is set, written when the file is new or the value differs from the
    one last applied (see the module's notes)."""
    applied = read_json(ENV_APPLIED_FILE, {})
    applied = applied if isinstance(applied, dict) else {}
    changed = False
    for name, key in ENV_KEYS.items():
        if not env_set(name):
            continue
        raw = os.environ[name]
        if not created and applied.get(name) == raw:
            continue
        value, why = coerce(TOP_RULES[key], raw)
        if why:
            notes.append(f"WARN {name}={raw!r}: {key} {why}; kept {config.get(key)!r}")
        else:
            config[key] = value
            shown = "(set)" if key == "Password" and value else ("(none)" if key == "Password" else value)
            notes.append(f"{key} = {shown} ({name}{', new file' if created else ', changed'})")
        applied[name] = raw
        changed = True
    # SOTF_SETTINGS_JSON: every other key of the file as one JSON object, e.g.
    # {"GameSettings":{"Structure.Damage":true},"CustomGameModeSettings":{"GameSetting.Vail.EnemyHealth":"High"}}
    raw = os.environ.get("SOTF_SETTINGS_JSON", "").strip()
    if raw and (created or applied.get("SOTF_SETTINGS_JSON") != raw):
        try:
            change = json.loads(raw)
            if not isinstance(change, dict):
                raise ValueError("not an object")
        except ValueError as e:
            notes.append(f"WARN SOTF_SETTINGS_JSON is not a JSON object ({e}); ignored")
            change = {}
        for key, why in merge_settings(config, change).items():
            notes.append(f"WARN SOTF_SETTINGS_JSON: {key} {why}; skipped")
        if change:
            notes.append(f"SOTF_SETTINGS_JSON applied ({', '.join(sorted(change))})")
        applied["SOTF_SETTINGS_JSON"] = raw
        changed = True
    if changed:
        write_json(ENV_APPLIED_FILE, applied)


def apply_config(notes):
    config, existed = load_config()
    created = not existed
    if created:
        notes.append("dedicatedserver.cfg written with the game's defaults (the server stops on a first start without one)")
    for key, value in CONFIG_DEFAULTS.items():
        if key not in config:
            config[key] = json.loads(json.dumps(value))
    apply_env(config, notes, created)
    ports = env_ports(notes)
    if ports is None:
        return None
    config.update(ports)
    # The server binds what IpAddress says: anything but all interfaces would not be reachable
    # through Docker's port publishing.
    config["IpAddress"] = "0.0.0.0"
    for key in ("GameSettings", "CustomGameModeSettings"):
        if not isinstance(config.get(key), dict):
            config[key] = {}
    apply_new_world(config, notes)
    if config.get("SaveMode") == "New":
        # "New" wipes the slot on EVERY start: a crash restart, a game update or a move to another
        # node would each throw the world away. Honoured once, as the new world it asks for.
        notes.append(f"SaveMode New in the file: making a new world in slot {config.get('SaveSlot')} once (backed up first), then Continue")
        start_new_world(config.get("SaveSlot"), notes)
        config["SaveMode"] = "Continue"
    save_config(config)
    notes.append(f"slot {config.get('SaveSlot')}, mode {config.get('GameMode')}, ports game {config['GamePort']} query {config['QueryPort']} blob {config['BlobSyncPort']}")
    return config


def apply_new_world(config, notes):
    """A new world the panel asked for: the slot it goes in, its mode; the slot is backed up and
    emptied, and the game makes a fresh world there (SaveMode Continue on an empty slot does that:
    "SaveMode is Continue, but no save found. Creating a new save", measured)."""
    pending = read_json(NEW_WORLD_FILE)
    if not isinstance(pending, dict):
        return
    try:
        os.remove(NEW_WORLD_FILE)
    except OSError:
        pass
    slot = slot_number(pending.get("slot"))
    if slot is None:
        notes.append(f"WARN the pending new world has no usable slot: {pending!r}")
        return
    config["SaveSlot"] = slot
    mode = pending.get("mode")
    if mode:
        value, why = coerce(TOP_RULES["GameMode"], mode)
        if not why:
            config["GameMode"] = value
    config["SaveMode"] = "Continue"
    start_new_world(slot, notes)


def start_new_world(slot, notes):
    slot = slot_number(slot)
    if slot is None:
        return
    d = slot_dir(slot)
    if os.path.isdir(d) and os.listdir(d):
        for line in make_backup(f"before a new world in slot {slot}", force=True):
            notes.append(line)
        shutil.rmtree(d, ignore_errors=True)
        notes.append(f"slot {slot} emptied for a new world")
    else:
        notes.append(f"slot {slot} is empty: a new world will be made there")


# ------------------------------------------------------------------------------------------------
# ownerswhitelist.txt
# ------------------------------------------------------------------------------------------------

OWNERS_HEADER = (
    "# In order to be able to administrate your server from in game directly, you will need to setup server ownership.\n"
    "# Add below the steam ids of every server owner, one steam id per line.\n"
    "# To find your SteamID, open Steam and click on your name on the top right, then go to Account Details.\n"
    "# You can use # to comment out a line. That can be helpful to keep track of SteamIDs, you can include their name in the line above or below, starting with a #.\n"
)


def read_owners():
    """[{"id", "name"}] from the file: one SteamID64 per line; a comment line right above an id is
    taken as its name (the game's own suggestion for keeping track of who is who)."""
    owners = []
    try:
        with open(OWNERS_FILE, encoding="utf-8-sig") as f:
            lines = f.read().splitlines()
    except OSError:
        return owners
    previous = None
    for raw in lines:
        line = raw.strip()
        if line.startswith("#"):
            text = line.lstrip("#").strip()
            previous = text if text and not text.startswith("In order to") and not text.startswith("Add below") \
                and not text.startswith("To find your") and not text.startswith("You can use") else None
            continue
        sid = steam_id(line.split("#")[0])
        if sid and all(o["id"] != sid for o in owners):
            owners.append({"id": sid, "name": previous or ""})
        previous = None
    return owners


def write_owners(owners):
    lines = [OWNERS_HEADER]
    for o in owners:
        name = clean_text(o.get("name") or "", 64).replace("#", "")
        if name:
            lines.append(f"# {name}\n")
        lines.append(f"{o['id']}\n")
    write_text(OWNERS_FILE, "".join(lines))


def apply_owners(notes):
    """SOTF_OWNERS: SteamID64s added on every start, never removed. An id taken off in the panel
    that is still in SOTF_OWNERS comes back on the next start: the deploy's list is the owner's
    standing choice, and the panel says which ids come from it."""
    owners = read_owners()
    if not os.path.exists(OWNERS_FILE):
        write_owners(owners)
    if not env_set("SOTF_OWNERS"):
        return
    added = []
    for item in re.split(r"[\s,;]+", os.environ["SOTF_OWNERS"]):
        if not item:
            continue
        sid = steam_id(item)
        if not sid:
            notes.append(f"WARN SOTF_OWNERS: {item!r} is not a SteamID64")
            continue
        if all(o["id"] != sid for o in owners):
            owners.append({"id": sid, "name": ""})
            added.append(sid)
    if added:
        write_owners(owners)
        notes.append(f"owners added from SOTF_OWNERS: {', '.join(added)}")


# ------------------------------------------------------------------------------------------------
# State
# ------------------------------------------------------------------------------------------------

def load_state():
    data = read_json(STATE_FILE, {})
    return data if isinstance(data, dict) else {}


def cmd_state(args):
    state = load_state()
    new = args[0] if args else "unknown"
    if new == "starting" and state.get("state") != "starting":
        state["generation"] = int(state.get("generation") or 0) + 1
    state["state"] = new
    state["message"] = args[1] if len(args) > 1 else ""
    state["since"] = int(time.time())
    if new == "running":
        state["runningSince"] = int(time.time())
    write_json(STATE_FILE, state)


def cmd_note(args):
    if not args:
        fail("usage: note <key> [value]", 64)
    state = load_state()
    if len(args) > 1 and args[1] != "":
        state[args[0]] = int(args[1]) if args[1].isdigit() else args[1]
    else:
        state.pop(args[0], None)
    write_json(STATE_FILE, state)


# ------------------------------------------------------------------------------------------------
# A2S: who is on, asked of the server itself on its query port
# ------------------------------------------------------------------------------------------------

A2S_INFO = b"\xff\xff\xff\xffTSource Engine Query\x00"
A2S_PLAYER = b"\xff\xff\xff\xffU"


def _cstring(data, at):
    end = data.index(b"\x00", at)
    return data[at:end].decode("utf-8", "replace"), end + 1


def parse_info(body):
    """An A2S_INFO reply without its 4-byte header -> dict. ValueError otherwise."""
    if len(body) < 2 or body[0] != 0x49:
        raise ValueError("not an A2S_INFO reply")
    at = 2
    name, at = _cstring(body, at)
    game_map, at = _cstring(body, at)
    _folder, at = _cstring(body, at)
    game, at = _cstring(body, at)
    at += 2
    players, max_players, bots = body[at], body[at + 1], body[at + 2]
    at += 3
    _server_type, _env, visibility, _vac = body[at:at + 4]
    at += 4
    version, at = _cstring(body, at)
    return {"name": name, "map": game_map, "game": game, "players": players, "maxPlayers": max_players,
            "bots": bots, "password": bool(visibility), "version": version}


def parse_players(body):
    """An A2S_PLAYER reply without its header -> [{"name", "seconds"}]."""
    if len(body) < 2 or body[0] != 0x44:
        raise ValueError("not an A2S_PLAYER reply")
    count = body[1]
    at = 2
    players = []
    for _ in range(count):
        at += 1
        name, at = _cstring(body, at)
        _score, seconds = struct.unpack_from("<lf", body, at)
        at += 8
        if name:
            players.append({"name": name, "seconds": int(seconds)})
    return players


def a2s(port, request, host="127.0.0.1", timeout=2.0):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sent = request if request != A2S_PLAYER else request + b"\xff\xff\xff\xff"
        for _ in range(3):
            sock.sendto(sent, (host, port))
            data, _ = sock.recvfrom(4096)
            if data[:4] != b"\xff\xff\xff\xff":
                raise ValueError("split or malformed reply")
            body = data[4:]
            if body[:1] == b"\x41" and len(body) >= 5:
                sent = (request if request != A2S_PLAYER else A2S_PLAYER) + body[1:5]
                continue
            return body
        raise ValueError("challenged too often")
    finally:
        sock.close()


def query_port():
    config = read_json(CONFIG_FILE, {}) or {}
    try:
        return int(config.get("QueryPort") or os.environ.get("SOTF_QUERY_PORT") or 27016)
    except (TypeError, ValueError):
        return 27016


def query(port=None):
    """(info, players) from the server, or (None, None) when it does not answer."""
    port = port or query_port()
    try:
        info = parse_info(a2s(port, A2S_INFO))
    except (OSError, ValueError, IndexError, struct.error):
        return None, None
    try:
        players = parse_players(a2s(port, A2S_PLAYER))
    except (OSError, ValueError, IndexError, struct.error):
        players = None
    return info, players


def cmd_players(_args):
    info, _ = query()
    if info is not None:
        print(info["players"])


# ------------------------------------------------------------------------------------------------
# Saves
# ------------------------------------------------------------------------------------------------

def save_summary(d):
    """What a slot's SaveData.zip says about its world: mode, hours played, save time."""
    zpath = os.path.join(d, "SaveData.zip")
    info = {"exists": os.path.isfile(zpath)}
    if not info["exists"]:
        return info
    try:
        st = os.stat(zpath)
        info["modified"] = int(st.st_mtime)
        info["size"] = sum(os.path.getsize(os.path.join(d, f)) for f in os.listdir(d) if os.path.isfile(os.path.join(d, f)))
        with zipfile.ZipFile(zpath) as z:
            names = set(z.namelist())
            if "GameStateSaveData.json" in names:
                outer = json.loads(z.read("GameStateSaveData.json"))
                state = json.loads(outer.get("Data", {}).get("GameState", "{}"))
                info["gameType"] = state.get("GameType")
                info["gameHours"] = state.get("GameHours")
                info["saveTime"] = state.get("SaveTime")
                info["crashSite"] = state.get("CrashSite")
            if "MultiplayerPlayerRolesSaveData.json" in names:
                outer = json.loads(z.read("MultiplayerPlayerRolesSaveData.json"))
                roles = json.loads(outer.get("Data", {}).get("MultiplayerPlayerRoles", "{}"))
                info["playersKnown"] = len(roles.get("PlayerList") or [])
    except (OSError, ValueError, zipfile.BadZipFile, KeyError):
        info["damaged"] = True
    return info


def list_slots():
    slots = []
    if os.path.isdir(SAVES_DIR):
        for name in sorted(os.listdir(SAVES_DIR)):
            if SAVE_RE.match(name) and os.path.isdir(os.path.join(SAVES_DIR, name)):
                n = int(name)
                if 1 <= n <= MAX_SLOT:
                    slots.append({"slot": n, **save_summary(os.path.join(SAVES_DIR, name))})
    return slots


def cmd_saves(_args):
    config = read_json(CONFIG_FILE, {}) or {}
    pending = read_json(NEW_WORLD_FILE)
    out({"slots": list_slots(), "active": config.get("SaveSlot", 1), "gameMode": config.get("GameMode"),
         "running": running_slot(), "newWorld": pending if isinstance(pending, dict) else None,
         "maxSlot": MAX_SLOT})


def running_slot():
    """The slot the server is playing now (the one it started with), or None when it is not up."""
    state = load_state()
    return state.get("slot") if state.get("state") in ("running", "starting") else None


def cmd_use_slot(args):
    slot = slot_number(args[0]) if args else None
    if slot is None:
        fail(f"a slot is a number from 1 to {MAX_SLOT}")
    config, _ = load_config()
    config["SaveSlot"] = slot
    config["SaveMode"] = "Continue"
    save_config(config)
    try:
        os.remove(NEW_WORLD_FILE)
    except OSError:
        pass
    exists = os.path.isfile(os.path.join(slot_dir(slot), "SaveData.zip"))
    out({"ok": True, "slot": slot, "exists": exists, "restartNeeded": True})


def cmd_new_world(args):
    slot = slot_number(args[0]) if args else None
    if slot is None:
        fail(f"a slot is a number from 1 to {MAX_SLOT}")
    mode = None
    if len(args) > 1 and args[1]:
        mode, why = coerce(TOP_RULES["GameMode"], args[1])
        if why:
            fail(f"GameMode {why}")
    write_json(NEW_WORLD_FILE, {"slot": slot, "mode": mode, "asked": int(time.time())})
    config, _ = load_config()
    config["SaveSlot"] = slot
    if mode:
        config["GameMode"] = mode
    save_config(config)
    out({"ok": True, "slot": slot, "mode": mode or config.get("GameMode"), "restartNeeded": True})


def cmd_delete_slot(args):
    slot = slot_number(args[0]) if args else None
    if slot is None:
        fail(f"a slot is a number from 1 to {MAX_SLOT}")
    config = read_json(CONFIG_FILE, {}) or {}
    if slot == config.get("SaveSlot") or slot == running_slot():
        fail("That is the slot the server plays. Switch to another slot first.")
    d = slot_dir(slot)
    if not os.path.isdir(d):
        fail("That slot is already empty.")
    shutil.rmtree(d)
    out({"ok": True, "slot": slot})


def _safe_members(z):
    """The archive's files, refusing paths that leave the folder and archives that are too big."""
    total = 0
    members = []
    for info in z.infolist():
        name = info.filename.replace("\\", "/")
        if info.is_dir():
            continue
        if name.startswith("/") or ".." in name.split("/"):
            raise ValueError(f"unsafe path in the archive: {name}")
        total += info.file_size
        if total > IMPORT_MAX_BYTES:
            raise ValueError("the archive is too big to be a save")
        members.append((info, name))
    return members


def cmd_import_save(args):
    if len(args) < 2:
        fail("usage: import-save <zip> <slot>", 64)
    src, slot = args[0], slot_number(args[1])
    if slot is None:
        fail(f"a slot is a number from 1 to {MAX_SLOT}")
    d = slot_dir(slot)
    if os.path.isdir(d) and os.listdir(d):
        fail("That slot already has a world. Pick an empty slot (or delete that one first).")
    try:
        with zipfile.ZipFile(src) as z:
            members = _safe_members(z)
            names = [n for _, n in members]
            # 1. The save's own SaveData.zip (its entries are the *SaveData.json files).
            if any(n.endswith("GameStateSaveData.json") for n in names) and not any(n.endswith("SaveData.zip") for n in names):
                os.makedirs(d, exist_ok=True)
                shutil.copyfile(src, os.path.join(d, "SaveData.zip"))
                kind = "SaveData.zip"
            else:
                # 2. A save FOLDER, zipped: the folder holding SaveData.zip, at any depth.
                inner = [n for n in names if n.split("/")[-1] == "SaveData.zip"]
                if len(inner) != 1:
                    raise ValueError("no save found: the archive must be a save folder (with SaveData.zip in it) or a SaveData.zip")
                prefix = inner[0][: -len("SaveData.zip")]
                os.makedirs(d, exist_ok=True)
                for info, name in members:
                    if not name.startswith(prefix):
                        continue
                    rel = name[len(prefix):]
                    if "/" in rel or not rel:
                        continue
                    with z.open(info) as fin, open(os.path.join(d, rel), "wb") as fout:
                        shutil.copyfileobj(fin, fout)
                kind = "save folder"
    except (OSError, ValueError, zipfile.BadZipFile) as e:
        shutil.rmtree(d, ignore_errors=True)
        fail(str(e) if isinstance(e, ValueError) else f"the file is not a usable zip: {e}")
    summary = save_summary(d)
    if summary.get("damaged") or not summary.get("exists"):
        shutil.rmtree(d, ignore_errors=True)
        fail("The save could not be read (SaveData.zip is damaged).")
    try:
        os.remove(src)
    except OSError:
        pass
    out({"ok": True, "slot": slot, "kind": kind, **summary})


def cmd_export_save(args):
    if len(args) < 2:
        fail("usage: export-save <slot> <out.zip>", 64)
    slot = slot_number(args[0])
    if slot is None or not os.path.isdir(slot_dir(slot)):
        fail("That slot has no world.")
    dest = args[1]
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    folder = f"{slot:010d}"
    with zipfile.ZipFile(dest + ".part", "w", zipfile.ZIP_DEFLATED) as z:
        for name in sorted(os.listdir(slot_dir(slot))):
            path = os.path.join(slot_dir(slot), name)
            if os.path.isfile(path):
                z.write(path, f"{folder}/{name}")
    os.replace(dest + ".part", dest)
    os.chmod(dest, 0o666)
    out({"ok": True, "slot": slot, "file": dest, "size": os.path.getsize(dest)})


# ------------------------------------------------------------------------------------------------
# Settings (the panel's form)
# ------------------------------------------------------------------------------------------------

def rules_json(rules):
    return {k: {"type": kind, **({"choices": arg} if kind == "choice" else {}),
                **({"min": arg[0], "max": arg[1]} if kind in ("int", "float") else {}),
                **({"max": arg} if kind == "text" else {})} for k, (kind, arg) in rules.items()}


def cmd_settings(_args):
    config, existed = load_config()
    out({"config": config, "exists": existed, "defaults": CONFIG_DEFAULTS,
         "rules": {"top": rules_json(TOP_RULES), "gameSettings": rules_json(GAME_SETTINGS_RULES),
                   "custom": rules_json(CUSTOM_RULES)},
         "envOwned": sorted(k for k, v in ENV_KEYS.items() if env_set(k)),
         "ports": {k: config.get(k) for k in ("GamePort", "QueryPort", "BlobSyncPort")}})


def merge_settings(config, change):
    """Writes the settings in `change` (top-level keys, GameSettings, CustomGameModeSettings) into
    `config`; returns {key: why} for the ones refused. Shared by the panel and SOTF_SETTINGS_JSON."""
    errors = {}
    for key, value in change.items():
        if key in TOP_RULES:
            v, why = coerce(TOP_RULES[key], value)
            if why:
                errors[key] = why
            else:
                config[key] = v
        elif key in ("GameSettings", "CustomGameModeSettings"):
            rules = GAME_SETTINGS_RULES if key == "GameSettings" else CUSTOM_RULES
            if not isinstance(value, dict):
                errors[key] = "must be an object"
                continue
            section = config.get(key) if isinstance(config.get(key), dict) else {}
            for sub, subvalue in value.items():
                if sub not in rules:
                    errors[f"{key}.{sub}"] = "is not a setting the game knows"
                elif subvalue is None:
                    section.pop(sub, None)
                else:
                    v, why = coerce(rules[sub], subvalue)
                    if why:
                        errors[f"{key}.{sub}"] = why
                    else:
                        section[sub] = v
            config[key] = section
        elif key in ("GamePort", "QueryPort", "BlobSyncPort", "IpAddress"):
            errors[key] = "is set by the deployment (the ports Flux publishes), not here"
        else:
            errors[key] = "is not a setting the panel can change"
    return errors


def cmd_set_settings(args):
    if not args:
        fail("usage: set-settings '<json>'", 64)
    try:
        change = json.loads(args[0])
    except ValueError:
        fail("the settings are not JSON")
    if not isinstance(change, dict):
        fail("the settings must be a JSON object")
    config, _ = load_config()
    for key, value in CONFIG_DEFAULTS.items():
        config.setdefault(key, json.loads(json.dumps(value)))
    errors = merge_settings(config, change)
    if errors:
        out({"ok": False, "error": "Some settings were not accepted.", "fields": errors})
        sys.exit(1)
    # SaveMode New is kept in the file for one start only: apply turns it into a one-off new world.
    save_config(config)
    out({"ok": True, "restartNeeded": True})


# ------------------------------------------------------------------------------------------------
# Owners
# ------------------------------------------------------------------------------------------------

def cmd_owners(_args):
    env_ids = [steam_id(x) for x in re.split(r"[\s,;]+", os.environ.get("SOTF_OWNERS", "")) if steam_id(x)]
    out({"owners": read_owners(), "fromEnv": env_ids})


def cmd_set_owners(args):
    if not args:
        fail("usage: set-owners '<json>'", 64)
    try:
        data = json.loads(args[0])
    except ValueError:
        fail("the owners are not JSON")
    items = data.get("owners") if isinstance(data, dict) else None
    if not isinstance(items, list):
        fail('expected {"owners": [...]}')
    owners, bad = [], []
    for item in items:
        sid = steam_id(item.get("id") if isinstance(item, dict) else item)
        if not sid:
            bad.append(str(item.get("id") if isinstance(item, dict) else item))
            continue
        if all(o["id"] != sid for o in owners):
            owners.append({"id": sid, "name": clean_text(item.get("name", "") if isinstance(item, dict) else "", 64)})
    if bad:
        fail(f"Not a SteamID64: {', '.join(bad)}")
    write_owners(owners)
    out({"ok": True, "owners": owners, "restartNeeded": True})


# ------------------------------------------------------------------------------------------------
# Status
# ------------------------------------------------------------------------------------------------

def installed_build():
    path = os.path.join(SERVER_DIR, "steamapps", f"appmanifest_{STEAM_APP}.acf")
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            m = re.search(r'"buildid"\s+"(\d+)"', f.read())
            return m.group(1) if m else None
    except OSError:
        return None


def cmd_status(_args):
    state = load_state()
    config = read_json(CONFIG_FILE, {}) or {}
    info, players = (None, None)
    if state.get("state") == "running":
        info, players = query(int(config.get("QueryPort") or 27016))
    result = {
        "state": state.get("state") or "unknown",
        "message": state.get("message") or "",
        "since": state.get("since"),
        "runningSince": state.get("runningSince"),
        "generation": int(state.get("generation") or 0),
        "slot": state.get("slot"),
        "configSlot": config.get("SaveSlot"),
        "gameMode": config.get("GameMode"),
        "serverName": config.get("ServerName"),
        "maxPlayers": config.get("MaxPlayers"),
        "passworded": bool(config.get("Password")),
        "ports": {k: config.get(k) for k in ("GamePort", "QueryPort", "BlobSyncPort")},
        "build": installed_build(),
        "image": os.environ.get("FLUX_IMAGE_VERSION", "dev"),
        "query": info is not None,
        "playerCount": info["players"] if info else None,
        "players": players if players is not None else ([] if info else None),
        "nextRestart": state.get("nextRestart"),
        "updateWaiting": state.get("updateWaiting"),
        "restartPending": os.path.exists(RESTART_MARKER),
        "restorePending": os.path.exists(RESTORE_FILE),
        "newWorldPending": read_json(NEW_WORLD_FILE),
        "lastBackup": (list_backups() or [{}])[0].get("time"),
    }
    out(result)


def cmd_restart(_args):
    state = load_state()
    if state.get("state") not in ("running", "starting", "updating", "restarting"):
        fail("The server is not running.")
    if not os.path.exists(RESTART_MARKER):
        not_before = 0
        if state.get("state") == "running" and state.get("runningSince"):
            not_before = int(state["runningSince"]) + SETTLE_SECONDS
        with open(RESTART_MARKER, "w", encoding="utf-8") as f:
            f.write(f"requested: from the panel\nnotbefore={not_before}\n")
    out({"ok": True, "restarting": True})


# ------------------------------------------------------------------------------------------------
# Backups: userdata/ (the cfg, the owners, every save slot) as one .tar.gz
# ------------------------------------------------------------------------------------------------

def load_index():
    data = read_json(BACKUP_INDEX, {})
    return data if isinstance(data, dict) else {}


def list_backups():
    index = load_index()
    rows = []
    if os.path.isdir(BACKUP_DIR):
        for name in sorted(os.listdir(BACKUP_DIR), reverse=True):
            if not BACKUP_NAME_RE.match(name):
                continue
            path = os.path.join(BACKUP_DIR, name)
            st = os.stat(path)
            meta = index.get(name, {})
            rows.append({"name": name, "size": st.st_size, "time": int(meta.get("time") or st.st_mtime),
                         "why": meta.get("why") or "", "slots": meta.get("slots") or [], "keep": bool(meta.get("keep"))})
    return rows


def prune_backups(keep):
    """The newest `keep` are kept, plus every one marked keep (made before a restore or a new world),
    plus the newest made while the server was up: a crash loop that backs up on every start can
    never rotate the last good world away."""
    rows = list_backups()
    index = load_index()
    kept = 0
    good_seen = False
    for row in rows:
        meta = index.get(row["name"], {})
        if meta.get("keep"):
            continue
        if not good_seen and meta.get("good"):
            good_seen = True
            continue
        kept += 1
        if kept > keep:
            try:
                os.remove(os.path.join(BACKUP_DIR, row["name"]))
            except OSError:
                pass
            index.pop(row["name"], None)
    write_json(BACKUP_INDEX, index)


def make_backup(why, force=False):
    """Returns the notes. Skipped when there is nothing to back up, or the newest is younger
    than FLUX_BACKUP_MIN_AGE_MINUTES (unless forced)."""
    notes = []
    if not os.path.isdir(USERDATA) or not os.listdir(USERDATA):
        return ["# backup skipped: nothing saved yet"]
    min_age = int(os.environ.get("FLUX_BACKUP_MIN_AGE_MINUTES", "60")) * 60
    rows = list_backups()
    if not force and rows and time.time() - rows[0]["time"] < min_age:
        return [f"# backup skipped: the newest is {int((time.time() - rows[0]['time']) / 60)} min old"]
    os.makedirs(BACKUP_DIR, exist_ok=True)
    name = time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-sotf.tar.gz"
    while os.path.exists(os.path.join(BACKUP_DIR, name)):
        time.sleep(1)
        name = time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-sotf.tar.gz"
    path = os.path.join(BACKUP_DIR, name)
    with tarfile.open(path + ".part", "w:gz") as t:
        for entry in ("dedicatedserver.cfg", "ownerswhitelist.txt", "blobsync.cfg", "Saves/DedicatedServer"):
            full = os.path.join(USERDATA, entry)
            if os.path.exists(full):
                t.add(full, arcname=f"userdata/{entry}")
    os.replace(path + ".part", path)
    index = load_index()
    state = load_state()
    index[name] = {"time": int(time.time()), "why": why, "slots": [s["slot"] for s in list_slots() if s.get("exists")],
                   "keep": why.startswith("before"), "good": state.get("state") == "running"}
    write_json(BACKUP_INDEX, index)
    prune_backups(int(os.environ.get("FLUX_BACKUP_KEEP", "10")))
    notes.append(f"# backup {name} ({why}, {os.path.getsize(path) // 1024} KB)")
    return notes


def cmd_backup(args):
    why = args[0] if args else "by hand"
    for line in make_backup(why, force=len(args) > 1 and args[1] == "force"):
        print(line)


def cmd_backups(_args):
    out({"backups": list_backups()})


def cmd_restore(args):
    name = os.path.basename(args[0]) if args else ""
    if not BACKUP_NAME_RE.match(name) or not os.path.isfile(os.path.join(BACKUP_DIR, name)):
        fail("No such backup.")
    write_json(RESTORE_FILE, {"name": name, "asked": int(time.time())})
    state = load_state()
    running = state.get("state") in ("running", "starting", "updating")
    if running and not os.path.exists(RESTART_MARKER):
        with open(RESTART_MARKER, "w", encoding="utf-8") as f:
            f.write(f"requested: restore {name}\nnotbefore=0\n")
    out({"ok": True, "restarting": running, "name": name})


def cmd_do_restore(_args):
    pending = read_json(RESTORE_FILE)
    if not isinstance(pending, dict):
        return
    try:
        os.remove(RESTORE_FILE)
    except OSError:
        pass
    name = os.path.basename(str(pending.get("name", "")))
    path = os.path.join(BACKUP_DIR, name)
    if not BACKUP_NAME_RE.match(name) or not os.path.isfile(path):
        print(f"# WARN the backup to restore is gone: {name}")
        return
    for line in make_backup(f"before restoring {name}", force=True):
        print(line)
    tmp = tempfile.mkdtemp(dir=DATA_DIR, prefix=".flux-restore-")
    try:
        with tarfile.open(path) as t:
            for member in t.getmembers():
                if member.name.startswith("/") or ".." in member.name.split("/") or not member.name.startswith("userdata/"):
                    raise ValueError(f"unsafe path {member.name}")
                if not (member.isfile() or member.isdir()):
                    raise ValueError(f"not a file: {member.name}")
            t.extractall(tmp)  # noqa: S202 - every member checked above
        restored = os.path.join(tmp, "userdata")
        saves = os.path.join(USERDATA, "Saves", "DedicatedServer")
        if os.path.isdir(os.path.join(restored, "Saves", "DedicatedServer")):
            shutil.rmtree(saves, ignore_errors=True)
            os.makedirs(os.path.dirname(saves), exist_ok=True)
            shutil.move(os.path.join(restored, "Saves", "DedicatedServer"), saves)
        for f in ("dedicatedserver.cfg", "ownerswhitelist.txt", "blobsync.cfg"):
            if os.path.isfile(os.path.join(restored, f)):
                shutil.copyfile(os.path.join(restored, f), os.path.join(USERDATA, f))
        print(f"# restored {name}")
    except (OSError, ValueError, tarfile.TarError) as e:
        print(f"# WARN the restore of {name} failed: {e}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ------------------------------------------------------------------------------------------------
# Game updates that did not install
# ------------------------------------------------------------------------------------------------

def cmd_update_target(args):
    if args:
        write_json(UPDATE_TARGET_FILE, {"build": args[0], "time": int(time.time())})


def cmd_update_check(_args):
    target = read_json(UPDATE_TARGET_FILE)
    if not isinstance(target, dict):
        return
    try:
        os.remove(UPDATE_TARGET_FILE)
    except OSError:
        pass
    build = installed_build()
    if build != str(target.get("build")):
        write_json(UPDATE_FAILED_FILE, {"build": str(target.get("build")), "time": int(time.time())})
        print(f"# WARN the update to build {target.get('build')} did not install (still {build}); not retried for 6 hours")


def cmd_update_skip(args):
    failed = read_json(UPDATE_FAILED_FILE)
    if isinstance(failed, dict) and args and str(failed.get("build")) == args[0] \
            and time.time() - float(failed.get("time") or 0) < UPDATE_FAILED_SKIP:
        sys.exit(0)
    sys.exit(1)


# ------------------------------------------------------------------------------------------------

def cmd_apply(_args):
    notes = []
    os.makedirs(USERDATA, exist_ok=True)
    os.makedirs(STATE_DIR, exist_ok=True)
    config = apply_config(notes)
    apply_owners(notes)
    # The game looks for its own (client) App ID next to the exe (Endnight's start script writes it).
    try:
        if os.path.isdir(SERVER_DIR):
            write_text(os.path.join(SERVER_DIR, "steam_appid.txt"), os.environ.get("FLUX_GAME_APP_ID", "1326470"))
    except OSError as e:
        notes.append(f"WARN steam_appid.txt: {e}")
    for line in notes:
        print(f"# {line}")
    if config is None:
        sys.exit(2)
    state = load_state()
    state["slot"] = config.get("SaveSlot")
    write_json(STATE_FILE, state)


COMMANDS = {
    "apply": cmd_apply, "state": cmd_state, "note": cmd_note, "status": cmd_status,
    "settings": cmd_settings, "set-settings": cmd_set_settings, "saves": cmd_saves,
    "use-slot": cmd_use_slot, "new-world": cmd_new_world, "delete-slot": cmd_delete_slot,
    "import-save": cmd_import_save, "export-save": cmd_export_save, "owners": cmd_owners,
    "set-owners": cmd_set_owners, "restart": cmd_restart, "backups": cmd_backups,
    "restore": cmd_restore, "backup": cmd_backup, "do-restore": cmd_do_restore,
    "update-target": cmd_update_target, "update-check": cmd_update_check,
    "update-skip": cmd_update_skip, "players": cmd_players,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        print(__doc__, file=sys.stderr)
        return 64
    COMMANDS[argv[1]](argv[2:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
