
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

            # Collect all nodes that advertise the 'message' capability
            msg_nodes = {
                nid: node for nid, node in nodes.get(world, {}).items()
                if "message" in node.get("capabilities", []) and node.get("url")
            }

            if not msg_nodes:
                _LOGGER.warning("No message-capable node for world '%s'", world)
                continue

            online_list = online.get(world, [])

            if name == BROADCAST_KEYWORD:
                # Broadcast: send to="all" to EVERY message-capable node so that
                # avatars registered with different Hubs all receive the message.
                # Each LSL Hub delivers only to its own registered list, so there
                # are no duplicates unless an avatar is registered with two Hubs.
                for nid, node in msg_nodes.items():
                    await _send(session, node["url"], "all", message, world)
            else:
                # Targeted: try every node — the LSL script returns 404 if the
                # avatar is not in that node's registered list, so the message
                # reaches whichever Hub the avatar is actually registered with.
                if name not in online_list:
                    _LOGGER.debug(
                        "Sending to '%s' in '%s' (not in last presence poll — "
                        "LSL will reject if not registered)",
                        name, world,
                    )
                for nid, node in msg_nodes.items():
                    await _send(session, node["url"], name, message, world)


def _ascii_safe(text: str) -> str:
    """Replace non-ASCII characters that LSL can't handle cleanly.

    LSL's HTTP-in body handling is byte-oriented — multi-byte UTF-8 sequences
    (e.g. ° → 0xC2 0xB0) arrive as two separate characters, producing mojibake.
    Common substitutions are applied first; anything remaining is dropped.
    """
    replacements = {
        "°": " deg",
        "–": "-",
        "—": "-",
        "\u2018": "'", "\u2019": "'",   # curly single quotes
        "\u201c": '"', "\u201d": '"',   # curly double quotes
        "…": "...",
        "€": "EUR",
        "£": "GBP",
        "©": "(c)",
        "®": "(R)",
        "™": "(TM)",
    }
    for char, sub in replacements.items():
        text = text.replace(char, sub)
    return text.encode("ascii", "ignore").decode("ascii")


async def _send(session, url, avatar, message, world):
    try:
        timeout  = aiohttp.ClientTimeout(total=5)
        response = await session.post(
            url, json={"to": avatar, "message": _ascii_safe(message)}, timeout=timeout
        )
        if response.status == 404:
            _LOGGER.debug(
                "Message to '%s' in '%s': avatar not registered on this node (404)",
                avatar, world,
            )
        else:
            _LOGGER.debug("Sent message to %s in %s (HTTP %s)", avatar, world, response.status)
    except Exception as e:
        _LOGGER.error("Failed to send to %s in %s: %s", avatar, world, e)
