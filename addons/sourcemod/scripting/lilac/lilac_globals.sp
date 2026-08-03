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

#define NATIVE_EXISTS(%0)   (GetFeatureStatus(FeatureType_Native, %0) == FeatureStatus_Available)
#define UPDATE_URL          "https://raw.githubusercontent.com/Ferks-FK/sm-plugin-lilac/refs/heads/master/updatefile.txt"

#define CMD_LENGTH   330

#define CVAR_ENABLE                 0
#define CVAR_WELCOME                1
#define CVAR_SB                     2
#define CVAR_MA                     3
#define CVAR_AR                     4
#define CVAR_LOG                    5
#define CVAR_LOG_EXTRA              6
#define CVAR_LOG_MISC               7
#define CVAR_LOG_DATE               8
#define CVAR_BAN                    9
#define CVAR_BAN_LENGTH             10
#define CVAR_BAN_LANGUAGE          11
#define CVAR_CHEAT_WARN            12
#define CVAR_ANGLES                13
#define CVAR_PATCH_ANGLES          14
#define CVAR_CHAT                  15
#define CVAR_CONVAR                16
#define CVAR_NOLERP                17
#define CVAR_BHOP                  18
#define CVAR_AIMBOT                19
#define CVAR_AIMBOT_AUTOSHOOT      20
#define CVAR_AIMLOCK               21
#define CVAR_AIMLOCK_LIGHT         22
#define CVAR_BACKTRACK_PATCH       23
#define CVAR_BACKTRACK_TOLERANCE   24
#define CVAR_MAX_PING              25
#define CVAR_MAX_PING_SPEC         26
#define CVAR_MAX_LERP              27
#define CVAR_MACRO                 28
#define CVAR_MACRO_WARNING         29
#define CVAR_MACRO_DEAL_METHOD     30
#define CVAR_MACRO_MODE            31
#define CVAR_FILTER_NAME           32
#define CVAR_FILTER_CHAT           33
#define CVAR_LOSS_FIX              34
#define CVAR_AUTO_UPDATE           35
#define CVAR_SOURCEIRC             36
#define CVAR_DATABASE              37
#define CVAR_SPEEDHACK             38
#define CVAR_INFECTED_DMG          39
#define CVAR_NET_VETO              40
#define CVAR_MAX                   41

#define BHOP_INDEX_MIN     0
#define BHOP_INDEX_JUMP    1
#define BHOP_INDEX_MAX     2
#define BHOP_INDEX_TOTAL   3
#define BHOP_INDEX_AIR     4
#define BHOP_MAX           5

#define BHOP_MODE_DISABLED     0
#define BHOP_MODE_RESERVED_1   1
#define BHOP_MODE_RESERVED_2   2
#define BHOP_MODE_CUSTOM       3
#define BHOP_MODE_LOW          4
#define BHOP_MODE_MEDIUM       5
#define BHOP_MODE_HIGH         6

#define MACRO_LOG_LENGTH   200

#define MACRO_AUTOJUMP    0
#define MACRO_AUTOSHOOT   1
#define MACRO_ARRAY       2

#define ACTION_SHOT   1

#define QUERY_MAX_FAILURES   24
#define QUERY_TIMEOUT        30
#define QUERY_TIMER          5.0

#define AIMLOCK_BAN_MIN   5

#define INFECTED_DMG_BAN_MIN 3

#define AIMBOT_BAN_MIN           5
#define AIMBOT_MAX_TOTAL_DELTA   (180.0 * 2.5)
#define AIMBOT_FLAG_REPEAT       (1 << 0)
#define AIMBOT_FLAG_AUTOSHOOT    (1 << 1)
#define AIMBOT_FLAG_SNAP         (1 << 2)
#define AIMBOT_FLAG_SNAP2        (1 << 3)
#define AIMBOT_FLAG_SMOOTH       (1 << 4) /* Monotonic convergence: counters AimStep-style evasion. */
#define AIMBOT_FLAG_JITTER       (1 << 5) /* High pre-shot angle variance combined with an accurate shot. */

#define SPEEDHACK_BAN_MIN    5
#define SPEEDHACK_CMD_RATIO  1.9 /* Flag if cmds/sec > tickrate * this value. */

/* Network safety veto. This is not a detector: it suppresses punishment when
 * the connection makes timing-based analysis unreliable. Aggregation is by
 * maximum, not mean — a single spike inside the window is enough to
 * distrust the sample. */
#define NET_SAMPLES      50      /* 50 samples @ 10Hz = 5 second window */
#define NET_MAX_PING     150.0
#define NET_MAX_JITTER   25.0
#define NET_MAX_LOSS     0.02
#define NET_MAX_CHOKE    0.02

#define STRFLAG_NEWLINE          (1 << 0) /* Carriage return or Newline. */
#define STRFLAG_WIDE_CHAR_SPAM   (1 << 1) /* Lots of wide character spam. */

#define DATABASE_BAN 0
#define DATABASE_KICK -1
#define DATABASE_LOG_ONLY -2

#define TICKBASE_CLAMP_SECS   2
#define TICKBASE_LOG_SECS    25

#define PLUGIN_NAME      "[Lilac] Little Anti-Cheat"
#define PLUGIN_AUTHOR    "J_Tanzanite, Ferks-FK"
#define PLUGIN_DESC      "An opensource Anti-Cheat"
#define PLUGIN_VERSION   "1.8.3"
#define PLUGIN_URL       "https://github.com/J-Tanzanite/Little-Anti-Cheat"

/* Set to 0 to remove all shadow-metric code from the build. */
#define LILAC_ANGLE_METRIC_DEBUG 1

// ============================================================
// Server lag detection
// ============================================================
#define SERVER_LAG_TPS_HIGH_MULT    1.5
#define SERVER_LAG_TPS_LOW_MULT     0.75 // tickspersec below rolling baseline*this = stall/tick-drop
#define SERVER_LAG_PAUSE_SECS       5.0
#define SERVER_LAG_MAP_START_WAIT   15.0
#define SERVER_LAG_CALIB_SAMPLES    15   // seconds of seeding before the rolling baseline goes live
#define SERVER_LAG_CALIB_MIN_RATIO  0.5  // seed samples below nominal*this are rejected
#define SERVER_LAG_BASELINE_ALPHA   0.05 // EWMA weight per healthy window (~20s to fully track a new sustained level)

// TPS counting
int   g_iTicksThisSecond = 0;
float g_fTPSWindowStart   = 0.0;
int   g_iCurrentTPS       = 0;
int   g_iTriggerTPS       = 0;
int   g_iServerTickrate   = 0;

// Rolling baseline — the ongoing "recent normal" TPS. Seeded once via a short
// calibration after map start, then EWMA-updated every window that wasn't
// itself flagged as anomalous, so it drifts to match sustained load changes
// (more players, heavier map) without needing a hand-tuned fixed number.
float g_fTPSBaselineEWMA  = 0.0;
int   g_iTPSCalibSum      = 0;
int   g_iTPSCalibSamples  = 0;

// Lag pause state
float g_fTimeSinceMapStart   = 0.0;
float g_fServerLagPauseUntil = 0.0;
bool  g_bServerLagLogged     = false;

// Tracks whether the TPS window has been armed after the grace period.
bool  g_bTPSWindowArmed      = false;

// Tracks whether the server is currently in a lag pause state.
float g_flTickbaseLastLog[MAXPLAYERS + 1];

/* Convars. */
Convar hcvar[CVAR_MAX]; /* ConVar = built in SourceMod  |  Convar = kidfearless's convar_class */
int icvar[CVAR_MAX];
int sv_cheats = 0;
int time_sv_cheats = 0;
int force_disable_bhop = 0;

/* Banlength overwrite. */
int ban_length_overwrite[CHEAT_MAX];

/* Database. */
Database lil_db;
char sql_buffer[1500]; /* It's probably bigger than what you need, but better be safe than sorry I guess. */
char db_name[64]; /* Database config name from hcvar[CVAR_DATABASE]. */

/* Misc. */
EngineVersion g_bGame;

int tick_rate;
int macro_max;
int bhop_settings[BHOP_MAX];
int bhop_settings_min[BHOP_MAX];

char line_buffer[2048];
char dateformat[512] = "%Y/%m/%d %H:%M:%S";
char log_file[PLATFORM_MAX_PATH];
char smooth_telemetry_log_file[PLATFORM_MAX_PATH];
char angle_metric_log_file[PLATFORM_MAX_PATH];
float max_angles[3] = {89.01, 0.0, 50.01};
Handle forwardhandle = INVALID_HANDLE;
Handle forwardhandleban = INVALID_HANDLE;
Handle forwardhandleallow = INVALID_HANDLE;

/* External plugins. */
bool sourcebans_exist = false;
bool sourcebanspp_exist = false;
bool materialadmin_exist = false;
bool autorecorder_exist = false;

/* Logging.
 * Todo: Might wanna move a lot of this variables to
 * their own files if they are only used there.
 * Just so the code gets a lot cleaner. */
int playerinfo_index[MAXPLAYERS + 1];
int playerinfo_buttons[MAXPLAYERS + 1][CMD_LENGTH];
int playerinfo_actions[MAXPLAYERS + 1][CMD_LENGTH];
int playerinfo_aimlock_sus[MAXPLAYERS + 1];
int playerinfo_aimlock[MAXPLAYERS + 1];
float playerinfo_time_bumpercart[MAXPLAYERS + 1];
float playerinfo_time_teleported[MAXPLAYERS + 1];
float playerinfo_time_aimlock[MAXPLAYERS + 1];
float playerinfo_time_process_aimlock[MAXPLAYERS + 1];
float playerinfo_angles[MAXPLAYERS + 1][CMD_LENGTH][3];
float playerinfo_time_usercmd[MAXPLAYERS + 1][CMD_LENGTH];
float playerinfo_time_forward[MAXPLAYERS + 1][CHEAT_MAX];
bool playerinfo_banned_flags[MAXPLAYERS + 1][CHEAT_MAX];
char playerinfo_detected[MAXPLAYERS + 1][1024];

float playerinfo_net_ping[MAXPLAYERS + 1][NET_SAMPLES];
bool  playerinfo_net_valid[MAXPLAYERS + 1][NET_SAMPLES];
int   playerinfo_net_index[MAXPLAYERS + 1];
int   playerinfo_net_count[MAXPLAYERS + 1];

/* Forward declarations so we don't need third-party include files. */

#define MA_BAN_STEAM  1

native Function IRC_MsgFlaggedChannels(const char[] flag, const char[] format, any ...);
native Function MABanPlayer(int iClient, int iTarget, int iType, int iTime, char[] sReason);
native Function SBBanPlayer(int client, int target, int time, const char[] reason);
native Function SBPP_BanPlayer(int iAdmin, int iTarget, int iTime, const char[] sReason);
native Function Updater_AddPlugin(const char[] url);
native Function Updater_RemovePlugin();
native bool AR_GetMatchID(char[] matchID, int maxlen);
