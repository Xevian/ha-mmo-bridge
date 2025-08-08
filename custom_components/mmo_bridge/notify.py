
from homeassistant.components.notify import BaseNotificationService
import requests
import logging

_LOGGER = logging.getLogger(__name__)

def get_service(hass, config, discovery_info=None):
    return SLNotificationService(hass)

class SLNotificationService(BaseNotificationService):
    def __init__(self, hass):
        self.hass = hass

    def send_message(self, message="", **kwargs):
        targets = kwargs.get("target", [])
        if isinstance(targets, str):
            targets = [targets]
        # Support multi-world routing: targets can be strings like "world:name" or just "name" (defaults to secondlife)
        adapters = self.hass.data.get("adapters", {})
        registries = self.hass.data.get("registries", {})

        if not adapters:
            _LOGGER.warning("No adapter endpoints registered.")
            return

        for raw in targets:
            string_world = "secondlife"
            string_name = raw
            # Split on first ':' if provided
            try:
                if ":" in raw:
                    parts = raw.split(":", 1)
                    string_world, string_name = parts[0], parts[1]
            except Exception:  # defensive
                pass

            registry = registries.get(string_world, {"online": []})
            online = registry.get("online", [])
            adapter_info = adapters.get(string_world) or {}
            url = adapter_info.get("url") if isinstance(adapter_info, dict) else adapter_info
            caps = adapter_info.get("capabilities", []) if isinstance(adapter_info, dict) else []

            if not url:
                _LOGGER.warning("No adapter URL for world '%s'", string_world)
                continue

            # Require capability to message if declared
            if caps and "message" not in caps:
                _LOGGER.warning("Adapter for '%s' does not support messaging", string_world)
                continue

            if string_name in online:
                payload = {"to": string_name, "message": message}
                try:
                    requests.post(url, json=payload, timeout=5)
                except Exception as e:
                    _LOGGER.error("Failed to send to %s:%s: %s", string_world, string_name, e)
