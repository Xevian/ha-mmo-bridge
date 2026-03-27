
from homeassistant.components.webhook import async_register
from homeassistant.components import persistent_notification
from homeassistant.helpers.storage import Store
from homeassistant.helpers.network import get_url, NoURLAvailableError
from homeassistant.helpers.dispatcher import async_dispatcher_send
from homeassistant.helpers import discovery
from aiohttp import web
import logging
import secrets

DOMAIN = "mmo_bridge"
SIGNAL_PRESENCE_UPDATED = f"{DOMAIN}_presence_updated"

_LOGGER = logging.getLogger(__name__)

async def async_setup(hass, config):
    hass.data.setdefault(DOMAIN, {})
    hass.data[DOMAIN]["registries"] = {}   # world -> {"online": [...]}
    hass.data[DOMAIN]["adapters"] = {}     # world -> {"url": str, "capabilities": [...]}
    hass.data[DOMAIN]["async_add_sensor_entities"] = None  # set by sensor platform

    # Load persisted token and adapter URLs
    store = Store(hass, 1, DOMAIN)
    stored = await store.async_load() or {}
    token = stored.get("token")
    if not token:
        token = secrets.token_urlsafe(24)
    hass.data[DOMAIN]["token"] = token

    # Restore adapter URLs persisted from the previous run
    for world, adapter in stored.get("adapters", {}).items():
        hass.data[DOMAIN]["adapters"][world] = adapter
        hass.data[DOMAIN]["registries"][world] = {"online": []}
        _LOGGER.info("Restored adapter for world '%s' from storage", world)

    await store.async_save({"token": token, "adapters": hass.data[DOMAIN]["adapters"]})

    async def handle_notify_webhook(hass_arg, webhook_id, request):
        data = await request.json()
        token_qs = request.query.get("token")
        if token_qs != hass.data[DOMAIN].get("token"):
            return web.Response(status=403)

        world = data.get("world", "secondlife")

        if "adapter_url" in data or "lsl_url" in data:
            url = data.get("adapter_url") or data.get("lsl_url")
            capabilities = data.get("capabilities") or []
            if isinstance(capabilities, str):
                capabilities = [capabilities]
            hass.data[DOMAIN]["adapters"][world] = {"url": url, "capabilities": capabilities}
            if world not in hass.data[DOMAIN]["registries"]:
                hass.data[DOMAIN]["registries"][world] = {"online": []}
            # Persist so the adapter URL survives HA restarts
            await store.async_save({"token": token, "adapters": hass.data[DOMAIN]["adapters"]})
            _LOGGER.info("Adapter registered for world '%s': %s", world, url)
            # Create a sensor for this world if the platform is ready
            _ensure_sensor(hass, world)

        if "online" in data:
            if world not in hass.data[DOMAIN]["registries"]:
                hass.data[DOMAIN]["registries"][world] = {"online": []}

            old_online = set(hass.data[DOMAIN]["registries"][world].get("online", []))
            new_online = set(data["online"])

            # Fire events for avatars that came online or went offline
            for avatar in new_online - old_online:
                _LOGGER.debug("%s came online in %s", avatar, world)
                hass.bus.async_fire(f"{DOMAIN}_avatar_online", {"world": world, "avatar": avatar})
            for avatar in old_online - new_online:
                _LOGGER.debug("%s went offline in %s", avatar, world)
                hass.bus.async_fire(f"{DOMAIN}_avatar_offline", {"world": world, "avatar": avatar})

            hass.data[DOMAIN]["registries"][world]["online"] = data["online"]
            async_dispatcher_send(hass, SIGNAL_PRESENCE_UPDATED, world)

        return web.Response(text="OK")

    async_register(
        hass,
        DOMAIN,
        "MMO Bridge",
        "mmo_bridge",
        handle_notify_webhook,
    )

    # Load sensor platform
    hass.async_create_task(
        discovery.async_load_platform(hass, "sensor", DOMAIN, {}, config)
    )

    # Build a user-visible URL to copy into adapters
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


def _ensure_sensor(hass, world):
    """Create a sensor entity for a world the first time its adapter registers."""
    from .sensor import MMOBridgeSensor
    existing = hass.data[DOMAIN].setdefault("sensor_entities", {})
    if world in existing:
        return
    add_entities = hass.data[DOMAIN].get("async_add_sensor_entities")
    if add_entities is None:
        return
    sensor = MMOBridgeSensor(hass, world)
    existing[world] = sensor
    add_entities([sensor])
