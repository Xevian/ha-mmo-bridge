
// ── MMO Bridge — Avatar HUD ───────────────────────────────────────────────────
//
// Wear as a HUD or attachment. Sends avatar state (AFK, busy, location) to
// Home Assistant and lets you run labelled HA scripts from a touch menu.
//
// URL bootstrap (no manual typing needed):
//   1. Touch the bridge object — it sends the HA URL to this HUD automatically.
//   2. If you re-enter range of your bridge after an HA restart, URL auto-updates.
//   3. Manual fallback: /6 seturl <full webhook URL including ?token=...>
//
// Script menu:
//   Touch the HUD to open the script menu. Any HA script labelled "MMO Script"
//   appears for all avatars. Scripts labelled "MMO - <Your Name>" are private
//   to you. Commands are HMAC-signed so only this HUD can trigger them.
//
// Security: the HUD stores the trusted bridge object's UUID on first contact.
// URL updates from any other object are silently ignored.
// To trust a new bridge: /6 setbridge  (clears the stored key)
// ─────────────────────────────────────────────────────────────────────────────

// ── Linkset data keys ─────────────────────────────────────────────────────────
string LD_HA_URL        = "mmohud_ha_url";
string LD_BRIDGE_KEY    = "mmohud_bridge_key";  // trusted bridge object UUID
string LD_POLL_INTERVAL = "mmohud_poll_interval";
string LD_HMAC_SECRET   = "mmohud_hmac_secret"; // per-avatar HMAC secret from HA

// ── Shared channel — MUST match sl_notify_controller.lsl ─────────────────────
integer BRIDGE_HUD_CHANNEL = -1296912194;

// ── Configuration ─────────────────────────────────────────────────────────────
string  ha_url;
string  my_url;
string  trusted_bridge_key;     // only accept URL updates from this object
string  hmac_secret;            // HMAC-SHA256 secret for signing commands
integer CMD_CHANNEL     = 6;
integer listen_handle;
integer hud_listen_handle;
integer menu_channel;
integer menu_listen_handle;

// ── URL request management ────────────────────────────────────────────────────
key     urlRequestId;
integer url_request_inflight = FALSE;
integer is_ready             = FALSE;
float   url_retry_s          = 2.0;
float   poll_interval        = 15.0;  // shorter than bridge — we want quick AFK detection
key     regRequestKey;

// ── Script menu state ─────────────────────────────────────────────────────────
key     scriptListRequestKey;
key     commandRequestKey;
list    cached_scripts;       // [id, name, id, name, ...] from HA
integer SCRIPT_MENU_MAX = 11; // max script buttons (1 slot reserved for Cancel)

// ── Helpers ───────────────────────────────────────────────────────────────────

string buildPayload() {
    integer info   = llGetAgentInfo(llGetOwner());
    vector  pos    = llGetPos();
    list    parcel = llGetParcelDetails(pos, [PARCEL_DETAILS_NAME]);

    string afk  = JSON_FALSE;
    string busy = JSON_FALSE;
    if (info & AGENT_AWAY) afk  = JSON_TRUE;
    if (info & AGENT_BUSY) busy = JSON_TRUE;

    return llList2Json(JSON_OBJECT, [
        "world",        "secondlife",
        "capabilities", llList2Json(JSON_ARRAY, ["avatar_state"]),
        "avatar",       llKey2Name(llGetOwner()),
        "afk",          afk,
        "busy",         busy,
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
    regRequestKey = llHTTPRequest(ha_url,
        [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"], buildPayload());
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

// ── Script menu helpers ───────────────────────────────────────────────────────

requestScriptList() {
    if (ha_url == "" || !is_ready) {
        llOwnerSay("MMO HUD: not connected to HA yet.");
        return;
    }
    string payload = llList2Json(JSON_OBJECT, [
        "world",  "secondlife",
        "type",   "hud_list_scripts",
        "avatar", llKey2Name(llGetOwner())
    ]);
    scriptListRequestKey = llHTTPRequest(ha_url,
        [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"], payload);
}

showScriptMenu() {
    integer count = llGetListLength(cached_scripts) / 2;
    if (count == 0) {
        llOwnerSay("MMO HUD: no scripts available. In HA, label a script 'MMO Script' to add it here.");
        return;
    }

    list    buttons;
    integer i;
    integer limit = count;
    if (limit > SCRIPT_MENU_MAX) limit = SCRIPT_MENU_MAX;
    for (i = 0; i < limit; i++) {
        string btn = llList2String(cached_scripts, i * 2 + 1);
        if (llStringLength(btn) > 24) btn = llGetSubString(btn, 0, 23);
        buttons += [btn];
    }
    buttons += ["Cancel"];

    if (menu_listen_handle) llListenRemove(menu_listen_handle);
    menu_listen_handle = llListen(menu_channel, "", llGetOwner(), "");
    llDialog(llGetOwner(), "MMO Scripts — choose an action:", buttons, menu_channel);
}

sendCommand(string script_id) {
    if (hmac_secret == "") {
        llOwnerSay("MMO HUD: no command token yet — reconnecting to HA.");
        registerWithHA();
        return;
    }
    // Capture timestamp before the mandatory 10-second llHMAC delay.
    // HA allows a 60-second replay window so the 10s wait is well within budget.
    integer ts    = llGetUnixTime();
    string  canon = (string)ts + ".script." + script_id;
    llOwnerSay("MMO HUD: signing... (~10s)");
    string sig = llHMAC(hmac_secret, canon, "sha256");
    string payload = llList2Json(JSON_OBJECT, [
        "world",  "secondlife",
        "type",   "hud_command",
        "avatar", llKey2Name(llGetOwner()),
        "script", script_id,
        "ts",     ts,
        "sig",    sig
    ]);
    commandRequestKey = llHTTPRequest(ha_url,
        [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"], payload);
}

showHelp() {
    llOwnerSay("MMO HUD — commands on channel " + (string)CMD_CHANNEL
        + " (use /" + (string)CMD_CHANNEL + " <command>):");
    llOwnerSay("  seturl <url>    — manually set HA webhook URL (fallback)");
    llOwnerSay("  setpoll <sec>   — set state poll interval (min 5s, default 15s)");
    llOwnerSay("  setbridge       — clear trusted bridge key (re-pair next bridge)");
    llOwnerSay("  status          — show current status");
    llOwnerSay("  push            — force an immediate state push to HA");
    llOwnerSay("  help            — show this message");
    llOwnerSay("Touch the HUD to open the HA script menu.");
}

// ── Main ──────────────────────────────────────────────────────────────────────

default {
    state_entry() {
        // Guard: only run when actually worn — show a hint if rezzed in-world
        if (!llGetAttached()) {
            llSetText("MMO HUD\nWear me — do not rez in world", <1.0, 0.3, 0.3>, 1.0);
            return;
        }
        llSetText("", <0,0,0>, 0.0);  // clear any leftover text when worn

        is_ready             = FALSE;
        url_request_inflight = FALSE;
        url_retry_s          = 2.0;
        regRequestKey        = NULL_KEY;
        scriptListRequestKey = NULL_KEY;
        commandRequestKey    = NULL_KEY;
        cached_scripts       = [];

        // Stable per-session menu channel derived from owner UUID
        menu_channel = (integer)("0x" + llGetSubString((string)llGetOwner(), 0, 7))
                       | 0x80000000;
        if (menu_listen_handle) llListenRemove(menu_listen_handle);
        menu_listen_handle = 0;

        // Restore HA URL
        ha_url = llLinksetDataRead(LD_HA_URL);
        if (ha_url != "")
            llOwnerSay("MMO HUD: loaded HA URL from storage.");
        else
            llOwnerSay("MMO HUD: no HA URL — touch your bridge object to get one automatically.");

        // Restore trusted bridge key, HMAC secret, and poll interval
        trusted_bridge_key = llLinksetDataRead(LD_BRIDGE_KEY);
        hmac_secret        = llLinksetDataRead(LD_HMAC_SECRET);

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

    touch_start(integer total) {
        if (!is_ready || ha_url == "") {
            llOwnerSay("MMO HUD: not connected to HA yet.");
            return;
        }
        // Always fetch a fresh list on touch so newly-labelled scripts appear immediately
        llOwnerSay("MMO HUD: fetching scripts...");
        requestScriptList();
    }

    listen(integer channel, string name, key id, string msg) {
        // ── URL update from bridge ────────────────────────────────────────────
        if (channel == BRIDGE_HUD_CHANNEL) {
            string type = llJsonGetValue(msg, ["type"]);
            if (type != "url_update") return;

            string new_ha_url     = llJsonGetValue(msg, ["ha_url"]);

            if (new_ha_url == JSON_INVALID || new_ha_url == "") return;

            // Security: reject if sender doesn't match our trusted bridge
            // (trusted_bridge_key == "" means we haven't paired yet — accept and store)
            if (trusted_bridge_key != "" && (string)id != trusted_bridge_key) {
                llOwnerSay("MMO HUD: ignored URL update from untrusted object "
                    + (string)id + ". Use /6 setbridge to re-pair.");
                return;
            }

            // Only announce if the URL actually changed
            if (new_ha_url != ha_url)
                llOwnerSay("MMO HUD: HA URL updated from bridge (" + name + ").");

            ha_url             = new_ha_url;
            trusted_bridge_key = (string)id;
            llLinksetDataWrite(LD_HA_URL,     ha_url);
            llLinksetDataWrite(LD_BRIDGE_KEY, trusted_bridge_key);

            if (is_ready) {
                registerWithHA();
                sendStateNow();
            }
            return;
        }

        // ── Script menu dialog response ───────────────────────────────────────
        if (channel == menu_channel) {
            llListenRemove(menu_listen_handle);
            menu_listen_handle = 0;
            if (msg == "Cancel") return;

            // Match the button label back to a script id
            integer i;
            integer len = llGetListLength(cached_scripts);
            for (i = 0; i < len; i += 2) {
                string btn_label = llList2String(cached_scripts, i + 1);
                if (llStringLength(btn_label) > 24)
                    btn_label = llGetSubString(btn_label, 0, 23);
                if (btn_label == msg) {
                    sendCommand(llList2String(cached_scripts, i));
                    return;
                }
            }
            llOwnerSay("MMO HUD: unknown selection '" + msg + "'.");
            return;
        }

        // ── Owner chat commands ───────────────────────────────────────────────
        msg = llStringTrim(msg, STRING_TRIM);

        if (llGetSubString(msg, 0, 6) == "seturl ") {
            string new_url = llStringTrim(llGetSubString(msg, 7, -1), STRING_TRIM);
            if (new_url == "") {
                llOwnerSay("Usage: /6 seturl <full webhook URL including ?token=...>");
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
            string url_display    = ha_url;
            if (url_display == "") url_display = "(not set)";
            string bridge_display = trusted_bridge_key;
            if (bridge_display == "") bridge_display = "(none — will accept next bridge)";
            string secret_display = "(not set)";
            if (hmac_secret != "") secret_display = "(set)";
            llOwnerSay("HA URL      : " + url_display);
            llOwnerSay("Bridge key  : " + bridge_display);
            if (is_ready)
                llOwnerSay("Script URL  : " + my_url);
            else
                llOwnerSay("Script URL  : (not ready)");
            llOwnerSay("HMAC secret : " + secret_display);
            llOwnerSay("Scripts     : " + (string)(llGetListLength(cached_scripts) / 2) + " cached");
            llOwnerSay("Poll every  : " + (string)((integer)poll_interval) + "s");

        } else if (msg == "push") {
            llOwnerSay("MMO HUD: forcing state push to HA...");
            sendStateNow();

        } else if (msg == "help") {
            showHelp();

        } else {
            llOwnerSay("Unknown command. Type /6 help for available commands.");
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
        // ── Registration response — extract HMAC secret ───────────────────────
        if (req == regRequestKey) {
            regRequestKey = NULL_KEY;
            if (status != 200) {
                llOwnerSay("MMO HUD: HA rejected state push (HTTP " + (string)status
                    + "). Check URL — use /6 setbridge to re-pair.");
                return;
            }
            // HA returns {"status":"ok","hmac_secret":"..."} on avatar_state payloads
            string new_secret = llJsonGetValue(body, ["hmac_secret"]);
            if (new_secret != JSON_INVALID && new_secret != "" && new_secret != hmac_secret) {
                hmac_secret = new_secret;
                llLinksetDataWrite(LD_HMAC_SECRET, hmac_secret);
            }
            return;
        }

        // ── Script list response ──────────────────────────────────────────────
        if (req == scriptListRequestKey) {
            scriptListRequestKey = NULL_KEY;
            if (status != 200) {
                llOwnerSay("MMO HUD: failed to fetch script list (HTTP "
                    + (string)status + ").");
                return;
            }
            // Parse [{"id":"...","name":"..."}, ...] into cached_scripts flat list
            list raw = llJson2List(llJsonGetValue(body, ["scripts"]));
            cached_scripts = [];
            integer i;
            integer len = llGetListLength(raw);
            for (i = 0; i < len; i++) {
                string entry = llList2String(raw, i);
                string sid   = llJsonGetValue(entry, ["id"]);
                string sname = llJsonGetValue(entry, ["name"]);
                if (sid != JSON_INVALID && sid != "")
                    cached_scripts += [sid, sname];
            }
            if (llGetListLength(cached_scripts) == 0) {
                llOwnerSay("MMO HUD: no scripts available. In HA, label a script 'MMO Script' to add it here.");
                return;
            }
            showScriptMenu();
            return;
        }

        // ── Command response ──────────────────────────────────────────────────
        if (req == commandRequestKey) {
            commandRequestKey = NULL_KEY;
            if (status == 200) {
                llOwnerSay("MMO HUD: done.");
            } else if (status == 403) {
                llOwnerSay("MMO HUD: command rejected — try re-attaching the HUD.");
            } else {
                llOwnerSay("MMO HUD: command failed (HTTP " + (string)status + ").");
            }
            return;
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
            url_retry_s    = 2.0;
            cached_scripts = [];   // stale after region swap; refreshed on next touch
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
