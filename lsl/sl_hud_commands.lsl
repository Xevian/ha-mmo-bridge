
// ── MMO Bridge — HUD Commands Script ─────────────────────────────────────────
//
// Companion script for sl_avatar_hud.lsl — handles the interactive script menu
// and HMAC-signed command dispatch. Lives in the same linkset as the main HUD.
//
// Keeping this separate means llHMAC signing only blocks this script, not the
// main HUD. The main HUD stays responsive for state polling, bridge URL updates,
// and chat commands while a command is being signed.
//
// touch_start is handled here directly — no inter-script messaging needed.
// ha_url and hmac_secret are read from protected linkset data written by
// the main HUD on registration.
// ─────────────────────────────────────────────────────────────────────────────

// ── Protocol version — MUST match sl_avatar_hud.lsl ──────────────────────────
integer PROTOCOL_VERSION = 1;
string  SCRIPT_VERSION   = "0.2.1";  // in-world version — matches manifest.json

// ── Linkset data keys (shared with sl_avatar_hud.lsl — read-only here) ────────
string LD_HA_URL      = "mmohud_ha_url";
string LD_HMAC_SECRET = "mmohud_hmac_secret";
string LD_PASS        = "mmo_bridge";  // passphrase for protected linkset data (must match sl_avatar_hud.lsl)

// ── Menu state ────────────────────────────────────────────────────────────────
integer menu_channel;
integer menu_listen_handle;
list    cached_scripts;        // [id, name, id, name, ...]
key     scriptListRequestKey;
key     commandRequestKey;
integer SCRIPT_MENU_MAX  = 11;  // max script buttons (1 slot reserved for Cancel)
float   MENU_TIMEOUT_S   = 30.0; // auto-close listen if user ignores the dialog

// ── Helpers ───────────────────────────────────────────────────────────────────

requestScriptList() {
    string ha_url = llLinksetDataReadProtected(LD_HA_URL, LD_PASS);
    if (ha_url == "") {
        llOwnerSay("MMO HUD: not connected to HA — no URL stored.");
        return;
    }
    string payload = llList2Json(JSON_OBJECT, [
        "protocol", PROTOCOL_VERSION,
        "world",    "secondlife",
        "type",     "hud_list_scripts",
        "avatar",   llKey2Name(llGetOwner())
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
    llSetTimerEvent(MENU_TIMEOUT_S);  // clean up if user ignores the dialog
}

sendCommand(string script_id) {
    string ha_url      = llLinksetDataReadProtected(LD_HA_URL,      LD_PASS);
    string hmac_secret = llLinksetDataReadProtected(LD_HMAC_SECRET, LD_PASS);

    if (ha_url == "") {
        llOwnerSay("MMO HUD: not connected to HA.");
        return;
    }
    if (hmac_secret == "") {
        llOwnerSay("MMO HUD: no command token yet — try re-attaching the HUD.");
        return;
    }

    integer ts    = llGetUnixTime();
    string  canon = (string)ts + ".script." + script_id;
    string  sig   = llHMAC(hmac_secret, canon, "sha256");

    string payload = llList2Json(JSON_OBJECT, [
        "protocol", PROTOCOL_VERSION,
        "world",    "secondlife",
        "type",     "hud_command",
        "avatar",   llKey2Name(llGetOwner()),
        "script", script_id,
        "ts",     ts,
        "sig",    sig
    ]);
    commandRequestKey = llHTTPRequest(ha_url,
        [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/json"], payload);
}

// ── Main ──────────────────────────────────────────────────────────────────────

default {
    state_entry() {
        // Linkset data is owned and wiped by sl_avatar_hud.lsl on owner change —
        // no independent wipe needed here, but reset menu state cleanly regardless.

        // Stable per-session menu channel derived from owner UUID
        menu_channel = (integer)("0x" + llGetSubString((string)llGetOwner(), 0, 7))
                       | 0x80000000;

        if (menu_listen_handle) llListenRemove(menu_listen_handle);
        menu_listen_handle   = 0;
        scriptListRequestKey = NULL_KEY;
        commandRequestKey    = NULL_KEY;
        cached_scripts       = [];
    }

    touch_start(integer total) {
        if (llDetectedKey(0) != llGetOwner()) return;
        // Always fetch a fresh list so newly-labelled scripts appear immediately
        requestScriptList();
    }

    listen(integer channel, string name, key id, string msg) {
        if (channel != menu_channel) return;

        llListenRemove(menu_listen_handle);
        menu_listen_handle = 0;
        llSetTimerEvent(0.0);  // cancel timeout
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
    }

    http_response(key req, integer status, list meta, string body) {
        // ── Script list response ──────────────────────────────────────────────
        if (req == scriptListRequestKey) {
            scriptListRequestKey = NULL_KEY;
            if (status != 200) {
                llOwnerSay("MMO HUD: failed to fetch script list (HTTP "
                    + (string)status + ").");
                return;
            }
            // Parse [{"id":"...","name":"..."}, ...] into a flat [id, name, ...] list
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
        // Menu dialog timed out — user ignored it. Clean up the listen.
        llSetTimerEvent(0.0);
        if (menu_listen_handle) {
            llListenRemove(menu_listen_handle);
            menu_listen_handle = 0;
        }
    }

    changed(integer c) {
        if (c & CHANGED_OWNER) {
            // Linkset data is cleared by sl_avatar_hud.lsl on owner change —
            // just reset this companion script
            llResetScript();
        }
        if (c & CHANGED_INVENTORY) {
            llResetScript();
        }
        if (c & (CHANGED_REGION | CHANGED_REGION_START | CHANGED_TELEPORT)) {
            // Cached scripts are region-agnostic (they're in HA) but clear them
            // so the next touch fetches fresh — belt-and-braces after a TP
            cached_scripts = [];
            if (menu_listen_handle) {
                llListenRemove(menu_listen_handle);
                menu_listen_handle = 0;
            }
        }
    }

    on_rez(integer p) {
        llResetScript();
    }
}
