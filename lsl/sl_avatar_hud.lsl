
// ── MMO Bridge — Avatar HUD ───────────────────────────────────────────────────
//
// Wear as a HUD or attachment. Sends avatar state (AFK, busy, in-voice,
// location) to Home Assistant as attributes on the device tracker entity.
//
// URL bootstrap (no manual typing needed):
//   1. Touch the bridge object to register — it sends the HA URL to this HUD
//      automatically via a private channel.
//   2. If you come back into range of your bridge after an HA restart, the
//      bridge pushes the updated URL to the HUD automatically.
//   3. Manual fallback: /6 seturl <full webhook URL including ?token=...>
//
// Security: the HUD stores the trusted bridge object's UUID on first contact.
// URL updates from any other object's key are silently ignored — you won't
// accidentally pick up a stranger's HA URL just by walking near their bridge.
// To trust a new bridge: /5 setbridge  (clears the stored key)
// ─────────────────────────────────────────────────────────────────────────────

// ── Linkset data keys ─────────────────────────────────────────────────────────
string LD_HA_URL        = "mmohud_ha_url";
string LD_BRIDGE_KEY    = "mmohud_bridge_key";  // trusted bridge object UUID
string LD_POLL_INTERVAL = "mmohud_poll_interval";

// ── Shared channel — MUST match sl_notify_controller.lsl ─────────────────────
integer BRIDGE_HUD_CHANNEL = -1296912194;

// ── Configuration ─────────────────────────────────────────────────────────────
string  ha_url;
string  my_url;
string  trusted_bridge_key;     // only accept URL updates from this object
integer CMD_CHANNEL     = 6;  // 5 is reserved for bridge/stats objects
integer listen_handle;
integer hud_listen_handle;

// ── URL request management ────────────────────────────────────────────────────
key     urlRequestId;
integer url_request_inflight = FALSE;
integer is_ready             = FALSE;
float   url_retry_s          = 2.0;
float   poll_interval        = 15.0;  // shorter than bridge — we want quick AFK detection
key     regRequestKey;

// ── Helpers ───────────────────────────────────────────────────────────────────

string computeAvatarSlug() {
    string nm    = llToLower(llKey2Name(llGetOwner()));
    list   parts = llParseString2List(nm, [" "], []);
    return llDumpList2String(parts, "_");
}

string buildPayload() {
    integer info   = llGetAgentInfo(llGetOwner());
    vector  pos    = llGetPos();
    list    parcel = llGetParcelDetails(pos, [PARCEL_DETAILS_NAME]);

    return llList2Json(JSON_OBJECT, [
        "world",        "secondlife",
        "capabilities", llList2Json(JSON_ARRAY, ["avatar_state"]),
        "avatar",       llKey2Name(llGetOwner()),
        "afk",          (info & AGENT_AWAY)    ? JSON_TRUE : JSON_FALSE,
        "busy",         (info & AGENT_BUSY)     ? JSON_TRUE : JSON_FALSE,
        "in_voice",     (info & AGENT_IN_VOICE) ? JSON_TRUE : JSON_FALSE,
        "region",       llGetRegionName(),
        "parcel",       llList2String(parcel, 0),
        "pos",          (string)pos
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

registerWithHA() {
    if (!is_ready || ha_url == "") return;
    // Registration-only payload — no adapter_url, HUD is send-only
    string payload = buildPayload();
    regRequestKey = llHTTPRequest(ha_url,
        [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"], payload);
}

sendStateNow() {
    if (ha_url == "" || !is_ready) return;
    llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"],
        buildPayload());
}

requestUrlFromBridge() {
    if (trusted_bridge_key == "") return;
    llRegionSayTo((key)trusted_bridge_key, BRIDGE_HUD_CHANNEL, llList2Json(JSON_OBJECT, [
        "type",       "request_url",
        "avatar_key", (string)llGetOwner()
    ]));
}

showHelp() {
    llOwnerSay("MMO HUD — chat commands on channel " + (string)CMD_CHANNEL + " (use /" + (string)CMD_CHANNEL + " <command>):");
    llOwnerSay("  seturl <url>    — manually set HA webhook URL (fallback)");
    llOwnerSay("  setpoll <sec>   — set state poll interval (min 5s, default 15s)");
    llOwnerSay("  setbridge       — clear trusted bridge key (accept next bridge that responds)");
    llOwnerSay("  status          — show current status");
    llOwnerSay("  push            — force an immediate state push to HA");
    llOwnerSay("  help            — show this message");
}

// ── Main ──────────────────────────────────────────────────────────────────────

default {
    state_entry() {
        is_ready             = FALSE;
        url_request_inflight = FALSE;
        url_retry_s          = 2.0;
        regRequestKey        = NULL_KEY;

        // Restore HA URL
        ha_url = llLinksetDataRead(LD_HA_URL);
        if (ha_url != "")
            llOwnerSay("MMO HUD: loaded HA URL from storage.");
        else
            llOwnerSay("MMO HUD: no HA URL — touch your bridge object to get one automatically.");

        // Restore trusted bridge key
        trusted_bridge_key = llLinksetDataRead(LD_BRIDGE_KEY);

        // Restore poll interval
        string stored_poll = llLinksetDataRead(LD_POLL_INTERVAL);
        if (stored_poll != "") poll_interval = (float)stored_poll;

        // Listen for owner commands
        if (listen_handle) llListenRemove(listen_handle);
        listen_handle = llListen(CMD_CHANNEL, "", llGetOwner(), "");

        // Listen for URL updates from the bridge
        if (hud_listen_handle) llListenRemove(hud_listen_handle);
        hud_listen_handle = llListen(BRIDGE_HUD_CHANNEL, "", NULL_KEY, "");


        doRequestUrl();
    }

    listen(integer channel, string name, key id, string msg) {
        // ── URL update from bridge ────────────────────────────────────────────
        if (channel == BRIDGE_HUD_CHANNEL) {
            string type = llJsonGetValue(msg, ["type"]);
            if (type != "url_update") return;

            string new_ha_url    = llJsonGetValue(msg, ["ha_url"]);
            string new_bridge_key = llJsonGetValue(msg, ["bridge_key"]);

            if (new_ha_url == JSON_INVALID || new_ha_url == "") return;

            // Security: reject if sender doesn't match our trusted bridge
            // (trusted_bridge_key == "" means we haven't paired yet — accept and store)
            if (trusted_bridge_key != "" && (string)id != trusted_bridge_key) {
                llOwnerSay("MMO HUD: ignored URL update from untrusted object "
                    + (string)id + ". Use /5 setbridge to re-pair.");
                return;
            }

            ha_url             = new_ha_url;
            trusted_bridge_key = (string)id;
            llLinksetDataWrite(LD_HA_URL,     ha_url);
            llLinksetDataWrite(LD_BRIDGE_KEY, trusted_bridge_key);
            llOwnerSay("MMO HUD: HA URL updated from bridge (" + name + ").");
    
            if (is_ready) {
                registerWithHA();
                sendStateNow();
            }
            return;
        }

        // ── Owner chat commands ───────────────────────────────────────────────
        msg = llStringTrim(msg, STRING_TRIM);

        if (llGetSubString(msg, 0, 6) == "seturl ") {
            string new_url = llStringTrim(llGetSubString(msg, 7, -1), STRING_TRIM);
            if (new_url == "") {
                llOwnerSay("Usage: /5 seturl <full webhook URL including ?token=...>");
                return;
            }
            ha_url = new_url;
            llLinksetDataWrite(LD_HA_URL, ha_url);
            // Manual seturl — clear bridge key so we don't block future auto-updates
            trusted_bridge_key = "";
            llLinksetDataDelete(LD_BRIDGE_KEY);
            llOwnerSay("MMO HUD: HA URL saved (bridge pairing cleared).");
    
            if (is_ready) registerWithHA();

        } else if (llGetSubString(msg, 0, 7) == "setpoll ") {
            float secs = (float)llStringTrim(llGetSubString(msg, 8, -1), STRING_TRIM);
            if (secs < 5.0) {
                llOwnerSay("Poll interval must be at least 5 seconds.");
            } else {
                poll_interval = secs;
                llLinksetDataWrite(LD_POLL_INTERVAL, (string)poll_interval);
                llSetTimerEvent(poll_interval);
                llOwnerSay("Poll interval set to " + (string)((integer)poll_interval) + "s.");
            }

        } else if (msg == "setbridge") {
            trusted_bridge_key = "";
            llLinksetDataDelete(LD_BRIDGE_KEY);
            llOwnerSay("MMO HUD: bridge pairing cleared. Touch your bridge object to re-pair.");

        } else if (msg == "status") {
            llOwnerSay("── MMO HUD status ──");
            llOwnerSay("HA URL      : " + (ha_url != "" ? ha_url : "(not set)"));
            llOwnerSay("Bridge key  : " + (trusted_bridge_key != "" ? trusted_bridge_key : "(none — will accept next bridge)"));
            if (is_ready)
                llOwnerSay("Script URL  : " + my_url);
            else
                llOwnerSay("Script URL  : (not ready)");
            llOwnerSay("Poll every  : " + (string)((integer)poll_interval) + "s");

        } else if (msg == "push") {
            llOwnerSay("MMO HUD: forcing state push to HA...");
            sendStateNow();

        } else if (msg == "help") {
            showHelp();

        } else {
            llOwnerSay("Unknown command. Type /5 help for available commands.");
        }
    }

    http_request(key id, string method, string body) {
        if (id == urlRequestId) {
            if (method == URL_REQUEST_DENIED) {
                url_request_inflight = FALSE;
                is_ready             = FALSE;
                llOwnerSay("MMO HUD: URL request denied, retrying in "
                    + (string)((integer)url_retry_s) + "s...");
        
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
                // Ask bridge for latest URL in case it changed while we were offline
                requestUrlFromBridge();
                return;
            }
        }
        // HUD is send-only — no commands expected from HA
        llHTTPResponse(id, 200, "OK");
    }

    http_response(key req, integer status, list meta, string body) {
        if (req == regRequestKey) {
            if (status == 200) {
                llOwnerSay("MMO HUD: connected to HA.");
            } else {
                llOwnerSay("MMO HUD: HA rejected state push (HTTP " + (string)status
                    + "). Check URL — use /5 setbridge to re-pair.");
            }
            regRequestKey = NULL_KEY;
        }
    }

    timer() {
        if (!is_ready) {
            doRequestUrl();
            return;
        }
        sendStateNow();
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
    
            doRequestUrl();
            llSetTimerEvent(url_retry_s);
            // Once we have a URL again, we'll ask the bridge for an update
            // via requestUrlFromBridge() called in URL_REQUEST_GRANTED
        }
    }

    attach(key av) {
        if (av != NULL_KEY) {
            // Re-attached — full reset
            llResetScript();
        }
    }

    on_rez(integer p) {
        llResetScript();
    }
}
