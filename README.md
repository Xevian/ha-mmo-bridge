
# Home Assistant × MMO Bridge

A generic bridge to connect Home Assistant with online worlds (e.g., Second Life, others) via per-world adapters.

## Features

- Custom notify platform (`notify.mmo_bridge`) can send messages to online avatars across "worlds"
- Second Life LSL adapter registers its HTTP-in URL with HA and pushes presence
- In-world avatars can register themselves with a touch
- Online status is pushed every 60s
- Supports secure control calls back into HA (extendable)

## Token

Using placeholder token: `mmo_bridge_b797e53cb3b9`
Update this in the `.lsl`, Home Assistant secrets, and webhook config if needed.
