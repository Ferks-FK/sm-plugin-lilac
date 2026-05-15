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

static int speedhack_detection[MAXPLAYERS + 1];
float player_avg_choke[MAXPLAYERS + 1];

void lilac_speedhack_reset_client(int client)
{
    speedhack_detection[client] = 0;
    player_avg_choke[client] = 0.0;
}

void lilac_speedhack_update_choke(int client)
{
    player_avg_choke[client] =
        (0.1 * GetClientAvgChoke(client, NetFlow_Incoming)) +
        (0.9 * player_avg_choke[client]);
}

public Action timer_check_speedhack(Handle timer)
{
    if (!icvar[CVAR_ENABLE] || !icvar[CVAR_SPEEDHACK])
        return Plugin_Continue;

    /* Tickrate must be sane to compare against. */
    if (tick_rate <= 0)
        return Plugin_Continue;

    /* Compute once per timer fire — these values are server-wide constants
    * that cannot change between client iterations in the same callback. */
    float now = GetGameTime();

    /* Use sv_maxcmdrate as the baseline if it is higher than tick_rate.
    * Some servers allow clients to send commands above the tickrate
    * (e.g. 66-tick server with sv_maxcmdrate 100). Using only tick_rate
    * as the base would cause false positives for those legitimate players. */
    int baseline = tick_rate;
    ConVar hMaxCmdrate = FindConVar("sv_maxcmdrate");
    if (hMaxCmdrate != null && hMaxCmdrate.IntValue > baseline)
        baseline = hMaxCmdrate.IntValue;

    for (int client = 1; client <= MaxClients; client++) {
        if (!is_player_valid(client) || IsFakeClient(client))
            continue;

        if (playerinfo_banned_flags[client][CHEAT_SPEEDHACK])
            continue;

        /* Player just connected, buffer may not be representative yet. */
        if (GetClientTime(client) < 10.0)
            continue;

        /* Update choke value for the player. */
        lilac_speedhack_update_choke(client);

        if (!IsPlayerAlive(client))
            continue;

        /* High packet loss can cause the server to process queued cmds in
        * bursts, which would trigger false positives. */
        if (skip_due_to_loss(client))
            continue;

        /* Count usercmds processed in the last second. */
        int count = 0;
        int ind = playerinfo_index[client];

        for (int i = 0; i < CMD_LENGTH; i++) {
            ind = wrap_index(ind - 1);

            float t = playerinfo_time_usercmd[client][ind];

            /* Uninitialized slot — stop early. */
            if (t == 0.0)
                break;

            /* Older than 1 second — stop. */
            if (now - t > 1.0)
                break;

            count++;
        }

        /* Flag if the count significantly exceeds what the server allows.
        * The ratio 1.5 gives comfortable clearance for normal variance
        * (e.g., 66 tick → threshold = 99 cmds/sec) while catching
        * even speedfactor=1 (doubles speed → ~132 cmds/sec). */
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

	char sDetails[256];
	Format(sDetails, sizeof(sDetails),
		"Detection: %d | CmdsPerSec: %d | ExpectedMax: ~%d | AvgChoke: %.2f",
		speedhack_detection[client], cmdcount,
		RoundToFloor(float(baseline) * SPEEDHACK_CMD_RATIO),
        player_avg_choke[client]);

	lilac_save_player_details(client, sDetails);
	lilac_forward_client_cheat(client, CHEAT_SPEEDHACK);

	/* Don't log the first detection. */
	if (++speedhack_detection[client] < 2)
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
		&& icvar[CVAR_SPEEDHACK] >= SPEEDHACK_BAN_MIN) {

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
