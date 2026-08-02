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
	Network safety veto.

	Only used by modules whose analysis depends on the order and timing of
	consecutive usercmds: aimbot and aimlock. Speedhack counts commands per
	second and infected damage checks damage values — neither is distorted
	by latency or jitter, so both keep using skip_due_to_loss().
*/

void lilac_network_reset_client(int client)
{
	playerinfo_net_index[client] = 0;
	playerinfo_net_count[client] = 0;

	for (int i = 0; i < NET_SAMPLES; i++) {
		playerinfo_net_ping[client][i] = 0.0;
		playerinfo_net_valid[client][i] = false;
	}
}

public Action timer_sample_network(Handle timer)
{
	if (!icvar[CVAR_ENABLE])
		return Plugin_Continue;

	for (int i = 1; i <= MaxClients; i++) {
		if (!is_player_valid(i) || IsFakeClient(i))
			continue;

		int idx = playerinfo_net_index[i];
		float ping = GetClientAvgLatency(i, NetFlow_Outgoing) * 1000.0;

		/* reject negatives and absurd values. */
		playerinfo_net_valid[i][idx] = (ping >= 0.0 && ping < 10000.0);
		playerinfo_net_ping[i][idx] = ping;

		if (++playerinfo_net_index[i] >= NET_SAMPLES)
			playerinfo_net_index[i] = 0;

		if (playerinfo_net_count[i] < NET_SAMPLES)
			playerinfo_net_count[i]++;
	}

	return Plugin_Continue;
}

/* Mean absolute variation between consecutive ping samples.
 * The engine does not expose jitter, so it is derived from our own sampling.
 * Returns -1.0 when there is not enough contiguous valid data. */
float lilac_network_get_jitter(int client)
{
	float total = 0.0;
	float last = -1.0;
	int pairs = 0;
	int n = playerinfo_net_count[client];

	if (n < 2)
		return -1.0;

	/* Walk oldest to newest. */
	int start = (n < NET_SAMPLES) ? 0 : playerinfo_net_index[client];

	for (int k = 0; k < n; k++) {
		int i = (start + k) % NET_SAMPLES;

		if (!playerinfo_net_valid[client][i]) {
			last = -1.0; /* a gap breaks the chain */
			continue;
		}

		if (last >= 0.0) {
			total += FloatAbs(playerinfo_net_ping[client][i] - last);
			pairs++;
		}

		last = playerinfo_net_ping[client][i];
	}

	return (pairs > 0) ? (total / float(pairs)) : -1.0;
}

float lilac_network_get_max_ping(int client)
{
	float max = 0.0;

	for (int k = 0; k < playerinfo_net_count[client]; k++) {
		if (playerinfo_net_valid[client][k] && playerinfo_net_ping[client][k] > max)
			max = playerinfo_net_ping[client][k];
	}

	return max;
}

int lilac_network_get_invalid_count(int client)
{
	int invalid = 0;

	for (int k = 0; k < playerinfo_net_count[client]; k++) {
		if (!playerinfo_net_valid[client][k])
			invalid++;
	}

	return invalid;
}

/* Numbers behind the decision, so an admin can see why a detection
 * was not trusted — and so thresholds can be recalibrated from real data. */
void lilac_network_format(int client, char[] buffer, int maxlen)
{
	FormatEx(buffer, maxlen,
		"Ping: %.0f | Jitter: %.1f | Loss: %.1f/%.1f | Choke: %.1f/%.1f | BadSamples: %d",
		lilac_network_get_max_ping(client),
		lilac_network_get_jitter(client),
		GetClientAvgLoss(client, NetFlow_Incoming) * 100.0,
		GetClientAvgLoss(client, NetFlow_Outgoing) * 100.0,
		GetClientAvgChoke(client, NetFlow_Incoming) * 100.0,
		GetClientAvgChoke(client, NetFlow_Outgoing) * 100.0,
		lilac_network_get_invalid_count(client));
}

/* True when the connection makes timing-based analysis unreliable. */
bool lilac_network_vetoed(int client)
{
	if (!icvar[CVAR_NET_VETO])
		return false;

	/* Not enough data yet. */
	if (playerinfo_net_count[client] < 2)
		return true;

	if (lilac_network_get_invalid_count(client) > 0)
		return true;

	float jitter = lilac_network_get_jitter(client);

	if (jitter < 0.0 || jitter >= NET_MAX_JITTER)
		return true;

	if (lilac_network_get_max_ping(client) >= NET_MAX_PING)
		return true;

	if (GetClientAvgLoss(client, NetFlow_Incoming) >= NET_MAX_LOSS
		|| GetClientAvgLoss(client, NetFlow_Outgoing) >= NET_MAX_LOSS)
		return true;

	if (GetClientAvgChoke(client, NetFlow_Incoming) >= NET_MAX_CHOKE
		|| GetClientAvgChoke(client, NetFlow_Outgoing) >= NET_MAX_CHOKE)
		return true;

	return false;
}