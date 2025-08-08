
from homeassistant.components.webhook import async_register_admin_webhook
from homeassistant.components import persistent_notification
from homeassistant.helpers.storage import Store
from homeassistant.helpers.network import async_get_external_url, async_get_internal_url
from aiohttp import web
import logging
import secrets

DOMAIN = "mmo_bridge"
_LOGGER = logging.getLogger(__name__)

async def async_setup(hass, config):
    # Generic multi-world storage
    hass.data["registries"] = {}   # world -> {"online": [...]} (we store just list for now)
    # world -> {"url": str, "capabilities": ["presence", "message", ...]}
    hass.data["adapters"] = {}

    # Load or generate token and persist it
    store = Store(hass, 1, DOMAIN)
    data = await store.async_load() or {}
    token = data.get("token")
    if not token:
        token = secrets.token_urlsafe(24)
        await store.async_save({"token": token})
    hass.data["mmo_bridge_token"] = token

    async def handle_notify_webhook(hass_arg, webhook_id, request):
        data = await request.json()
        token_qs = request.query.get("token")
        if token_qs != hass.data.get("mmo_bridge_token"):
            return web.Response(status=403)

        # Determine world (default to Second Life for backward compatibility)
        world = data.get("world", "secondlife")

        # Adapter URL registration (backward compat: "lsl_url")
        if "adapter_url" in data or "lsl_url" in data:
            url = data.get("adapter_url") or data.get("lsl_url")
            capabilities = data.get("capabilities") or []
            # Normalize capabilities to list of strings
            if isinstance(capabilities, str):
                capabilities = [capabilities]
            hass.data["adapters"][world] = {"url": url, "capabilities": capabilities}
            # Ensure registry node exists
            if world not in hass.data["registries"]:
                hass.data["registries"][world] = {"online": []}
        elif "online" in data:
            if world not in hass.data["registries"]:
                hass.data["registries"][world] = {"online": []}
            hass.data["registries"][world]["online"] = data["online"]
        return web.Response(text="OK")

    # Register admin-only webhook at /api/webhook/mmo_bridge
    async_register_admin_webhook(
        hass,
        DOMAIN,            # domain
        "MMO Bridge",      # name
        "mmo_bridge",      # webhook_id
        handle_notify_webhook,
    )

    # Build a user-visible URL to copy into adapters
    path = f"/api/webhook/mmo_bridge?token={token}"
    ext = None
    try:
        ext = await async_get_external_url(hass)
    except Exception:
        pass
    base = ext or None
    if base is None:
        try:
            base = await async_get_internal_url(hass)
        except Exception:
            base = None
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
