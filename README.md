
# Home Assistant × MMO Bridge

A generic bridge to connect Home Assistant with online virtual worlds (e.g. Second Life) via per-world adapters. Presence tracking, IM delivery, sensor entities, and two-way object control — all driven by HA automations.

---

## Features

- **Presence tracking** — avatars register in-world, online/offline status pushed to HA every N seconds
- **IM delivery** — send messages to online avatars from any HA automation or service call
- **Broadcast** — message everyone online at once
- **Sensor entities** — per-world online count, region FPS, time dilation, agent counts, all graphable
- **Hover text control** — push custom status lines to the in-world object from HA
- **Region metadata** — region name, parcel, sim version, agent counts, time dilation, FPS
- **Region restart detection** — HA event fires when the sim comes back up
- **Token-based webhook auth** — secure, persisted across restarts
- **Restart resilient** — adapter URL and avatar list survive both HA and SL restarts

---

## Installation

1. Copy `custom_components/mmo_bridge/` into your Home Assistant `custom_components/` directory.
2. Add to `configuration.yaml`:

```yaml
mmo_bridge:

notify:
  - platform: mmo_bridge
    name: MMO Bridge
```

3. Restart Home Assistant.
4. Open **Notifications** in the HA sidebar — the MMO Bridge notification shows your webhook URL and token. Keep this handy for the SL setup step.

---

## Second Life Setup

### First time

1. Create an object in-world (or use an existing one).
2. Add `lsl/sl_notify_controller.lsl` as a script.
3. Set the object's **group** — only members with the group tag active can register.
4. The script will start and print status to local chat. It will prompt you to set the HA URL.
5. In local chat, run:

```
/5 seturl https://your-ha.duckdns.org/api/webhook/mmo_bridge?token=YOUR_TOKEN
```

The URL is saved to the object permanently. The script registers with HA, then sends an initial presence report.

### Registering avatars

Touch the object with the group tag **active**. You'll receive an IM confirmation.
Touch again if already registered → IM reminder. To unregister, ask the owner to run `/5 remove Your Name`.

### Chat commands (owner only, channel `/5`)

| Command | Description |
|---|---|
| `seturl <url>` | Save HA webhook URL and re-register |
| `setpoll <seconds>` | Set presence poll interval (min 10s, default 60s) |
| `status` | Show HA URL, script URL, poll interval, registered avatars |
| `list` | List all registered avatars with keys |
| `remove <name>` | Remove a specific avatar by display name |
| `clearusers` | Remove all registered avatars |
| `help` | Show available commands |

### Hover text

The object displays a live status above it, colour-coded:

| Colour | Meaning |
|---|---|
| 🟢 Green | Connected — shows region and online/registered count |
| 🟡 Amber | Connecting or waiting for URL |
| 🔴 Red | No HA URL configured |

Custom lines from HA appear below the status line (see [Hover text service](#mmo_bridgeset_object_text) below).

---

## Entities

After the first presence poll the following entities are created automatically (no configuration needed):

| Entity | Description |
|---|---|
| `sensor.mmo_bridge_secondlife_online` | Online avatar count. Attributes: list of online names, region, parcel, sim info |
| `sensor.mmo_bridge_secondlife_parcel_agents` | Avatars currently on the parcel |
| `sensor.mmo_bridge_secondlife_region_agents` | Avatars currently in the region |
| `sensor.mmo_bridge_secondlife_time_dilation` | Sim time dilation (0.0–1.0) |
| `sensor.mmo_bridge_secondlife_region_fps` | Sim frame rate |

---

## Services

### `notify.mmo_bridge` — send an IM to an online avatar

```yaml
service: notify.mmo_bridge
data:
  message: "Dinner's ready!"
  target: "Avatar Name"
```

**Broadcast to everyone online:**

```yaml
service: notify.mmo_bridge
data:
  message: "Dinner's ready!"
  # omit target, or:
  target: "all"
```

**Scope to one world:**

```yaml
target: "secondlife:all"
```

If the target avatar is not currently online the message is silently dropped.

---

### `mmo_bridge.request_update` — trigger an immediate presence poll

Forces the in-world object to poll avatar online status and update its hover text right now, without waiting for the next scheduled poll.

```yaml
service: mmo_bridge.request_update
# optional — omit to refresh all worlds
data:
  world: secondlife
```

---

### `mmo_bridge.set_object_text` — push a custom line to hover text

Push a named line of text to the in-world object's hover text. Each `key` is independent — different automations can manage their own lines without interfering. Send an empty `value` to remove the line.

```yaml
service: mmo_bridge.set_object_text
data:
  key: plex
  value: "Plex: 2 watching"
```

Remove the line:

```yaml
service: mmo_bridge.set_object_text
data:
  key: plex
  value: ""
```

Custom lines persist across script resets (stored in linkset data).

---

## Events

| Event | Payload | Description |
|---|---|---|
| `mmo_bridge_avatar_online` | `{world, avatar}` | Avatar came online |
| `mmo_bridge_avatar_offline` | `{world, avatar}` | Avatar went offline |
| `mmo_bridge_region_restart` | `{world, world_data}` | Sim restarted |

---

## Example Automations

**Notify all online avatars when the doorbell rings:**

```yaml
automation:
  alias: "Doorbell → SL"
  trigger:
    platform: state
    entity_id: binary_sensor.doorbell
    to: "on"
  condition:
    condition: numeric_state
    entity_id: sensor.mmo_bridge_secondlife_online
    above: 0
  action:
    service: notify.mmo_bridge
    data:
      message: "Someone's at the door!"
```

**Welcome an avatar when they come online:**

```yaml
automation:
  alias: "Welcome Xevian"
  trigger:
    platform: event
    event_type: mmo_bridge_avatar_online
    event_data:
      world: secondlife
      avatar: "Xevian Wake"
  action:
    service: notify.mmo_bridge
    data:
      message: "Welcome back!"
      target: "Xevian Wake"
```

**Show Plex status on the object, remove when nothing is playing:**

```yaml
automation:
  alias: "Plex → SL hover text"
  trigger:
    platform: state
    entity_id: sensor.plex_watching
  action:
    service: mmo_bridge.set_object_text
    data:
      key: plex
      value: >
        {% if states('sensor.plex_watching') | int > 0 %}
          Plex: {{ states('sensor.plex_watching') }} watching
        {% else %}

        {% endif %}
```

**Alert in SL when the sim restarts:**

```yaml
automation:
  alias: "Region restart alert"
  trigger:
    platform: event
    event_type: mmo_bridge_region_restart
  action:
    service: notify.notify
    data:
      message: "{{ trigger.event.data.world_data.region }} has restarted."
```

---

## Security

- A random token is generated on first run and persisted to HA storage.
- All webhook requests are validated against this token — a missing or wrong token returns 403.
- The token is displayed once in the HA notification. It can also be found in `.storage/mmo_bridge` if needed.
- The SL script stores the full URL (including token) in linkset data on the object — set the object so only trusted people can modify it.
