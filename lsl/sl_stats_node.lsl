
// ── MMO Bridge — Stats Node ───────────────────────────────────────────────────
//
// Capabilities: world_data, display, region_say
//
// Drop this script into any in-world object to push region metrics (FPS, time
// dilation, agent counts, etc.) to Home Assistant as a graphable sensor node.
// It does NOT manage avatar registration or deliver IMs — use
// sl_notify_controller.lsl for that.
//
// Setup: /4 seturl <webhook URL including ?token=...>
// ─────────────────────────────────────────────────────────────────────────────

// ── Protocol version — bump when making breaking payload changes ──────────────
integer PROTOCOL_VERSION = 1;
string  SCRIPT_VERSION   = "0.2.1";  // in-world version — matches manifest.json

// ── Linkset data keys ─────────────────────────────────────────────────────────
string LD_HA_URL        = "mmostats_ha_url";
string LD_POLL_INTERVAL = "mmostats_poll_interval";
string LD_CUSTOM_LINES  = "mmostats_custom_lines";
string LD_OWNER         = "mmostats_owner";
string LD_TRIG_CHANNEL  = "mmostats_trig_channel";  // stored as string; absent = disabled
string LD_PASS          = "mmo_bridge";  // passphrase for protected linkset data

// ── Configuration ─────────────────────────────────────────────────────────────
string  ha_url;
string  my_url;
list    custom_lines;             // [key, value, key, value, ...] pushed from HA
integer CMD_CHANNEL        = 4;
integer listen_handle;
integer trig_channel       = 0;            // 0 = trigger relay disabled
integer trig_listen_handle = 0;

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

    string parcel_name = llList2String(llGetParcelDetails(llGetPos(), [PARCEL_DETAILS_NAME]), 0);
    if (parcel_name == "") parcel_name = llGetRegionName();

    if (ha_url == "") {
        line1 = "MMO Node";
        line2 = "No HA URL — use /5 seturl";
        color = <1.0, 0.3, 0.3>;  // red
    } else if (!is_ready) {
        line1 = "MMO Node | " + parcel_name;
        line2 = "Connecting...";
        color = <1.0, 0.7, 0.0>;  // amber
    } else {
        line1 = "MMO Node | " + parcel_name;
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
        "protocol",     PROTOCOL_VERSION,
        "world",        "secondlife",
        "node_id",      computeNodeId(),
        "adapter_url",  my_url,
        "capabilities", llList2Json(JSON_ARRAY, ["world_data", "display", "region_say"]),
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
        "protocol",     PROTOCOL_VERSION,
        "world",        "secondlife",
        "node_id",      computeNodeId(),
        "adapter_url",  my_url,
        "capabilities", llList2Json(JSON_ARRAY, ["world_data", "display", "region_say"])
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
    llOwnerSay("MMO Stats Node — chat commands on channel /" + (string)CMD_CHANNEL + ":");
    llOwnerSay("  seturl <url>   — save HA webhook URL and re-register");
    llOwnerSay("  setpoll <sec>  — set stats poll interval (min 10s, default 60s)");
    llOwnerSay("  status         — show current status");
    llOwnerSay("  push           — force an immediate stats push to HA");
    llOwnerSay("  settrigchan    — enable/rotate trigger relay (random negative channel)");
    llOwnerSay("  settrigchan <n>— set trigger relay to specific negative channel");
    llOwnerSay("  hardreset      — clear ALL stored data and reset (use if moving to new HA)");
    llOwnerSay("  help           — show this message");
}

// ── Trigger relay ─────────────────────────────────────────────────────────────

integer genTrigChannel() {
    return -100000 - (integer)llFrand(2000000000.0);
}

startTrigListener() {
    if (trig_listen_handle) llListenRemove(trig_listen_handle);
    trig_listen_handle = llListen(trig_channel, "", NULL_KEY, "");
}

handleTriggerRelay(key sender_id, string payload) {
    // 1. Validate JSON — trigger field must be present and non-empty
    string trigger_val = llJsonGetValue(payload, ["trigger"]);
    if (trigger_val == JSON_INVALID || trigger_val == "") return;

    // 2. Node only accepts from objects owned by the Node owner
    list obj_details = llGetObjectDetails(sender_id, [OBJECT_OWNER]);
    if (!llGetListLength(obj_details)) return;
    if ((key)llList2String(obj_details, 0) != llGetOwner()) return;

    // 3. Inject metadata and relay to HA
    string out = payload;
    out = llJsonSetValue(out, ["type"],    "inworld_trigger");
    out = llJsonSetValue(out, ["world"],   "secondlife");
    out = llJsonSetValue(out, ["node_id"], computeNodeId());
    out = llJsonSetValue(out, ["owner"],   llKey2Name(llGetOwner()));
    llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"], out);
}

// ── Main ──────────────────────────────────────────────────────────────────────

default {
    state_entry() {
        // Reset to base name immediately — gets updated with parcel name once ready.
        // Ensures a clean name when boxing up for distribution.
        llSetObjectName("MMO Node");

        string stored_owner  = llLinksetDataRead(LD_OWNER);
        string current_owner = (string)llGetOwner();
        if (stored_owner != current_owner) {
            llLinksetDataReset();  // wipes protected + unprotected entries alike
            llLinksetDataWrite(LD_OWNER, current_owner);
        }

        is_ready             = FALSE;
        url_request_inflight = FALSE;
        url_retry_s          = 2.0;
        regRequestKey        = NULL_KEY;

        // Load HA URL
        ha_url = llLinksetDataReadProtected(LD_HA_URL, LD_PASS);
        if (ha_url == "") {
            // Migrate unprotected entry written by scripts before v0.2.1
            ha_url = llLinksetDataRead(LD_HA_URL);
            if (ha_url != "") {
                llLinksetDataWriteProtected(LD_HA_URL, ha_url, LD_PASS);
                llLinksetDataDelete(LD_HA_URL);
            }
        }
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

        // Restore trigger relay channel (absent = disabled)
        trig_channel       = 0;
        trig_listen_handle = 0;
        string stored_trig = llLinksetDataRead(LD_TRIG_CHANNEL);
        if (stored_trig != "") {
            trig_channel = (integer)stored_trig;
            startTrigListener();
            llOwnerSay("MMO Stats: trigger relay active on channel " + (string)trig_channel + ".");
        }

        // Start listening for owner commands
        if (listen_handle) llListenRemove(listen_handle);
        listen_handle = llListen(CMD_CHANNEL, "", llGetOwner(), "");

        // Name the object after its parcel so it's identifiable in-world
        list   parcel      = llGetParcelDetails(llGetPos(), [PARCEL_DETAILS_NAME]);
        string parcel_name = llList2String(parcel, 0);
        if (parcel_name != "")
            llSetObjectName("MMO Node - " + parcel_name);
        else
            llSetObjectName("MMO Node");

        updateHoverText();
        llOwnerSay("MMO Stats: starting, requesting HTTP-in URL...");
        doRequestUrl();
    }

    listen(integer channel, string name, key id, string msg) {
        // Trigger relay — from in-world scripted objects to HA
        if (trig_channel != 0 && channel == trig_channel) {
            handleTriggerRelay(id, msg);
            return;
        }

        msg = llStringTrim(msg, STRING_TRIM);

        if (llGetSubString(msg, 0, 6) == "seturl ") {
            string new_url = llStringTrim(llGetSubString(msg, 7, -1), STRING_TRIM);
            if (new_url == "") {
                llOwnerSay("Usage: /4 seturl <full webhook URL including ?token=...>");
                return;
            }
            ha_url = new_url;
            llLinksetDataWriteProtected(LD_HA_URL, ha_url, LD_PASS);
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
            llOwnerSay("Version   : " + SCRIPT_VERSION + " (protocol v" + (string)PROTOCOL_VERSION + ")");
            llOwnerSay("HA URL    : " + ha_url);
            if (is_ready)
                llOwnerSay("Script URL: " + my_url);
            else
                llOwnerSay("Script URL: (not ready)");
            llOwnerSay("Node ID   : " + computeNodeId());
            llOwnerSay("Poll every: " + (string)((integer)poll_interval) + "s");
            if (trig_channel != 0)
                llOwnerSay("Trig chan  : " + (string)trig_channel);
            else
                llOwnerSay("Trig chan  : disabled  (/4 settrigchan to enable)");

        } else if (msg == "push") {
            llOwnerSay("MMO Stats: forcing stats push to HA...");
            sendStatsNow();

        } else if (msg == "settrigchan") {
            integer old_chan = trig_channel;
            trig_channel = genTrigChannel();
            llLinksetDataWrite(LD_TRIG_CHANNEL, (string)trig_channel);
            startTrigListener();
            if (old_chan != 0)
                llOwnerSay("Trigger channel rotated from " + (string)old_chan
                    + " to " + (string)trig_channel + ". Update your trigger objects.");
            else
                llOwnerSay("Trigger relay enabled. Channel: " + (string)trig_channel
                    + ". Add this to your trigger objects.");

        } else if (llGetSubString(msg, 0, 11) == "settrigchan ") {
            integer new_chan = (integer)llStringTrim(llGetSubString(msg, 12, -1), STRING_TRIM);
            if (new_chan >= 0) {
                llOwnerSay("Trigger channel must be negative (e.g. /4 settrigchan -12345678).");
                return;
            }
            integer was_disabled = (trig_channel == 0);
            trig_channel = new_chan;
            llLinksetDataWrite(LD_TRIG_CHANNEL, (string)trig_channel);
            startTrigListener();
            if (was_disabled)
                llOwnerSay("Trigger relay enabled on channel " + (string)trig_channel + ".");
            else
                llOwnerSay("Trigger channel updated to " + (string)trig_channel + ".");

        } else if (msg == "help") {
            showHelp();

        } else if (msg == "hardreset") {
            llOwnerSay("MMO Stats: clearing all stored data and resetting...");
            llLinksetDataReset();
            llResetScript();

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
            } else if (cmd == "region_say") {
                integer chan = (integer)llJsonGetValue(body, ["channel"]);
                string  rmsg = llJsonGetValue(body, ["message"]);
                if (rmsg != JSON_INVALID && rmsg != "") {
                    // llRegionSay does not work on channel 0 — use llSay instead
                    if (chan == 0)
                        llSay(0, rmsg);
                    else
                        llRegionSay(chan, rmsg);
                }
            } else if (cmd == "set_text") {
                string ckey = llJsonGetValue(body, ["key"]);
                string cval = llJsonGetValue(body, ["value"]);
                // Guard against oversized values (HA caps these too, belt-and-braces)
                if (llStringLength(ckey) > 64)  ckey = llGetSubString(ckey, 0, 63);
                if (llStringLength(cval) > 256) cval = llGetSubString(cval, 0, 255);
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
                string ha_proto = llJsonGetValue(body, ["protocol"]);
                if (ha_proto != JSON_INVALID && (integer)ha_proto > PROTOCOL_VERSION)
                    llOwnerSay("MMO Stats: HA is running protocol v" + ha_proto
                        + " (this script is v" + (string)PROTOCOL_VERSION
                        + "). Consider updating your scripts.");
                llOwnerSay("MMO Stats: registered with HA. Sending initial stats...");
                sendStatsNow();
            } else if (status == 400) {
                string err = llJsonGetValue(body, ["error"]);
                if (err == "protocol_outdated")
                    llOwnerSay("MMO Stats: script protocol v" + (string)PROTOCOL_VERSION
                        + " is too old for this HA installation. Please update your scripts.");
                else
                    llOwnerSay("MMO Stats: HA registration failed (HTTP 400). Check URL and token.");
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
        if (c & CHANGED_OWNER) {
            llLinksetDataReset();
            llResetScript();
        }
        if (c & CHANGED_INVENTORY) {
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
            // Re-apply name in case object was moved to a different parcel
            string parcel_name = llList2String(llGetParcelDetails(llGetPos(), [PARCEL_DETAILS_NAME]), 0);
            if (parcel_name != "")
                llSetObjectName("MMO Node - " + parcel_name);
            else
                llSetObjectName("MMO Node");
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
