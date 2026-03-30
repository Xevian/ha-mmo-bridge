
// ── MMO Bridge — Avatar HUD (main) ───────────────────────────────────────────
//
// Wear as a HUD or attachment. Sends avatar state (AFK, busy, location) to
// Home Assistant as attributes on the device tracker entity.
//
// A companion script (sl_hud_commands.lsl) in the same linkset handles the
// touch menu and HMAC-signed script commands. Keeping them separate means
// llHMAC signing only blocks the command script — this script stays fully
// responsive for state polling and bridge communication.
//
// URL bootstrap (no manual typing needed):
//   1. Touch the bridge object — it sends the HA URL to this HUD automatically.
//   2. If you re-enter range of your bridge after an HA restart, URL auto-updates.
//   3. Manual fallback: /6 seturl <full webhook URL including ?token=...>
//
// Security: the HUD stores the trusted bridge object's UUID on first contact.
// URL updates from any other object are silently ignored.
// To trust a new bridge: /6 setbridge  (clears the stored key)
// ─────────────────────────────────────────────────────────────────────────────

// ── Protocol version — bump when making breaking payload changes ──────────────
integer PROTOCOL_VERSION = 1;

// ── Linkset data keys ─────────────────────────────────────────────────────────
string LD_HA_URL        = "mmohud_ha_url";
string LD_BRIDGE_KEY    = "mmohud_bridge_key";   // trusted bridge object UUID
string LD_POLL_INTERVAL = "mmohud_poll_interval";
string LD_HMAC_SECRET   = "mmohud_hmac_secret";  // per-avatar secret from HA

// ── Shared channel — MUST match sl_notify_controller.lsl ─────────────────────
integer BRIDGE_HUD_CHANNEL = -1296912194;

// ── Linked-message protocol — MUST match sl_hud_commands.lsl ─────────────────
integer MSG_OPEN_MENU = 1001;  // → command script: open the script menu

// ── Configuration ─────────────────────────────────────────────────────────────
string  ha_url;
string  my_url;
string  trusted_bridge_key;
integer CMD_CHANNEL = 6;
integer listen_handle;
integer hud_listen_handle;

// ── URL request management ────────────────────────────────────────────────────
key     urlRequestId;
integer url_request_inflight = FALSE;
integer is_ready             = FALSE;
float   url_retry_s          = 2.0;
float   poll_interval        = 15.0;
key     regRequestKey;

// ── Change tracking — only push when something meaningful shifts ───────────────
// Position is included in payloads but too noisy to use as a change trigger.
string  last_afk    = "";
string  last_busy   = "";
string  last_region = "";
string  last_parcel = "";

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
        "protocol",     PROTOCOL_VERSION,
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

integer stateChanged() {
    // Returns TRUE if any tracked field differs from the last push.
    integer info   = llGetAgentInfo(llGetOwner());
    vector  pos    = llGetPos();
    list    parcel = llGetParcelDetails(pos, [PARCEL_DETAILS_NAME]);

    string afk    = JSON_FALSE;
    string busy   = JSON_FALSE;
    if (info & AGENT_AWAY) afk  = JSON_TRUE;
    if (info & AGENT_BUSY) busy = JSON_TRUE;

    string region = llGetRegionName();
    string parcel_name = llList2String(parcel, 0);

    return (afk    != last_afk
         || busy   != last_busy
         || region != last_region
         || parcel_name != last_parcel);
}

updateLastState() {
    integer info   = llGetAgentInfo(llGetOwner());
    vector  pos    = llGetPos();
    list    parcel = llGetParcelDetails(pos, [PARCEL_DETAILS_NAME]);

    if (info & AGENT_AWAY) last_afk  = JSON_TRUE;  else last_afk  = JSON_FALSE;
    if (info & AGENT_BUSY) last_busy = JSON_TRUE;   else last_busy = JSON_FALSE;
    last_region = llGetRegionName();
    last_parcel = llList2String(parcel, 0);
}

sendStateNow() {
    if (ha_url == "" || !is_ready) return;
    llHTTPRequest(ha_url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"],
        buildPayload());
    updateLastState();
}

sendStateIfChanged() {
    if (ha_url == "" || !is_ready) return;
    if (stateChanged()) sendStateNow();
}

requestUrlFromBridge() {
    if (trusted_bridge_key == "") return;
    llRegionSayTo((key)trusted_bridge_key, BRIDGE_HUD_CHANNEL, llList2Json(JSON_OBJECT, [
        "type",       "request_url",
        "avatar_key", (string)llGetOwner()
    ]));
}

showHelp() {
    llOwnerSay("MMO HUD — commands on channel " + (string)CMD_CHANNEL
        + " (use /" + (string)CMD_CHANNEL + " <command>):");
    llOwnerSay("  seturl <url>    — manually set HA webhook URL (fallback)");
    llOwnerSay("  setpoll <sec>   — set state poll interval (min 5s, default 15s)");
    llOwnerSay("  setbridge       — clear trusted bridge key (re-pair next bridge)");
    llOwnerSay("  status          — show current status");
    llOwnerSay("  push            — force an immediate state push to HA");
    llOwnerSay("  hardreset       — clear ALL stored data and reset (re-pair from scratch)");
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
        llSetText("", <0,0,0>, 0.0);

        is_ready             = FALSE;
        url_request_inflight = FALSE;
        url_retry_s          = 2.0;
        regRequestKey        = NULL_KEY;

        // Restore persisted settings
        ha_url             = llLinksetDataRead(LD_HA_URL);
        trusted_bridge_key = llLinksetDataRead(LD_BRIDGE_KEY);

        if (ha_url != "")
            llOwnerSay("MMO HUD: loaded HA URL from storage.");
        else
            llOwnerSay("MMO HUD: no HA URL — touch your bridge object to get one automatically.");

        string stored_poll = llLinksetDataRead(LD_POLL_INTERVAL);
        if (stored_poll != "") poll_interval = (float)stored_poll;

        // Listen for owner chat commands
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
        // Delegate menu handling entirely to the command script
        llMessageLinked(LINK_SET, MSG_OPEN_MENU, "", NULL_KEY);
    }

    listen(integer channel, string name, key id, string msg) {
        // ── URL update from bridge ────────────────────────────────────────────
        if (channel == BRIDGE_HUD_CHANNEL) {
            string type = llJsonGetValue(msg, ["type"]);
            if (type != "url_update") return;

            string new_ha_url = llJsonGetValue(msg, ["ha_url"]);
            if (new_ha_url == JSON_INVALID || new_ha_url == "") return;

            if (trusted_bridge_key != "" && (string)id != trusted_bridge_key) {
                llOwnerSay("MMO HUD: ignored URL update from untrusted object "
                    + (string)id + ". Use /6 setbridge to re-pair.");
                return;
            }

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
            if (url_display    == "") url_display    = "(not set)";
            string bridge_display = trusted_bridge_key;
            if (bridge_display == "") bridge_display = "(none — will accept next bridge)";
            string secret_display = "(not set)";
            if (llLinksetDataRead(LD_HMAC_SECRET) != "") secret_display = "(set)";
            llOwnerSay("HA URL      : " + url_display);
            llOwnerSay("Bridge key  : " + bridge_display);
            if (is_ready)
                llOwnerSay("Script URL  : " + my_url);
            else
                llOwnerSay("Script URL  : (not ready)");
            llOwnerSay("HMAC secret : " + secret_display);
            llOwnerSay("Poll every  : " + (string)((integer)poll_interval) + "s");

        } else if (msg == "push") {
            llOwnerSay("MMO HUD: forcing state push to HA...");
            sendStateNow();

        } else if (msg == "help") {
            showHelp();

        } else if (msg == "hardreset") {
            llOwnerSay("MMO HUD: clearing all stored data and resetting...");
            llLinksetDataDelete(LD_HA_URL);
            llLinksetDataDelete(LD_BRIDGE_KEY);
            llLinksetDataDelete(LD_POLL_INTERVAL);
            llLinksetDataDelete(LD_HMAC_SECRET);
            llResetScript();

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
                requestUrlFromBridge();
                return;
            }
        }
        llHTTPResponse(id, 200, "OK");
    }

    http_response(key req, integer status, list meta, string body) {
        if (req == regRequestKey) {
            regRequestKey = NULL_KEY;
            if (status == 400) {
                string err = llJsonGetValue(body, ["error"]);
                if (err == "protocol_outdated")
                    llOwnerSay("MMO HUD: script protocol v" + (string)PROTOCOL_VERSION
                        + " is too old for this HA installation. Please update your HUD scripts.");
                else
                    llOwnerSay("MMO HUD: HA rejected state push (HTTP 400). Check URL.");
                return;
            }
            if (status != 200) {
                llOwnerSay("MMO HUD: HA rejected state push (HTTP " + (string)status
                    + "). Check URL — use /6 setbridge to re-pair.");
                return;
            }
            // Warn if HA is running a newer protocol than this script knows about
            string ha_proto = llJsonGetValue(body, ["protocol"]);
            if (ha_proto != JSON_INVALID && (integer)ha_proto > PROTOCOL_VERSION)
                llOwnerSay("MMO HUD: HA is running protocol v" + ha_proto
                    + " (this script is v" + (string)PROTOCOL_VERSION
                    + "). Consider updating your HUD scripts.");

            // HA returns {"status":"ok","hmac_secret":"..."} on avatar_state payloads.
            // Store it into linkset data so sl_hud_commands.lsl can read it directly.
            string new_secret = llJsonGetValue(body, ["hmac_secret"]);
            if (new_secret != JSON_INVALID && new_secret != "") {
                string current = llLinksetDataRead(LD_HMAC_SECRET);
                if (new_secret != current)
                    llLinksetDataWrite(LD_HMAC_SECRET, new_secret);
            }
        }
    }

    timer() {
        if (!is_ready) {
            doRequestUrl();
            return;
        }
        sendStateIfChanged();
    }

    changed(integer c) {
        if (c & CHANGED_OWNER) {
            llLinksetDataDelete(LD_HA_URL);
            llLinksetDataDelete(LD_BRIDGE_KEY);
            llLinksetDataDelete(LD_POLL_INTERVAL);
            llLinksetDataDelete(LD_HMAC_SECRET);
            llResetScript();
        }
        if (c & CHANGED_INVENTORY) {
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
            // Clear tracked state so the first push after arrival always fires
            last_afk    = "";
            last_busy   = "";
            last_region = "";
            last_parcel = "";
            doRequestUrl();
            llSetTimerEvent(url_retry_s);
        }
    }

    attach(key av) {
        if (av != NULL_KEY) {
            llResetScript();
        }
    }

    on_rez(integer p) {
        llResetScript();
    }
}
