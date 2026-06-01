// =============================================================================
//  MMO Bridge — Parcel Visitor Monitor  (plugin)
//
//  Drop this script into the Hub object alongside sl_notify_controller.lsl.
//  It polls llGetAgentList every POLL_INTERVAL seconds, resolves display
//  names, then hands the list to the Hub via link_message. The Hub injects
//  the webhook URL, auth token, node_id and world — this script needs none
//  of that.
//
//  Events fired in HA:
//    mmo_bridge_parcel_arrived  { world, node_id, key, name }
//    mmo_bridge_parcel_left     { world, node_id, key, name }
//
//  Sensor created in HA:
//    sensor.mmo_bridge_<world>_<node_id>_parcel_visitors
//      state      = number of avatars on the parcel
//      attributes = agents list (names)
//
//  To use as a standalone object (not inside the Hub), see the commented-out
//  version at the bottom of this file — that variant needs its own URL and
//  node_id set via linkset data.
// =============================================================================

// Must match the constant in sl_notify_controller.lsl
integer MMO_PLUGIN_MSG = 0x4D4D4F;

// How often to poll (seconds). Lower = more responsive but more HTTP traffic.
// Minimum recommended: 10s. Match or exceed the Hub's poll interval.
float POLL_INTERVAL = 15.0;

// ── State ─────────────────────────────────────────────────────────────────────

list g_pending_keys;  // UUIDs still waiting for display-name resolution
list g_resolved;      // completed entries as "uuid|display_name"
key  g_name_req;      // outstanding llRequestDisplayName request key

// ── Helpers ───────────────────────────────────────────────────────────────────

string jsonEscape(string s) {
    s = llDumpList2String(llParseStringKeepNulls(s, ["\\"], []), "\\\\");
    s = llDumpList2String(llParseStringKeepNulls(s, ["\""], []), "\\\"");
    return s;
}

sendToHub() {
    string agents_json = "[";
    integer i;
    integer n = llGetListLength(g_resolved);
    for (i = 0; i < n; i++) {
        string entry = llList2String(g_resolved, i);
        integer sep  = llSubStringIndex(entry, "|");
        string k     = llGetSubString(entry, 0, sep - 1);
        string nm    = jsonEscape(llGetSubString(entry, sep + 1, -1));
        if (i > 0) agents_json += ",";
        agents_json += "{\"key\":\"" + k + "\",\"name\":\"" + nm + "\"}";
    }
    agents_json += "]";

    string payload = "{\"type\":\"parcel_agents\",\"agents\":" + agents_json + "}";
    llMessageLinked(LINK_SET, MMO_PLUGIN_MSG, payload, "");
}

startPoll() {
    g_pending_keys = llGetAgentList(AGENT_LIST_PARCEL, []);
    g_resolved     = [];

    if (llGetListLength(g_pending_keys) == 0) {
        // Parcel is empty — send immediately so HA clears its list
        sendToHub();
        return;
    }

    // Resolve names one at a time via dataserver
    g_name_req = llRequestDisplayName(llList2Key(g_pending_keys, 0));
}

// ── Main ──────────────────────────────────────────────────────────────────────

default {
    state_entry() {
        llSetTimerEvent(POLL_INTERVAL);
        startPoll();
    }

    timer() {
        startPoll();
    }

    dataserver(key request_id, string data) {
        if (request_id != g_name_req) return;

        key    agent_key = llList2Key(g_pending_keys, 0);
        string name      = data;
        if (name == "") name = llKey2Name(agent_key);   // legacy name fallback
        if (name == "") name = (string)agent_key;       // UUID fallback

        g_resolved    += [(string)agent_key + "|" + name];
        g_pending_keys = llDeleteSubList(g_pending_keys, 0, 0);

        if (llGetListLength(g_pending_keys) > 0) {
            g_name_req = llRequestDisplayName(llList2Key(g_pending_keys, 0));
        } else {
            sendToHub();
        }
    }

    changed(integer change) {
        if (change & (CHANGED_OWNER | CHANGED_REGION | CHANGED_REGION_START))
            llResetScript();
    }
}
