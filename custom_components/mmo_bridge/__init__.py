
from homeassistant.components.webhook import async_register
from homeassistant.components import persistent_notification
from homeassistant.helpers.storage import Store
from homeassistant.helpers.network import get_url, NoURLAvailableError
from homeassistant.helpers.dispatcher import async_dispatcher_send
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.reload import async_setup_reload_service
from homeassistant.helpers import discovery
from homeassistant.util import slugify
from homeassistant.const import STATE_HOME, STATE_NOT_HOME, STATE_UNAVAILABLE
from aiohttp import web
import aiohttp
import logging
import secrets

DOMAIN = "mmo_bridge"
SIGNAL_PRESENCE_UPDATED = f"{DOMAIN}_presence_updated"
SIGNAL_NODE_UPDATED     = f"{DOMAIN}_node_updated"
# HA Store version — always 1. We track our own schema version inside the data
# dict (key "version") to avoid HA's built-in migration pipeline.
_HA_STORE_VERSION = 1
STORE_VERSION     = 2  # our internal schema version

_LOGGER = logging.getLogger(__name__)


async def async_setup(hass, config):
    hass.data.setdefault(DOMAIN, {})

    # ── v0.2.0 data shapes ────────────────────────────────────────────────────
    # nodes[world][node_id] = {url, capabilities, world_data}
    # online_by_world[world] = [avatar_name, ...]
    # avatar_home[world][avatar_name] = True/False
    # known_avatars[world][avatar_name] = key_str
    hass.data[DOMAIN]["nodes"]           = {}
    hass.data[DOMAIN]["online_by_world"] = {}
    hass.data[DOMAIN]["avatar_home"]     = {}
    hass.data[DOMAIN]["known_avatars"]   = {}
    hass.data[DOMAIN]["async_add_sensor_entities"] = None

    # Load persisted token and node URLs.
    # _HA_STORE_VERSION is always 1 — HA never triggers its own migration logic.
    # We manage schema upgrades ourselves via the "version" key inside the data.
    store  = Store(hass, _HA_STORE_VERSION, DOMAIN)
    stored = await store.async_load() or {}

    # Migrate v1 flat adapters → v2 nested nodes
    if stored and stored.get("version", 1) == 1:
        stored = _migrate_v1_to_v2(stored)

    token = stored.get("token")
    if not token:
        token = secrets.token_urlsafe(24)
    hass.data[DOMAIN]["token"] = token

    # Restore nodes from storage
    for world, nodes in stored.get("nodes", {}).items():
        hass.data[DOMAIN]["nodes"][world]           = nodes
        hass.data[DOMAIN]["online_by_world"][world] = []
        hass.data[DOMAIN]["avatar_home"][world]     = {}
        _LOGGER.info("Restored %d node(s) for world '%s' from storage", len(nodes), world)

    await store.async_save(_make_store_payload(token, hass.data[DOMAIN]["nodes"]))

    # ── Webhook handler ───────────────────────────────────────────────────────

    async def handle_notify_webhook(hass_arg, webhook_id, request):
        data      = await request.json()
        token_qs  = request.query.get("token")
        if token_qs != hass.data[DOMAIN].get("token"):
            return web.Response(status=403)

        world        = data.get("world", "secondlife")
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

            await store.async_save(_make_store_payload(token, hass.data[DOMAIN]["nodes"]))
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

    async def handle_set_object_text(call):
        """Push a named hover-text line to a display-capable node."""
        world = call.data.get("world", "secondlife")
        key   = call.data.get("key", "")
        value = call.data.get("value", "")
        if not key:
            _LOGGER.warning("set_object_text: 'key' is required")
            return

        # Prefer a node that advertises the 'display' capability
        url = None
        for node in hass.data[DOMAIN]["nodes"].get(world, {}).values():
            if "display" in node.get("capabilities", []):
                url = node.get("url")
                break
        # Fall back to any node for this world
        if not url:
            for node in hass.data[DOMAIN]["nodes"].get(world, {}).values():
                url = node.get("url")
                if url:
                    break

        if not url:
            _LOGGER.warning("set_object_text: no adapter URL for world '%s'", world)
            return
        try:
            session = async_get_clientsession(hass)
            timeout = aiohttp.ClientTimeout(total=5)
            await session.post(
                url, json={"command": "set_text", "key": key, "value": value}, timeout=timeout
            )
        except Exception as e:
            _LOGGER.error("Failed to set object text for world '%s': %s", world, e)

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


def _make_store_payload(token, nodes):
    """Strip runtime-only world_data before persisting."""
    nodes_to_save = {}
    for world, nmap in nodes.items():
        nodes_to_save[world] = {}
        for nid, node in nmap.items():
            nodes_to_save[world][nid] = {
                "url":          node.get("url", ""),
                "capabilities": node.get("capabilities", []),
            }
    return {"token": token, "nodes": nodes_to_save, "version": STORE_VERSION}


# ── Device tracker helper ─────────────────────────────────────────────────────

def _update_device_tracker(hass, world, avatar):
    """Create/update a device_tracker entity for an avatar."""
    entity_id   = f"device_tracker.{DOMAIN}_{slugify(world)}_{slugify(avatar)}"
    online      = hass.data[DOMAIN]["online_by_world"].get(world, [])
    at_home_map = hass.data[DOMAIN]["avatar_home"].get(world, {})

    if avatar in online:
        state = STATE_HOME if at_home_map.get(avatar) else STATE_NOT_HOME
    else:
        state = STATE_UNAVAILABLE  # offline — distinct from away

    hass.states.async_set(entity_id, state, {
        "source_type":   "gps",
        "friendly_name": avatar,
        "world":         world,
    })


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
