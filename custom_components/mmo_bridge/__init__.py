
from homeassistant.components.webhook import async_register
from homeassistant.components import persistent_notification
from homeassistant.helpers.storage import Store
from homeassistant.helpers.network import get_url, NoURLAvailableError
from homeassistant.helpers.dispatcher import async_dispatcher_send
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.reload import async_setup_reload_service
from homeassistant.helpers import discovery, entity_registry as er, label_registry as lr
from homeassistant.util import slugify
from homeassistant.const import STATE_HOME, STATE_NOT_HOME, STATE_UNAVAILABLE
from homeassistant.components.device_tracker.const import SourceType
from aiohttp import web
import aiohttp
import logging
import secrets
import hmac as py_hmac
import hashlib
import base64
import time

DOMAIN = "mmo_bridge"
SIGNAL_PRESENCE_UPDATED = f"{DOMAIN}_presence_updated"
SIGNAL_NODE_UPDATED     = f"{DOMAIN}_node_updated"

# Protocol version — bump when making breaking changes to the webhook payload
# schema. LSL scripts include this in every payload; HA checks it and rejects
# (HTTP 400) anything below MIN_PROTOCOL_VERSION.
PROTOCOL_VERSION     = 1
MIN_PROTOCOL_VERSION = 1  # oldest script version still accepted
# HA Store version — always 1. We track our own schema version inside the data
# dict (key "version") to avoid HA's built-in migration pipeline.
_HA_STORE_VERSION = 1
STORE_VERSION     = 2  # our internal schema version

# Labels auto-created by the integration.
# Any HA script tagged "MMO Script" is accessible to all registered HUDs.
# Any script tagged "MMO - <Avatar Name>" is accessible only to that avatar's HUD.
MMO_LABEL_GLOBAL = "MMO Script"
MMO_LABEL_PREFIX = "MMO - "

_LOGGER = logging.getLogger(__name__)


async def async_setup(hass, config):
    hass.data.setdefault(DOMAIN, {})

    # ── v0.2.0 data shapes ────────────────────────────────────────────────────
    # nodes[world][node_id] = {url, capabilities, world_data}
    # online_by_world[world] = [avatar_name, ...]
    # avatar_home[world][avatar_name] = True/False
    # known_avatars[world][avatar_name] = key_str
    # avatar_hmac_secrets[avatar_slug] = hex_secret  (persisted)
    hass.data[DOMAIN]["nodes"]               = {}
    hass.data[DOMAIN]["online_by_world"]     = {}
    hass.data[DOMAIN]["avatar_home"]         = {}
    hass.data[DOMAIN]["known_avatars"]       = {}
    hass.data[DOMAIN]["avatar_state"]        = {}
    hass.data[DOMAIN]["avatar_hmac_secrets"] = {}
    hass.data[DOMAIN]["async_add_sensor_entities"] = None

    # Load persisted token, nodes, and HMAC secrets.
    store  = Store(hass, _HA_STORE_VERSION, DOMAIN)
    stored = await store.async_load() or {}

    # Migrate v1 flat adapters → v2 nested nodes
    if stored and stored.get("version", 1) == 1:
        stored = _migrate_v1_to_v2(stored)

    token = stored.get("token")
    if not token:
        token = secrets.token_urlsafe(24)
    hass.data[DOMAIN]["token"] = token

    # Restore per-avatar HMAC secrets
    hass.data[DOMAIN]["avatar_hmac_secrets"] = stored.get("avatar_hmac_secrets", {})

    # Restore nodes from storage
    for world, nodes in stored.get("nodes", {}).items():
        hass.data[DOMAIN]["nodes"][world]           = nodes
        hass.data[DOMAIN]["online_by_world"][world] = []
        hass.data[DOMAIN]["avatar_home"][world]     = {}
        _LOGGER.info("Restored %d node(s) for world '%s' from storage", len(nodes), world)

    await store.async_save(_make_store_payload(
        token, hass.data[DOMAIN]["nodes"], hass.data[DOMAIN]["avatar_hmac_secrets"]
    ))

    # Ensure the global "MMO Script" label exists in HA
    _ensure_mmo_labels(hass)

    # ── Webhook handler ───────────────────────────────────────────────────────

    async def handle_notify_webhook(hass_arg, webhook_id, request):
        try:
            data = await request.json()
        except Exception:
            return web.Response(status=400, text="invalid JSON")
        token_qs  = request.query.get("token")
        if token_qs != hass.data[DOMAIN].get("token"):
            return web.Response(status=403)

        world        = data.get("world", "secondlife")
        payload_type = data.get("type", "")

        # ── Protocol version check ────────────────────────────────────────────
        script_proto = data.get("protocol")
        if script_proto is not None:
            script_proto = int(script_proto)
            if script_proto < MIN_PROTOCOL_VERSION:
                _LOGGER.warning(
                    "Rejected payload from script protocol v%d (minimum is v%d)",
                    script_proto, MIN_PROTOCOL_VERSION,
                )
                return web.json_response(
                    {"error": "protocol_outdated", "current": PROTOCOL_VERSION},
                    status=400,
                )
            if script_proto > PROTOCOL_VERSION:
                _LOGGER.warning(
                    "Script is running protocol v%d, newer than HA's v%d — "
                    "consider updating the integration",
                    script_proto, PROTOCOL_VERSION,
                )

        # ── HUD: fetch labelled script list ───────────────────────────────────
        if payload_type == "hud_list_scripts":
            avatar = data.get("avatar", "")
            if not avatar:
                return web.Response(status=400)
            scripts = _get_scripts_for_avatar(hass, avatar)
            _LOGGER.debug(
                "hud_list_scripts: returning %d script(s) for '%s'", len(scripts), avatar
            )
            return web.json_response({"protocol": PROTOCOL_VERSION, "scripts": scripts})

        # ── HUD: execute a labelled script ────────────────────────────────────
        if payload_type == "hud_command":
            avatar    = data.get("avatar", "")
            script_id = data.get("script", "")
            ts        = int(data.get("ts", 0))
            sig       = data.get("sig", "")

            if not avatar or not script_id:
                return web.Response(status=400)

            avatar_slug = slugify(avatar)
            secret = hass.data[DOMAIN].get("avatar_hmac_secrets", {}).get(avatar_slug)
            if not secret:
                _LOGGER.warning("hud_command: no HMAC secret for avatar '%s'", avatar)
                return web.Response(status=403, text="not registered")

            if not _verify_command_hmac(secret, ts, script_id, sig):
                _LOGGER.warning("hud_command: HMAC verify failed for avatar '%s'", avatar)
                return web.Response(status=403, text="invalid signature")

            # Confirm the script is actually labelled for this avatar
            allowed_ids = {s["id"] for s in _get_scripts_for_avatar(hass, avatar)}
            if script_id not in allowed_ids:
                _LOGGER.warning(
                    "hud_command: script '%s' not labelled for avatar '%s'",
                    script_id, avatar,
                )
                return web.Response(status=403, text="script not allowed")

            try:
                await hass.services.async_call(
                    "script", "turn_on",
                    {"entity_id": f"script.{script_id}"},
                    blocking=False,
                )
                _LOGGER.info(
                    "hud_command: ran script '%s' for avatar '%s'", script_id, avatar
                )
            except Exception as exc:
                _LOGGER.error("hud_command: failed to run '%s': %s", script_id, exc)
                return web.Response(status=500)

            return web.json_response({"protocol": PROTOCOL_VERSION, "status": "ok"})

        # ── Standard node/presence/state processing ───────────────────────────
        raw_node_id  = data.get("node_id", "")
        node_id      = slugify(raw_node_id) if raw_node_id else "default"

        # ── Node registration / URL update ────────────────────────────────────
        if "adapter_url" in data or "lsl_url" in data:
            url          = data.get("adapter_url") or data.get("lsl_url")
            capabilities = data.get("capabilities") or []
            if isinstance(capabilities, str):
                capabilities = [capabilities]

            if world not in hass.data[DOMAIN]["nodes"]:
                hass.data[DOMAIN]["nodes"][world]           = {}
                hass.data[DOMAIN]["online_by_world"][world] = []
                hass.data[DOMAIN]["avatar_home"][world]     = {}

            # Preserve existing world_data if already set
            existing_wd = (
                hass.data[DOMAIN]["nodes"][world]
                .get(node_id, {})
                .get("world_data", {})
            )
            hass.data[DOMAIN]["nodes"][world][node_id] = {
                "url":          url,
                "capabilities": capabilities,
                "world_data":   existing_wd,
            }

            # Drop the placeholder "default" node created by v1→v2 migration once
            # a real named node (with capabilities) has registered for this world
            if node_id != "default" and capabilities:
                stale = hass.data[DOMAIN]["nodes"][world].pop("default", None)
                if stale:
                    _LOGGER.info(
                        "Removed stale 'default' node for world '%s' "
                        "(replaced by node '%s')", world, node_id
                    )

            await store.async_save(_make_store_payload(
                token, hass.data[DOMAIN]["nodes"],
                hass.data[DOMAIN]["avatar_hmac_secrets"],
            ))
            _LOGGER.info("Node '%s' registered for world '%s': %s", node_id, world, url)

            _ensure_online_sensor(hass, world)
            _ensure_node_sensors(hass, world, node_id)

        # ── World data update ─────────────────────────────────────────────────
        if "world_data" in data:
            world_nodes = hass.data[DOMAIN]["nodes"].get(world, {})
            if node_id in world_nodes:
                world_nodes[node_id]["world_data"] = data["world_data"]
            # Expand sensors for any new numeric keys in this payload
            _ensure_node_sensors(hass, world, node_id)
            async_dispatcher_send(hass, SIGNAL_NODE_UPDATED, world, node_id)

        # ── Presence update ───────────────────────────────────────────────────
        if "online" in data:
            if world not in hass.data[DOMAIN]["online_by_world"]:
                hass.data[DOMAIN]["online_by_world"][world] = []
                hass.data[DOMAIN]["avatar_home"][world]     = {}

            old_online = set(hass.data[DOMAIN]["online_by_world"][world])
            new_online = set(data["online"])

            for avatar in new_online - old_online:
                _LOGGER.debug("%s came online in %s", avatar, world)
                hass.bus.async_fire(f"{DOMAIN}_avatar_online", {"world": world, "avatar": avatar})
            for avatar in old_online - new_online:
                _LOGGER.debug("%s went offline in %s", avatar, world)
                hass.bus.async_fire(f"{DOMAIN}_avatar_offline", {"world": world, "avatar": avatar})

            hass.data[DOMAIN]["online_by_world"][world] = data["online"]

            # Update at-home status for each online avatar
            if "at_home" in data:
                at_home_set = set(data["at_home"])
                for avatar in new_online:
                    hass.data[DOMAIN]["avatar_home"][world][avatar] = avatar in at_home_set

            # Region restart event
            if data.get("region_restart"):
                _LOGGER.info("Region restart detected for world '%s'", world)
                hass.bus.async_fire(f"{DOMAIN}_region_restart", {
                    "world":      world,
                    "world_data": data.get("world_data", {}),
                })

            # Refresh device tracker for every avatar we've ever seen
            for avatar in old_online | new_online:
                _update_device_tracker(hass, world, avatar)

            async_dispatcher_send(hass, SIGNAL_PRESENCE_UPDATED, world)

        # ── Avatar state update (from HUD/attachment) ─────────────────────────
        if "avatar_state" in (data.get("capabilities") or []):
            avatar = data.get("avatar")
            if avatar:
                avatar_slug = slugify(avatar)
                hass.data[DOMAIN]["avatar_state"].setdefault(world, {})
                old = hass.data[DOMAIN]["avatar_state"][world].get(avatar, {})
                new_state = {
                    "afk":    data.get("afk",  False),
                    "busy":   data.get("busy", False),
                    "region": data.get("region"),
                    "parcel": data.get("parcel"),
                }
                hass.data[DOMAIN]["avatar_state"][world][avatar] = new_state

                # Fire events for boolean state transitions
                for flag in ("afk", "busy"):
                    if old.get(flag) != new_state[flag]:
                        hass.bus.async_fire(f"{DOMAIN}_avatar_{flag}_changed", {
                            "world":  world,
                            "avatar": avatar,
                            flag:     new_state[flag],
                        })

                _update_device_tracker(hass, world, avatar)

                # Issue a per-avatar HMAC secret on first contact; return it on
                # every registration response so the HUD can recover after reset.
                secrets_map = hass.data[DOMAIN]["avatar_hmac_secrets"]
                if avatar_slug not in secrets_map:
                    secrets_map[avatar_slug] = secrets.token_hex(32)
                    _ensure_avatar_label(hass, avatar)
                    await store.async_save(_make_store_payload(
                        token, hass.data[DOMAIN]["nodes"], secrets_map
                    ))
                    _LOGGER.info(
                        "Issued HMAC secret and created label for avatar '%s'", avatar
                    )

                return web.json_response({
                    "protocol":    PROTOCOL_VERSION,
                    "status":      "ok",
                    "hmac_secret": secrets_map[avatar_slug],
                })

        return web.Response(text="OK")

    async_register(hass, DOMAIN, "MMO Bridge", "mmo_bridge", handle_notify_webhook)

    # ── Services ──────────────────────────────────────────────────────────────

    async def handle_request_update(call):
        """Force an immediate presence poll on one or all worlds."""
        world  = call.data.get("world")
        worlds = [world] if world else list(hass.data[DOMAIN]["nodes"].keys())
        session = async_get_clientsession(hass)
        for w in worlds:
            for nid, node in hass.data[DOMAIN]["nodes"].get(w, {}).items():
                url = node.get("url")
                if not url:
                    continue
                try:
                    timeout = aiohttp.ClientTimeout(total=5)
                    await session.post(url, json={"command": "refresh"}, timeout=timeout)
                    _LOGGER.debug("Sent refresh to node '%s' in world '%s'", nid, w)
                except Exception as e:
                    _LOGGER.error("Failed to send refresh to '%s'/'%s': %s", w, nid, e)

    hass.services.async_register(DOMAIN, "request_update", handle_request_update)

    async def handle_send_message(call):
        """Send an in-world IM via the notify platform.

        Mirrors notify.mmo_bridge so the action is discoverable in the
        Services / Actions panel alongside the other MMO Bridge actions.
        """
        message = call.data.get("message", "")
        target  = call.data.get("target")
        if not message:
            _LOGGER.warning("send_message: 'message' is required")
            return
        notify_data = {"message": message}
        if target:
            notify_data["target"] = [target] if isinstance(target, str) else target
        await hass.services.async_call("notify", DOMAIN, notify_data, blocking=True)

    hass.services.async_register(DOMAIN, "send_message", handle_send_message)

    async def handle_set_object_text(call):
        """Push a named hover-text line to display-capable node(s).

        node_id omitted → send to ALL display-capable nodes in the world
        node_id set     → send to that specific node only
        """
        world   = call.data.get("world", "secondlife")
        key     = call.data.get("key", "")
        value   = call.data.get("value", "")
        node_id = call.data.get("node_id")   # optional — None means broadcast
        if not key:
            _LOGGER.warning("set_object_text: 'key' is required")
            return
        # Cap lengths — LSL hover text is truncated at 4096 chars total; keep
        # individual key/value pairs well within that.
        key   = key[:64]
        value = value[:256]

        world_nodes = hass.data[DOMAIN]["nodes"].get(world, {})
        if not world_nodes:
            _LOGGER.warning("set_object_text: no nodes registered for world '%s'", world)
            return

        # Build the target list
        if node_id:
            node = world_nodes.get(node_id)
            if not node:
                _LOGGER.warning(
                    "set_object_text: node '%s' not found in world '%s'", node_id, world
                )
                return
            targets = {node_id: node}
        else:
            targets = {nid: n for nid, n in world_nodes.items()
                       if "display" in n.get("capabilities", [])}
            if not targets:
                targets = world_nodes

        session = async_get_clientsession(hass)
        for nid, node in targets.items():
            url = node.get("url")
            if not url:
                continue
            try:
                timeout = aiohttp.ClientTimeout(total=5)
                await session.post(
                    url, json={"command": "set_text", "key": key, "value": value},
                    timeout=timeout,
                )
                _LOGGER.debug("set_object_text sent to node '%s' in '%s'", nid, world)
            except Exception as e:
                _LOGGER.error(
                    "Failed to set object text on node '%s' in '%s': %s", nid, world, e
                )

    hass.services.async_register(DOMAIN, "set_object_text", handle_set_object_text)

    # Register mmo_bridge.reload service — reloads sensor + notify platforms
    # without restarting HA. Changes to __init__.py still require a full restart.
    await async_setup_reload_service(hass, DOMAIN, ["sensor", "notify"])

    # Load sensor platform
    hass.async_create_task(
        discovery.async_load_platform(hass, "sensor", DOMAIN, {}, config)
    )

    # Build a user-visible URL to paste into adapters
    path = f"/api/webhook/mmo_bridge?token={token}"
    base = None
    try:
        base = get_url(hass, prefer_external=True)
    except NoURLAvailableError:
        pass
    full_url = f"{base}{path}" if base else path

    message = (
        "MMO Bridge webhook is ready. Copy this URL into your adapter (e.g., LSL script):\n\n"
        f"URL: {full_url}\n"
        f"Token: {token}\n"
        "If no base URL is shown, configure Home Assistant external/internal URL settings."
    )
    persistent_notification.async_create(
        hass,
        message,
        title="MMO Bridge",
        notification_id="mmo_bridge_webhook_info",
    )
    _LOGGER.info("MMO Bridge webhook URL: %s", full_url)
    return True


# ── Storage helpers ───────────────────────────────────────────────────────────

def _migrate_v1_to_v2(stored):
    """Migrate v1 flat adapters dict → v2 nested nodes structure."""
    nodes = {}
    for world, adapter in stored.get("adapters", {}).items():
        if isinstance(adapter, dict):
            url  = adapter.get("url", "")
            caps = adapter.get("capabilities", [])
        else:
            url  = str(adapter)
            caps = []
        nodes[world] = {
            "default": {"url": url, "capabilities": caps, "world_data": {}}
        }
    _LOGGER.info("MMO Bridge: migrated storage from v1 → v2")
    return {"token": stored.get("token"), "nodes": nodes, "version": 2}


def _make_store_payload(token, nodes, avatar_hmac_secrets=None):
    """Strip runtime-only world_data before persisting."""
    nodes_to_save = {}
    for world, nmap in nodes.items():
        nodes_to_save[world] = {}
        for nid, node in nmap.items():
            nodes_to_save[world][nid] = {
                "url":          node.get("url", ""),
                "capabilities": node.get("capabilities", []),
            }
    return {
        "token":               token,
        "nodes":               nodes_to_save,
        "version":             STORE_VERSION,
        "avatar_hmac_secrets": avatar_hmac_secrets or {},
    }


# ── Label helpers ─────────────────────────────────────────────────────────────

def _ensure_mmo_labels(hass):
    """Create the global 'MMO Script' label if it doesn't already exist."""
    registry = lr.async_get(hass)
    if not registry.async_get_label_by_name(MMO_LABEL_GLOBAL):
        registry.async_create(MMO_LABEL_GLOBAL, color="#0288d1", icon="mdi:controller-classic")
        _LOGGER.info("Created HA label '%s'", MMO_LABEL_GLOBAL)


def _ensure_avatar_label(hass, avatar_name):
    """Create a per-avatar 'MMO - <Name>' label if it doesn't already exist."""
    label_name = f"{MMO_LABEL_PREFIX}{avatar_name}"
    registry   = lr.async_get(hass)
    if not registry.async_get_label_by_name(label_name):
        registry.async_create(label_name, color="#7b1fa2", icon="mdi:account")
        _LOGGER.info("Created HA label '%s'", label_name)


def _get_scripts_for_avatar(hass, avatar_name):
    """Return scripts labelled 'MMO Script' or 'MMO - <avatar_name>'.

    Each entry is {"id": <entity id without 'script.' prefix>, "name": <friendly name>}.
    """
    entity_reg = er.async_get(hass)
    label_reg  = lr.async_get(hass)

    allowed_label_ids: set = set()
    global_label = label_reg.async_get_label_by_name(MMO_LABEL_GLOBAL)
    if global_label:
        allowed_label_ids.add(global_label.label_id)
    avatar_label = label_reg.async_get_label_by_name(f"{MMO_LABEL_PREFIX}{avatar_name}")
    if avatar_label:
        allowed_label_ids.add(avatar_label.label_id)

    if not allowed_label_ids:
        return []

    scripts = []
    for entry in entity_reg.entities.values():
        if entry.domain != "script":
            continue
        if not (entry.labels & allowed_label_ids):
            continue
        state = hass.states.get(entry.entity_id)
        name  = (
            (state.attributes.get("friendly_name") if state else None)
            or entry.name
            or entry.entity_id.replace("script.", "").replace("_", " ").title()
        )
        scripts.append({
            "id":   entry.entity_id.replace("script.", ""),
            "name": name,
        })

    return scripts


# ── HMAC verification ─────────────────────────────────────────────────────────

def _verify_command_hmac(secret: str, ts: int, script_id: str, sig: str) -> bool:
    """Verify a HUD command HMAC signature.

    The canonical message is "<ts>.script.<script_id>", signed with HMAC-SHA256
    and base64-encoded — matching llHMAC(secret, canon, "sha256") in LSL.
    A 60-second replay window provides tolerance for SL network latency and
    clock skew between the viewer and the HA server.
    """
    age = abs(int(time.time()) - ts)
    if age > 60:
        _LOGGER.warning("hud_command: timestamp too old (%ds)", age)
        return False

    canon    = f"{ts}.script.{script_id}"
    expected = base64.b64encode(
        py_hmac.new(secret.encode(), canon.encode(), hashlib.sha256).digest()
    ).decode()
    return py_hmac.compare_digest(expected, sig)


# ── Device tracker helper ─────────────────────────────────────────────────────

def _update_device_tracker(hass, world, avatar):
    """Create/update a device_tracker entity for an avatar."""
    entity_id   = f"device_tracker.{DOMAIN}_{slugify(world)}_{slugify(avatar)}"
    online      = hass.data[DOMAIN]["online_by_world"].get(world, [])
    at_home_map = hass.data[DOMAIN]["avatar_home"].get(world, {})
    av_state    = hass.data[DOMAIN].get("avatar_state", {}).get(world, {}).get(avatar, {})

    if avatar in online:
        state = STATE_HOME if at_home_map.get(avatar) else STATE_NOT_HOME
    else:
        state = STATE_UNAVAILABLE  # offline — distinct from away

    attrs = {
        "source_type":   SourceType.GPS,
        "friendly_name": avatar,
        "world":         world,
    }
    if av_state:
        attrs["afk"]  = av_state.get("afk",  False)
        attrs["busy"] = av_state.get("busy", False)
        if av_state.get("region"):
            attrs["sl_region"] = av_state["region"]
        if av_state.get("parcel"):
            attrs["sl_parcel"] = av_state["parcel"]

    hass.states.async_set(entity_id, state, attrs)


# ── Sensor-creation helpers ───────────────────────────────────────────────────

def _ensure_online_sensor(hass, world):
    """Create the online-count sensor for a world (idempotent)."""
    from .sensor import MMOBridgeSensor
    existing = hass.data[DOMAIN].setdefault("sensor_entities", {})
    key = f"{world}__online"
    if key in existing:
        return
    add_entities = hass.data[DOMAIN].get("async_add_sensor_entities")
    if add_entities is None:
        return
    entity = MMOBridgeSensor(hass, world)
    existing[key] = entity
    add_entities([entity])


def _ensure_node_sensors(hass, world, node_id):
    """Create world-data sensors for a node (idempotent).

    Sensors are created for:
    - Every key in WORLD_DATA_SENSORS (well-known SL metrics, always present)
    - Any additional numeric key that has already arrived in world_data for
      this node and is not in WORLD_DATA_STRING_KEYS (dynamic expansion for
      other worlds or future SL fields)

    The 'default' node is a v1→v2 migration placeholder — skip it entirely.
    """
    if node_id == "default":
        return
    from .sensor import (
        MMOBridgeWorldDataSensor,
        WORLD_DATA_SENSORS,
        WORLD_DATA_STRING_KEYS,
    )
    existing     = hass.data[DOMAIN].setdefault("sensor_entities", {})
    add_entities = hass.data[DOMAIN].get("async_add_sensor_entities")
    if add_entities is None:
        return

    new_entities = []

    def _add_sensor(sensor_key, name_suffix, unit, icon, cast_fn):
        ekey = f"{world}__{node_id}__{sensor_key}"
        if ekey in existing:
            return
        entity = MMOBridgeWorldDataSensor(
            hass, world, node_id, sensor_key, name_suffix, unit, icon, cast_fn
        )
        existing[ekey] = entity
        new_entities.append(entity)

    # Well-known keys — always create these regardless of whether data has arrived
    for sensor_key, (name_suffix, unit, icon, cast_fn) in WORLD_DATA_SENSORS.items():
        _add_sensor(sensor_key, name_suffix, unit, icon, cast_fn)

    # Dynamic keys — any numeric field already present in world_data but not
    # already handled above or explicitly flagged as a string field
    world_data = (
        hass.data[DOMAIN]["nodes"]
        .get(world, {})
        .get(node_id, {})
        .get("world_data", {})
    )
    for sensor_key, raw_value in world_data.items():
        if sensor_key in WORLD_DATA_SENSORS or sensor_key in WORLD_DATA_STRING_KEYS:
            continue
        try:
            float(raw_value)   # only create a sensor if the value is numeric
        except (ValueError, TypeError):
            continue
        name_suffix = sensor_key.replace("_", " ").title()
        _add_sensor(sensor_key, name_suffix, None, "mdi:chart-line", float)

    if new_entities:
        add_entities(new_entities)


def _ensure_sensor(hass, world):
    """Compatibility shim — called by sensor platform for restored worlds."""
    _ensure_online_sensor(hass, world)
    for node_id in hass.data[DOMAIN]["nodes"].get(world, {}):
        _ensure_node_sensors(hass, world, node_id)
