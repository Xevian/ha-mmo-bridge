
// ── MMO Bridge — Hub (Notify Controller) ─────────────────────────────────────
//
// Capabilities: presence, message, display, region_say
//
// Rez on your home parcel and set the object's group. Group members touch to
// register — the Hub tracks online/offline presence and delivers IMs sent
// from Home Assistant automations. It also pushes at-home detection (who is
// physically on the parcel), live region/world data, and hover text lines
// that HA can update remotely.
//
// Setup: /5 seturl <webhook URL including ?token=...>
// ─────────────────────────────────────────────────────────────────────────────

// ── Protocol version — bump when making breaking payload changes ──────────────
integer PROTOCOL_VERSION = 1;
string  SCRIPT_VERSION   = "0.2.1";  // in-world version — matches manifest.json

// ── Linkset data keys ───────────────────────────────────────────────────────
string LD_HA_URL        = "mmo_ha_url";
string LD_REGISTERED    = "mmo_registered";
string LD_POLL_INTERVAL = "mmo_poll_interval";
string LD_CUSTOM_LINES  = "mmo_custom_lines";
string LD_OWNER         = "mmo_owner";
string LD_TRIG_CHANNEL  = "mmo_trig_channel";  // stored as string; absent = disabled
string LD_PASS          = "mmo_bridge";  // passphrase for protected linkset data

// ── Configuration ────────────────────────────────────────────────────────────
string  ha_url; // Set via: /5 seturl <url>
string  my_url;
list    registered;                        // [key, name, key, name, ...]
list    custom_lines;                      // [key, value, key, value, ...] pushed from HA
integer CMD_CHANNEL        = 5;            // Owner chat: /5 <command>
integer listen_handle;
integer hud_listen_handle;
integer trig_channel       = 0;            // 0 = trigger relay disabled
integer trig_listen_handle = 0;

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

    string parcel_name = llList2String(llGetParcelDetails(llGetPos(), [PARCEL_DETAILS_NAME]), 0);
    if (parcel_name == "") parcel_name = llGetRegionName();

    if (ha_url == "") {
        line1 = "MMO Hub";
        line2 = "No HA URL — use /5 seturl";
        color = <1.0, 0.3, 0.3>;  // red
    } else if (!is_ready) {
        line1 = "MMO Hub | " + parcel_name;
        line2 = "Connecting...";
        color = <1.0, 0.7, 0.0>;  // amber
    } else {
        line1 = "MMO Hub | " + parcel_name;
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
        "protocol",     PROTOCOL_VERSION,
        "world",        "secondlife",
        "node_id",      computeNodeId(),
        "adapter_url",  my_url,
        "capabilities", llList2Json(JSON_ARRAY, ["presence", "message", "display", "region_say"])
    ]);
    regRequestKey = llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"], payload);
    llOwnerSay("MMO Bridge: registering with HA...");
}

string buildOnlineJson(list names) {
    string arr    = llList2Json(JSON_ARRAY, names);
    string caps   = llList2Json(JSON_ARRAY, ["presence", "message", "display", "region_say"]);
    string athome = llList2Json(JSON_ARRAY, buildAtHome());
    list fields = [
        "protocol",     PROTOCOL_VERSION,
        "world",        "secondlife",
        "node_id",      computeNodeId(),
        "adapter_url",  my_url,
        "capabilities", caps,  // presence, message, display, region_say
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

string formatMessage(string msg) {
    string bar = "====================";
    return "\n" + bar + "\n== " + msg + "\n" + bar;
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
    llOwnerSay("  settrigchan    — enable/rotate trigger relay (random negative channel)");
    llOwnerSay("  settrigchan <n>— set trigger relay to specific negative channel");
    llOwnerSay("  hardreset      — clear ALL stored data and reset (use if moving to new HA)");
    llOwnerSay("  help           — show this message");
}

// ── Trigger relay ────────────────────────────────────────────────────────────

integer genTrigChannel() {
    // Negative channels can't be triggered from in-world chat — scripts only.
    // Avoid -1 (DEBUG_CHANNEL) and small values.
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

    // 2. Check object owner is a registered avatar
    list obj_details = llGetObjectDetails(sender_id, [OBJECT_OWNER]);
    if (!llGetListLength(obj_details)) return;
    key    sender_owner = (key)llList2String(obj_details, 0);
    string owner_name   = "";
    integer len = llGetListLength(registered);
    integer i;
    for (i = 0; i < len; i += 2) {
        if ((key)llList2String(registered, i) == sender_owner) {
            owner_name = llList2String(registered, i + 1);
            jump owner_ok;
        }
    }
    return;  // owner not in registered list — silently drop
    @owner_ok;

    // 3. Inject metadata and relay to HA
    string out = payload;
    out = llJsonSetValue(out, ["type"],    "inworld_trigger");
    out = llJsonSetValue(out, ["world"],   "secondlife");
    out = llJsonSetValue(out, ["node_id"], computeNodeId());
    out = llJsonSetValue(out, ["owner"],   owner_name);
    llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"], out);
}

// ── Main ─────────────────────────────────────────────────────────────────────

default {
    state_entry() {
        // Reset to base name immediately — gets updated with parcel name once ready.
        // Ensures a clean name when boxing up for distribution.
        llSetObjectName("MMO Hub");

        // ── Security checks — abort if not properly locked down ───────────────
        // Check both the object AND this script for next-owner Modify permission.
        // If either is set, anyone receiving a copy can add/read scripts and
        // extract your HA credentials. Set both to No-Modify before deploying.
        if ((llGetObjectPermMask(MASK_NEXT) | llGetInventoryPermMask(llGetScriptName(), MASK_NEXT)) & PERM_MODIFY) {
            llSetText("MMO Hub\n⚠ Security setup needed — check owner chat", <1.0, 0.5, 0.0>, 1.0);
            llOwnerSay("⚠ SECURITY (" + llGetScriptName() + "): this object or script "
                + "still has Modify permission for the next owner. Anyone receiving a "
                + "copy could add scripts to read your HA credentials. Set the OBJECT "
                + "and ALL scripts to No-Modify for Next Owner, then Reset Script.");
            return;
        }
        // Refuse to run on the default passphrase — change LD_PASS to something
        // unique in all four scripts before use. The default is public knowledge.
        if (LD_PASS == "mmo_bridge") {
            llSetText("MMO Hub\n⚠ Security setup needed — check owner chat", <1.0, 0.5, 0.0>, 1.0);
            llOwnerSay("⚠ SECURITY (" + llGetScriptName() + "): LD_PASS is still the "
                + "default 'mmo_bridge'. Change it to a unique passphrase in ALL four "
                + "scripts (Hub, Node, HUD, HUD Commands), then Reset Script.");
            return;
        }

        // Belt-and-braces ownership check — CHANGED_OWNER only fires for
        // in-world transfers. Inventory copies arrive already owned by the
        // recipient so we must detect the mismatch here and wipe stale data.
        string stored_owner = llLinksetDataRead(LD_OWNER);
        string current_owner = (string)llGetOwner();
        if (stored_owner != current_owner) {
            llLinksetDataReset();  // wipes protected + unprotected entries alike
            llLinksetDataWrite(LD_OWNER, current_owner);
        }

        is_ready             = FALSE;
        url_request_inflight = FALSE;
        url_retry_s          = 2.0;
        regRequestKey        = NULL_KEY;

        // Load HA URL from linkset data
        ha_url = llLinksetDataReadProtected(LD_HA_URL, LD_PASS);
        if (ha_url == "") {
            // Migrate unprotected entry written by scripts before v0.2.1
            ha_url = llLinksetDataRead(LD_HA_URL);
            if (ha_url != "") {
                llLinksetDataWriteProtected(LD_HA_URL, ha_url, LD_PASS);
                llLinksetDataDelete(LD_HA_URL);
            }
        }
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

        // Restore trigger relay channel (absent = disabled)
        trig_channel       = 0;
        trig_listen_handle = 0;
        string stored_trig = llLinksetDataRead(LD_TRIG_CHANNEL);
        if (stored_trig != "") {
            trig_channel = (integer)stored_trig;
            startTrigListener();
            llOwnerSay("MMO Bridge: trigger relay active on channel " + (string)trig_channel + ".");
        }

        // Start listening for owner commands
        if (listen_handle) llListenRemove(listen_handle);
        listen_handle = llListen(CMD_CHANNEL, "", llGetOwner(), "");

        // Start listening for HUD URL requests from registered avatars
        if (hud_listen_handle) llListenRemove(hud_listen_handle);
        hud_listen_handle = llListen(BRIDGE_HUD_CHANNEL, "", NULL_KEY, "");

        // Name the object after its parcel so it's identifiable in-world
        list   parcel      = llGetParcelDetails(llGetPos(), [PARCEL_DETAILS_NAME]);
        string parcel_name = llList2String(parcel, 0);
        if (parcel_name != "")
            llSetObjectName("MMO Hub - " + parcel_name);
        else
            llSetObjectName("MMO Hub");

        updateHoverText();
        llOwnerSay("MMO Bridge: starting, requesting HTTP-in URL...");
        doRequestUrl();
    }

    listen(integer channel, string name, key id, string msg) {
        // Trigger relay — from in-world scripted objects to HA
        if (trig_channel != 0 && channel == trig_channel) {
            handleTriggerRelay(id, msg);
            return;
        }

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
            llLinksetDataWriteProtected(LD_HA_URL, ha_url, LD_PASS);
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
            llOwnerSay("Version   : " + SCRIPT_VERSION + " (protocol v" + (string)PROTOCOL_VERSION + ")");
            llOwnerSay("HA URL    : " + ha_url);
            if (is_ready)
                llOwnerSay("Script URL: " + my_url);
            else
                llOwnerSay("Script URL: (not ready)");
            llOwnerSay("Poll every: " + (string)((integer)poll_interval) + "s");
            if (trig_channel != 0)
                llOwnerSay("Trig chan  : " + (string)trig_channel);
            else
                llOwnerSay("Trig chan  : disabled  (/5 settrigchan to enable)");
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

        } else if (msg == "settrigchan") {
            // No arg: generate/rotate random negative channel
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
            // Arg given: set specific channel (must be negative)
            integer new_chan = (integer)llStringTrim(llGetSubString(msg, 12, -1), STRING_TRIM);
            if (new_chan >= 0) {
                llOwnerSay("Trigger channel must be negative (e.g. /5 settrigchan -12345678).");
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
            llOwnerSay("MMO Bridge: clearing all stored data and resetting...");
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
                    llInstantMessage(av, formatMessage(msg));
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
                llInstantMessage(target, formatMessage(msg));
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
                // Warn if HA is running a newer protocol than this script knows about
                string ha_proto = llJsonGetValue(body, ["protocol"]);
                if (ha_proto != JSON_INVALID && (integer)ha_proto > PROTOCOL_VERSION)
                    llOwnerSay("MMO Bridge: HA is running protocol v" + ha_proto
                        + " (this script is v" + (string)PROTOCOL_VERSION
                        + "). Consider updating your scripts.");
                llOwnerSay("MMO Bridge: registered with HA. Sending initial presence report...");
                sendPresenceNow();
            } else if (status == 400) {
                string err = llJsonGetValue(body, ["error"]);
                if (err == "protocol_outdated")
                    llOwnerSay("MMO Bridge: script protocol v" + (string)PROTOCOL_VERSION
                        + " is too old for this HA installation. Please update your scripts.");
                else
                    llOwnerSay("MMO Bridge: HA registration failed (HTTP 400). Check URL and token.");
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
