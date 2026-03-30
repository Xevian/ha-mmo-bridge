
// ── Linkset data keys ───────────────────────────────────────────────────────
string LD_HA_URL        = "mmo_ha_url";
string LD_REGISTERED    = "mmo_registered";
string LD_POLL_INTERVAL = "mmo_poll_interval";
string LD_CUSTOM_LINES  = "mmo_custom_lines";

// ── Configuration ────────────────────────────────────────────────────────────
string  ha_url; // Set via: /5 seturl <url>
string  my_url;
list    registered;                        // [key, name, key, name, ...]
list    custom_lines;                      // [key, value, key, value, ...] pushed from HA
integer CMD_CHANNEL        = 5;            // Owner chat: /5 <command>
integer listen_handle;
integer hud_listen_handle;

// Shared private channel for bridge↔HUD URL bootstrap.
// Must match the constant in sl_avatar_hud.lsl.
integer BRIDGE_HUD_CHANNEL = -1296912194;

// ── Async online checks ───────────────────────────────────────────────────────
integer pending_checks   = 0;
list    request_id_to_name;
list    online_names;
integer last_online_count = 0;

// ── URL request management ───────────────────────────────────────────────────
key     urlRequestId;
integer url_request_inflight = FALSE;
integer is_ready             = FALSE;
float   url_retry_s          = 2.0;
float   poll_interval        = 60.0;
key     regRequestKey;
integer region_restarted     = FALSE;

// ── Helpers ──────────────────────────────────────────────────────────────────

string computeNodeId() {
    vector pos    = llGetPos();
    list   parcel = llGetParcelDetails(pos, [PARCEL_DETAILS_NAME]);
    string nm     = llToLower(llList2String(parcel, 0));
    list   parts  = llParseString2List(nm, [" "], []);
    return llDumpList2String(parts, "_");
}

list buildAtHome() {
    list parcel_agents = llGetAgentList(AGENT_LIST_PARCEL, []);
    list at_home = [];
    integer len = llGetListLength(registered);
    integer i;
    for (i = 0; i < len; i += 2) {
        key    av = (key)llList2String(registered, i);
        string nm = llList2String(registered, i + 1);
        if (llListFindList(parcel_agents, [av]) != -1) {
            at_home += [nm];
        }
    }
    return at_home;
}

updateHoverText() {
    integer reg_count = llGetListLength(registered) / 2;
    string  line1;
    string  line2;
    vector  color;

    if (ha_url == "") {
        line1 = "MMO Bridge";
        line2 = "No HA URL — use /5 seturl";
        color = <1.0, 0.3, 0.3>;  // red
    } else if (!is_ready) {
        line1 = "MMO Bridge | " + llGetRegionName();
        line2 = "Connecting...";
        color = <1.0, 0.7, 0.0>;  // amber
    } else {
        line1 = "MMO Bridge | " + llGetRegionName();
        line2 = (string)last_online_count + " online / " + (string)reg_count + " registered";
        color = <0.3, 1.0, 0.3>;  // green
    }

    string text = line1 + "\n" + line2;

    // Append custom lines pushed from HA (e.g. "Plex: 1 Watcher")
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

saveRegistered() {
    llLinksetDataWrite(LD_REGISTERED, llList2Json(JSON_ARRAY, registered));
}

registerWithHA() {
    if (!is_ready || ha_url == "") return;
    string payload = llList2Json(JSON_OBJECT, [
        "world",        "secondlife",
        "node_id",      computeNodeId(),
        "adapter_url",  my_url,
        "capabilities", llList2Json(JSON_ARRAY, ["presence", "message", "display"])
    ]);
    regRequestKey = llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"], payload);
    llOwnerSay("MMO Bridge: registering with HA...");
}

string buildOnlineJson(list names) {
    string arr    = llList2Json(JSON_ARRAY, names);
    string caps   = llList2Json(JSON_ARRAY, ["presence", "message", "display"]);
    string athome = llList2Json(JSON_ARRAY, buildAtHome());
    list fields = [
        "world",        "secondlife",
        "node_id",      computeNodeId(),
        "adapter_url",  my_url,
        "capabilities", caps,
        "world_data",   buildWorldData(),
        "online",       arr,
        "at_home",      athome
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

sendPresenceNow() {
    if (ha_url == "") return;
    online_names       = [];
    request_id_to_name = [];
    pending_checks     = 0;

    integer len = llGetListLength(registered);
    integer i;
    for (i = 0; i < len; i += 2) {
        key    av  = (key)llList2String(registered, i);
        string nm  = llList2String(registered, i + 1);
        key    req = llRequestAgentData(av, DATA_ONLINE);
        request_id_to_name += [req, nm];
        ++pending_checks;
    }

    if (pending_checks == 0) {
        last_online_count = 0;
        llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"],
            buildOnlineJson(online_names));
        updateHoverText();
    }
}

sendUrlToHud(key av) {
    if (ha_url == "") return;
    llRegionSayTo(av, BRIDGE_HUD_CHANNEL, llList2Json(JSON_OBJECT, [
        "type",       "url_update",
        "ha_url",     ha_url,
        "bridge_key", (string)llGetKey()
    ]));
}

notifyHuds() {
    integer len = llGetListLength(registered);
    integer i;
    for (i = 0; i < len; i += 2) {
        sendUrlToHud((key)llList2String(registered, i));
    }
}

showHelp() {
    llOwnerSay("MMO Bridge — chat commands on channel " + (string)CMD_CHANNEL + ":");
    llOwnerSay("  seturl <url>   — save HA webhook URL and re-register");
    llOwnerSay("  setpoll <sec>  — set presence poll interval (min 10s, default 60s)");
    llOwnerSay("  status         — show current status");
    llOwnerSay("  list           — list all registered avatars");
    llOwnerSay("  remove <name>  — remove a specific avatar by name");
    llOwnerSay("  push           — force an immediate presence push to HA");
    llOwnerSay("  clearusers     — remove all registered avatars");
    llOwnerSay("  help           — show this message");
}

// ── Main ─────────────────────────────────────────────────────────────────────

default {
    state_entry() {
        is_ready             = FALSE;
        url_request_inflight = FALSE;
        url_retry_s          = 2.0;
        regRequestKey        = NULL_KEY;

        // Load HA URL from linkset data
        ha_url = llLinksetDataRead(LD_HA_URL);
        if (ha_url != "") {
            llOwnerSay("MMO Bridge: loaded HA URL from linkset data.");
        } else {
            llOwnerSay("MMO Bridge: no HA URL configured. Use /5 seturl <url> to set it.");
        }

        // Load poll interval from linkset data
        string stored_poll = llLinksetDataRead(LD_POLL_INTERVAL);
        if (stored_poll != "") poll_interval = (float)stored_poll;

        // Restore registered avatars from linkset data
        string stored_reg = llLinksetDataRead(LD_REGISTERED);
        if (stored_reg != "") {
            registered = llJson2List(stored_reg);
            llOwnerSay("MMO Bridge: restored " + (string)(llGetListLength(registered) / 2) + " registered avatar(s).");
        } else {
            registered = [];
        }

        // Restore custom hover text lines from linkset data
        string stored_lines = llLinksetDataRead(LD_CUSTOM_LINES);
        if (stored_lines != "")
            custom_lines = llJson2List(stored_lines);
        else
            custom_lines = [];

        // Start listening for owner commands
        if (listen_handle) llListenRemove(listen_handle);
        listen_handle = llListen(CMD_CHANNEL, "", llGetOwner(), "");

        // Start listening for HUD URL requests from registered avatars
        if (hud_listen_handle) llListenRemove(hud_listen_handle);
        hud_listen_handle = llListen(BRIDGE_HUD_CHANNEL, "", NULL_KEY, "");

        updateHoverText();
        llOwnerSay("MMO Bridge: starting, requesting HTTP-in URL...");
        doRequestUrl();
    }

    listen(integer channel, string name, key id, string msg) {
        // HUD requesting a URL update — respond only if avatar is registered
        if (channel == BRIDGE_HUD_CHANNEL) {
            string type   = llJsonGetValue(msg, ["type"]);
            string av_str = llJsonGetValue(msg, ["avatar_key"]);
            if (type == "request_url" && av_str != JSON_INVALID) {
                if (llListFindList(registered, [av_str]) != -1) {
                    sendUrlToHud((key)av_str);
                }
            }
            return;
        }

        msg = llStringTrim(msg, STRING_TRIM);

        if (llGetSubString(msg, 0, 6) == "seturl ") {
            string new_url = llStringTrim(llGetSubString(msg, 7, -1), STRING_TRIM);
            if (new_url == "") {
                llOwnerSay("Usage: /5 seturl <full webhook URL including ?token=...>");
                return;
            }
            ha_url = new_url;
            llLinksetDataWrite(LD_HA_URL, ha_url);
            llOwnerSay("MMO Bridge: HA URL saved.");
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
            llOwnerSay("── MMO Bridge status ──");
            llOwnerSay("HA URL    : " + ha_url);
            if (is_ready)
                llOwnerSay("Script URL: " + my_url);
            else
                llOwnerSay("Script URL: (not ready)");
            llOwnerSay("Poll every: " + (string)((integer)poll_interval) + "s");
            integer reg_count = llGetListLength(registered) / 2;
            llOwnerSay("Registered: " + (string)reg_count + " avatar(s)");
            integer si;
            for (si = 0; si < llGetListLength(registered); si += 2) {
                llOwnerSay("  - " + llList2String(registered, si + 1));
            }

        } else if (msg == "list") {
            integer len = llGetListLength(registered);
            if (len == 0) {
                llOwnerSay("No avatars registered.");
                return;
            }
            integer i;
            for (i = 0; i < len; i += 2) {
                llOwnerSay("  " + llList2String(registered, i + 1)
                    + "  (" + llList2String(registered, i) + ")");
            }

        } else if (llGetSubString(msg, 0, 6) == "remove ") {
            string target_name = llStringTrim(llGetSubString(msg, 7, -1), STRING_TRIM);
            integer found = -1;
            integer len = llGetListLength(registered);
            integer i;
            for (i = 0; i < len; i += 2) {
                if (llList2String(registered, i + 1) == target_name) {
                    found = i;
                    jump removedone;
                }
            }
            @removedone;
            if (found != -1) {
                registered = llDeleteSubList(registered, found, found + 1);
                saveRegistered();
                updateHoverText();
                llOwnerSay(target_name + " removed (" + (string)(llGetListLength(registered) / 2) + " remaining).");
            } else {
                llOwnerSay("No avatar named '" + target_name + "' is registered.");
            }

        } else if (msg == "push") {
            llOwnerSay("MMO Bridge: forcing presence push to HA...");
            sendPresenceNow();

        } else if (msg == "clearusers") {
            registered = [];
            llLinksetDataDelete(LD_REGISTERED);
            updateHoverText();
            llOwnerSay("MMO Bridge: all registered avatars cleared.");

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
                llOwnerSay("MMO Bridge: URL request denied, retrying in " + (string)((integer)url_retry_s) + "s...");
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
                // Push updated URL to all registered HUDs (HA restart changes the URL)
                notifyHuds();
                return;
            }
        }

        // Commands from HA
        string cmd = llJsonGetValue(body, ["command"]);
        if (cmd != JSON_INVALID && cmd != "") {
            if (cmd == "refresh") {
                sendPresenceNow();
            } else if (cmd == "set_text") {
                string ckey = llJsonGetValue(body, ["key"]);
                string cval = llJsonGetValue(body, ["value"]);
                if (ckey != JSON_INVALID && ckey != "") {
                    integer idx = llListFindList(custom_lines, [ckey]);
                    if (cval == "" || cval == JSON_INVALID) {
                        // Empty value removes the line
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

        // Inbound message from HA: {"to":"Name","message":"Text"}
        //                      or {"to":"all","message":"Text"}  (broadcast)
        string toName = llJsonGetValue(body, ["to"]);
        string msg    = llJsonGetValue(body, ["message"]);

        if (toName != JSON_INVALID && toName != "" && msg != JSON_INVALID && msg != "") {
            // Broadcast to all registered avatars
            if (toName == "all") {
                integer len = llGetListLength(registered);
                integer i;
                for (i = 0; i < len; i += 2) {
                    key av = (key)llList2String(registered, i);
                    llInstantMessage(av, msg);
                }
                llHTTPResponse(id, 200, "OK");
                return;
            }
            // Targeted delivery
            key target = NULL_KEY;
            integer len = llGetListLength(registered);
            integer i;
            for (i = 0; i < len; i += 2) {
                if (llList2String(registered, i + 1) == toName) {
                    target = (key)llList2String(registered, i);
                    jump found;
                }
            }
            @found;
            if (target != NULL_KEY) {
                llInstantMessage(target, msg);
                llHTTPResponse(id, 200, "OK");
                return;
            }
            llHTTPResponse(id, 404, "Avatar not registered");
            return;
        }

        llHTTPResponse(id, 200, "OK");
    }

    http_response(key req, integer status, list meta, string body) {
        if (req == regRequestKey) {
            if (status == 200) {
                llOwnerSay("MMO Bridge: registered with HA. Sending initial presence report...");
                sendPresenceNow();
            } else {
                llOwnerSay("MMO Bridge: HA registration failed (HTTP " + (string)status + "). Check URL and token.");
            }
            regRequestKey = NULL_KEY;
        }
    }

    touch_start(integer n) {
        key    agent = llDetectedKey(0);
        string name  = llDetectedName(0);

        // Only allow group members with the group active (set the object's group accordingly)
        if (!llSameGroup(agent)) {
            llInstantMessage(agent, "Sorry, registration is restricted to group members. Activate the group tag and try again.");
            return;
        }

        if (llListFindList(registered, [(string)agent]) == -1) {
            registered += [(string)agent, name];
            saveRegistered();
            updateHoverText();
            llOwnerSay(name + " registered (" + (string)(llGetListLength(registered) / 2) + " total).");
            // Send HA URL to this avatar's HUD immediately
            sendUrlToHud(agent);
        } else {
            llInstantMessage(agent, "You are already registered — refreshing your HUD URL. Ask the owner to remove you if needed.");
            // Re-send URL in case their HUD restarted and lost it
            sendUrlToHud(agent);
        }
    }

    timer() {
        if (!is_ready) {
            doRequestUrl();
            return;
        }
        sendPresenceNow();
    }

    dataserver(key req, string data) {
        integer idx = llListFindList(request_id_to_name, [req]);
        if (idx == -1) return;

        string nm = llList2String(request_id_to_name, idx + 1);
        request_id_to_name = llDeleteSubList(request_id_to_name, idx, idx + 1);
        if (data == "1") online_names += [nm];
        --pending_checks;
        if (pending_checks <= 0) {
            last_online_count = llGetListLength(online_names);
            llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"],
                buildOnlineJson(online_names));
            updateHoverText();
        }
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
            llOwnerSay("MMO Bridge: region change, re-requesting URL...");
            updateHoverText();
            doRequestUrl();
            llSetTimerEvent(url_retry_s);
        }
    }

    on_rez(integer p) {
        llResetScript();
    }
}
