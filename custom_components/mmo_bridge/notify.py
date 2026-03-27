
from homeassistant.components.notify import BaseNotificationService
from homeassistant.helpers.aiohttp_client import async_get_clientsession
import aiohttp
import logging

from . import DOMAIN

_LOGGER = logging.getLogger(__name__)

BROADCAST_KEYWORD = "all"


async def async_get_service(hass, config, discovery_info=None):
    return SLNotificationService(hass)


class SLNotificationService(BaseNotificationService):
    def __init__(self, hass):
        self.hass = hass

    async def async_send_message(self, message="", **kwargs):
        bridge = self.hass.data.get(DOMAIN, {})
        adapters = bridge.get("adapters", {})
        registries = bridge.get("registries", {})

        if not adapters:
            _LOGGER.warning("No adapter endpoints registered.")
            return

        targets = kwargs.get("target", [])
        if isinstance(targets, str):
            targets = [targets]

        # No target or ["all"] — broadcast to every online avatar in every world
        if not targets or targets == [BROADCAST_KEYWORD]:
            targets = [
                f"{world}:{BROADCAST_KEYWORD}"
                for world in adapters
            ]

        session = async_get_clientsession(self.hass)

        for raw in targets:
            world = "secondlife"
            name = raw
            if ":" in raw:
                world, name = raw.split(":", 1)

            adapter_info = adapters.get(world) or {}
            url = adapter_info.get("url") if isinstance(adapter_info, dict) else adapter_info
            caps = adapter_info.get("capabilities", []) if isinstance(adapter_info, dict) else []

            if not url:
                _LOGGER.warning("No adapter URL for world '%s'", world)
                continue

            if caps and "message" not in caps:
                _LOGGER.warning("Adapter for '%s' does not support messaging", world)
                continue

            online = registries.get(world, {}).get("online", [])

            # Broadcast to all online avatars in this world
            if name == BROADCAST_KEYWORD:
                if not online:
                    _LOGGER.debug("Broadcast to '%s': no avatars online", world)
                    continue
                for avatar in online:
                    await _send(session, url, avatar, message, world)
            else:
                if name in online:
                    await _send(session, url, name, message, world)
                else:
                    _LOGGER.debug("'%s' is not online in '%s', skipping", name, world)


async def _send(session, url, avatar, message, world):
    try:
        timeout = aiohttp.ClientTimeout(total=5)
        await session.post(url, json={"to": avatar, "message": message}, timeout=timeout)
        _LOGGER.debug("Sent message to %s in %s", avatar, world)
    except Exception as e:
        _LOGGER.error("Failed to send to %s in %s: %s", avatar, world, e)
