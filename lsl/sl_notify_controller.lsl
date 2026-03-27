
string ha_url = "http://url-token";  // Replace with your HA webhook URL (including ?token=...)
string my_url;
list registered;                // [key, name, key, name, ...]

// Async online checks
integer pending_checks = 0;
list request_id_to_name;        // [request_id, name, ...]
list online_names;

// URL request management
key urlRequestId;
integer url_request_inflight = FALSE;
integer is_ready = FALSE;
float url_retry_s = 2.0;
float poll_interval = 60.0;

// Track registration request so we can detect success/failure
key regRequestKey;

string buildOnlineJson(list names) {
    string arr = llList2Json(JSON_ARRAY, names);
    return llList2Json(JSON_OBJECT, ["world", "secondlife", "online", arr]);
}

doRequestUrl() {
    if (url_request_inflight) return;
    if (my_url != "") {
        llReleaseURL(my_url);
        my_url = "";
    }
    urlRequestId = llRequestURL();
    url_request_inflight = TRUE;
}

scheduleUrlRetry() {
    llSetTimerEvent(url_retry_s);
    url_retry_s *= 2.0;
    if (url_retry_s > 60.0) url_retry_s = 60.0;
}

sendPresenceNow() {
    online_names = [];
    request_id_to_name = [];
    pending_checks = 0;

    integer len = llGetListLength(registered);
    for (integer i = 0; i < len; i += 2) {
        key av = (key)llList2String(registered, i);
        string nm = llList2String(registered, i + 1);
        key req = llRequestAgentData(av, DATA_ONLINE);
        request_id_to_name += [req, nm];
        ++pending_checks;
    }

    if (pending_checks == 0) {
        string json = buildOnlineJson(online_names);
        llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"], json);
    }
}

default {
    state_entry() {
        is_ready = FALSE;
        url_request_inflight = FALSE;
        url_retry_s = 2.0;
        regRequestKey = NULL_KEY;
        llOwnerSay("MMO Bridge: starting, requesting HTTP-in URL...");
        doRequestUrl();
    }

    http_request(key id, string method, string body) {
        // URL lifecycle events
        if (id == urlRequestId) {
            if (method == URL_REQUEST_DENIED) {
                url_request_inflight = FALSE;
                is_ready = FALSE;
                llOwnerSay("MMO Bridge: URL request denied, retrying in " + (string)((integer)url_retry_s) + "s...");
                scheduleUrlRetry();
                return;
            }
            if (method == URL_REQUEST_GRANTED) {
                url_request_inflight = FALSE;
                is_ready = TRUE;
                my_url = body;
                url_retry_s = 2.0;
                llOwnerSay("MMO Bridge: URL granted, registering with HA...");

                string payload = llList2Json(
                    JSON_OBJECT,
                    [
                        "world", "secondlife",
                        "adapter_url", my_url,
                        "capabilities", llList2Json(JSON_ARRAY, ["presence", "message"])
                    ]
                );
                regRequestKey = llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"], payload);

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
            for (integer i = 0; i < len; i += 2) {
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
            // Avatar not registered or not found
            llHTTPResponse(id, 404, "Avatar not registered");
            return;
        }

        llHTTPResponse(id, 200, "OK");
    }

    http_response(key req, integer status, list meta, string body) {
        if (req == regRequestKey) {
            if (status == 200) {
                llOwnerSay("MMO Bridge: registered with HA successfully. Sending initial presence report...");
                sendPresenceNow();
            } else {
                llOwnerSay("MMO Bridge: HA registration failed (HTTP " + (string)status + "). Check ha_url and token.");
            }
            regRequestKey = NULL_KEY;
        }
        // Ignore responses from presence push calls
    }

    touch_start(integer n) {
        key agent = llDetectedKey(0);
        string name = llDetectedName(0);
        integer idx = llListFindList(registered, [agent]);
        if (idx == -1) {
            registered += [agent, name];
            llOwnerSay(name + " registered (" + (string)(llGetListLength(registered) / 2) + " total).");
        } else {
            // Already registered — deregister on second touch
            registered = llDeleteSubList(registered, idx, idx + 1);
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
        if (data == "1") {
            online_names += [nm];
        }
        --pending_checks;
        if (pending_checks <= 0) {
            string json = buildOnlineJson(online_names);
            llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"], json);
        }
    }

    changed(integer c) {
        if (c & (CHANGED_OWNER | CHANGED_INVENTORY)) {
            llResetScript();
        }
        if (c & (CHANGED_REGION | CHANGED_REGION_START | CHANGED_TELEPORT)) {
            is_ready = FALSE;
            url_request_inflight = FALSE;
            if (my_url != "") {
                llReleaseURL(my_url);
                my_url = "";
            }
            url_retry_s = 2.0;
            llOwnerSay("MMO Bridge: region change detected, re-requesting URL...");
            doRequestUrl();
            llSetTimerEvent(url_retry_s);
        }
    }

    on_rez(integer p) {
        llResetScript();
    }
}
