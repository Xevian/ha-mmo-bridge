
from homeassistant.components.webhook import async_register
from homeassistant.components import persistent_notification
from homeassistant.helpers.storage import Store
from homeassistant.helpers.network import async_get_external_url, async_get_internal_url, NoURLAvailableError
from aiohttp import web
import logging
import secrets

DOMAIN = "mmo_bridge"
_LOGGER = logging.getLogger(__name__)

async def async_setup(hass, config):
    hass.data.setdefault(DOMAIN, {})
    hass.data[DOMAIN]["registries"] = {}   # world -> {"online": [...]}
    hass.data[DOMAIN]["adapters"] = {}     # world -> {"url": str, "capabilities": [...]}

    # Load or generate token and persist it
    store = Store(hass, 1, DOMAIN)
    data = await store.async_load() or {}
    token = data.get("token")
    if not token:
        token = secrets.token_urlsafe(24)
        await store.async_save({"token": token})
    hass.data[DOMAIN]["token"] = token

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
        elif "online" in data:
            if world not in hass.data[DOMAIN]["registries"]:
                hass.data[DOMAIN]["registries"][world] = {"online": []}
            hass.data[DOMAIN]["registries"][world]["online"] = data["online"]
        return web.Response(text="OK")

    async_register(
        hass,
        DOMAIN,
        "MMO Bridge",
        "mmo_bridge",
        handle_notify_webhook,
    )

    # Build a user-visible URL to copy into adapters
    path = f"/api/webhook/mmo_bridge?token={token}"
    base = None
    try:
        base = await async_get_external_url(hass)
    except NoURLAvailableError:
        pass
    if base is None:
        try:
            base = await async_get_internal_url(hass)
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
