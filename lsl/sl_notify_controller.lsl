
string ha_url = "http://url-token";
string my_url;
list registered;                // [key, name, key, name, ...]

// For async online checks
integer pending_checks = 0;
list request_id_to_name;        // [request_id, name, request_id, name, ...]
list online_names;              // names currently online

// URL request management
key urlRequestId;
integer url_request_inflight = FALSE;
integer is_ready = FALSE;       // true once URL granted and registered with HA
float url_retry_s = 2.0;        // exponential backoff start
float poll_interval = 60.0;     // seconds between presence polls

string buildOnlineJson(list names) {
    // { "online": [ ... ] }
    string arr = llList2Json(JSON_ARRAY, names);
    return llList2Json(JSON_OBJECT, ["world", "secondlife", "online", arr]);
}

// Helper to (re)request an HTTP-in URL with inflight protection
doRequestUrl() {
    if (url_request_inflight) return;
    // Release old URL if any (best effort)
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

default {
    state_entry() {
        // Initial URL request
        is_ready = FALSE;
        url_request_inflight = FALSE;
        url_retry_s = 2.0;
        doRequestUrl();
    }

    // Handle inbound HTTP from Home Assistant
    http_request(key id, string method, string body) {
        // Handle responses from llRequestURL
        if (id == urlRequestId) {
            if (method == URL_REQUEST_DENIED) {
                url_request_inflight = FALSE;
                is_ready = FALSE;
                // Backoff and retry
                scheduleUrlRetry();
                return;
            } else if (method == URL_REQUEST_GRANTED) {
                url_request_inflight = FALSE;
                is_ready = TRUE;
                my_url = body; // granted URL is in body
                url_retry_s = 2.0; // reset backoff

                // Register our URL with HA
                string payload = llList2Json(
                    JSON_OBJECT,
                    [
                        "world", "secondlife",
                        "adapter_url", my_url,
                        "capabilities", llList2Json(JSON_ARRAY, ["presence", "message"])
                    ]
                );
                llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"], payload);

                // Switch to presence polling interval
                llSetTimerEvent(poll_interval);
                return;
            }
        }

        // Expecting JSON: {"to":"Name", "message":"Text"}
        list pairs = llJson2List(body);
        integer idxTo = llListFindList(pairs, ["to"]);
        integer idxMsg = llListFindList(pairs, ["message"]);
        string toName = idxTo != -1 ? llList2String(pairs, idxTo + 1) : "";
        string msg = idxMsg != -1 ? llList2String(pairs, idxMsg + 1) : "";

        if (toName != "" && msg != "") {
            // Find avatar key by registered name
            key target = NULL_KEY;
            integer len = llGetListLength(registered);
            for (integer i = 0; i < len; i += 2) {
                if (llList2String(registered, i + 1) == toName) {
                    target = (key)llList2String(registered, i);
                    break;
                }
            }
            if (target) {
                llInstantMessage(target, msg);
                llHTTPResponse(id, 200, "OK");
                return;
            }
        }

        // Fallback: just acknowledge
        llHTTPResponse(id, 200, "OK");
    }

    // Outbound HTTP responses (from our llHTTPRequest to HA)
    http_response(key req, integer status, list meta, string body) {
        // No-op; could log if needed
    }

    // Tap object to register avatar
    touch_start(integer n) {
        key agent = llDetectedKey(0);
        string name = llDetectedName(0);
        if (llListFindList(registered, [agent]) == -1) {
            registered += [agent, name];
            llOwnerSay(name + " registered.");
        }
    }

    // Periodically query who is online and push to HA
    timer() {
        // If URL isn't ready yet, keep retrying with backoff cadence
        if (!is_ready) {
            doRequestUrl();
            return;
        }

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

        // If none to check, send empty list now
        if (pending_checks == 0) {
            string json = buildOnlineJson(online_names);
            llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"], json);
        }
    }

    // Receive results from llRequestAgentData
    dataserver(key req, string data) {
        integer idx = llListFindList(request_id_to_name, [req]);
        if (idx != -1) {
            string nm = llList2String(request_id_to_name, idx + 1);
            // Remove this pair
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
    }

    changed(integer c) {
        if (c & (CHANGED_OWNER | CHANGED_INVENTORY)) {
            llResetScript();
        }
        if (c & (CHANGED_REGION | CHANGED_REGION_START | CHANGED_TELEPORT)) {
            // Region changes invalidate URLs; re-request
            is_ready = FALSE;
            url_request_inflight = FALSE;
            if (my_url != "") {
                llReleaseURL(my_url);
                my_url = "";
            }
            url_retry_s = 2.0;
            doRequestUrl();
            // Use shorter retry cadence until granted
            llSetTimerEvent(url_retry_s);
        }
    }

    on_rez(integer p) {
        llResetScript();
    }
}
