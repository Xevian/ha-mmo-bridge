
// ── Linkset data keys ───────────────────────────────────────────────────────
string LD_HA_URL     = "mmo_ha_url";
string LD_REGISTERED = "mmo_registered";

// ── Configuration ────────────────────────────────────────────────────────────
string  ha_url; // Set via: /5 seturl <url>
string  my_url;
list    registered;                        // [key, name, key, name, ...]
integer CMD_CHANNEL  = 5;                  // Owner chat: /5 <command>
integer listen_handle;

// ── Async online checks ───────────────────────────────────────────────────────
integer pending_checks = 0;
list    request_id_to_name;
list    online_names;

// ── URL request management ───────────────────────────────────────────────────
key     urlRequestId;
integer url_request_inflight = FALSE;
integer is_ready             = FALSE;
float   url_retry_s          = 2.0;
float   poll_interval        = 60.0;
key     regRequestKey;

// ── Helpers ──────────────────────────────────────────────────────────────────

saveRegistered() {
    llLinksetDataWrite(LD_REGISTERED, llList2Json(JSON_ARRAY, registered));
}

registerWithHA() {
    if (!is_ready || ha_url == "") return;
    string payload = llList2Json(JSON_OBJECT, [
        "world",        "secondlife",
        "adapter_url",  my_url,
        "capabilities", llList2Json(JSON_ARRAY, ["presence", "message"])
    ]);
    regRequestKey = llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"], payload);
    llOwnerSay("MMO Bridge: registering with HA...");
}

string buildOnlineJson(list names) {
    string arr  = llList2Json(JSON_ARRAY, names);
    string caps = llList2Json(JSON_ARRAY, ["presence", "message"]);
    return llList2Json(JSON_OBJECT, [
        "world",        "secondlife",
        "adapter_url",  my_url,
        "capabilities", caps,
        "online",       arr
    ]);
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
        llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"],
            buildOnlineJson(online_names));
    }
}

showHelp() {
    llOwnerSay("MMO Bridge — chat commands on channel " + (string)CMD_CHANNEL + ":");
    llOwnerSay("  seturl <url>  — save HA webhook URL to linkset data and re-register");
    llOwnerSay("  status        — show HA URL, script URL, and registered avatar count");
    llOwnerSay("  list          — list all registered avatars");
    llOwnerSay("  clearusers    — remove all registered avatars");
    llOwnerSay("  help          — show this message");
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

        // Restore registered avatars from linkset data
        string stored_reg = llLinksetDataRead(LD_REGISTERED);
        if (stored_reg != "") {
            registered = llJson2List(stored_reg);
            llOwnerSay("MMO Bridge: restored " + (string)(llGetListLength(registered) / 2) + " registered avatar(s).");
        } else {
            registered = [];
        }

        // Start listening for owner commands
        if (listen_handle) llListenRemove(listen_handle);
        listen_handle = llListen(CMD_CHANNEL, "", llGetOwner(), "");

        llOwnerSay("MMO Bridge: starting, requesting HTTP-in URL...");
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
            llOwnerSay("MMO Bridge: HA URL saved.");
            registerWithHA();

        } else if (msg == "status") {
            llOwnerSay("── MMO Bridge status ──");
            llOwnerSay("HA URL    : " + ha_url);
            if (is_ready)
                llOwnerSay("Script URL: " + my_url);
            else
                llOwnerSay("Script URL: (not ready)");
            llOwnerSay("Registered: " + (string)(llGetListLength(registered) / 2) + " avatar(s)");

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

        } else if (msg == "clearusers") {
            registered = [];
            llLinksetDataDelete(LD_REGISTERED);
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
                scheduleUrlRetry();
                return;
            }
            if (method == URL_REQUEST_GRANTED) {
                url_request_inflight = FALSE;
                is_ready             = TRUE;
                my_url               = body;
                url_retry_s          = 2.0;
                registerWithHA();
                llSetTimerEvent(poll_interval);
                return;
            }
        }

        // Inbound message from HA: {"to":"Name","message":"Text"}
        string toName = llJsonGetValue(body, ["to"]);
        string msg    = llJsonGetValue(body, ["message"]);

        if (toName != JSON_INVALID && toName != "" && msg != JSON_INVALID && msg != "") {
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
        integer idx  = llListFindList(registered, [agent]);
        if (idx == -1) {
            registered += [agent, name];
            saveRegistered();
            llOwnerSay(name + " registered (" + (string)(llGetListLength(registered) / 2) + " total).");
        } else {
            registered = llDeleteSubList(registered, idx, idx + 1);
            saveRegistered();
            llOwnerSay(name + " deregistered (" + (string)(llGetListLength(registered) / 2) + " remaining).");
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
            llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"],
                buildOnlineJson(online_names));
        }
    }

    changed(integer c) {
        if (c & (CHANGED_OWNER | CHANGED_INVENTORY)) {
            llResetScript();
        }
        if (c & (CHANGED_REGION | CHANGED_REGION_START | CHANGED_TELEPORT)) {
            is_ready             = FALSE;
            url_request_inflight = FALSE;
            if (my_url != "") {
                llReleaseURL(my_url);
                my_url = "";
            }
            url_retry_s = 2.0;
            llOwnerSay("MMO Bridge: region change, re-requesting URL...");
            doRequestUrl();
            llSetTimerEvent(url_retry_s);
        }
    }

    on_rez(integer p) {
        llResetScript();
    }
}
