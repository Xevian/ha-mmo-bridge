
from homeassistant.helpers.entity import Entity
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.helpers import entity_registry as er
from homeassistant.core import callback
import logging

from . import DOMAIN, SIGNAL_PRESENCE_UPDATED, SIGNAL_NODE_UPDATED

_LOGGER = logging.getLogger(__name__)

# World-data fields exposed as individual graphable sensors.
# (key, name suffix, unit, icon, cast_fn)
WORLD_DATA_SENSORS = [
    ("agents_on_parcel", "Parcel Agents", "avatars", "mdi:account-group",    int),
    ("agents_in_region", "Region Agents", "avatars", "mdi:account-multiple", int),
    ("time_dilation",    "Time Dilation", None,      "mdi:clock-fast",       float),
    ("region_fps",       "Region FPS",    "FPS",     "mdi:speedometer",      float),
]


async def async_setup_platform(hass, config, async_add_entities, discovery_info=None):
    """Store the async_add_entities callback so __init__ can create sensors dynamically."""
    hass.data[DOMAIN]["async_add_sensor_entities"] = async_add_entities
    hass.data[DOMAIN].setdefault("sensor_entities", {})

    # Remove orphaned entity registry entries from previous formats:
    #   v0.1.x: mmo_bridge_<world>_<key>               (no node_id)
    #   v0.2.0 migration artifact: mmo_bridge_<world>_default_<key>
    registry = er.async_get(hass)
    for world in hass.data[DOMAIN]["nodes"]:
        for sensor_key, _, _, _, _ in WORLD_DATA_SENSORS:
            for old_unique_id in (
                f"{DOMAIN}_{world}_{sensor_key}",           # v0.1.x
                f"{DOMAIN}_{world}_default_{sensor_key}",   # v0.2.0 migration node
            ):
                entity_id = registry.async_get_entity_id("sensor", DOMAIN, old_unique_id)
                if entity_id:
                    registry.async_remove(entity_id)
                    _LOGGER.info("Removed legacy sensor entity %s (%s)", entity_id, old_unique_id)

    # Create sensors for any worlds/nodes that registered before the platform was ready
    from . import _ensure_online_sensor, _ensure_node_sensors
    for world, nodes in hass.data[DOMAIN]["nodes"].items():
        _ensure_online_sensor(hass, world)
        for node_id in nodes:
            _ensure_node_sensors(hass, world, node_id)


class MMOBridgeSensor(Entity):
    """Sensor tracking how many avatars are online in a given world."""

    def __init__(self, hass, world):
        self._hass  = hass
        self._world = world
        self._online = []

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
        return {
            "world":  self._world,
            "online": self._online,
        }

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
        self._online = self.hass.data[DOMAIN]["online_by_world"].get(self._world, [])
        self.async_write_ha_state()


class MMOBridgeWorldDataSensor(Entity):
    """Sensor exposing a single numeric world_data field from a specific node."""

    def __init__(self, hass, world, node_id, key, name_suffix, unit, icon, cast_fn):
        self._hass        = hass
        self._world       = world
        self._node_id     = node_id
        self._key         = key
        self._name_suffix = name_suffix
        self._unit        = unit
        self._icon        = icon
        self._cast_fn     = cast_fn
        self._state       = None

    @property
    def name(self):
        node_label = self._node_id.replace("_", " ").title()
        return f"MMO Bridge {self._world.title()} {node_label} {self._name_suffix}"

    @property
    def unique_id(self):
        return f"{DOMAIN}_{self._world}_{self._node_id}_{self._key}"

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
    def extra_state_attributes(self):
        return {
            "world":   self._world,
            "node_id": self._node_id,
        }

    @property
    def should_poll(self):
        return False

    async def async_added_to_hass(self):
        self.async_on_remove(
            async_dispatcher_connect(
                self.hass, SIGNAL_NODE_UPDATED, self._handle_update
            )
        )

    @callback
    def _handle_update(self, world, node_id):
        if world != self._world or node_id != self._node_id:
            return
        raw = (
            self.hass.data[DOMAIN]["nodes"]
            .get(self._world, {})
            .get(self._node_id, {})
            .get("world_data", {})
            .get(self._key)
        )
        if raw is not None:
            try:
                self._state = self._cast_fn(raw)
            except (ValueError, TypeError):
                self._state = None
        self.async_write_ha_state()
