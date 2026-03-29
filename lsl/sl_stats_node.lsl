
// ── MMO Bridge — Stats Node ───────────────────────────────────────────────────
//
// Capabilities: world_data, display
//
// Drop this script into any in-world object to push region metrics (FPS, time
// dilation, agent counts, etc.) to Home Assistant as a graphable sensor node.
// It does NOT manage avatar registration or deliver IMs — use
// sl_notify_controller.lsl for that.
//
// Setup: /5 seturl <webhook URL including ?token=...>
// ─────────────────────────────────────────────────────────────────────────────

// ── Linkset data keys ─────────────────────────────────────────────────────────
string LD_HA_URL        = "mmostats_ha_url";
string LD_POLL_INTERVAL = "mmostats_poll_interval";
string LD_CUSTOM_LINES  = "mmostats_custom_lines";

// ── Configuration ─────────────────────────────────────────────────────────────
string  ha_url;
string  my_url;
list    custom_lines;             // [key, value, key, value, ...] pushed from HA
integer CMD_CHANNEL  = 5;
integer listen_handle;

// ── URL request management ────────────────────────────────────────────────────
key     urlRequestId;
integer url_request_inflight = FALSE;
integer is_ready             = FALSE;
float   url_retry_s          = 2.0;
float   poll_interval        = 60.0;
key     regRequestKey;
integer region_restarted     = FALSE;

// ── Helpers ───────────────────────────────────────────────────────────────────

string computeNodeId() {
    vector pos    = llGetPos();
    list   parcel = llGetParcelDetails(pos, [PARCEL_DETAILS_NAME]);
    string nm     = llToLower(llList2String(parcel, 0));
    list   parts  = llParseString2List(nm, [" "], []);
    return llDumpList2String(parts, "_");
}

updateHoverText() {
    string line1;
    string line2;
    vector color;

    if (ha_url == "") {
        line1 = "MMO Stats";
        line2 = "No HA URL — use /5 seturl";
        color = <1.0, 0.3, 0.3>;  // red
    } else if (!is_ready) {
        line1 = "MMO Stats | " + llGetRegionName();
        line2 = "Connecting...";
        color = <1.0, 0.7, 0.0>;  // amber
    } else {
        line1 = "MMO Stats | " + llGetRegionName();
        line2 = "FPS: " + (string)((integer)llGetRegionFPS())
              + "  TD: " + llGetSubString((string)llGetRegionTimeDilation(), 0, 3);
        color = <0.3, 1.0, 0.3>;  // green
    }

    string text = line1 + "\n" + line2;

    integer i;
    for (i = 0; i < llGetListLength(custom_lines); i += 2) {
        string val = llList2String(custom_lines, i + 1);
        if (val != "") text += "\n" + val;
    }

    llSetText(text, color, 1.0);
}

string buildWorldData() {
    vector pos           = llGetPos();
    list   parcel        = llGetParcelDetails(pos, [PARCEL_DETAILS_NAME]);
    list   parcel_agents = llGetAgentList(AGENT_LIST_PARCEL, []);
    list   region_agents = llGetAgentList(AGENT_LIST_REGION, []);
    return llList2Json(JSON_OBJECT, [
        "region",           llGetRegionName(),
        "parcel",           llList2String(parcel, 0),
        "sim_channel",      llGetEnv("sim_channel"),
        "sim_version",      llGetEnv("sim_version"),
        "agents_on_parcel", llGetListLength(parcel_agents),
        "agents_in_region", llGetListLength(region_agents),
        "time_dilation",    (string)llGetRegionTimeDilation(),
        "region_fps",       (string)llGetRegionFPS(),
        "sim_start_time",   llGetEnv("sim_start_time")
    ]);
}

string buildPayload() {
    list fields = [
        "world",        "secondlife",
        "node_id",      computeNodeId(),
        "adapter_url",  my_url,
        "capabilities", llList2Json(JSON_ARRAY, ["world_data", "display"]),
        "world_data",   buildWorldData()
    ];
    if (region_restarted) {
        fields += ["region_restart", JSON_TRUE];
        region_restarted = FALSE;
    }
    return llList2Json(JSON_OBJECT, fields);
}

doRequestUrl() {
    if (url_request_inflight) return;
    if (my_url != "") {
        llReleaseURL(my_url);
        my_url = "";
    }
    urlRequestId         = llRequestURL();
    url_request_inflight = TRUE;
}

scheduleUrlRetry() {
    llSetTimerEvent(url_retry_s);
    url_retry_s *= 2.0;
    if (url_retry_s > 60.0) url_retry_s = 60.0;
}

registerWithHA() {
    if (!is_ready || ha_url == "") return;
    string payload = llList2Json(JSON_OBJECT, [
        "world",        "secondlife",
        "node_id",      computeNodeId(),
        "adapter_url",  my_url,
        "capabilities", llList2Json(JSON_ARRAY, ["world_data", "display"])
    ]);
    regRequestKey = llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"], payload);
    llOwnerSay("MMO Stats: registering with HA...");
}

sendStatsNow() {
    if (ha_url == "") return;
    llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"], buildPayload());
    updateHoverText();
}

showHelp() {
    llOwnerSay("MMO Stats — chat commands on channel " + (string)CMD_CHANNEL + ":");
    llOwnerSay("  seturl <url>   — save HA webhook URL and re-register");
    llOwnerSay("  setpoll <sec>  — set stats poll interval (min 10s, default 60s)");
    llOwnerSay("  status         — show current status");
    llOwnerSay("  help           — show this message");
}

// ── Main ──────────────────────────────────────────────────────────────────────

default {
    state_entry() {
        is_ready             = FALSE;
        url_request_inflight = FALSE;
        url_retry_s          = 2.0;
        regRequestKey        = NULL_KEY;

        // Load HA URL
        ha_url = llLinksetDataRead(LD_HA_URL);
        if (ha_url != "")
            llOwnerSay("MMO Stats: loaded HA URL from linkset data.");
        else
            llOwnerSay("MMO Stats: no HA URL configured. Use /5 seturl <url> to set it.");

        // Load poll interval
        string stored_poll = llLinksetDataRead(LD_POLL_INTERVAL);
        if (stored_poll != "") poll_interval = (float)stored_poll;

        // Restore custom hover text lines
        string stored_lines = llLinksetDataRead(LD_CUSTOM_LINES);
        if (stored_lines != "")
            custom_lines = llJson2List(stored_lines);
        else
            custom_lines = [];

        // Start listening for owner commands
        if (listen_handle) llListenRemove(listen_handle);
        listen_handle = llListen(CMD_CHANNEL, "", llGetOwner(), "");

        updateHoverText();
        llOwnerSay("MMO Stats: starting, requesting HTTP-in URL...");
        doRequestUrl();
    }

    listen(integer channel, string name, key id, string msg) {
        msg = llStringTrim(msg, STRING_TRIM);

        if (llGetSubString(msg, 0, 6) == "seturl ") {
            string new_url = llStringTrim(llGetSubString(msg, 7, -1), STRING_TRIM);
            if (new_url == "") {
                llOwnerSay("Usage: /5 seturl <full webhook URL including ?token=...>");
                return;
            }
            ha_url = new_url;
            llLinksetDataWrite(LD_HA_URL, ha_url);
            llOwnerSay("MMO Stats: HA URL saved.");
            updateHoverText();
            registerWithHA();

        } else if (llGetSubString(msg, 0, 7) == "setpoll ") {
            float secs = (float)llStringTrim(llGetSubString(msg, 8, -1), STRING_TRIM);
            if (secs < 10.0) {
                llOwnerSay("Poll interval must be at least 10 seconds.");
            } else {
                poll_interval = secs;
                llLinksetDataWrite(LD_POLL_INTERVAL, (string)poll_interval);
                llSetTimerEvent(poll_interval);
                llOwnerSay("Poll interval set to " + (string)((integer)poll_interval) + "s.");
            }

        } else if (msg == "status") {
            llOwnerSay("── MMO Stats status ──");
            llOwnerSay("HA URL    : " + ha_url);
            if (is_ready)
                llOwnerSay("Script URL: " + my_url);
            else
                llOwnerSay("Script URL: (not ready)");
            llOwnerSay("Node ID   : " + computeNodeId());
            llOwnerSay("Poll every: " + (string)((integer)poll_interval) + "s");

        } else if (msg == "help") {
            showHelp();

        } else {
            llOwnerSay("Unknown command. Type /5 help for available commands.");
        }
    }

    http_request(key id, string method, string body) {
        // URL lifecycle events
        if (id == urlRequestId) {
            if (method == URL_REQUEST_DENIED) {
                url_request_inflight = FALSE;
                is_ready             = FALSE;
                llOwnerSay("MMO Stats: URL request denied, retrying in " + (string)((integer)url_retry_s) + "s...");
                updateHoverText();
                scheduleUrlRetry();
                return;
            }
            if (method == URL_REQUEST_GRANTED) {
                url_request_inflight = FALSE;
                is_ready             = TRUE;
                my_url               = body;
                url_retry_s          = 2.0;
                updateHoverText();
                registerWithHA();
                llSetTimerEvent(poll_interval);
                return;
            }
        }

        // Commands from HA
        string cmd = llJsonGetValue(body, ["command"]);
        if (cmd != JSON_INVALID && cmd != "") {
            if (cmd == "refresh") {
                sendStatsNow();
            } else if (cmd == "set_text") {
                string ckey = llJsonGetValue(body, ["key"]);
                string cval = llJsonGetValue(body, ["value"]);
                if (ckey != JSON_INVALID && ckey != "") {
                    integer idx = llListFindList(custom_lines, [ckey]);
                    if (cval == "" || cval == JSON_INVALID) {
                        if (idx != -1)
                            custom_lines = llDeleteSubList(custom_lines, idx, idx + 1);
                    } else if (idx == -1) {
                        custom_lines += [ckey, cval];
                    } else {
                        custom_lines = llListReplaceList(custom_lines, [ckey, cval], idx, idx + 1);
                    }
                    llLinksetDataWrite(LD_CUSTOM_LINES, llList2Json(JSON_ARRAY, custom_lines));
                    updateHoverText();
                }
            }
            llHTTPResponse(id, 200, "OK");
            return;
        }

        llHTTPResponse(id, 200, "OK");
    }

    http_response(key req, integer status, list meta, string body) {
        if (req == regRequestKey) {
            if (status == 200) {
                llOwnerSay("MMO Stats: registered with HA. Sending initial stats...");
                sendStatsNow();
            } else {
                llOwnerSay("MMO Stats: HA registration failed (HTTP " + (string)status + "). Check URL and token.");
            }
            regRequestKey = NULL_KEY;
        }
    }

    timer() {
        if (!is_ready) {
            doRequestUrl();
            return;
        }
        sendStatsNow();
    }

    changed(integer c) {
        if (c & (CHANGED_OWNER | CHANGED_INVENTORY)) {
            llResetScript();
        }
        if (c & (CHANGED_REGION | CHANGED_REGION_START | CHANGED_TELEPORT)) {
            if (c & CHANGED_REGION_START) region_restarted = TRUE;
            is_ready             = FALSE;
            url_request_inflight = FALSE;
            if (my_url != "") {
                llReleaseURL(my_url);
                my_url = "";
            }
            url_retry_s = 2.0;
            llOwnerSay("MMO Stats: region change, re-requesting URL...");
            updateHoverText();
            doRequestUrl();
            llSetTimerEvent(url_retry_s);
        }
    }

    on_rez(integer p) {
        llResetScript();
    }
}
