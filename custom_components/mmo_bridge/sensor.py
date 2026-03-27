
from homeassistant.helpers.entity import Entity
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.core import callback
import logging

from . import DOMAIN, SIGNAL_PRESENCE_UPDATED

_LOGGER = logging.getLogger(__name__)


async def async_setup_platform(hass, config, async_add_entities, discovery_info=None):
    """Store the async_add_entities callback so __init__ can create sensors dynamically."""
    hass.data[DOMAIN]["async_add_sensor_entities"] = async_add_entities
    hass.data[DOMAIN].setdefault("sensor_entities", {})

    # Create sensors for any worlds that registered before the platform was ready
    from . import _ensure_sensor
    for world in list(hass.data[DOMAIN]["adapters"].keys()):
        _ensure_sensor(hass, world)


class MMOBridgeSensor(Entity):
    """Sensor tracking how many avatars are online in a given world."""

    def __init__(self, hass, world):
        self._hass = hass
        self._world = world
        self._online = []
        self._world_data = {}

    @property
    def name(self):
        return f"MMO Bridge {self._world.title()} Online"

    @property
    def unique_id(self):
        return f"{DOMAIN}_{self._world}_online"

    @property
    def state(self):
        return len(self._online)

    @property
    def unit_of_measurement(self):
        return "avatars"

    @property
    def icon(self):
        return "mdi:account-multiple"

    @property
    def extra_state_attributes(self):
        attrs = {
            "world": self._world,
            "online": self._online,
        }
        # Merge in whatever world_data the adapter sent — generic across all worlds
        attrs.update(self._world_data)
        return attrs

    @property
    def should_poll(self):
        return False

    async def async_added_to_hass(self):
        self.async_on_remove(
            async_dispatcher_connect(
                self.hass, SIGNAL_PRESENCE_UPDATED, self._handle_presence_update
            )
        )

    @callback
    def _handle_presence_update(self, world):
        if world != self._world:
            return
        registry = self.hass.data[DOMAIN]["registries"].get(self._world, {})
        self._online = registry.get("online", [])
        self._world_data = registry.get("world_data", {})
        self.async_write_ha_state()
