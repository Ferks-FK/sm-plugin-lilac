/*
	Little Anti-Cheat
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

/*
	Survivor burst-damage exploit detector.

	Motivated by a confirmed case (player banned for bhop, unrelated demo
	review turned this up separately) where a cheat turned a silenced SMG
	into a rapid multi-pellet burst — dozens of "bullets" landing per tick —
	killing over half a Tank's health in ~3 seconds. Nothing in Lilac
	currently catches that on its own; that player was only caught because
	he also happened to be bhopping at the same time.

	First version of this module tracked damage per VICTIM zombie class
	("did the Tank take more than X damage this second"). Wrong axis: how
	much damage a target received says nothing about whether the WEAPON that
	dealt it is behaving within its physical limits — a shotgun and an SMG
	have completely different legitimate ceilings, and conflating them by
	target class either false-flags a legitimate point-blank shotgun blast
	or misses an SMG doing shotgun-level damage. What actually broke here
	was the weapon: it cycled far faster / hit far more times than it can.

	This version tracks damage per (attacker, weapon) instead: how much
	damage THIS weapon dealt within a rolling window, independent of what it
	hit. That's the direct, weapon-intrinsic signal, and it naturally
	extends to any target (survivor or infected) without needing a separate
	threshold per victim class.

	CURRENTLY IN MEASUREMENT MODE, NOT ENFORCEMENT.
	weapon_dmg_threshold below is intentionally empty (no maximums set).
	Restricted to the Tank only for now (see the m_zombieClass check below) —
	keeps volume manageable so this can run during ordinary play instead of
	needing dedicated test sessions. Every qualifying hit is appended to its
	own dedicated file (logs/lilac_survivor_damage_calib.log, see
	lilac_survivor_damage_calib_log() in lilac_stock.sp) with the
	rolling-window total and the highest total ever seen for that weapon, so
	real max-damage numbers can be measured from normal gameplay before any
	ceiling is trusted enough to gate a ban. Once real numbers are gathered:
	  1. Fill in weapon_dmg_threshold with real per-weapon maximums.
	  2. Widen the Tank-only restriction to other classes if they need
	     calibrating too.
	  3. Swap the calibration log call for the commented-out call to
	     lilac_survivor_damage_flag() right below it.
	  4. Re-add the icvar[CVAR_SURVIVOR_DMG] gate at the top of the event
	     handler (left out for now so measurement mode works regardless of
	     that cvar's value).
*/

#define SURV_DMG_WINDOW      1.0   /* Rolling window in seconds. */
#define SURV_DMG_BUF_SIZE    128   /* Ring buffer slots per player. */

/* Per-weapon max plausible damage within SURV_DMG_WINDOW, keyed by weapon
 * classname (e.g. "weapon_smg_silenced"). Populated at runtime once real
 * numbers are measured — see the header comment above. Empty for now: no
 * weapon is checked against a ceiling while in measurement mode. */
static StringMap weapon_dmg_threshold = null;

/* Highest window-total ever observed per weapon this map, purely for the
 * chat readout below ("session max") — not used for any decision. */
static StringMap weapon_dmg_session_max = null;

static float surv_dmg_time      [MAXPLAYERS + 1][SURV_DMG_BUF_SIZE];
static int   surv_dmg_amount    [MAXPLAYERS + 1][SURV_DMG_BUF_SIZE];
static int   surv_dmg_head      [MAXPLAYERS + 1];
static int   surv_dmg_detections[MAXPLAYERS + 1];

/* Weapon the ring buffer above is currently accumulating for. The window is
 * reset whenever the attacker's active weapon changes, so damage from a
 * previous weapon never bleeds into the next one's total — this is what
 * makes the sum a per-weapon figure instead of a per-attacker one. */
static char surv_dmg_weapon[MAXPLAYERS + 1][64];

void lilac_survivor_damage_reset_client(int client)
{
	surv_dmg_head[client]       = 0;
	surv_dmg_detections[client] = 0;
	surv_dmg_weapon[client][0]  = '\0';

	for (int i = 0; i < SURV_DMG_BUF_SIZE; i++)
	{
		surv_dmg_time  [client][i] = 0.0;
		surv_dmg_amount[client][i] = 0;
	}
}

static void lilac_survivor_damage_init_maps()
{
	if (weapon_dmg_threshold == null)
		weapon_dmg_threshold = new StringMap();

	if (weapon_dmg_session_max == null)
		weapon_dmg_session_max = new StringMap();
}

public Action event_player_hurt_survivor_dmg(Event event, const char[] name, bool dontBroadcast)
{
    /* Deliberately NOT also gated on icvar[CVAR_SURVIVOR_DMG] right now —
     * that cvar defaults to 0 (disabled), but measurement mode should work
     * regardless of it so calibration doesn't require flipping a cvar that
     * doesn't do anything meaningful yet. Re-add "|| !icvar[CVAR_SURVIVOR_DMG]"
     * here once this moves to real enforcement. */
    if (!icvar[CVAR_ENABLE])
        return Plugin_Continue;

    lilac_survivor_damage_init_maps();

    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    int victim   = GetClientOfUserId(GetEventInt(event, "userid"));
    int damage   = GetEventInt(event, "dmg_health");

    if (!is_player_valid(attacker) || IsFakeClient(attacker))
        return Plugin_Continue;

    if (!is_player_valid(victim) || damage <= 0)
        return Plugin_Continue;

    /* Attacker must be survivor team (2), victim must be infected team (3). */
    if (GetClientTeam(attacker) != 2 || GetClientTeam(victim) != 3)
        return Plugin_Continue;

    /* Tank only for now — keeps calibration log volume manageable during
     * normal play. Widen this once Tank thresholds are set and other
     * classes need calibrating too. */
    if (GetEntProp(victim, Prop_Send, "m_zombieClass") != L4D2_ZC_TANK)
        return Plugin_Continue;

    // if (playerinfo_banned_flags[attacker][CHEAT_SURVIVOR_DMG])
    //     return Plugin_Continue;

    /* High packet loss can cause burst events — skip to avoid false positives. */
    if (skip_due_to_loss(attacker))
        return Plugin_Continue;

    char weapon[64];
    if (!GetClientWeapon(attacker, weapon, sizeof(weapon)) || weapon[0] == '\0')
        return Plugin_Continue;

    /* Weapon changed since the last recorded hit — start a fresh window
     * instead of mixing damage from two different weapons into one sum. */
    if (!StrEqual(weapon, surv_dmg_weapon[attacker]))
    {
        strcopy(surv_dmg_weapon[attacker], sizeof(surv_dmg_weapon[]), weapon);

        for (int i = 0; i < SURV_DMG_BUF_SIZE; i++)
        {
            surv_dmg_time  [attacker][i] = 0.0;
            surv_dmg_amount[attacker][i] = 0;
        }

        surv_dmg_head[attacker] = 0;
    }

    /* Hits are NOT deduplicated by game tick here (unlike
     * lilac_infected_damage.sp). A shotgun's pellets — or the exploit this
     * module exists to catch — legitimately land as several separate hits
     * within the same tick, and that IS the pattern being measured.
     * Collapsing same-tick hits into one would hide the signal instead of
     * catching it. */

    /* Store this hit in the ring buffer. */
    float now = GetGameTime();
    int   slot = surv_dmg_head[attacker];

    surv_dmg_time  [attacker][slot] = now;
    surv_dmg_amount[attacker][slot] = damage;
    surv_dmg_head  [attacker]       = (slot + 1) % SURV_DMG_BUF_SIZE;

    /* Sum all hits dealt with THIS weapon that fall inside the rolling
     * window (no mixing with other weapons — see the reset above). */
    int total = 0;

    for (int i = 0; i < SURV_DMG_BUF_SIZE; i++)
    {
        if (surv_dmg_time[attacker][i] > 0.0
            && now - surv_dmg_time[attacker][i] <= SURV_DMG_WINDOW)
        {
            total += surv_dmg_amount[attacker][i];
        }
    }

    /* ===== Measurement mode: log to a dedicated file instead of flagging ===== */
    int sessionMax = 0;
    weapon_dmg_session_max.GetValue(weapon, sessionMax);

    if (total > sessionMax)
    {
        sessionMax = total;
        weapon_dmg_session_max.SetValue(weapon, sessionMax);
    }

    lilac_survivor_damage_calib_log(attacker, weapon, damage, total, sessionMax, GetClientHealth(victim));

    int threshold = 0;
    weapon_dmg_threshold.GetValue(weapon, threshold);

    // if (threshold > 0 && total > threshold)
    //     lilac_survivor_damage_flag(attacker, victim, weapon, total, damage, threshold);

    return Plugin_Continue;
}

/* Full detection/ban pipeline — written and ready, mirrors
 * lilac_infected_damage_flag's structure, but not currently called anywhere
 * (see event_player_hurt_survivor_dmg above). */
static void lilac_survivor_damage_flag(int attacker, int victim, const char[] weapon, int total, int last_hit, int threshold)
{
	if (lilac_forward_allow_cheat_detection(attacker, CHEAT_SURVIVOR_DMG) == false)
		return;

	/* Reset the window after flagging so a single burst doesn't keep firing. */
	for (int i = 0; i < SURV_DMG_BUF_SIZE; i++)
	{
		surv_dmg_time  [attacker][i] = 0.0;
		surv_dmg_amount[attacker][i] = 0;
	}

	CreateTimer(600.0, timer_decrement_survivor_dmg, GetClientUserId(attacker),
		TIMER_FLAG_NO_MAPCHANGE);

	++surv_dmg_detections[attacker];

	char sDetails[256];
	Format(sDetails, sizeof(sDetails),
		"Detection: %d | Weapon: %s | DmgInWindow: %d | Threshold: %d | LastHit: %d | Victim: %N",
		surv_dmg_detections[attacker], weapon, total,
		threshold, last_hit, victim);

	lilac_save_player_details(attacker, sDetails);
	lilac_forward_client_cheat(attacker, CHEAT_SURVIVOR_DMG);

	/* First detection: only forward, don't warn or log yet.
	 * A single spike can happen on high-loss servers. */
	if (surv_dmg_detections[attacker] < 2)
		return;

	if (icvar[CVAR_CHEAT_WARN])
		lilac_warn_admins(attacker, CHEAT_SURVIVOR_DMG, surv_dmg_detections[attacker]);

	if (icvar[CVAR_LOG])
	{
		lilac_log_setup_client(attacker);
		Format(line_buffer, sizeof(line_buffer),
			"%s is suspected of using a survivor damage exploit (%s).",
			line_buffer, sDetails);

		lilac_log(true);

		if (icvar[CVAR_LOG_EXTRA] == 2)
			lilac_log_extra(attacker);
	}

	database_log(attacker, "survivor_damage", surv_dmg_detections[attacker],
		float(total), float(threshold));

	if (surv_dmg_detections[attacker] >= icvar[CVAR_SURVIVOR_DMG]
		&& icvar[CVAR_SURVIVOR_DMG] >= SURVIVOR_DMG_BAN_MIN)
	{
		if (icvar[CVAR_LOG])
		{
			lilac_log_setup_client(attacker);
			Format(line_buffer, sizeof(line_buffer),
				"%s was banned for using a survivor damage exploit.", line_buffer);

			lilac_log(true);

			if (icvar[CVAR_LOG_EXTRA])
				lilac_log_extra(attacker);
		}

		database_log(attacker, "survivor_damage", DATABASE_BAN);

		playerinfo_banned_flags[attacker][CHEAT_SURVIVOR_DMG] = true;
		lilac_ban_client(attacker, CHEAT_SURVIVOR_DMG);
	}
}

public Action timer_decrement_survivor_dmg(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);

	if (is_player_valid(client) && surv_dmg_detections[client] > 0)
		surv_dmg_detections[client]--;

	return Plugin_Continue;
}
