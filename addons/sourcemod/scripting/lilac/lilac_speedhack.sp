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
#define SPEEDHACK_LOSS_GRACE         20.0    // Seconds to suppress after high loss event
#define SPEEDHACK_LOSS_HIGH_THRESH   0.15    // Loss threshold that triggers grace period
#define SPEEDHACK_LATENCY_ALPHA      0.1     // EWMA smoothing factor for latency tracking
#define SPEEDHACK_CV_SQ_THRESHOLD    0.1     // CV² > 0.1 → std dev > ~32% of mean

// ===== Per-client state =====
static int speedhack_detection[MAXPLAYERS + 1];
static float player_avg_choke[MAXPLAYERS + 1];

// Loss grace period tracking
static float player_last_high_loss[MAXPLAYERS + 1];

// Latency stability: EWMA of value and EWMA of squared value for variance
// Initialized to -1.0 as sentinel; first sample seeds directly.
static float player_latency_out_ewma[MAXPLAYERS + 1];
static float player_latency_out_sq_ewma[MAXPLAYERS + 1];

// Server-wide
static ConVar g_hMaxCmdrate = null;
static bool g_bMaxCmdrateChecked = false;

void lilac_speedhack_reset_client(int client)
{
    speedhack_detection[client] = 0;
    player_avg_choke[client] = 0.0;
    player_last_high_loss[client] = 0.0;
    player_latency_out_ewma[client] = -1.0;
    player_latency_out_sq_ewma[client] = -1.0;

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

        /* Update tracking unconditionally so EWMAs converge during the
         * grace period and are ready when detection actually starts. */
        lilac_speedhack_update_choke(client);

        /* Update latency stability tracking.
         * First sample seeds the EWMA directly to avoid the warm-up
         * artifact where variance is non-zero for constant input. */
        float lat = GetClientAvgLatency(client, NetFlow_Outgoing);

        if (player_latency_out_ewma[client] < 0.0) {
            player_latency_out_ewma[client] = lat;
            player_latency_out_sq_ewma[client] = lat * lat;
        } else {
            player_latency_out_ewma[client] =
                SPEEDHACK_LATENCY_ALPHA * lat +
                (1.0 - SPEEDHACK_LATENCY_ALPHA) * player_latency_out_ewma[client];
            player_latency_out_sq_ewma[client] =
                SPEEDHACK_LATENCY_ALPHA * (lat * lat) +
                (1.0 - SPEEDHACK_LATENCY_ALPHA) * player_latency_out_sq_ewma[client];
        }

        /* Track high loss events for grace period. */
        if (icvar[CVAR_LOSS_FIX]) {
            if (GetClientAvgLoss(client, NetFlow_Incoming) > SPEEDHACK_LOSS_HIGH_THRESH)
                player_last_high_loss[client] = now;
        }

        /* Player just connected, buffer may not be representative yet. */
        if (GetClientTime(client) < 10.0)
            continue;

        if (!IsPlayerAlive(client))
            continue;

        /* ===== High loss grace period =====
         * After high loss, queued cmds are processed in bursts as
         * connectivity recovers. Suppress detection for a period. */
        if (icvar[CVAR_LOSS_FIX]
            && player_last_high_loss[client] > 0.0
            && (now - player_last_high_loss[client]) < SPEEDHACK_LOSS_GRACE)
        {
            continue;
        }

        /* Existing: instantaneous high loss check. */
        if (skip_due_to_loss(client, 0.15, NetFlow_Incoming))
            continue;

        /* ===== Latency instability check (CV²) =====
         * Coefficient of variation squared computed from online EWMA
         * statistics: variance = E[X²] - (E[X])², CV² = var / mean².
         *
         * A CV² > 0.1 means std dev exceeds ~32% of the mean.
         * Connection quality is the ping module's responsibility.
         *
         * Validation from real logs:
         *   Cheater:    latency ~0.039 ± 0.001 → CV² ≈ 0.0007
         *   Lagging FP: latency ~0.056 ± 0.022 → CV² ≈ 0.15 */
        float variance = player_latency_out_sq_ewma[client]
            - (player_latency_out_ewma[client] * player_latency_out_ewma[client]);

        if (variance < 0.0)
            variance = 0.0;

        float cv_sq = 0.0;
        if (player_latency_out_ewma[client] > 0.01)
            cv_sq = variance / (player_latency_out_ewma[client] * player_latency_out_ewma[client]);

        if (cv_sq > SPEEDHACK_CV_SQ_THRESHOLD)
            continue;

        /* Existing: choke-based skip. */
        if (player_avg_choke[client] > 0.3
            && GetClientAvgChoke(client, NetFlow_Incoming) > 0.2)
            continue;

        if (player_avg_choke[client] > 0.1
            && GetClientAvgChoke(client, NetFlow_Incoming) > 0.1)
            continue;

        /* Count usercmds processed in the last second. */
        int count = 0;
        int ind = playerinfo_index[client];

        for (int i = 0; i < CMD_LENGTH; i++) {
            ind = wrap_index(ind - 1);

            float t = playerinfo_time_usercmd[client][ind];

            if (t == 0.0)
                break;

            if (now - t > 1.0)
                break;

            count++;
        }

        if (float(count) > float(baseline) * SPEEDHACK_CMD_RATIO)
            lilac_detected_speedhack(client, count, baseline, cv_sq);
    }

    return Plugin_Continue;
}

static void lilac_detected_speedhack(int client, int cmdcount, int baseline, float cv_sq)
{
    if (playerinfo_banned_flags[client][CHEAT_SPEEDHACK])
        return;

    if (lilac_forward_allow_cheat_detection(client, CHEAT_SPEEDHACK) == false)
        return;

    /* Detection expires in 10 minutes. */
    CreateTimer(600.0, timer_decrement_speedhack, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

    ++speedhack_detection[client];

    char sDetails[256];
    Format(sDetails, sizeof(sDetails),
        "Detection: %d | CmdsPerSec: %d | ExpectedMax: ~%d | AvgChoke: %.2f | CV2: %.4f | Current TPS: %d | Effective TPS: %d | Tickrate: %d",
        speedhack_detection[client], cmdcount,
        RoundToFloor(float(baseline) * SPEEDHACK_CMD_RATIO),
        player_avg_choke[client],
        cv_sq,
        g_iCurrentTPS,
        g_iEffectiveTPS,
        g_iServerTickrate);

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