// =============================================================================
//  MMO Bridge — Parcel Agent Monitor
//  Tracks every avatar currently on the parcel and reports to Home Assistant.
//
//  Events fired in HA:
//    mmo_bridge_parcel_arrived  {world, node_id, key, name}
//    mmo_bridge_parcel_left     {world, node_id, key, name}
//
//  Sensor created in HA:
//    sensor.mmo_bridge_<world>_<node_id>_parcel  (state = count, attrs = names)
//
//  Setup:
//    1. Drop this script into any object sitting on your parcel.
//    2. Set WEBHOOK_URL and NODE_ID via linkset data (see llLinksetDataWrite calls
//       in state_entry), or hard-code them below.
//    3. The object must remain rezzed and on the parcel to keep reporting.
//
//  Linkset data keys (set from another script or the Hub):
//    mmo_webhook_url  — full webhook URL including ?token=...
//    mmo_node_id      — node identifier (must match your Hub's node_id)
//    mmo_world        — optional, defaults to "secondlife"
//    mmo_poll_interval — optional poll interval in seconds, default 15
// =============================================================================

string LD_WEBHOOK       = "mmo_webhook_url";
string LD_NODE_ID       = "mmo_node_id";
string LD_WORLD         = "mmo_world";
string LD_POLL_INTERVAL = "mmo_poll_interval";

string g_webhook_url;
string g_node_id;
string g_world = "secondlife";
float  g_poll_interval = 15.0;

// Name-resolution state
list   g_pending_keys;   // UUIDs still waiting for display-name lookup
list   g_resolved;       // completed entries as "uuid|display_name"
key    g_name_req;       // current outstanding llRequestDisplayName key

// ── Helpers ──────────────────────────────────────────────────────────────────

string jsonEscape(string s) {
    // Escape backslash and double-quote for JSON string values
    s = llDumpList2String(llParseStringKeepNulls(s, ["\\"], []), "\\\\");
    s = llDumpList2String(llParseStringKeepNulls(s, ["\""], []), "\\\"");
    return s;
}

postToHA() {
    if (g_webhook_url == "") {
        llOwnerSay("[Parcel Monitor] No webhook URL set — skipping post.");
        return;
    }

    // Build agents JSON array from resolved list
    string agents_json = "[";
    integer i;
    integer n = llGetListLength(g_resolved);
    for (i = 0; i < n; i++) {
        string entry  = llList2String(g_resolved, i);
        integer sep   = llSubStringIndex(entry, "|");
        string  k     = llGetSubString(entry, 0, sep - 1);
        string  nm    = jsonEscape(llGetSubString(entry, sep + 1, -1));
        if (i > 0) agents_json += ",";
        agents_json += "{\"key\":\"" + k + "\",\"name\":\"" + nm + "\"}";
    }
    agents_json += "]";

    string body = "{"
        + "\"type\":\"parcel_agents\","
        + "\"world\":\"" + g_world + "\","
        + "\"node_id\":\"" + g_node_id + "\","
        + "\"agents\":" + agents_json
        + "}";

    llHTTPRequest(
        g_webhook_url,
        [HTTP_METHOD, "POST",
         HTTP_MIMETYPE, "application/json",
         HTTP_BODY_MAXLENGTH, 16384],
        body
    );
}

startPoll() {
    g_pending_keys = llGetAgentList(AGENT_LIST_PARCEL, []);
    g_resolved     = [];

    if (llGetListLength(g_pending_keys) == 0) {
        // Parcel is empty — post immediately so HA clears its list
        postToHA();
        return;
    }

    // Kick off async name resolution for the first agent
    g_name_req = llRequestDisplayName(llList2Key(g_pending_keys, 0));
}

loadConfig() {
    string url = llLinksetDataRead(LD_WEBHOOK);
    if (url != "") g_webhook_url = url;

    string nid = llLinksetDataRead(LD_NODE_ID);
    if (nid != "") g_node_id = nid;

    string w = llLinksetDataRead(LD_WORLD);
    if (w != "") g_world = w;

    string pi = llLinksetDataRead(LD_POLL_INTERVAL);
    if ((integer)pi > 0) g_poll_interval = (float)pi;
}

// ── Default state ─────────────────────────────────────────────────────────────

default {
    state_entry() {
        loadConfig();

        if (g_webhook_url == "" || g_node_id == "") {
            llOwnerSay(
                "[Parcel Monitor] Not configured. Set linkset data:\n"
                + "  " + LD_WEBHOOK + " = <your webhook URL>\n"
                + "  " + LD_NODE_ID + " = <node id>"
            );
            // Don't start polling until configured
            return;
        }

        llOwnerSay("[Parcel Monitor] Starting — polling every "
            + (string)((integer)g_poll_interval) + "s for world '"
            + g_world + "' node '" + g_node_id + "'");

        llSetTimerEvent(g_poll_interval);
        startPoll();  // immediate first poll
    }

    timer() {
        startPoll();
    }

    dataserver(key request_id, string data) {
        // Only handle our own outstanding name request
        if (request_id != g_name_req) return;

        key agent_key = llList2Key(g_pending_keys, 0);
        string name   = data;

        // Fallback: if display name is blank, try the legacy name; if still
        // blank, use the UUID string so HA always has something to show.
        if (name == "") {
            name = llKey2Name(agent_key);
        }
        if (name == "") {
            name = (string)agent_key;
        }

        g_resolved    += [(string)agent_key + "|" + name];
        g_pending_keys = llDeleteSubList(g_pending_keys, 0, 0);

        if (llGetListLength(g_pending_keys) > 0) {
            // More agents to resolve
            g_name_req = llRequestDisplayName(llList2Key(g_pending_keys, 0));
        } else {
            // All names resolved — post to HA
            postToHA();
        }
    }

    http_response(key request_id, integer status, list metadata, string body) {
        if (status != 200) {
            llOwnerSay("[Parcel Monitor] Webhook error " + (string)status
                + ": " + body);
        }
    }

    // Reload config if linkset data changes (e.g. Hub updates the URL)
    linkset_data(integer action, string name, string value) {
        if (name == LD_WEBHOOK || name == LD_NODE_ID
                || name == LD_WORLD || name == LD_POLL_INTERVAL) {
            llResetScript();
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
        if (change & CHANGED_REGION) llResetScript();
    }
}
