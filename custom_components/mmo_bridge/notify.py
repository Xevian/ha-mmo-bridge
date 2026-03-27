
from homeassistant.components.notify import BaseNotificationService
from homeassistant.helpers.aiohttp_client import async_get_clientsession
import aiohttp
import logging

from . import DOMAIN

_LOGGER = logging.getLogger(__name__)

async def async_get_service(hass, config, discovery_info=None):
    return SLNotificationService(hass)

class SLNotificationService(BaseNotificationService):
    def __init__(self, hass):
        self.hass = hass

    async def async_send_message(self, message="", **kwargs):
        targets = kwargs.get("target", [])
        if isinstance(targets, str):
            targets = [targets]

        bridge = self.hass.data.get(DOMAIN, {})
        adapters = bridge.get("adapters", {})
        registries = bridge.get("registries", {})

        if not adapters:
            _LOGGER.warning("No adapter endpoints registered.")
            return

        session = async_get_clientsession(self.hass)

        for raw in targets:
            string_world = "secondlife"
            string_name = raw
            if ":" in raw:
                parts = raw.split(":", 1)
                string_world, string_name = parts[0], parts[1]

            registry = registries.get(string_world, {"online": []})
            online = registry.get("online", [])
            adapter_info = adapters.get(string_world) or {}
            url = adapter_info.get("url") if isinstance(adapter_info, dict) else adapter_info
            caps = adapter_info.get("capabilities", []) if isinstance(adapter_info, dict) else []

            if not url:
                _LOGGER.warning("No adapter URL for world '%s'", string_world)
                continue

            if caps and "message" not in caps:
                _LOGGER.warning("Adapter for '%s' does not support messaging", string_world)
                continue

            if string_name in online:
                payload = {"to": string_name, "message": message}
                try:
                    timeout = aiohttp.ClientTimeout(total=5)
                    await session.post(url, json=payload, timeout=timeout)
                except Exception as e:
                    _LOGGER.error("Failed to send to %s:%s: %s", string_world, string_name, e)
