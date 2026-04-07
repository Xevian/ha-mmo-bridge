
// ── MMO Bridge — Doorbell Example ─────────────────────────────────────────────
//
// Example trigger object for use with the MMO Bridge Hub (trigger relay).
//
// Hover text shows the owner's name and live online/offline status.
//
// Touch behaviour:
//
//   Owner ONLINE:
//     Visitor touches doorbell
//     → Owner receives IM directly  (no HA involved — fast, reliable)
//     → Visitor receives confirmation IM
//
//   Owner OFFLINE:
//     Visitor touches doorbell
//     → Trigger sent to Hub  →  HA fires mmo_bridge_inworld_trigger
//     → HA automation replies via mmo_bridge.region_say on reply_channel
//     → Doorbell receives reply and IMs it to the visitor
//     → Visitor receives the message
//
// Setup:
//   1. Edit HUB_TRIG_CHANNEL below to match your Hub's /5 settrigchan value.
//   2. Rez the doorbell in the same region as your Hub.
//   3. Make sure your avatar (the doorbell owner) is registered with the Hub.
//   4. Optional: set up an HA automation (see example at bottom of file).
//      The automation receives the trigger and replies via mmo_bridge.region_say
//      using the reply_channel included in the event data.
//
// ─────────────────────────────────────────────────────────────────────────────

// ── Configuration — edit this ────────────────────────────────────────────────

// Must match the value shown by /5 settrigchan on your Hub.
// Run /5 settrigchan on your Hub if you haven't already — it prints the channel.
integer HUB_TRIG_CHANNEL = -99999999;

// How often (seconds) to re-check the owner's online status for hover text.
float POLL_INTERVAL = 30.0;

// Minimum seconds between knocks from the same visitor.
float COOLDOWN = 30.0;

// ── Runtime state ─────────────────────────────────────────────────────────────

integer owner_online    = FALSE;
string  owner_name      = "";
key     name_req;           // pending DATA_NAME dataserver key
key     online_req;         // pending DATA_ONLINE dataserver key

// A random negative channel generated at startup. The doorbell listens here
// for HA replies. Included in every trigger payload as "reply_channel" so HA
// knows where to send the response back via mmo_bridge.region_say.
integer reply_channel;
integer reply_listen;

// Cooldown tracking: [key, unix_time, key, unix_time, ...]
list    cooldown_list;


// ── Helpers ───────────────────────────────────────────────────────────────────

// Returns TRUE if toucher is still within the cooldown window.
// Also prunes expired entries to keep the list tidy.
integer isOnCooldown(key toucher) {
    integer now = llGetUnixTime();
    list    out = [];
    integer len = llGetListLength(cooldown_list);
    integer i;
    integer found = FALSE;
    for (i = 0; i < len; i += 2) {
        key     k = (key)llList2String(cooldown_list, i);
        integer t = llList2Integer(cooldown_list, i + 1);
        if (now - t < (integer)COOLDOWN) {
            out += [k, t];   // still active — keep it
            if (k == toucher) found = TRUE;
        }
        // expired entries are simply dropped
    }
    cooldown_list = out;
    return found;
}

// Record a fresh knock from this toucher.
setCooldown(key toucher) {
    integer now = llGetUnixTime();
    integer idx = llListFindList(cooldown_list, [(string)toucher]);
    if (idx != -1)
        cooldown_list = llListReplaceList(cooldown_list, [toucher, now], idx, idx + 1);
    else
        cooldown_list += [toucher, now];
}

updateHoverText() {
    string label = owner_name;
    if (label == "") label = "Doorbell";

    string status;
    vector color;
    if (owner_online) {
        status = "● Online";
        color  = <0.2, 1.0, 0.2>;   // green
    } else {
        status = "● Offline";
        color  = <1.0, 0.3, 0.3>;   // red
    }
    llSetText(label + "\n" + status, color, 1.0);
}

// ── Main ──────────────────────────────────────────────────────────────────────

default {
    state_entry() {
        // Random negative reply channel — can't be triggered from chat,
        // scripts only. Regenerated on each reset so collisions are vanishingly
        // unlikely across multiple doorbells in the same region.
        reply_channel = -1000000 - (integer)llFrand(1000000000.0);

        cooldown_list = [];

        if (reply_listen) llListenRemove(reply_listen);
        reply_listen = llListen(reply_channel, "", NULL_KEY, "");

        llOwnerSay("MMO Doorbell ready.");
        llOwnerSay("Hub trigger channel : " + (string)HUB_TRIG_CHANNEL
            + "  ← must match your Hub's /5 settrigchan value");
        llOwnerSay("HA reply channel    : " + (string)reply_channel
            + "  ← put this in your HA automation (or let it auto-route via reply_channel)");

        // Resolve owner name and initial online status asynchronously
        owner_name = llKey2Name(llGetOwner());   // fast if cached; fallback below
        name_req   = llRequestAgentData(llGetOwner(), DATA_NAME);
        online_req = llRequestAgentData(llGetOwner(), DATA_ONLINE);

        updateHoverText();
        llSetTimerEvent(POLL_INTERVAL);
    }

    dataserver(key req, string data) {
        if (req == name_req) {
            if (data != "" && data != "0") {
                owner_name = data;
                updateHoverText();
            }
        } else if (req == online_req) {
            owner_online = (data == "1");
            updateHoverText();
        }
    }

    timer() {
        // Re-poll online status to keep hover text fresh
        online_req = llRequestAgentData(llGetOwner(), DATA_ONLINE);
    }

    touch_start(integer n) {
        key    toucher      = llDetectedKey(0);
        string toucher_name = llDetectedName(0);

        // Ignore the owner touching their own doorbell
        if (toucher == llGetOwner()) {
            llInstantMessage(toucher, "This is your doorbell. Reply channel: "
                + (string)reply_channel);
            return;
        }

        // Cooldown — silently ignore repeat knocks within the window
        if (isOnCooldown(toucher)) {
            llInstantMessage(toucher, "You already knocked recently — please wait a moment.");
            return;
        }
        setCooldown(toucher);

        if (owner_online) {
            // ── Fast path: owner is in-world — IM them directly, no HA needed ──
            string owner_display = owner_name;
            if (owner_display == "") owner_display = "the owner";

            llInstantMessage(llGetOwner(),
                "🔔 Someone is at your door!\n"
                + toucher_name + "\n"
                + "secondlife:///app/agent/" + (string)toucher + "/about");

            llInstantMessage(toucher,
                owner_display + " is online — your knock has been sent directly!");

        } else {
            // ── Offline path: relay trigger to Hub → HA ───────────────────────
            // Hub validates that the object owner (us) is registered with it,
            // injects world/node_id/owner fields, then POSTs to HA.
            string payload = llList2Json(JSON_OBJECT, [
                "trigger",        "doorbell",
                "toucher_name",   toucher_name,
                "toucher_key",    (string)toucher,
                "reply_channel",  reply_channel
            ]);
            llRegionSay(HUB_TRIG_CHANNEL, payload);

            string display_name = owner_name;
            if (display_name == "") display_name = "The owner";
            llInstantMessage(toucher,
                display_name + " is currently offline — your visit has been noted!");
        }
    }

    listen(integer channel, string name, key id, string msg) {
        if (channel != reply_channel) return;

        // HA sends back JSON: {"to": "<toucher_key>", "message": "<text>"}
        // toucher_key was included in the original trigger payload, so HA can
        // route the reply to the right visitor without the doorbell tracking state.
        string to_key = llJsonGetValue(msg, ["to"]);
        string text   = llJsonGetValue(msg, ["message"]);

        if (to_key != JSON_INVALID && to_key != ""
                && text != JSON_INVALID && text != "") {
            llInstantMessage((key)to_key, text);
        }
    }

    changed(integer c) {
        if (c & (CHANGED_OWNER | CHANGED_INVENTORY)) {
            llResetScript();
        }
        if (c & (CHANGED_REGION | CHANGED_REGION_START | CHANGED_TELEPORT)) {
            // Re-establish listener after region change
            if (reply_listen) llListenRemove(reply_listen);
            reply_listen = llListen(reply_channel, "", NULL_KEY, "");
            online_req   = llRequestAgentData(llGetOwner(), DATA_ONLINE);
        }
    }

    on_rez(integer p) { llResetScript(); }
}

// ─────────────────────────────────────────────────────────────────────────────
// Example HA automation (add to your automations.yaml or via the UI)
//
// When the doorbell fires while the owner is offline, it sends a trigger with:
//   trigger       : "doorbell"
//   toucher_name  : display name of the visitor
//   toucher_key   : UUID of the visitor
//   reply_channel : the channel to region_say a reply back to
//   owner         : registered name of the doorbell owner (added by Hub)
//   node_id       : slug of the Hub's parcel (added by Hub)
//   world         : "secondlife" (added by Hub)
//
// The reply goes via mmo_bridge.region_say → Hub's llRegionSay → doorbell
// listen() → llInstantMessage to the visitor.
//
// automation:
//   - alias: "SL Doorbell — offline owner notification"
//     trigger:
//       - platform: event
//         event_type: mmo_bridge_inworld_trigger
//         event_data:
//           trigger: doorbell
//     action:
//       # 1. Send a push notification / IM / TTS / whatever to the owner in RL
//       - service: notify.mobile_app_your_phone
//         data:
//           title: "Someone at your SL door!"
//           message: "{{ trigger.event.data.toucher_name }} knocked."
//
//       # 2. Reply to the visitor in-world via the doorbell.
//         The doorbell expects JSON: {"to": "<toucher_key>", "message": "<text>"}
//         It uses "to" to IM the right visitor directly — no state needed on the
//         doorbell side, and multiple simultaneous visitors are handled correctly.
//
//         IMPORTANT: always specify node_id. Without it, region_say broadcasts to
//         ALL nodes (Hub + Stats Node etc.) and the doorbell hears the message
//         multiple times. node_id is injected by the Hub into every trigger payload
//         so we can route the reply back through the exact same node.
//       - service: mmo_bridge.region_say
//         data:
//           node_id: "{{ trigger.event.data.node_id }}"
//           channel: "{{ trigger.event.data.reply_channel | int }}"
//           message:
//             to: "{{ trigger.event.data.toucher_key }}"
//             message: "{{ trigger.event.data.owner }} is offline but has been notified. They'll get back to you soon!"
//         # message can be a YAML dict — region_say serialises it to JSON automatically.
// ─────────────────────────────────────────────────────────────────────────────
