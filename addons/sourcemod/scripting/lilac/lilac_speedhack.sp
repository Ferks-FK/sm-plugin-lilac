/*
    Little Anti-Cheat - Speedhack Module
    Copyright (C) 2026-2026 Ferks-FK

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

// ===== Constants =====
#define SPEEDHACK_NET_VETO_GRACE     20.0    // Seconds to keep suppressing after the network veto clears

// Shadow mode: only logs what a per-player rule would decide.
#define SHADOW_LEARN_SECS            30      // Seconds spent learning a player's normal.
#define SHADOW_MEMORY_SECS           60.0    // How slowly his normal follows him afterwards.
#define SHADOW_MIN_CONTRAST          1.5     // How far above his normal counts as suspicious.
#define SHADOW_NOTE_COOLDOWN         30.0    // Seconds between "not banned" lines per player.
#define SHADOW_CONTRAST_KEEP         3       // Recent suspicious seconds the decision looks at.

// ===== Per-client state =====
static int speedhack_detection[MAXPLAYERS + 1];
static float player_avg_choke[MAXPLAYERS + 1];

// Network veto grace period tracking — GetGameTime() of the last tick the
// shared network veto (lilac_network_vetoed) flagged this client, 0.0 = never.
static float player_last_vetoed[MAXPLAYERS + 1];

// Shadow mode, per player.
static float shadow_normal[MAXPLAYERS + 1];
static float shadow_seed_sum[MAXPLAYERS + 1];
static int shadow_observed[MAXPLAYERS + 1];
static float shadow_contrast[MAXPLAYERS + 1][SHADOW_CONTRAST_KEEP];
static int shadow_contrast_count[MAXPLAYERS + 1];
static bool shadow_would_ban_logged[MAXPLAYERS + 1];
static float shadow_last_note[MAXPLAYERS + 1];
static float shadow_last_flag[MAXPLAYERS + 1];

// Server-wide
static ConVar g_hMaxCmdrate = null;
static bool g_bMaxCmdrateChecked = false;

// Game time seen on the previous check, to detect the game being paused.
static float g_flLastSpeedhackClock = -1.0;

void lilac_speedhack_reset_client(int client)
{
    speedhack_detection[client] = 0;
    player_avg_choke[client] = 0.0;
    player_last_vetoed[client] = 0.0;

    shadow_normal[client] = 0.0;
    shadow_seed_sum[client] = 0.0;
    shadow_observed[client] = 0;
    shadow_contrast_count[client] = 0;
    shadow_would_ban_logged[client] = false;
    shadow_last_note[client] = 0.0;
    shadow_last_flag[client] = 0.0;

    lilac_tickbase_fix_reset_client(client);
}

static void lilac_speedhack_shadow_decide(int client, int count, float normal, float contrast)
{
    /* Same detection count the real rule asks for. */
    if (icvar[CVAR_SPEEDHACK] < SPEEDHACK_BAN_MIN
        || speedhack_detection[client] < icvar[CVAR_SPEEDHACK])
        return;

    int n = (shadow_contrast_count[client] < SHADOW_CONTRAST_KEEP)
        ? shadow_contrast_count[client] : SHADOW_CONTRAST_KEEP;

    float vals[SHADOW_CONTRAST_KEEP];
    for (int i = 0; i < n; i++)
        vals[i] = shadow_contrast[client][i];

    /* Median of the recent suspicious seconds. */
    for (int i = 1; i < n; i++) {
        float key = vals[i];
        int j = i - 1;

        while (j >= 0 && vals[j] > key) {
            vals[j + 1] = vals[j];
            j--;
        }

        vals[j + 1] = key;
    }

    if (n == 0)
        return;

    float median = vals[n / 2];
    bool would_ban = (median >= SHADOW_MIN_CONTRAST);

    if (would_ban) {
        if (shadow_would_ban_logged[client])
            return;

        shadow_would_ban_logged[client] = true;
    }
    else {
        /* Already would have been banned, later lines would only confuse. */
        if (shadow_would_ban_logged[client])
            return;

        float now = GetEngineTime();

        if (now - shadow_last_note[client] < SHADOW_NOTE_COOLDOWN)
            return;

        shadow_last_note[client] = now;
    }

    /* Several players over the limit at once points to a server event. */
    int others = 0;
    float flag_now = GetEngineTime();

    for (int i = 1; i <= MaxClients; i++) {
        if (i != client && is_player_valid(i)
            && shadow_last_flag[i] > 0.0 && flag_now - shadow_last_flag[i] <= 3.0)
            others++;
    }

    char sMessage[256];
    FormatEx(sMessage, sizeof(sMessage),
        "%s | Detection: %d | CmdsPerSec: %d | Normal: %.0f | Contrast: %.1f | MedianContrast: %.1f | AvgChoke: %.2f | Observed: %ds | OthersFlagged: %d",
        would_ban ? "WOULD BAN (today: no ban, choke gate)" : "not banned, looks normal for this player",
        speedhack_detection[client], count, normal, contrast, median,
        player_avg_choke[client], shadow_observed[client], others);

    lilac_log_speedhack_shadow(client, sMessage);
}

/* Learns each player's normal command rate, then judges the seconds over the
 * limit against it. Only players with real choke are judged, as they are the
 * ones the choke gate keeps from being banned. Logs only. */
static void lilac_speedhack_shadow(int client, int count, bool flagged)
{
    if (flagged)
        shadow_last_flag[client] = GetEngineTime();

    if (shadow_observed[client] < SHADOW_LEARN_SECS) {
        shadow_seed_sum[client] += float(count);

        if (++shadow_observed[client] == SHADOW_LEARN_SECS)
            shadow_normal[client] = shadow_seed_sum[client] / float(SHADOW_LEARN_SECS);

        return;
    }

    float normal = shadow_normal[client];

    if (flagged && normal > 0.0 && player_avg_choke[client] >= 0.10) {
        float contrast = float(count) / normal;

        shadow_contrast[client][shadow_contrast_count[client] % SHADOW_CONTRAST_KEEP] = contrast;
        shadow_contrast_count[client]++;

        lilac_speedhack_shadow_decide(client, count, normal, contrast);
    }

    shadow_normal[client] += (float(count) - normal) / SHADOW_MEMORY_SECS;
    shadow_observed[client]++;
}

void lilac_speedhack_update_choke(int client)
{
    float choke = GetClientAvgChoke(client, NetFlow_Incoming);

    /* Impossible values are corrupted accounting (tickbase manipulation),
     * not a bad connection, so they must not block the ban gate. */
    if (choke > NET_CHOKE_VALID_MAX)
        choke = 0.0;

    player_avg_choke[client] =
        (0.25 * choke) +
        (0.75 * player_avg_choke[client]);
}

public Action timer_check_speedhack(Handle timer)
{
    if (!icvar[CVAR_ENABLE] || !icvar[CVAR_SPEEDHACK])
        return Plugin_Continue;

    if (tick_rate <= 0)
        return Plugin_Continue;

    if (lilac_server_is_lagging()) {
        lilac_server_lag_log_once();

        return Plugin_Continue;
    } else {
        lilac_server_lag_reset_log();
    }

    float now = GetGameTime();

    /* Game time doesn't move while the game is paused, but players keep
     * sending commands, which looks like a speedhack. Skip the check
     * while paused. */
    if (now == g_flLastSpeedhackClock) {
        g_flLastSpeedhackClock = now;

        return Plugin_Continue;
    }

    g_flLastSpeedhackClock = now;

    int baseline = tick_rate;
    if (!g_bMaxCmdrateChecked) {
        g_hMaxCmdrate = FindConVar("sv_maxcmdrate");
        g_bMaxCmdrateChecked = true;
    }
    if (g_hMaxCmdrate != null && g_hMaxCmdrate.IntValue > baseline)
        baseline = g_hMaxCmdrate.IntValue;

    for (int client = 1; client <= MaxClients; client++) {
        if (!is_player_valid(client) || IsFakeClient(client))
            continue;

        if (playerinfo_banned_flags[client][CHEAT_SPEEDHACK])
            continue;

        /* Update unconditionally so it's primed by the time the grace
         * period below needs to read it, same reasoning as before. */
        lilac_speedhack_update_choke(client);

        bool vetoed = lilac_network_vetoed(client);
        if (vetoed)
            player_last_vetoed[client] = now;

        /* Player just connected, buffer may not be representative yet. */
        if (GetClientTime(client) < 10.0)
            continue;

        if (!IsPlayerAlive(client))
            continue;

        /* ===== Network veto (shared with aimbot/aimlock) =====
         * Vetoes on ping, jitter, loss or choke in either direction — far
         * tighter and more accurate than a bespoke per-module check, and the
         * data is already being sampled at 10Hz regardless of who reads it.
         *
         * A stall/backlog caused by bad connectivity doesn't necessarily end
         * the instant the veto clears — the server may still be draining
         * commands that queued up during the bad stretch. Keep suppressing
         * for a tail after the veto lifts, same role the old loss-only grace
         * period served. */
        if (vetoed
            || (player_last_vetoed[client] > 0.0
                && (now - player_last_vetoed[client]) < SPEEDHACK_NET_VETO_GRACE))
        {
            continue;
        }

        /* Count usercmds processed in the last second. */
        int count = lilac_recent_cmd_count(client, now);

        bool flagged = (float(count) > float(baseline) * SPEEDHACK_CMD_RATIO);

        if (flagged)
            lilac_detected_speedhack(client, count, baseline);

        lilac_speedhack_shadow(client, count, flagged);
    }

    return Plugin_Continue;
}

static void lilac_detected_speedhack(int client, int cmdcount, int baseline)
{
    if (playerinfo_banned_flags[client][CHEAT_SPEEDHACK])
        return;

    if (lilac_forward_allow_cheat_detection(client, CHEAT_SPEEDHACK) == false)
        return;

    /* Detection expires in 10 minutes. */
    CreateTimer(600.0, timer_decrement_speedhack, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

    ++speedhack_detection[client];

    char sNet[192];
    lilac_network_format(client, sNet, sizeof(sNet));

    char sDetails[384];
    Format(sDetails, sizeof(sDetails),
        "Detection: %d | CmdsPerSec: %d | ExpectedMax: ~%d | AvgChoke: %.2f | Current TPS: %d | Baseline TPS: %d | Tickrate: %d | %s",
        speedhack_detection[client], cmdcount,
        RoundToFloor(float(baseline) * SPEEDHACK_CMD_RATIO),
        player_avg_choke[client],
        g_iCurrentTPS,
        RoundToNearest(g_fTPSBaselineEWMA),
        g_iServerTickrate,
        sNet);

    lilac_save_player_details(client, sDetails);
    lilac_forward_client_cheat(client, CHEAT_SPEEDHACK);

    /* Don't log the first detection. */
    if (speedhack_detection[client] < 2)
        return;

    lilac_discord_report(client, CHEAT_SPEEDHACK, DISCORD_SUSPECT);

    if (icvar[CVAR_CHEAT_WARN])
        lilac_warn_admins(client, CHEAT_SPEEDHACK, speedhack_detection[client]);

    if (icvar[CVAR_LOG]) {
        lilac_log_setup_client(client);
        Format(line_buffer, sizeof(line_buffer),
            "%s is suspected of using a speedhack (%s).",
            line_buffer, sDetails);

        lilac_log(true);

        if (icvar[CVAR_LOG_EXTRA] == 2)
            lilac_log_extra(client);
    }
    database_log(client, "speedhack", speedhack_detection[client], float(cmdcount), 0.0);

    if (speedhack_detection[client] >= icvar[CVAR_SPEEDHACK]
        && icvar[CVAR_SPEEDHACK] >= SPEEDHACK_BAN_MIN
        && player_avg_choke[client] < 0.10) {

        if (icvar[CVAR_LOG]) {
            lilac_log_setup_client(client);
            Format(line_buffer, sizeof(line_buffer),
                "%s was banned for Speedhack.", line_buffer);

            lilac_log(true);

            if (icvar[CVAR_LOG_EXTRA])
                lilac_log_extra(client);
        }
        database_log(client, "speedhack", DATABASE_BAN);

        playerinfo_banned_flags[client][CHEAT_SPEEDHACK] = true;
        lilac_ban_client(client, CHEAT_SPEEDHACK);
    }
}

public Action timer_decrement_speedhack(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);

    if (!is_player_valid(client))
        return Plugin_Continue;

    if (speedhack_detection[client] > 0)
        speedhack_detection[client]--;

    return Plugin_Continue;
}