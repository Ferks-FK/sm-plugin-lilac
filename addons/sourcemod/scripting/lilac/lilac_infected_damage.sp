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

#define INF_DMG_WINDOW      1.0   /* Rolling window in seconds. */
#define INF_DMG_BUF_SIZE    128    /* Ring buffer slots per player. */

/* L4D2 zombie classes. */
#define L4D2_ZC_SMOKER   1
#define L4D2_ZC_BOOMER   2
#define L4D2_ZC_HUNTER   3
#define L4D2_ZC_SPITTER  4
#define L4D2_ZC_JOCKEY   5
#define L4D2_ZC_CHARGER  6
#define L4D2_ZC_WITCH    7
#define L4D2_ZC_TANK     8

/* Maximum damage per INF_DMG_WINDOW before flagging, indexed by zombie class.
 * 0 disables detection for that class. */
static const int inf_dmg_threshold[9] = {0, 15, 0, 45, 60, 20, 50, 0, 72};

static int lilac_inf_threshold(int zclass)
{
	return (zclass >= 1 && zclass <= 8) ? inf_dmg_threshold[zclass] : 0;
}

/* Tickbase fix: clamp when server tick is this many seconds ahead of m_nTickBase.
 * 2 s is enough to absorb legitimate choke while catching intentional manipulation. */
#define TICKBASE_CLAMP_SECS   2
/* Only log when the gap is this large — clearly intentional, not just high latency. */
#define TICKBASE_LOG_SECS    25

static float inf_dmg_time       [MAXPLAYERS + 1][INF_DMG_BUF_SIZE];
static int   inf_dmg_amount     [MAXPLAYERS + 1][INF_DMG_BUF_SIZE];
static int   inf_dmg_head       [MAXPLAYERS + 1];
static int   inf_dmg_detections [MAXPLAYERS + 1];
static int   inf_dmg_last_tick  [MAXPLAYERS + 1];
static float inf_tbfix_last_log [MAXPLAYERS + 1];

void lilac_infected_damage_reset_client(int client)
{
	inf_dmg_head[client]       = 0;
	inf_dmg_detections[client] = 0;
	inf_dmg_last_tick[client]  = -1;
	inf_tbfix_last_log[client] = 0.0;

	for (int i = 0; i < INF_DMG_BUF_SIZE; i++)
	{
		inf_dmg_time  [client][i] = 0.0;
		inf_dmg_amount[client][i] = 0;
	}
}

public Action event_player_hurt(Event event, const char[] name, bool dontBroadcast)
{
    if (!icvar[CVAR_ENABLE] || !icvar[CVAR_INFECTED_DMG])
        return Plugin_Continue;

    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    int victim   = GetClientOfUserId(GetEventInt(event, "userid"));
    int damage   = GetEventInt(event, "dmg_health");

    if (!is_player_valid(attacker) || IsFakeClient(attacker))
        return Plugin_Continue;

    if (!is_player_valid(victim) || damage <= 0)
        return Plugin_Continue;

    /* Attacker must be infected team (3), victim must be survivor team (2). */
    if (GetClientTeam(attacker) != 3 || GetClientTeam(victim) != 2)
        return Plugin_Continue;

    if (playerinfo_banned_flags[attacker][CHEAT_INFECTED_DMG])
        return Plugin_Continue;

    /* High packet loss can cause burst events — skip to avoid false positives. */
    if (skip_due_to_loss(attacker))
        return Plugin_Continue;

    int zclass    = GetEntProp(attacker, Prop_Send, "m_zombieClass");
    int threshold = lilac_inf_threshold(zclass);

    if (threshold == 0)
        return Plugin_Continue;

    /* Skip hits that share a game tick with the previous recorded hit.
    * A single punch/swing can hit multiple survivors simultaneously (same tick),
    * which would multiply the damage count unfairly. Burst attacks via tickbase
    * manipulation are intercepted before reaching this point by lilac_tickbase_fix. */
    int current_tick = GetGameTickCount();
    if (current_tick == inf_dmg_last_tick[attacker])
        return Plugin_Continue;
    inf_dmg_last_tick[attacker] = current_tick;

    /* Tank: skip single hits above max punch damage — thrown objects cause much higher damage. */
    if (zclass == L4D2_ZC_TANK && damage > 30)
        return Plugin_Continue;

    /* Store this hit in the ring buffer. */
    float now = GetGameTime();
    int   slot = inf_dmg_head[attacker];

    inf_dmg_time  [attacker][slot] = now;
    inf_dmg_amount[attacker][slot] = damage;
    inf_dmg_head  [attacker]       = (slot + 1) % INF_DMG_BUF_SIZE;

    /* Sum all hits that fall inside the rolling window. */
    int total = 0;

    for (int i = 0; i < INF_DMG_BUF_SIZE; i++)
    {
        if (inf_dmg_time[attacker][i] > 0.0
            && now - inf_dmg_time[attacker][i] <= INF_DMG_WINDOW)
        {
            total += inf_dmg_amount[attacker][i];
        }
    }

    if (total > threshold)
        lilac_infected_damage_flag(attacker, victim, zclass, total, damage, threshold);

    return Plugin_Continue;
}

static void lilac_infected_damage_flag(int attacker, int victim, int zclass, int total, int last_hit, int threshold)
{
	if (lilac_forward_allow_cheat_detection(attacker, CHEAT_INFECTED_DMG) == false)
		return;

	/* Reset the window after flagging so a single burst doesn't keep firing. */
	for (int i = 0; i < INF_DMG_BUF_SIZE; i++)
	{
		inf_dmg_time  [attacker][i] = 0.0;
		inf_dmg_amount[attacker][i] = 0;
	}

	CreateTimer(600.0, timer_decrement_infected_dmg, GetClientUserId(attacker),
		TIMER_FLAG_NO_MAPCHANGE);

	++inf_dmg_detections[attacker];

	char class_name[16];
	switch (zclass)
	{
		case L4D2_ZC_SMOKER:  strcopy(class_name, sizeof(class_name), "Smoker");
		case L4D2_ZC_HUNTER:  strcopy(class_name, sizeof(class_name), "Hunter");
		case L4D2_ZC_SPITTER: strcopy(class_name, sizeof(class_name), "Spitter");
		case L4D2_ZC_JOCKEY:  strcopy(class_name, sizeof(class_name), "Jockey");
		case L4D2_ZC_CHARGER: strcopy(class_name, sizeof(class_name), "Charger");
		case L4D2_ZC_TANK:    strcopy(class_name, sizeof(class_name), "Tank");
		default:              strcopy(class_name, sizeof(class_name), "Unknown");
	}

	char sDetails[256];
	Format(sDetails, sizeof(sDetails),
		"Detection: %d | Class: %s | DmgInWindow: %d | Threshold: %d | LastHit: %d | Victim: %N",
		inf_dmg_detections[attacker], class_name, total,
		threshold, last_hit, victim);

	lilac_save_player_details(attacker, sDetails);
	lilac_forward_client_cheat(attacker, CHEAT_INFECTED_DMG);

	/* First detection: only forward, don't warn or log yet.
	 * A single spike can happen on high-loss servers. */
	if (inf_dmg_detections[attacker] < 2)
		return;

	if (icvar[CVAR_CHEAT_WARN])
		lilac_warn_admins(attacker, CHEAT_INFECTED_DMG, inf_dmg_detections[attacker]);

	if (icvar[CVAR_LOG])
	{
		lilac_log_setup_client(attacker);
		Format(line_buffer, sizeof(line_buffer),
			"%s is suspected of using an infected damage exploit (%s).",
			line_buffer, sDetails);

		lilac_log(true);

		if (icvar[CVAR_LOG_EXTRA] == 2)
			lilac_log_extra(attacker);
	}

	database_log(attacker, "infected_damage", inf_dmg_detections[attacker],
		float(total), float(threshold));

	if (inf_dmg_detections[attacker] >= icvar[CVAR_INFECTED_DMG]
		&& icvar[CVAR_INFECTED_DMG] >= INFECTED_DMG_BAN_MIN)
	{
		if (icvar[CVAR_LOG])
		{
			lilac_log_setup_client(attacker);
			Format(line_buffer, sizeof(line_buffer),
				"%s was banned for using an infected damage exploit.", line_buffer);

			lilac_log(true);

			if (icvar[CVAR_LOG_EXTRA])
				lilac_log_extra(attacker);
		}

		database_log(attacker, "infected_damage", DATABASE_BAN);

		playerinfo_banned_flags[attacker][CHEAT_INFECTED_DMG] = true;
		lilac_ban_client(attacker, CHEAT_INFECTED_DMG);
	}
}

public Action timer_decrement_infected_dmg(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);

	if (is_player_valid(client) && inf_dmg_detections[client] > 0)
		inf_dmg_detections[client]--;

	return Plugin_Continue;
}

/* Called from OnPlayerRunCmd every usercmd. Resets m_nTickBase when a client has
 * accumulated more ticks than TICKBASE_CLAMP_SECS allows, preventing burst-attack
 * exploits that bypass cooldown enforcement in RunCmd. */
void lilac_tickbase_fix(int client)
{
	if (!icvar[CVAR_ENABLE] || !icvar[CVAR_INFECTED_DMG])
		return;

	if (!IsPlayerAlive(client))
		return;

	int serverTick = GetGameTickCount();
	int diff       = serverTick - GetEntProp(client, Prop_Send, "m_nTickBase");

	if (diff <= tick_rate * TICKBASE_CLAMP_SECS)
		return;

	SetEntProp(client, Prop_Send, "m_nTickBase", serverTick);

	if (!icvar[CVAR_LOG] || diff <= tick_rate * TICKBASE_LOG_SECS)
		return;

	float now = GetGameTime();
	if (now - inf_tbfix_last_log[client] < 5.0)
		return;

	inf_tbfix_last_log[client] = now;
	lilac_log_setup_client(client);
	Format(line_buffer, sizeof(line_buffer),
		"%s tickbase manipulation: %d ticks (%.1fs) ahead. Clamped.",
		line_buffer, diff, float(diff) * GetTickInterval());
	lilac_log(true);
}