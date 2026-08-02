/*
    Little Anti-Cheat - Speedhack Module (SMAC-style comparison, log-only)
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

/* ===== Experimental comparison module =====
 * Re-implements speedhack detection using a token-bucket signal (inspired
 * by srcdslab/sm-plugin-SMAC's smac_speedhack.sp) instead of
 * lilac_speedhack.sp's trailing 1-second cmd count. The bucket drains by
 * 1 per processed usercmd and refills based on real elapsed time, so a
 * burst spanning two 1-second windows can't evade it the way a fixed
 * window can.
 *
 * The false-positive guard rails (latency CV^2, tickbase/loss grace
 * periods, choke skip) are duplicated from lilac_speedhack.sp so the two
 * detectors only differ in the primary trigger, keeping the comparison
 * fair.
 *
 * Log-only: this module never bans, forwards a cheat flag, or writes to
 * the database. It writes to its own log file so its detections can be
 * compared against lilac_speedhack.sp's without affecting moderation. */

#define SMAC_TICKBASE_GRACE     60.0    // Seconds to suppress after tickbase clamp
#define SMAC_LOSS_GRACE         20.0    // Seconds to suppress after high loss event
#define SMAC_LOSS_HIGH_THRESH   0.15    // Loss threshold that triggers grace period
#define SMAC_LATENCY_ALPHA      0.1     // EWMA smoothing factor for latency tracking
#define SMAC_CV_SQ_THRESHOLD    0.1     // CV^2 > 0.1 -> std dev > ~32% of mean

// ===== Per-client state =====
static float smac_bucket[MAXPLAYERS + 1];
static int   smac_detections[MAXPLAYERS + 1];
static float smac_avg_choke[MAXPLAYERS + 1];

static float smac_last_tickbase_clamp[MAXPLAYERS + 1];
static float smac_last_high_loss[MAXPLAYERS + 1];

// Sentinel -1.0: first sample seeds the EWMA directly (see lilac_speedhack.sp).
static float smac_latency_ewma[MAXPLAYERS + 1];
static float smac_latency_sq_ewma[MAXPLAYERS + 1];

// ===== Server-wide =====
static float smac_last_replenish = 0.0;

static ConVar g_hSmacMaxCmdrate = null;
static bool   g_bSmacMaxCmdrateChecked = false;

static char smac_log_file[PLATFORM_MAX_PATH];
static bool smac_log_ready = false;

void lilac_speedhack_smac_reset_client(int client)
{
    smac_bucket[client] = 0.0;
    smac_detections[client] = 0;
    smac_avg_choke[client] = 0.0;
    smac_last_tickbase_clamp[client] = 0.0;
    smac_last_high_loss[client] = 0.0;
    smac_latency_ewma[client] = -1.0;
    smac_latency_sq_ewma[client] = -1.0;
}

// ===== Hook point for the shared tickbase-fix helper (lilac_stock.sp) =====
void lilac_speedhack_smac_notify_tickbase_clamp(int client)
{
    smac_last_tickbase_clamp[client] = GetGameTime();
}

// ===== Hook point for OnPlayerRunCmd (lilac.sp) =====
// Mirrors SMAC's own OnPlayerRunCmd: 1 tick consumed per processed cmd.
void lilac_speedhack_smac_consume(int client)
{
    if (!IsPlayerAlive(client))
        return;

    smac_bucket[client] -= 1.0;
}

void lilac_speedhack_smac_log_setup()
{
    if (smac_log_ready)
        return;

    smac_log_ready = true;

    BuildPath(Path_SM, smac_log_file, sizeof(smac_log_file), "logs/lilac_speedhack_smac.log");

    if (FileExists(smac_log_file, false, NULL_STRING))
        return;

    Handle file = OpenFile(smac_log_file, "a");

    if (file == null) {
        PrintToServer("[Lilac] Cannot open speedhack_smac log file.");
        return;
    }

    char date[64];
    FormatTime(date, sizeof(date), dateformat, GetTime());

    WriteFileLine(file,
"=========[Notice]=========\n\
Speedhack (SMAC-comparison) Log - Little Anti-Cheat %s\n\
Created: %s\n\n\
This module is experimental and log-only: it never bans, warns, or affects\n\
moderation in any way. It re-implements speedhack detection using a\n\
token-bucket signal (see srcdslab/sm-plugin-SMAC's smac_speedhack.sp) so it\n\
can be compared against lilac_speedhack.sp's detections.\n\n",
        PLUGIN_VERSION, date);

    CloseHandle(file);
}

static void smac_log_write(int client, int detections, float bucket, float baseline, float cv_sq)
{
    lilac_speedhack_smac_log_setup();

    Handle file = OpenFile(smac_log_file, "a");

    if (file == null) {
        PrintToServer("[Lilac] Cannot open speedhack_smac log file.");
        return;
    }

    char date[64], steamid[64], ip[64], buffer[512];
    FormatTime(date, sizeof(date), dateformat, GetTime());
    GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid), true);
    GetClientIP(client, ip, sizeof(ip), true);

    FormatEx(buffer, sizeof(buffer),
        "%s [Version %s] {Name: \"%N\" | SteamID: %s | IP: %s} is suspected of using a speedhack (Detection: %d | Bucket: %.2f | Baseline: %.2f | CV2: %.4f).",
        date, PLUGIN_VERSION, client, steamid, ip, detections, bucket, baseline, cv_sq);

    /* Strip control characters, same cleanup as lilac_log(). */
    for (int i = 0; buffer[i]; i++) {
        if (buffer[i] == '\n' || buffer[i] == 0x0d)
            buffer[i] = '*';
        else if (buffer[i] < 32)
            buffer[i] = '#';
    }

    WriteFileLine(file, "%s", buffer);
    CloseHandle(file);
}

public Action timer_check_speedhack_smac(Handle timer)
{
    if (!icvar[CVAR_ENABLE] || !icvar[CVAR_SPEEDHACK])
        return Plugin_Continue;

    if (tick_rate <= 0)
        return Plugin_Continue;

    /* Reuse the original module's lag pause signal, but don't touch its
     * once-per-episode log latch - lilac_speedhack.sp already logs it. */
    if (lilac_server_is_lagging())
        return Plugin_Continue;

    float now = GetGameTime();
    float engineNow = GetEngineTime();

    int baseline_i = tick_rate;
    if (!g_bSmacMaxCmdrateChecked) {
        g_hSmacMaxCmdrate = FindConVar("sv_maxcmdrate");
        g_bSmacMaxCmdrateChecked = true;
    }
    if (g_hSmacMaxCmdrate != null && g_hSmacMaxCmdrate.IntValue > baseline_i)
        baseline_i = g_hSmacMaxCmdrate.IntValue;

    float baseline = float(baseline_i);
    float bucket_max = baseline * SPEEDHACK_CMD_RATIO;

    /* Refill amount based on real elapsed time, self-correcting for timer
     * drift/hitches the same way SMAC's Timer_AddTicks does. */
    if (smac_last_replenish <= 0.0)
        smac_last_replenish = engineNow;

    float refill = baseline * (engineNow - smac_last_replenish);
    smac_last_replenish = engineNow;

    for (int client = 1; client <= MaxClients; client++) {
        if (!is_player_valid(client) || IsFakeClient(client))
            continue;

        if (playerinfo_banned_flags[client][CHEAT_SPEEDHACK])
            continue;

        /* Refill/clamp and update tracking unconditionally, mirrors
         * lilac_speedhack.sp so EWMAs stay warm through grace periods. */
        smac_bucket[client] += refill;

        /* Clamp both ends: the ceiling stops unbounded credit from idling
         * (e.g. while dead), the floor stops a burst from leaving "debt"
         * that would outlast the grace periods below once they expire. */
        if (smac_bucket[client] > bucket_max)
            smac_bucket[client] = bucket_max;
        else if (smac_bucket[client] < 0.0)
            smac_bucket[client] = 0.0;

        smac_avg_choke[client] =
            (0.25 * GetClientAvgChoke(client, NetFlow_Incoming)) +
            (0.75 * smac_avg_choke[client]);

        float lat = GetClientAvgLatency(client, NetFlow_Outgoing);

        if (smac_latency_ewma[client] < 0.0) {
            smac_latency_ewma[client] = lat;
            smac_latency_sq_ewma[client] = lat * lat;
        } else {
            smac_latency_ewma[client] =
                SMAC_LATENCY_ALPHA * lat + (1.0 - SMAC_LATENCY_ALPHA) * smac_latency_ewma[client];
            smac_latency_sq_ewma[client] =
                SMAC_LATENCY_ALPHA * (lat * lat) + (1.0 - SMAC_LATENCY_ALPHA) * smac_latency_sq_ewma[client];
        }

        if (icvar[CVAR_LOSS_FIX]) {
            if (GetClientAvgLoss(client, NetFlow_Incoming) > SMAC_LOSS_HIGH_THRESH)
                smac_last_high_loss[client] = now;
        }

        /* Player just connected, buffer may not be representative yet. */
        if (GetClientTime(client) < 10.0)
            continue;

        if (!IsPlayerAlive(client))
            continue;

        /* Tickbase manipulation grace period. */
        if (smac_last_tickbase_clamp[client] > 0.0
            && (now - smac_last_tickbase_clamp[client]) < SMAC_TICKBASE_GRACE)
            continue;

        /* High loss grace period. */
        if (icvar[CVAR_LOSS_FIX]
            && smac_last_high_loss[client] > 0.0
            && (now - smac_last_high_loss[client]) < SMAC_LOSS_GRACE)
            continue;

        /* Instantaneous high loss check. */
        if (skip_due_to_loss(client, 0.15, NetFlow_Incoming))
            continue;

        /* Latency instability check (CV^2), see lilac_speedhack.sp for the derivation. */
        float variance = smac_latency_sq_ewma[client]
            - (smac_latency_ewma[client] * smac_latency_ewma[client]);

        if (variance < 0.0)
            variance = 0.0;

        float cv_sq = 0.0;
        if (smac_latency_ewma[client] > 0.01)
            cv_sq = variance / (smac_latency_ewma[client] * smac_latency_ewma[client]);

        if (cv_sq > SMAC_CV_SQ_THRESHOLD)
            continue;

        /* Choke-based skip. */
        if (smac_avg_choke[client] > 0.3
            && GetClientAvgChoke(client, NetFlow_Incoming) > 0.2)
            continue;

        if (smac_avg_choke[client] > 0.1
            && GetClientAvgChoke(client, NetFlow_Incoming) > 0.1)
            continue;

        /* ===== Primary signal: token bucket ran dry ===== */
        if (smac_bucket[client] <= 0.0)
            smac_speedhack_detected(client, baseline, cv_sq);
    }

    return Plugin_Continue;
}

static void smac_speedhack_detected(int client, float baseline, float cv_sq)
{
    /* Detection expires in 10 minutes, mirrors lilac_speedhack.sp. */
    CreateTimer(600.0, timer_decrement_speedhack_smac, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

    ++smac_detections[client];

    /* Don't log the first detection, same noise suppression as lilac_speedhack.sp. */
    if (smac_detections[client] < 2)
        return;

    if (icvar[CVAR_LOG])
        smac_log_write(client, smac_detections[client], smac_bucket[client], baseline, cv_sq);
}

public Action timer_decrement_speedhack_smac(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);

    if (!is_player_valid(client))
        return Plugin_Continue;

    if (smac_detections[client] > 0)
        smac_detections[client]--;

    return Plugin_Continue;
}
