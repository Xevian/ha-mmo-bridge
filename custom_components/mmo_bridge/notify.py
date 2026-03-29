
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
        bridge   = self.hass.data.get(DOMAIN, {})
        nodes    = bridge.get("nodes", {})           # world -> node_id -> {url, capabilities, ...}
        online   = bridge.get("online_by_world", {}) # world -> [avatar_name, ...]

        if not nodes:
            _LOGGER.warning("No adapter endpoints registered.")
            return

        targets = kwargs.get("target", [])
        if isinstance(targets, str):
            targets = [targets]

        # No target or ["all"] — broadcast to every world
        if not targets or targets == [BROADCAST_KEYWORD]:
            targets = [f"{world}:{BROADCAST_KEYWORD}" for world in nodes]

        session = async_get_clientsession(self.hass)

        for raw in targets:
            world = "secondlife"
            name  = raw
            if ":" in raw:
                world, name = raw.split(":", 1)

            # Find the first node that explicitly advertises the 'message' capability
            url = None
            for node in nodes.get(world, {}).values():
                if "message" in node.get("capabilities", []):
                    url = node.get("url")
                    if url:
                        break

            if not url:
                _LOGGER.warning("No message-capable node for world '%s'", world)
                continue

            online_list = online.get(world, [])

            if name == BROADCAST_KEYWORD:
                # Broadcast: send to="all" — the LSL script iterates its own
                # registered list and delivers to every avatar in-world.
                # This avoids relying on HA's online_by_world being up to date.
                await _send(session, url, "all", message, world)
            else:
                # Targeted: send unconditionally — the LSL script returns 404 if
                # the avatar is not registered.
                if name not in online_list:
                    _LOGGER.debug(
                        "Sending to '%s' in '%s' (not in last presence poll — "
                        "LSL will reject if not registered)",
                        name, world,
                    )
                await _send(session, url, name, message, world)


async def _send(session, url, avatar, message, world):
    try:
        timeout  = aiohttp.ClientTimeout(total=5)
        response = await session.post(
            url, json={"to": avatar, "message": message}, timeout=timeout
        )
        if response.status == 404:
            _LOGGER.warning(
                "Message to '%s' in '%s' rejected by LSL script (avatar not registered)",
                avatar, world,
            )
        else:
            _LOGGER.debug("Sent message to %s in %s (HTTP %s)", avatar, world, response.status)
    except Exception as e:
        _LOGGER.error("Failed to send to %s in %s: %s", avatar, world, e)
