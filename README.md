
# MMO Bridge for Home Assistant

Connects your Second Life avatar to Home Assistant. Track who is online, monitor region health, and trigger HA scripts from in-world via a wearable HUD — all secured with token auth and per-avatar HMAC signing.

---

## What it does

- **Presence tracking** — device tracker entities per avatar (`home` / `not_home` / `unavailable`)
- **Avatar state** — AFK, busy flags, current region and parcel pushed on change (not on a fixed schedule)
- **World data sensors** — region FPS, time dilation, agent counts — graphable history in HA
- **Parcel visitor tracking** — see who is on your parcel in real time, including non-registered visitors; arrival/departure events for automations
- **In-world IMs** — send messages to registered avatars from any HA automation
- **HA script menu** — touch the HUD in-world to run labelled HA scripts (lights, scenes, etc.)
- **Hover text control** — push live status lines to in-world objects from HA automations
- **Region announcements** — broadcast messages to local or region-wide chat from HA automations
- **Inworld trigger relay** — in-world scripted objects (doorbell, vendor, NPC) fire HA events that automations can act on
- **Plugin system** — drop extra scripts into the Hub object to extend it without touching the main script

---

## Requirements

- Home Assistant with an externally accessible HTTPS URL (Nabu Casa or self-hosted)
- A Second Life account able to rez objects and wear attachments

---

## Installation

### 1 — Copy the integration

Copy the `custom_components/mmo_bridge/` folder into your HA `config/custom_components/` directory, then restart Home Assistant.

### 2 — Add the integration

Go to **Settings → Integrations → Add Integration** and search for **MMO Bridge**. Click Submit — no configuration fields are needed.

### 3 — Get your webhook URL

Click **Configure** on the MMO Bridge integration card. Copy the URL shown — you'll need it for the in-world setup steps below.

> **Upgrading from an earlier version?** If you have `mmo_bridge:` or `notify: - platform: mmo_bridge` in `configuration.yaml`, do one restart with those lines still present (to auto-create the config entry), then you can remove them.

---

## Security setup (required before first use)

Before the scripts will run you must complete two steps. **All four scripts will refuse to start until both are done** — they print a clear `ownerSay` warning telling you what's still missing.

### 1 — Change `LD_PASS` in every script

Open each of the four LSL scripts and change the `LD_PASS` constant from the default to a unique passphrase of your choice:

```lsl
string LD_PASS = "mmo_bridge";  // ← change this
```

The same value must be set in all four scripts:
- `sl_notify_controller.lsl` (Hub)
- `sl_stats_node.lsl` (Node)
- `sl_avatar_hud.lsl` (HUD)
- `sl_hud_commands.lsl` (HUD Commands)

The default `"mmo_bridge"` is public knowledge (open source) — using it means anyone who gets a copy of your prim and knows the source can read your protected linkset data.

### 2 — Set scripts to No-Modify for the next owner

Right-click each script → **Properties** → uncheck **Modify** under *Next Owner*.

The object itself can stay Modify — recipients are welcome to reshape or retexture it however they like. Only the scripts need to be locked, because that's what protects the `LD_PASS` value from being read by someone who receives a copy.

> **During development** you obviously need Modify on for yourself. These checks only fire if the *next-owner* permission is set — your own Modify permission is unaffected.

---

## In-world setup

There are up to three in-world components. You only need the Bridge to get started — the Stats Node and HUD are optional add-ons.

### The Bridge object — presence + IM delivery

**Scripts:** `sl_notify_controller.lsl`

1. Rez a prim in-world (or use an existing object)
2. Drop `sl_notify_controller.lsl` into it
3. Set the object's **group** — only members with that group tag active can register
4. Set the HA URL: `/5 seturl https://your-ha.example.com/api/webhook/mmo_bridge?token=YOUR_TOKEN`

The object registers with HA and shows a colour-coded hover text:

| Colour | Meaning |
|---|---|
| 🟢 Green | Connected — region name + online/registered count |
| 🟡 Amber | Connecting |
| 🔴 Red | No HA URL set |

**Registering avatars:** touch the object with the group tag active. HA URL is sent to their HUD automatically. Touch again if already registered to refresh the HUD URL.

**Bridge commands** (owner only, channel `/5`):

| Command | Description |
|---|---|
| `/5 seturl <url>` | Save HA webhook URL and re-register |
| `/5 setpoll <sec>` | Presence poll interval (min 10s, default 60s) |
| `/5 status` | HA URL, script URL, registered avatars |
| `/5 list` | List all registered avatars (shows `[no broadcast]` flag) |
| `/5 remove <name>` | Remove an avatar by display name |
| `/5 clearusers` | Remove all registered avatars |
| `/5 push` | Force an immediate presence push |
| `/5 nobroadcast <name>` | Track presence but exclude from broadcast IMs |
| `/5 broadcast <name>` | Re-enable broadcast IMs for an excluded avatar |
| `/5 settrigchan` | Enable trigger relay / rotate to a new random channel |
| `/5 settrigchan <n>` | Set trigger relay to a specific negative channel |
| `/5 hardreset` | Clear all stored data and reset (use when moving to new HA) |
| `/5 help` | Show available commands |

---

### The Stats Node — world data sensors (optional)

**Scripts:** `sl_stats_node.lsl`

Pushes region FPS, time dilation, agent counts, and sim info to HA as graphable sensors. Best placed somewhere that stays rezzed permanently (a skybox, home parcel, etc.).

```
/4 seturl https://your-ha.example.com/api/webhook/mmo_bridge?token=YOUR_TOKEN
```

**Stats commands** (owner only, channel `/4`):

| Command | Description |
|---|---|
| `/4 seturl <url>` | Save HA webhook URL |
| `/4 setpoll <sec>` | Stats push interval (min 10s, default 60s) |
| `/4 status` | Current status and node ID |
| `/4 push` | Force an immediate stats push |
| `/4 settrigchan` | Enable trigger relay / rotate to a new random channel |
| `/4 settrigchan <n>` | Set trigger relay to a specific negative channel |
| `/4 hardreset` | Clear all stored data and reset |
| `/4 help` | Show available commands |

---

### Parcel visitor monitor — who's on your land (optional plugin)

**Script:** `sl_parcel_monitor.lsl`

Tracks every avatar currently on your parcel — including visitors who have never registered with your Hub — and reports the list to HA every 15 seconds.

**Setup:** drop `sl_parcel_monitor.lsl` into the **Hub object** alongside `sl_notify_controller.lsl`. It automatically shares the Hub's webhook URL, auth token, and node ID via the plugin system — no extra configuration needed.

When the plugin is running, the existing `sensor..._parcel_agents` sensor gains an `agents` attribute listing everyone currently on the parcel by name:

```yaml
# In a template or automation condition:
{{ state_attr('sensor.mmo_bridge_secondlife_xev_getaway_parcel_agents', 'agents') }}
# → ["Aki Resident", "Friend Resident", "Visitor Name"]
```

**Events fired:**

| Event | Payload | When |
|---|---|---|
| `mmo_bridge_parcel_arrived` | `{world, node_id, key, name}` | Avatar steps onto the parcel |
| `mmo_bridge_parcel_left` | `{world, node_id, key, name}` | Avatar leaves the parcel |

---

### The Avatar HUD — state tracking + script menu (optional)

**Scripts:** `sl_avatar_hud.lsl` + `sl_hud_commands.lsl` — **both must be in the same object**

The HUD tracks your AFK/busy state and current location, and lets you run HA scripts from a touch menu. It only pushes to HA when something actually changes — not on a fixed timer.

1. Create a prim (HUD attachment recommended — e.g. Centre 2)
2. Drop **both** `sl_avatar_hud.lsl` and `sl_hud_commands.lsl` into it
3. Wear it as a HUD attachment
4. **Touch the Bridge object** — it will push the HA URL to your HUD automatically

The HUD is invisible by default. It only speaks up when there's a problem.

**HUD commands** (channel `/6`):

| Command | Description |
|---|---|
| `/6 help` | List all commands |
| `/6 status` | Connection status, HMAC secret, bridge key |
| `/6 push` | Force an immediate state push to HA |
| `/6 setpoll <sec>` | How often to check for state changes (min 5s, default 15s) |
| `/6 seturl <url>` | Manually set HA webhook URL (fallback) |
| `/6 setbridge` | Clear bridge pairing — trust the next bridge you touch |

**Touch the HUD** to open the HA script menu. See [HA Script Menu](#ha-script-menu) below.

---

## HA Script Menu

Touch the HUD in-world to get a dialog of HA scripts you can run. Commands are HMAC-SHA256 signed with a per-avatar secret so only your HUD can trigger them.

### Adding scripts to the menu

1. In HA go to **Settings → Scripts** and create a script
2. Go to **Settings → Entities**, find the script entity, click it
3. Add label **`MMO Script`** → visible to all registered HUD avatars
4. Or add **`MMO - Your Name`** (e.g. `MMO - Xevian Wake`) → private to your HUD only

The integration creates these labels automatically — you just assign them. You can add or remove labels at any time; the next HUD touch always fetches a fresh list.

> **Note:** After picking a script, you'll see "signing..." for ~10 seconds — this is a Second Life limitation (the HMAC function has a mandatory delay). The main HUD stays responsive during this time.

**Example HA script** — toggle all lights in a room:

```yaml
alias: "Office Lights Toggle"
sequence:
  - service: light.toggle
    target:
      area: office
```

Label it `MMO Script`, then it appears in the touch menu.

---

## Home Assistant entities

### Device trackers

One per registered avatar: `device_tracker.mmo_bridge_secondlife_<avatar_slug>`

| State | Meaning |
|---|---|
| `home` | Online and on the home parcel |
| `not_home` | Online but elsewhere |
| `unavailable` | Offline |

**Attributes** (when HUD is worn): `afk`, `busy`, `sl_region`, `sl_parcel`, `world`

### Sensors

Created automatically when the Hub or Stats Node first registers:

| Entity | Description |
|---|---|
| `sensor.mmo_bridge_secondlife_online` | Online avatar count |
| `sensor.mmo_bridge_secondlife_<node>_region_fps` | Region frame rate |
| `sensor.mmo_bridge_secondlife_<node>_time_dilation` | Time dilation 0.0–1.0 |
| `sensor.mmo_bridge_secondlife_<node>_parcel_agents` | Avatars on your parcel (count; `agents` attribute added when parcel monitor plugin is running) |
| `sensor.mmo_bridge_secondlife_<node>_region_agents` | Avatars in the region |

`<node>` is the slugified parcel name (e.g. `xev_getaway`).

---

## Actions

All actions are available under **Settings → Automations → Add Action → MMO Bridge** or in Developer Tools → Actions.

### `mmo_bridge.send_message`

Send an IM to an avatar or broadcast to all online avatars.

```yaml
# Broadcast
action: mmo_bridge.send_message
data:
  message: "Dinner's ready!"

# Direct
action: mmo_bridge.send_message
data:
  message: "Your timer went off."
  target: "Xevian Wake"

# Specific world
action: mmo_bridge.send_message
data:
  message: "Hello!"
  target: "secondlife:Xevian Wake"
```

### `mmo_bridge.request_update`

Force an immediate presence poll without waiting for the next scheduled one.

```yaml
action: mmo_bridge.request_update
# data:
#   world: secondlife  # omit to refresh all worlds
```

### `mmo_bridge.set_object_text`

Push a named line of hover text to in-world node(s). Each `key` is independent — different automations can manage their own lines without clashing. Empty `value` removes the line.

```yaml
action: mmo_bridge.set_object_text
data:
  key: "nowplaying"
  value: "🎵 Bohemian Rhapsody"
  # node_id: "xev_getaway"  # omit to send to all display nodes
```

### `mmo_bridge.region_say`

Send a message to in-world chat via the Bridge or Stats Node object. `channel: 0` uses `llSay` (visible in local chat, ~20m radius). Any other channel uses `llRegionSay`, which reaches all listeners on that channel anywhere in the region — useful for NPC scripts or HUDs listening on a shared private channel.

```yaml
# Local chat announcement (channel 0)
action: mmo_bridge.region_say
data:
  message: "Server maintenance in 5 minutes."

# Region-wide on a private channel (e.g. for NPCs/HUDs listening on -9999)
action: mmo_bridge.region_say
data:
  channel: -9999
  message: "EVENT_START"

# Target a specific node
action: mmo_bridge.region_say
data:
  message: "Welcome to the party!"
  node_id: "xev_getaway"
```

---

## Events

| Event | Payload | When it fires |
|---|---|---|
| `mmo_bridge_avatar_online` | `{world, avatar}` | Avatar comes online |
| `mmo_bridge_avatar_offline` | `{world, avatar}` | Avatar goes offline |
| `mmo_bridge_avatar_afk_changed` | `{world, avatar, afk}` | AFK state toggles (HUD required) |
| `mmo_bridge_avatar_busy_changed` | `{world, avatar, busy}` | Busy state toggles (HUD required) |
| `mmo_bridge_region_restart` | `{world, world_data}` | Sim restarts |
| `mmo_bridge_inworld_trigger` | `{world, node_id, owner, trigger, ...}` | In-world trigger object fired (see below) |
| `mmo_bridge_parcel_arrived` | `{world, node_id, key, name}` | Avatar arrives on the parcel (plugin required) |
| `mmo_bridge_parcel_left` | `{world, node_id, key, name}` | Avatar leaves the parcel (plugin required) |
| `mmo_bridge_plugin_data` | `{world, node_id, type, ...}` | Custom plugin sent an unrecognised payload type (see Plugin system) |

---

## Inworld trigger relay

Any in-world scripted object can send a trigger event through the Bridge or Stats Node to Home Assistant. Use cases: a doorbell button, a vendor, an NPC greeting, a tip jar.

### Setup

1. On the Hub (or Node), run `/5 settrigchan` with no argument. It picks a random **negative** channel and enables the relay listener:
   ```
   Trigger relay enabled. Channel: -1847362910. Add this to your trigger objects.
   ```
2. Note the channel. Run `/5 status` any time to check it.
3. Running `/5 settrigchan` again **rotates** to a new channel — remember to update your trigger objects.
4. `/5 settrigchan -12345678` sets a specific channel if you prefer.

The relay is **disabled by default** and survives script resets. `hardreset` clears it.

### Trigger object script (minimal example)

```lsl
integer TRIG_CHAN = -1847362910;  // paste from /5 settrigchan or /5 status

touch_start(integer n) {
    llRegionSay(TRIG_CHAN, llList2Json(JSON_OBJECT, [
        "trigger",  "doorbell",
        "toucher",  llDetectedName(0)
    ]));
}
```

Any extra fields (`toucher`, `message`, `payment`, etc.) are passed through to HA untouched.

### Who can own trigger objects?

- **Hub relay** — the triggering object must be owned by any **registered avatar**
- **Node relay** — the triggering object must be owned by the **Node owner**

Unrecognised owners are silently dropped.

### `mmo_bridge_inworld_trigger` event payload

| Field | Always present | Description |
|---|---|---|
| `trigger` | Yes | Trigger name set by the script (e.g. `"doorbell"`) |
| `world` | Yes | `"secondlife"` |
| `node_id` | Yes | Slugified parcel name of the Hub/Node that relayed it |
| `owner` | Yes | Name of the registered avatar who owns the trigger object |
| `toucher` | Optional | Avatar name passed by the trigger script |
| `message` | Optional | Custom message passed by the trigger script |
| `payment` | Optional | L$ amount (for vendor use) |
| `...` | Optional | Any other fields in the trigger JSON are forwarded as-is |

---

## Example automations

### Notify when a housemate comes online

```yaml
automation:
  alias: "SL — Housemate online"
  trigger:
    - platform: event
      event_type: mmo_bridge_avatar_online
      event_data:
        world: secondlife
  action:
    - service: notify.mobile_app_your_phone
      data:
        message: "{{ trigger.event.data.avatar }} just came online"
```

### Send an IM when a timer fires

```yaml
automation:
  alias: "SL — Pasta timer"
  trigger:
    - platform: time
      at: "18:30:00"
  action:
    - service: mmo_bridge.send_message
      data:
        message: "Pasta timer! 🍝"
        target: "Xevian Wake"
```

### Real-world doorbell — someone touches your SL door

```yaml
automation:
  alias: "SL — Someone at the door"
  trigger:
    - platform: event
      event_type: mmo_bridge_inworld_trigger
      event_data:
        trigger: doorbell
  action:
    - service: notify.mobile_app_your_phone
      data:
        message: "{{ trigger.event.data.toucher }} is at your door in SL"
        title: "SL Doorbell"
```

### Vendor sale — log a payment and send a thank-you IM

```yaml
automation:
  alias: "SL — Vendor sale"
  trigger:
    - platform: event
      event_type: mmo_bridge_inworld_trigger
      event_data:
        trigger: vendor_sale
  action:
    - service: mmo_bridge.send_message
      data:
        message: >
          Thanks {{ trigger.event.data.toucher }}!
          You paid L${{ trigger.event.data.payment }}.
        target: "{{ trigger.event.data.toucher }}"
    - service: notify.mobile_app_your_phone
      data:
        message: >
          L${{ trigger.event.data.payment }} sale to
          {{ trigger.event.data.toucher }}
```

### HA doorbell → SL alert to everyone online

```yaml
automation:
  alias: "SL — Real doorbell to SL"
  trigger:
    - platform: state
      entity_id: binary_sensor.doorbell
      to: "on"
  condition:
    - condition: numeric_state
      entity_id: sensor.mmo_bridge_secondlife_online
      above: 0
  action:
    - service: mmo_bridge.send_message
      data:
        message: "Someone's at the real-world door!"
```

### Region announcement when an HA event fires

```yaml
automation:
  alias: "SL — Server restart warning"
  trigger:
    - platform: time
      at: "03:55:00"
  action:
    - service: mmo_bridge.region_say
      data:
        message: "Home server restarting in 5 minutes. SL bridge will reconnect shortly."
```

### Show now playing on the bridge hover text

```yaml
automation:
  alias: "SL — Now playing"
  trigger:
    - platform: state
      entity_id: media_player.living_room
  action:
    - service: mmo_bridge.set_object_text
      data:
        key: "nowplaying"
        value: >
          {% if is_state('media_player.living_room', 'playing') %}
            🎵 {{ state_attr('media_player.living_room', 'media_title') }}
          {% else %}
          {% endif %}
```

### Do Not Disturb — turn off lights when AFK

```yaml
automation:
  alias: "SL — AFK lights off"
  trigger:
    - platform: event
      event_type: mmo_bridge_avatar_afk_changed
      event_data:
        afk: true
  action:
    - service: light.turn_off
      target:
        area: office
```

### Notify when a specific visitor arrives on the parcel

Requires the parcel monitor plugin — see [Parcel visitor monitor](#parcel-visitor-monitor--whos-on-your-land-optional-plugin).

```yaml
automation:
  alias: "SL — Friend arrived"
  trigger:
    - platform: event
      event_type: mmo_bridge_parcel_arrived
      event_data:
        name: "Friend Resident"
  action:
    - service: notify.telegram
      data:
        message: "{{ trigger.event.data.name }} just arrived at your parcel!"
```

---

## Plugin system

The Hub exposes a lightweight message bus so optional scripts can extend its behaviour without any knowledge of the webhook URL, auth token, or node ID.

### How it works

Any script in the same object as the Hub can send a payload to HA by calling:

```lsl
integer MMO_PLUGIN_MSG = 0x4D4D4F;  // must match the Hub constant

llMessageLinked(LINK_SET, MMO_PLUGIN_MSG, json_payload, "");
```

The Hub's `link_message` handler injects `world`, `node_id`, and `protocol` then fires the HTTP request to HA. The plugin script needs no credentials.

### Well-known plugin payload types

| `type` field | HA handling |
|---|---|
| `parcel_agents` | Updates `parcel_agents` sensor attribute + fires arrival/departure events |

### Custom payload types

Any `type` value not listed above fires a generic `mmo_bridge_plugin_data` event in HA with all payload fields forwarded:

```yaml
trigger:
  - platform: event
    event_type: mmo_bridge_plugin_data
    event_data:
      type: my_sensor_data
action:
  - service: notify.telegram
    data:
      message: "Custom data: {{ trigger.event.data }}"
```

No HA code changes needed — just send the payload from LSL and react to the event in automations.

### Included plugins

| Script | What it does |
|---|---|
| `sl_parcel_monitor.lsl` | Tracks all avatars on the parcel, including non-registered visitors |

---

## Example Lovelace card

```yaml
type: entities
title: Second Life
entities:
  - entity: sensor.mmo_bridge_secondlife_online
    name: Online
  - entity: device_tracker.mmo_bridge_secondlife_xevian_wake
    name: Xevian Wake
  - entity: sensor.mmo_bridge_secondlife_xev_getaway_region_fps
    name: Region FPS
  - entity: sensor.mmo_bridge_secondlife_xev_getaway_time_dilation
    name: Time Dilation
  - entity: sensor.mmo_bridge_secondlife_xev_getaway_parcel_agents
    name: On Parcel
```

Compact glance view:

```yaml
type: glance
title: Second Life
show_state: true
entities:
  - entity: sensor.mmo_bridge_secondlife_online
    name: Online
  - entity: device_tracker.mmo_bridge_secondlife_xevian_wake
    name: Xevian
  - entity: sensor.mmo_bridge_secondlife_xev_getaway_region_fps
    name: FPS
  - entity: sensor.mmo_bridge_secondlife_xev_getaway_time_dilation
    name: TD
```

---

## Security model

| Layer | What it protects |
|---|---|
| Webhook token | All requests — wrong or missing token returns 403 |
| Trusted bridge UUID | HUD ignores URL updates from any object except the paired bridge |
| Per-avatar HMAC-SHA256 secret | Script commands — each avatar has a unique secret; commands include a timestamp to prevent replay |
| HA label whitelist | Only scripts explicitly labelled `MMO Script` or `MMO - <Name>` are reachable from the HUD |
| Trigger relay channel | Random negative channel generated by the owner — can't be triggered from in-world chat (scripts only); rotatable at any time |
| Trigger owner check | Hub relay: object owner must be a registered avatar. Node relay: object owner must be the Node owner. Unknown owners are silently dropped. |
| `LD_PASS` + No-Modify | Scripts refuse to run on the default passphrase or if next-owner Modify is set; see Security Setup section |

---

## Troubleshooting

**Bridge shows red / "No HA URL"**
Run `/5 seturl <webhook URL>` in local chat near the bridge object.

**HUD says "no HA URL — touch your bridge"**
Touch the bridge object while wearing the HUD — it pushes the URL automatically. If out of range, use `/6 seturl <url>` manually.

**Messages not being delivered**
Check that the recipient has registered by touching the bridge. Use `/5 list` on the bridge to see who is registered.

**Script menu shows nothing**
Ensure at least one HA script is labelled `MMO Script` under Settings → Entities. The labels are created by the integration at startup — check they exist under Settings → Labels.

**"command rejected" after picking a script**
Detach and re-wear the HUD — this re-registers and fetches a fresh HMAC secret from HA.

**Sensors showing `_2` suffix duplicates**
Leftover entity registry entries from a previous version. Go to Settings → Entities, search `mmo_bridge`, and delete the ones with `_2` in the name.
