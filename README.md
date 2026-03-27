
# Home Assistant × MMO Bridge

A generic bridge to connect Home Assistant with online worlds (e.g., Second Life, others) via per-world adapters.

## Features

- Custom notify platform (`notify.mmo_bridge`) can send messages to online avatars across "worlds"
- Second Life LSL adapter registers its HTTP-in URL with HA and pushes presence
- In-world avatars can register themselves with a touch
- Online status is pushed every 60s
- Token-based webhook authentication

## Installation

1. Copy `custom_components/mmo_bridge/` into your Home Assistant `custom_components/` directory.
2. Add the following to your `configuration.yaml`:

```yaml
mmo_bridge:

notify:
  - platform: mmo_bridge
    name: MMO Bridge
```

3. Restart Home Assistant.
4. Check **Notifications** in the HA UI — the MMO Bridge notification will show your webhook URL and token.

## Second Life Setup

1. Create an object in-world and add `lsl/sl_notify_controller.lsl` as a script.
2. Set the `ha_url` variable at the top of the script to the webhook URL shown in the HA notification (including the `?token=...` query string).
3. Save/reset the script. It will automatically register with HA.
4. Avatars can touch the object to register themselves for IM delivery.

## Usage

Send a message to an online avatar via the `notify.mmo_bridge` service:

```yaml
service: notify.mmo_bridge
data:
  message: "Hello from Home Assistant!"
  target: "Avatar Name"
```

For multi-world routing, prefix the target with the world name:

```yaml
target: "secondlife:Avatar Name"
```
