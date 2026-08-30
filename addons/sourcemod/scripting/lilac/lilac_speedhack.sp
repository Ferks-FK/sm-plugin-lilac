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

// ===== Per-client state =====
static int speedhack_detection[MAXPLAYERS + 1];
static float player_avg_choke[MAXPLAYERS + 1];

// Network veto grace period tracking — GetGameTime() of the last tick the
// shared network veto (lilac_network_vetoed) flagged this client, 0.0 = never.
static float player_last_vetoed[MAXPLAYERS + 1];

// Server-wide
static ConVar g_hMaxCmdrate = null;
static bool g_bMaxCmdrateChecked = false;

void lilac_speedhack_reset_client(int client)
{
    speedhack_detection[client] = 0;
    player_avg_choke[client] = 0.0;
    player_last_vetoed[client] = 0.0;

    lilac_tickbase_fix_reset_client(client);
}

void lilac_speedhack_update_choke(int client)
{
    player_avg_choke[client] =
        (0.25 * GetClientAvgChoke(client, NetFlow_Incoming)) +
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

        if (float(count) > float(baseline) * SPEEDHACK_CMD_RATIO)
            lilac_detected_speedhack(client, count, baseline);
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