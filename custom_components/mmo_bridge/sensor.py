
from homeassistant.helpers.entity import Entity
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.core import callback
import logging

from . import DOMAIN, SIGNAL_PRESENCE_UPDATED

_LOGGER = logging.getLogger(__name__)

# World-data fields to expose as individual graphable sensors.
# (key, name suffix, unit, icon, cast_fn)
# Add entries here to expose additional numeric fields automatically.
WORLD_DATA_SENSORS = [
    ("agents_on_parcel", "Parcel Agents",   "avatars", "mdi:account-group",    int),
    ("agents_in_region", "Region Agents",   "avatars", "mdi:account-multiple", int),
    ("time_dilation",    "Time Dilation",   None,      "mdi:clock-fast",       float),
    ("region_fps",       "Region FPS",      "FPS",     "mdi:speedometer",      float),
]


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
        attrs.update(self._world_data)
        return attrs

    @property
    def should_poll(self):
        return False

    async def async_added_to_hass(self):
        self.async_on_remove(
            async_dispatcher_connect(
                self.hass, SIGNAL_PRESENCE_UPDATED, self._handle_update
            )
        )

    @callback
    def _handle_update(self, world):
        if world != self._world:
            return
        registry = self.hass.data[DOMAIN]["registries"].get(self._world, {})
        self._online = registry.get("online", [])
        self._world_data = registry.get("world_data", {})
        self.async_write_ha_state()


class MMOBridgeWorldDataSensor(Entity):
    """Sensor exposing a single numeric world_data field as a graphable entity."""

    def __init__(self, hass, world, key, name_suffix, unit, icon, cast_fn):
        self._hass = hass
        self._world = world
        self._key = key
        self._name_suffix = name_suffix
        self._unit = unit
        self._icon = icon
        self._cast_fn = cast_fn
        self._state = None

    @property
    def name(self):
        return f"MMO Bridge {self._world.title()} {self._name_suffix}"

    @property
    def unique_id(self):
        return f"{DOMAIN}_{self._world}_{self._key}"

    @property
    def state(self):
        return self._state

    @property
    def unit_of_measurement(self):
        return self._unit

    @property
    def icon(self):
        return self._icon

    @property
    def should_poll(self):
        return False

    async def async_added_to_hass(self):
        self.async_on_remove(
            async_dispatcher_connect(
                self.hass, SIGNAL_PRESENCE_UPDATED, self._handle_update
            )
        )

    @callback
    def _handle_update(self, world):
        if world != self._world:
            return
        raw = (
            self.hass.data[DOMAIN]["registries"]
            .get(self._world, {})
            .get("world_data", {})
            .get(self._key)
        )
        if raw is not None:
            try:
                self._state = self._cast_fn(raw)
            except (ValueError, TypeError):
                self._state = None
        self.async_write_ha_state()
