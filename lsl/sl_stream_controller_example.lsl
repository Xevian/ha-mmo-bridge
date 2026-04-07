
// ── MMO Bridge — Parcel Stream Controller Example ─────────────────────────────
//
// Controls the parcel audio stream from HA automations via mmo_bridge.region_say.
// Stream presets are loaded from a notecard (no script editing needed).
//
// Notecard name: "MMO Streams"  (must match NOTECARD constant below)
// Notecard format — one preset per line:
//   Name | URL
//   # Lines starting with # are comments and are ignored
//   # Leave URL blank (or omit it) to create a "silence" preset
//
// Example notecard contents:
//   # MMO Stream Presets
//   Off     |
//   Jazz    | http://your-jazz-stream:port/stream
//   Ambient | http://your-ambient-stream:port/stream
//   Gaming  | http://your-gaming-stream:port/stream
//
// Commands received as JSON on CTRL_CHANNEL:
//   {"command": "set_stream",  "url": "http://...", "label": "My Radio"}
//   {"command": "set_preset",  "name": "Jazz"}
//   {"command": "next_preset"}
//   {"command": "prev_preset"}
//   {"command": "stop"}
//
// Owner touch cycles through presets in-world.
// Drop a new/updated notecard in to reload presets automatically.
//
// Requirements:
//   - Rez on the parcel you want to control
//   - Script owner must have rights to change parcel media
//     (own the land, or land group with media-change rights)
//   - Hub must be in the same region (region_say is region-wide only)
//
// ─────────────────────────────────────────────────────────────────────────────

// ── Configuration — edit these ────────────────────────────────────────────────

string  NOTECARD    = "MMO Streams";   // notecard in the same prim's inventory
integer CTRL_CHANNEL = -12345678;      // must be negative; match in HA automation

// ── Runtime state ─────────────────────────────────────────────────────────────

list    presets;           // [name, url, name, url, ...] — populated from notecard
integer ctrl_listen;
integer current_preset = 0;
string  current_label  = "";

// Notecard loading
integer loading  = FALSE;
integer nc_line  = 0;
key     nc_req;

// ── Helpers ───────────────────────────────────────────────────────────────────

integer presetCount() { return llGetListLength(presets) / 2; }
string  presetName(integer i) { return llList2String(presets, i * 2); }
string  presetUrl(integer i)  { return llList2String(presets, i * 2 + 1); }

integer findPreset(string name) {
    integer i;
    for (i = 0; i < presetCount(); i++) {
        if (llToLower(presetName(i)) == llToLower(name)) return i;
    }
    return -1;
}

updateHoverText() {
    string line2;
    vector color;
    if (loading) {
        line2 = "Loading presets...";
        color = <1.0, 0.7, 0.0>;
    } else if (current_label == "" || current_label == "Off") {
        line2 = "— Stopped —";
        color = <0.6, 0.6, 0.6>;
    } else {
        line2 = "♫  " + current_label;
        color = <0.3, 0.8, 1.0>;
    }
    llSetText("Stream Controller\n" + line2, color, 1.0);
}

applyPreset(integer idx) {
    if (idx < 0 || idx >= presetCount()) return;
    current_preset = idx;
    current_label  = presetName(idx);
    llSetParcelMusicURL(presetUrl(idx));
    updateHoverText();
    string suffix = "";
    if (presetUrl(idx) == "") suffix = " (stopped)";
    llOwnerSay("Stream: " + current_label + suffix);
}

applyUrl(string url, string label) {
    current_preset = -1;
    if (label != "" && label != JSON_INVALID)
        current_label = label;
    else
        current_label = url;
    llSetParcelMusicURL(url);
    updateHoverText();
    llOwnerSay("Stream set: " + current_label);
}

startLoadNotecard() {
    if (llGetInventoryType(NOTECARD) != INVENTORY_NOTECARD) {
        llOwnerSay("⚠ No notecard named '" + NOTECARD + "' found in inventory.");
        llOwnerSay("  Create one with lines formatted as:  Name | URL");
        llSetText("Stream Controller\n⚠ Missing: " + NOTECARD, <1.0, 0.3, 0.3>, 1.0);
        return;
    }
    presets  = [];
    nc_line  = 0;
    loading  = TRUE;
    updateHoverText();
    nc_req = llGetNotecardLine(NOTECARD, nc_line);
}

// ── Main ──────────────────────────────────────────────────────────────────────

default {
    state_entry() {
        if (ctrl_listen) llListenRemove(ctrl_listen);
        ctrl_listen = llListen(CTRL_CHANNEL, "", NULL_KEY, "");

        llOwnerSay("Stream Controller starting. Listening on channel "
            + (string)CTRL_CHANNEL + ".");
        llOwnerSay("Use mmo_bridge.region_say with this channel from HA.");
        llOwnerSay("Touch to cycle presets in-world.");

        startLoadNotecard();
    }

    dataserver(key req, string data) {
        if (req != nc_req) return;

        if (data == EOF) {
            loading = FALSE;
            integer count = presetCount();
            if (count == 0) {
                llOwnerSay("⚠ No valid presets found in '" + NOTECARD + "'.");
                llOwnerSay("  Format: Name | URL  (one per line, # for comments)");
                llSetText("Stream Controller\n⚠ No presets loaded", <1.0, 0.3, 0.3>, 1.0);
                return;
            }
            llOwnerSay("Loaded " + (string)count + " preset(s) from '" + NOTECARD + "'.");
            applyPreset(0);
            return;
        }

        // Parse line: trim whitespace, skip blank lines and comments
        string line = llStringTrim(data, STRING_TRIM);
        if (line != "" && llGetSubString(line, 0, 0) != "#") {
            integer pipe = llSubStringIndex(line, "|");
            string  name;
            string  url;
            if (pipe == -1) {
                name = llStringTrim(line, STRING_TRIM);
                url  = "";
            } else {
                name = llStringTrim(llGetSubString(line, 0, pipe - 1), STRING_TRIM);
                url  = llStringTrim(llGetSubString(line, pipe + 1, -1), STRING_TRIM);
            }
            if (name != "")
                presets += [name, url];
        }

        nc_req = llGetNotecardLine(NOTECARD, ++nc_line);
    }

    touch_start(integer n) {
        if (llDetectedKey(0) != llGetOwner()) return;
        if (loading) { llOwnerSay("Still loading presets — please wait."); return; }
        if (presetCount() == 0) { llOwnerSay("No presets loaded."); return; }
        integer next = current_preset + 1;
        if (next < 0 || next >= presetCount()) next = 0;
        applyPreset(next);
    }

    listen(integer channel, string name, key id, string msg) {
        if (channel != CTRL_CHANNEL) return;
        if (loading) { llOwnerSay("Still loading presets — command ignored."); return; }

        string cmd = llJsonGetValue(msg, ["command"]);
        if (cmd == JSON_INVALID || cmd == "") return;

        if (cmd == "set_stream") {
            string url   = llJsonGetValue(msg, ["url"]);
            string label = llJsonGetValue(msg, ["label"]);
            if (url == JSON_INVALID || url == "") {
                llOwnerSay("set_stream: missing 'url'.");
                return;
            }
            applyUrl(url, label);

        } else if (cmd == "set_preset") {
            string preset_name = llJsonGetValue(msg, ["name"]);
            if (preset_name == JSON_INVALID || preset_name == "") {
                llOwnerSay("set_preset: missing 'name'.");
                return;
            }
            integer idx = findPreset(preset_name);
            if (idx == -1) {
                llOwnerSay("set_preset: unknown preset '" + preset_name + "'.");
                return;
            }
            applyPreset(idx);

        } else if (cmd == "next_preset") {
            integer next = current_preset + 1;
            if (next < 0 || next >= presetCount()) next = 0;
            applyPreset(next);

        } else if (cmd == "prev_preset") {
            integer prev = current_preset - 1;
            if (prev < 0) prev = presetCount() - 1;
            applyPreset(prev);

        } else if (cmd == "stop") {
            current_preset = 0;
            current_label  = "";
            llSetParcelMusicURL("");
            updateHoverText();
            llOwnerSay("Stream stopped.");

        } else {
            llOwnerSay("Unknown command: " + cmd);
        }
    }

    changed(integer c) {
        if (c & (CHANGED_OWNER)) {
            llResetScript();
        }
        if (c & CHANGED_INVENTORY) {
            // Notecard updated — reload presets
            if (llGetInventoryType(NOTECARD) == INVENTORY_NOTECARD) {
                llOwnerSay("Notecard updated — reloading presets...");
                startLoadNotecard();
            }
        }
    }

    on_rez(integer p) { llResetScript(); }
}

// ─────────────────────────────────────────────────────────────────────────────
// Example HA automations
//
// IMPORTANT: always specify node_id in mmo_bridge.region_say calls.
// Without it, the action broadcasts to ALL nodes (Hub, Stats Node, etc.) and
// the stream controller receives the command multiple times. Use the node_id
// of your Hub (the slug of its parcel name — shown on the Hub's hover text).
//
// Switch to Jazz at 8pm:
//   automation:
//     - alias: "SL — Evening Jazz"
//       trigger:
//         - platform: time
//           at: "20:00:00"
//       action:
//         - service: mmo_bridge.region_say
//           data:
//             node_id: your_parcel_name   # slug of your Hub's parcel
//             channel: -12345678
//             message: '{"command": "set_preset", "name": "Jazz"}'
//
// Silence at midnight:
//   automation:
//     - alias: "SL — Midnight stream off"
//       trigger:
//         - platform: time
//           at: "00:00:00"
//       action:
//         - service: mmo_bridge.region_say
//           data:
//             node_id: your_parcel_name
//             channel: -12345678
//             message: '{"command": "stop"}'
//
// Mirror a Plex/Icecast stream when something starts playing:
//   automation:
//     - alias: "SL — Mirror Plex"
//       trigger:
//         - platform: state
//           entity_id: media_player.plex_player
//           to: "playing"
//       action:
//         - service: mmo_bridge.region_say
//           data:
//             node_id: your_parcel_name
//             channel: -12345678
//             message: >-
//               {"command": "set_stream",
//                "url": "http://your-icecast:8000/stream",
//                "label": "Plex"}
// ─────────────────────────────────────────────────────────────────────────────
