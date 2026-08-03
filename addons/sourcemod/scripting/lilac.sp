/*
	Little Anti-Cheat
	Copyright (C) 2018-2023 J_Tanzanite

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

/* Uncomment below line to compile for Team Fortress 2 Classic.
 * You'll need SourceMod 1.12 to compile.
 * Note: Doing so means the compiled plugin won't work correctly
 * for other source games. 
 * SourceMod 1.12: https://www.sourcemod.net/downloads.php?branch=1.12 */

#include <sourcemod>
#include <sdktools_engine>
#include <sdktools_entoutput>
#include <convar_class>
#include <lilac>

#undef REQUIRE_PLUGIN /* ... */
#undef REQUIRE_EXTENSIONS
#define REQUIRE_PLUGIN
#define REQUIRE_EXTENSIONS

#pragma semicolon 1
#pragma newdecls required

#include "lilac/lilac_globals.sp" /* Must be at top, contains defines. */

#include "lilac/lilac_aimbot.sp"
#include "lilac/lilac_aimlock.sp"
#include "lilac/lilac_angles.sp"
#include "lilac/lilac_backtrack.sp"
#include "lilac/lilac_bhop.sp"
#include "lilac/lilac_config.sp"
#include "lilac/lilac_convar.sp"
#include "lilac/lilac_database.sp"
#include "lilac/lilac_lerp.sp"
#include "lilac/lilac_macro.sp"
#include "lilac/lilac_network.sp"
#include "lilac/lilac_ping.sp"
#include "lilac/lilac_speedhack.sp"
#include "lilac/lilac_infected_damage.sp"
#include "lilac/lilac_stock.sp"
#include "lilac/lilac_string.sp" /* String takes care of chat and names. */

public Plugin myinfo = {
	name = PLUGIN_NAME,
	author = PLUGIN_AUTHOR,
	description = PLUGIN_DESC,
	version = PLUGIN_VERSION,
	url = PLUGIN_URL
};

public APLRes AskPluginLoad2(Handle hMyself, bool bLate, char[] sError, int err_max)
{
    EngineVersion version = GetEngineVersion();

    if (version == Engine_Left4Dead || version == Engine_Left4Dead2 || version == Engine_CSS || version == Engine_DODS)
    {
        g_bGame = version;

        RegPluginLibrary("lilac");

        CreateNative("lilac_GetDetectedInfos", lilac_native_get_detected_infos);

        /* Been told this isn't needed, but just in case. */
        MarkNativeAsOptional("SBBanPlayer");
        MarkNativeAsOptional("SBPP_BanPlayer");
        MarkNativeAsOptional("MABanPlayer");
        MarkNativeAsOptional("Updater_AddPlugin");
        MarkNativeAsOptional("Updater_RemovePlugin");
        MarkNativeAsOptional("IRC_MsgFlaggedChannels");
        MarkNativeAsOptional("AR_GetMatchID");

        /* Build the log path for the file in case the user has overridden sm_basepath. */
        BuildPath(Path_SM, log_file, sizeof(log_file), "logs/lilac.log");
        BuildPath(Path_SM, smooth_telemetry_log_file, sizeof(smooth_telemetry_log_file), "logs/lilac_smooth_telemetry.log");
        BuildPath(Path_SM, angle_metric_log_file, sizeof(angle_metric_log_file), "logs/lilac_angle_metric.log");

        return APLRes_Success;
    }

    strcopy(sError, err_max, "This plugin only supports Source Engine games. If you are seeing this message, it means your game isn't supported.");
    return APLRes_SilentFailure;
}

public void OnPluginStart()
{
    LoadTranslations("lilac.phrases.txt");
    
    HookEvent("player_death", event_player_death, EventHookMode_Pre);
    HookEvent("player_spawn", event_teleported, EventHookMode_Post);
    HookEvent("player_changename", event_namechange, EventHookMode_Post);

    if (g_bGame == Engine_Left4Dead2)
        HookEvent("player_hurt", event_player_hurt, EventHookMode_Post);

    HookEntityOutput("trigger_teleport", "OnEndTouch", map_teleport);

    /* Default ban lengths are -1. (Global ConVar). */
    for (int i = 0; i < CHEAT_MAX; i++)
        ban_length_overwrite[i] = -1;

    /* Bans for Bhop are permanent by default. */
    ban_length_overwrite[CHEAT_BHOP] = 0;

    /* Bans for Macros are 15 minutes by default. */
    ban_length_overwrite[CHEAT_MACRO] = 15;

    /* Bans for Speedhack are permanent by default. */
    ban_length_overwrite[CHEAT_SPEEDHACK] = 0;

    /* If sv_maxupdaterate is changed mid-game and then this plugin
    * is loaded, then it could lead to false positives.
    * Reset all stats on all players already in-game, but ignore lerp. */
    for (int i = 1; i <= MaxClients; i++) {
        lilac_reset_client(i);
        lilac_lerp_ignore_nolerp_client(i);
    }

    forwardhandle = CreateGlobalForward("lilac_cheater_detected",
        ET_Ignore, Param_Cell, Param_Cell);
    forwardhandleban = CreateGlobalForward("lilac_cheater_banned",
        ET_Ignore, Param_Cell, Param_Cell);
    forwardhandleallow = CreateGlobalForward("lilac_allow_cheat_detection",
        ET_Event, Param_Cell, Param_Cell);

    CreateTimer(QUERY_TIMER, timer_query, _, TIMER_REPEAT);
    CreateTimer(5.0, timer_check_ping, _, TIMER_REPEAT);
    CreateTimer(5.0, timer_check_lerp, _, TIMER_REPEAT);
    CreateTimer(1.0, timer_check_speedhack, _, TIMER_REPEAT);
    CreateTimer(0.1, timer_check_aimlock, _, TIMER_REPEAT);
    CreateTimer(0.1, timer_sample_network, _, TIMER_REPEAT);
    CreateTimer(60.0 * 5.0, timer_decrement_macro, _, TIMER_REPEAT);

    tick_rate = RoundToNearest(1.0 / GetTickInterval());

    /* Ignore low tickrates. */
    macro_max = (tick_rate >= 60 && tick_rate <= MACRO_LOG_LENGTH) ? 20 : 0;

    if (tick_rate > 50) {
        bhop_settings_min[BHOP_INDEX_MIN] = 5;
        bhop_settings_min[BHOP_INDEX_MAX] = 10;
        bhop_settings_min[BHOP_INDEX_TOTAL] = 1;
    }
    else {
        bhop_settings_min[BHOP_INDEX_MIN] = 10;
        bhop_settings_min[BHOP_INDEX_MAX] = 20;
        bhop_settings_min[BHOP_INDEX_TOTAL] = 3;
    }
    bhop_settings_min[BHOP_INDEX_JUMP] = -1;
    bhop_settings_min[BHOP_INDEX_AIR] = 0;

    /* This sets up convars and such. */
    lilac_config_setup();

    if (icvar[CVAR_LOG])
        lilac_log_first_time_setup();
}

public void OnAllPluginsLoaded()
{
    sourcebanspp_exist = LibraryExists("sourcebans++");
    sourcebans_exist = LibraryExists("sourcebans");
    materialadmin_exist = LibraryExists("materialadmin");
    autorecorder_exist = LibraryExists("autorecorder");

    if (LibraryExists("updater"))
        lilac_update_url();

    /* Startup message. */
    PrintToServer("[Little Anti-Cheat %s] Successfully loaded!", PLUGIN_VERSION);
}

public void OnLibraryAdded(const char []name)
{
    if (StrEqual(name, "sourcebans++"))
        sourcebanspp_exist = true;
    else if (StrEqual(name, "sourcebans"))
        sourcebans_exist = true;
    else if (StrEqual(name, "materialadmin"))
        materialadmin_exist = true;
    else if (StrEqual(name, "autorecorder"))
        autorecorder_exist = true;
    else if (StrEqual(name, "updater"))
        lilac_update_url();
}

public void OnLibraryRemoved(const char []name)
{
    if (StrEqual(name, "sourcebans++"))
        sourcebanspp_exist = false;
    else if (StrEqual(name, "sourcebans"))
        sourcebans_exist = false;
    else if (StrEqual(name, "materialadmin"))
        materialadmin_exist = false;
    else if (StrEqual(name, "autorecorder"))
        autorecorder_exist = false;
}

void lilac_update_url()
{
	if (icvar[CVAR_AUTO_UPDATE]) {
		if (!NATIVE_EXISTS("Updater_AddPlugin")) {
			PrintToServer("Error: Native Updater_AddPlugin() not found! Check if updater plugin is installed.");
			return;
		}

		Updater_AddPlugin(UPDATE_URL);
	}
	else {
		if (!NATIVE_EXISTS("Updater_RemovePlugin")) {
			PrintToServer("Error: Native Updater_RemovePlugin() not found! Check if updater plugin is installed.");
			return;
		}

		Updater_RemovePlugin();
	}
}

public void OnClientPutInServer(int client)
{
	lilac_reset_client(client);
	lilac_string_check_name(client);

	CreateTimer(30.0, timer_welcome, GetClientUserId(client));
}

public Action event_teleported(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid", -1));

	if (is_player_valid(client))
		playerinfo_time_teleported[client] = GetGameTime();

	return Plugin_Continue;
}

public void map_teleport(const char[] output, int caller, int activator, float delay)
{
	if (!is_player_valid(activator) || IsFakeClient(activator))
		return;

	playerinfo_time_teleported[activator] = GetGameTime();
}

public Action timer_welcome(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);

	/* Todo: Considering there are log-only options now...
	 * Perhaps I should check if ANYTHING can ban at all. */
	if (is_player_valid(client) && icvar[CVAR_WELCOME]
		&& icvar[CVAR_ENABLE] && icvar[CVAR_BAN])
		PrintToChat(client, "[Lilac] %T", "welcome_msg", client, PLUGIN_VERSION);

	return Plugin_Continue;
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3],
                float angles[3], int& weapon, int& subtype, int& cmdnum,
                int& tickcount, int& seed, int mouse[2])
{
    static int lbuttons[MAXPLAYERS + 1];

    if (!is_player_valid(client) || IsFakeClient(client))
        return Plugin_Continue;

    /* Increment the index. */
    if (++playerinfo_index[client] >= CMD_LENGTH)
        playerinfo_index[client] = 0;

    /* Store when the tick was processed. */
    playerinfo_time_usercmd[client][playerinfo_index[client]] = GetGameTime();

    /* Store information. */
    lilac_backtrack_store_tickcount(client, tickcount);
    set_player_log_angles(client, angles, playerinfo_index[client]);
    playerinfo_buttons[client][playerinfo_index[client]] = buttons;
    playerinfo_actions[client][playerinfo_index[client]] = 0;

    if ((buttons & IN_ATTACK) && bullettime_can_shoot(client))
        playerinfo_actions[client][playerinfo_index[client]] |= ACTION_SHOT;

    if (icvar[CVAR_ENABLE]) {
        /* Detect Angle-Cheats. */
        /* Only check for angles in CSS and DoD:S */
        if (icvar[CVAR_ANGLES] && (g_bGame == Engine_CSS || g_bGame == Engine_DODS))
            lilac_angles_check(client, angles);

        /* Detect Macros. */
        if (macro_max && icvar[CVAR_MACRO])
            lilac_macro_check(client, buttons, lbuttons[client]);

        /* Detect bhop. */
        if (!force_disable_bhop && icvar[CVAR_BHOP])
            lilac_bhop_check(client, buttons, lbuttons[client]);

        /* Patch Angle-Cheats. */
        if (icvar[CVAR_PATCH_ANGLES])
            lilac_angles_patch(angles);

        /* Patch Backtracking. */
        if (icvar[CVAR_BACKTRACK_PATCH])
            tickcount = lilac_backtrack_patch(client, tickcount);

        /* Clamp infected player tickbase to prevent burst-attack exploit. */
        lilac_tickbase_fix(client);
    }

    lbuttons[client] = buttons;

    return Plugin_Continue;
}

public void OnMapStart()
{
    g_fTimeSinceMapStart   = GetEngineTime();
    g_fServerLagPauseUntil = 0.0;
    g_bServerLagLogged     = false;
    g_iServerTickrate      = 0;
    g_iTicksThisSecond     = 0;
    g_fTPSWindowStart      = 0.0;
    g_iCurrentTPS          = 0;
    g_iTriggerTPS          = 0;

    g_iEffectiveTPS        = 0;
    g_iTPSCalibSum         = 0;
    g_iTPSCalibSamples     = 0;

    g_bTPSWindowArmed      = false;
}

public void OnGameFrame()
{
    float engineNow = GetEngineTime();

    if (g_iServerTickrate == 0)
    {
        g_iServerTickrate   = RoundToNearest(1.0 / GetTickInterval());
    }

    /* Grace period after map start — engine is still settling. */
    if (engineNow - SERVER_LAG_MAP_START_WAIT < g_fTimeSinceMapStart)
        return;

    /* Arm the TPS window exactly when the grace period ends.
     * Without this, g_fTPSWindowStart is still 0.0 and the first window
     * closes immediately with a single tick counted, producing a spurious
     * TPS=1 sample that contaminates calibration. */
    if (!g_bTPSWindowArmed)
    {
        g_bTPSWindowArmed  = true;
        g_fTPSWindowStart  = engineNow;
        g_iTicksThisSecond = 0;
        return;
    }

    g_iTicksThisSecond++;

    if (engineNow - 1.0 >= g_fTPSWindowStart)
    {
        g_fTPSWindowStart  = engineNow;
        g_iCurrentTPS      = g_iTicksThisSecond;
        g_iTicksThisSecond = 0;

        /* Calibration phase: measure the server's actual effective TPS. */
        if (g_iEffectiveTPS == 0)
        {
            /* Reject samples that are implausibly low — a sample far below the
             * nominal tickrate means the server was lagging DURING calibration,
             * which would poison the effective TPS. Discard and keep sampling. */
            if (g_iCurrentTPS < RoundToFloor(float(g_iServerTickrate) * SERVER_LAG_CALIB_MIN_RATIO))
                return;

            g_iTPSCalibSum += g_iCurrentTPS;
            g_iTPSCalibSamples++;

            if (g_iTPSCalibSamples >= SERVER_LAG_CALIB_SAMPLES)
                g_iEffectiveTPS = g_iTPSCalibSum / g_iTPSCalibSamples;

            return;
        }

        /* Detect LOW TPS — the stall/tick-drop itself, caught in real time.
         * This is the primary and more reliable signal: a stall guarantees
         * a reduced tick count in the window(s) it overlaps, whereas a
         * compensating catch-up spike afterward is not guaranteed to happen
         * (Source does not necessarily "replay" missed ticks in a burst). */
        int tpsLow = RoundToFloor(float(g_iEffectiveTPS) * SERVER_LAG_TPS_LOW_MULT);

        if (g_iCurrentTPS < tpsLow)
        {
            g_fServerLagPauseUntil = engineNow + SERVER_LAG_PAUSE_SECS;
            g_iTriggerTPS          = g_iCurrentTPS;
        }

        /* Detect HIGH TPS — the catch-up spike after a stall, if one occurs.
         * Kept as a secondary signal alongside the low-TPS check above. */
        int tpsHigh = RoundToCeil(float(g_iEffectiveTPS) * SERVER_LAG_TPS_HIGH_MULT);

        if (g_iCurrentTPS > tpsHigh)
        {
            /* Extend the pause on every qualifying spike, even if a pause is
             * already active — sustained lag with repeated catch-up spikes
             * keeps the detection paused instead of reopening the false-positive
             * window between spikes. */
            g_fServerLagPauseUntil = engineNow + SERVER_LAG_PAUSE_SECS;
            g_iTriggerTPS          = g_iCurrentTPS;
        }
    }
}