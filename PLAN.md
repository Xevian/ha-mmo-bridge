
# MMO Bridge — Plan & Ideas

Scratchpad for planned work, parked ideas, and design notes.
Features move to the README once implemented.

---

## In progress / next up

Nothing actively in flight — branch `claude/stoic-robinson` contains all recent work
pending merge into `master`.

---

## Ideas — HA → SL

### Sound alert
Play a sound from the Hub or Node when an HA automation fires. Audible
in-world ping without needing an IM.

- New command: `{"command": "play_sound", "volume": 1.0}`
- Sound asset must be in the Hub/Node inventory, or supply a known UUID
- `/5 setsound <UUID>` to configure; default to a standard SL built-in ping
- New HA service: `mmo_bridge.play_sound`
- **Effort:** small. Good quick win.

### Visual update (colour / glow) with optional revert
Change the Hub or Node object's colour and glow from HA. Useful as a
passive status indicator — e.g. glow red while alarm is armed.

- New command: `{"command": "set_visual", "color": [r,g,b], "glow": 0.0–1.0, "revert_after": <seconds>}`
- Revert timer: store `visual_revert_at` unix timestamp, check against it
  in the existing timer event tick — no second timer needed
- Store original colour/glow on first override so revert is always clean
- Texture swapping possible but requires asset in inventory — leave for later
- New HA service: `mmo_bridge.set_visual`
- **Effort:** medium.

### Two-way dialog
HA sends an `llDialog()` to a registered avatar (multiple-choice buttons);
avatar picks an option; result fires back as an `mmo_bridge_inworld_trigger`
event for automations to act on.

- `llDialog()` is **not** range-limited — any avatar in the Hub's region works
- Cross-region requires the HUD to include its HTTP-in URL in the
  `avatar_state` registration payload; HA stores it per avatar and POSTs
  directly to the HUD. HUD re-registers on every region change so HA always
  has the current URL. This would unlock general HA→HUD push for other
  features too — worth designing properly before implementing.
- Pending reply listener on a random channel; timeout cleans up if ignored
- **Effort:** medium–large. Depends on whether HUD URL push is added first.

### `llTextBox` interactive input
Like dialog but free-text. HA asks a question, avatar types a reply,
result comes back as a trigger payload.

- Same design questions as two-way dialog (range / HUD URL)
- Natural companion feature once dialog is done
- **Effort:** small once dialog infrastructure exists.

### Parcel stream URL
Change the parcel audio stream URL from HA (e.g. Sonos/media player
integration → SL parcel radio).

- `llSetParcelMusicURL()` requires the prim owner to have parcel media
  permissions. Group-owned land needs a group-deeded relay prim.
- **Pattern (no protocol changes needed):** owner sets up a group-deeded
  relay object that listens on the trigger relay channel for
  `{"trigger": "set_stream", "url": "..."}` and calls
  `llSetParcelMusicURL()`. HA fires via `mmo_bridge.region_say` on that
  channel. Document as a recipe rather than building it in.
- **Effort:** docs-only if using trigger relay pattern.

---

## Ideas — SL → HA

### Visitor detection
Hub/Node fires HA events when non-registered avatars arrive on or leave
the parcel. Off by default — too noisy for busy parcels (shops, clubs).

- Track previous `llGetAgentList` result; diff on each poll tick
- Fire `mmo_bridge_visitor_arrived` / `mmo_bridge_visitor_left`
  `{world, node_id, name}` — non-registered avatars only (registered
  avatars already have full presence tracking)
- Toggle command: `/5 setvisitors on|off` (consistent with other `set*`
  commands); stored in linkset data so it survives resets
- Node supports it too (same command on `/4`) — Node in a shop parcel
  is the primary use case
- **Name resolution:** `llKey2Name()` can return empty for uncached
  avatars; `llRequestAgentData(av, DATA_NAME)` is reliable but async.
  Ties into the 0.3 UUID-first tracking work — may be worth parking
  until then for consistency
- **Effort:** medium.

---

## Parked — targeting 0.3

These are protocol-level changes that need coordinated updates across
LSL scripts and the HA integration. Keeping them together avoids
multiple breaking-change releases.

### UUID as primary key for avatars and parcels
- **Problem:** legacy names can be changed (paid service); parcel names
  change freely. Using names as keys causes entity churn in HA.
- **Avatars:** `llGetOwner()` returns a stable UUID. Use it as the
  primary key; `llKey2Name()` / `llGetDisplayName()` for `friendly_name`.
- **Parcels:** `PARCEL_DETAILS_ID` returns a stable parcel UUID. Use
  as `node_id` instead of slugified parcel name.
- **HA entity names:** slugify UUID for entity_id; keep `friendly_name`
  human-readable and updatable without breaking history.
- Needs protocol version bump → `PROTOCOL_VERSION = 2`.

### UTF-8 display names
- `llGetDisplayName()` returns UTF-8 and can contain arbitrary characters.
- HA side already handles UTF-8 fine; LSL HTTP-in byte-handling is the
  constraint for anything going SL→HA.
- For HA `friendly_name` (stored in HA, never sent to LSL) this is fine
  immediately once UUID tracking is in place.

### Proper HACS packaging
- `config_flow.py` + `async_setup_entry` for UI-based setup
- `strings.json` for translations
- `hacs.json` for HACS listing
- Remove dead `known_avatars` stub from `hass.data`
- Replace `hass.states.async_set()` with proper `TrackerEntity` classes

---

## Completed (recent)

| Version | Feature |
|---|---|
| 0.2.1 | Protected linkset data for HA URL and HMAC secret |
| 0.2.1 | Migration from unprotected entries (one-time, on state_entry) |
| 0.2.1 | `llLinksetDataReset()` for hard reset and owner wipe |
| 0.2.1 | Stats Node moved to channel /4 (was conflicting with Hub /5) |
| 0.2.1 | SCRIPT_VERSION constant + header blurb on all scripts |
| 0.2.1 | `mmo_avatar` / `mmo_world` passed as HA script variables on HUD command |
| 0.2.1 | `llSetObjectName()` to base name on state_entry (clean boxing) |
| 0.2.1 | `touch_start` moved entirely to commands script; HUD decoupled |
| 0.2.1 | `_ascii_safe()` in notify.py — fixes `°` → `Â°` LSL mojibake |
| 0.2.1 | `mmo_bridge.region_say` service + `region_say` command in Hub/Node |
| 0.2.1 | Inworld trigger relay (`settrigchan`, `mmo_bridge_inworld_trigger` event) |
| 0.2.1 | Security checks: refuse to run on default LD_PASS or script No-Modify unset |
