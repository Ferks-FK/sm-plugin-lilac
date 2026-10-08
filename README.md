# Little Anti-Cheat

Little Anti-Cheat (Lilac) is a free and open source anti-cheat for Source games, and runs on SourceMod.\
It was originally developed by J_Tanzanite, and this repository is a maintained fork of the [SRCDSLAB fork](https://github.com/srcdslab/sm-plugin-lilac), with extra focus on Left 4 Dead 2 servers.\
This Anti-Cheat is by no means perfect, and it is bypassable to some extent, but it should still be helpful in dealing with cheaters :)

Current version: **1.8.5** (see [`updatefile.txt`](updatefile.txt) for the latest release notes).

### Current Cheat Detections:
 - Angle-Cheats (Basic Anti-Aims and Duckspeed).
 - Chat-Clear (When cheaters clear the chat).
 - Basic Invalid ConVar Detector (Checks if clients have sv_cheats turned on and such, with support for exact, range, minimum and maximum values).
 - BunnyHop (Bhop), with Low/Medium/High/Custom presets that adapt to the server tickrate.
 - Basic Projectile and Hitscan Aimbot (including Autoshoot).
 - Basic Aimlock.
 - Speedhack (pauses itself when the server is lagging, see the FAQ).
 - NoLerp.
 - Newlines in names.
 - [L4D2] Infected damage exploit.
 - [L4D2] Survivor burst-damage exploit against the Tank.

### Misc features:
 - Angle-Cheats Patch (Patches Angle-Cheats from working).
 - Max Interp Kicker (Kicks players for attempting to exploit interp (cl_interp 0.5)).
 - Max Ping Kicker (Bans players for having too high ping for 3 minutes, and/or moves them to spectators with a warning (Both disabled by default)).
 - Backtrack Patch (Patches backtrack cheats (Disabled by default)).
 - Macro detection (Disabled by default).
 - Invalid name detection.
 - Invalid characters in chat patch (+ chat clear exploit fix).
 - Network veto: Aimbot, Aimlock and Speedhack detections are ignored while the player's ping, jitter, packet loss or choke make timing-based analysis unreliable.
 - Tickbase correction (players with a tickbase behind the server are clamped, players ahead of it are only logged). A player whose tickbase keeps growing past 5 seconds ahead is no longer ignored by the network veto, and an alert is sent to Discord when it reaches 10 seconds.
 - Ghost-state protection (L4D2): infected players are not checked for Aimlock while they are in ghost state, as spawning/teleporting there faces a survivor and looks like an aimlock.
 - Detection warnings to admins in chat, translated to the language of each player.
 - Discord webhook reports for bans, kicks and suspected detections (Optional, disabled by default, needs the REST in Pawn extension).

### Supported Games:
 - [CS:S] Counter-Strike:Source
 - [L4D2] Left 4 Dead 2
 - [L4D] Left 4 Dead
 - [DoD:S] Day of Defeat: Source

### Untested, but should work in:
 - [HL2:DM] Half-Life 2:DeathMatch

TF2 (use [StAC](https://github.com/sapphonie/StAC-tf2) instead) and CS:GO are no longer supported.

## Installation
1. Download the latest `lilac.smx` from the [releases](https://github.com/Ferks-FK/sm-plugin-lilac/releases) page (or build it yourself, see below) and place it in `addons/sourcemod/plugins/`.
2. Copy the `addons/sourcemod/translations` folder to your server.
3. Restart the server or the map. The config file is created at `cfg/sourcemod/lilac_config.cfg`, where every `lilac_*` ConVar is documented.

The plugin is built with the SourceMod 1.12 compiler by the CI, so SourceMod 1.12 or newer is recommended.

### Building
Compile `addons/sourcemod/scripting/lilac.sp` with `spcomp`. All modules in `addons/sourcemod/scripting/lilac/` are included by that single file.\
The GitHub Actions workflow (`.github/workflows/ci.yml`) does this on every push.

### Updating
Set `lilac_auto_update 1` to let the Updater plugin keep Lilac up to date from this fork. `updatefile.txt` is kept in sync with the version by the CI.

## Configuration
All settings are ConVars. The ones you are most likely to change:

| ConVar | Default | Description |
| --- | --- | --- |
| `lilac_enable` | `1` | Enable Lilac. |
| `lilac_ban` | `1` | Ban cheaters. Set to `0` to test Lilac before fully trusting it with bans. |
| `lilac_ban_length` | `0` | Ban length in minutes (`0` = forever). |
| `lilac_bhop` | `5` | `0` = disabled, `3` = custom (unlocks `lilac_bhop_set`), `4` = low, `5` = medium, `6` = high. Negative values are log-only. |
| `lilac_aimbot` | `5` | `0` = disabled, `1` = log only, `5` or more = ban on n'th detection. |
| `lilac_aimlock` | `10` | `0` = disabled, `1` = log only, `5` or more = ban on n'th detection. |
| `lilac_speedhack` | `3` | `0` = disabled, `1` = log only, `3` or more = ban on n'th detection. |
| `lilac_infected_damage` | `3` | L4D2 only. `0` = disabled, `1` = log only, `3` or more = ban on n'th detection. |
| `lilac_survivor_damage` | `3` | L4D2 only. `0` = disabled, `1` = log only, `3` or more = ban on n'th detection. |
| `lilac_convar` | `1` | `-1` = log only, `0` = disabled, `1` = kick, `2` = ban. |
| `lilac_network_veto` | `1` | Ignore timing-based detections for players with a bad connection. |
| `lilac_macro` | `0` | `-1` = log only, `0` = disabled, `1` = enabled. |
| `lilac_database` | *(empty)* | Database name to log detections to (MySQL and SQLite supported). |
| `lilac_autorecorder` | `0` | Print the MatchID into logs via AutoRecorder, if it is installed. |
| `lilac_discord` | `0` | Discord webhook reports. `0` = disabled, `1` = bans and kicks, `2` = also suspected detections. |
| `lilac_discord_webhook` | *(empty)* | The Discord webhook URL. Keep it private. |

Each ban threshold has a minimum (5 for Aimbot and Aimlock, 3 for Speedhack, Infected damage and Survivor damage), and `1` is always log-only.

### Console commands
 - `lilac_set_ban_length` - Sets custom ban lengths for specific cheats.
 - `lilac_get_bans_length` - Shows the current ban lengths for all cheat types.
 - `lilac_ban_status` - Prints the banning status (which ban backend is being used).
 - `lilac_bhop_set` - Sets custom Bhop settings (needs `lilac_bhop 3`).
 - `lilac_date_list` - Lists the date formatting options for `lilac_log_date`.
 - `lilac_discord_test [ban|kick|suspect]` - Sends a sample report to the Discord webhook, to check it works.

### Discord reports
Lilac can post an embed to a Discord channel for each ban, kick and (optionally) suspected detection, with the player, SteamID64, detection, evidence, punishment, map, server address and MatchID.

1. Install the [REST in Pawn](https://github.com/ErikMinekus/sm-ripext) extension on the server.
2. Create a webhook in your Discord channel (Channel settings, Integrations, Webhooks) and copy its URL.
3. Set `lilac_discord_webhook` to that URL and `lilac_discord` to `1` or `2`.
4. Run `lilac_discord_test` in the server console to check that it works.

Extra ConVars: `lilac_discord_role` (a role ID to mention when a player is banned), `lilac_discord_address` (the `ip:port` to show, if it can't be detected) and `lilac_discord_logo` (an image URL for the icon and thumbnail).\
The player's IP is never sent. Reports are queued and sent slowly to respect Discord's rate limit, and suspected detections are limited to one per player and cheat every minute.\
Without the extension, or without a URL, this feature does nothing.

## FAQ
**Q: What is Autoshoot?**\
A: Autoshoot is when a cheat fires a perfect 1-tick shot.\
It's quite common for cheats to do this when using aimbot.\
Autoshoot detections work by detecting 1-tick perfect shots that lead to a kill twice in a row (Autoshoot will get logged if another aimbot type was detected tho).

You *can* get a false positive for Autoshoot, but that should be very rare.\
It is possible to trigger a false positive if you use "bind mwheeldown/up +attack", as scroll (for some reason) does perfect 1-tick input.\
That said, if someone has to go out of their way to do something stupid and abnormal to get a ban, they've basically asked for it.\
If this is a problem for you, you can set `lilac_aimbot_autoshoot` to `0`.

Important thing to note about Autoshoot, because this feature shoots for you, you cannot tell if someone is using Autoshoot by spectating them, or through STV demos. Autoshoot isn't visible in demos or for spectators.

**Q: What is NoLerp?**\
A: "NoLerp" is when cheats set their interpolation to 0ms (or lower than the minimum possible).\
This is often done to increase their Aimbot accuracy.

**Q: What are Angle-Cheats?**\
A: Angle-Cheats is when a player's view angles are set beyond the limits of the game.\
This is often done to create a desync between their model and hitbox, making it harder to shoot them.\
It can also be done to execute some other exploits.

Note: Lilac currently does not check for yaw, so some desyncs are still possible and not detected.

**Q: Are Macros cheats?**\
A: No.\
Macros are just when a player is using a script to input buttons for them (AutoHotKey for instance), or by using scroll to spam some input.\
This is why Macro detections can only ban for 15 to 60 minutes, and no more.\
Macro detections are by default disabled, because most servers don't care about this, and because they can produce false positives. If you enable them, `lilac_macro -1` (log only) is recommended, and treat the logs as a hint, not as proof.

**Q: Does Lilac ban for high ping?**\
A: Not quite.\
The optional high ping kicker (which is disabled by default) in Lilac bans players for 3 minutes, after that, they can reconnect.\
The reason for this is simple, if you only kicked high ping players, they could instantly reconnect.

**Q: What are the Infected damage and Survivor damage exploits? (L4D2 only)**\
A: Some cheats let a player hit much faster than the game normally allows, dealing a huge amount of damage in a split second.\
These two modules watch for that:

 - **Infected damage** watches special infected (Smoker, Hunter, Spitter, Jockey, Charger and Tank) attacking survivors.
 - **Survivor damage** watches survivors shooting or hitting the Tank.

If a player deals more damage in one second than is possible in a normal game, it counts as a detection.\
The first detection is not logged, and detections are forgotten after 10 minutes, so a single strange moment (like lag) won't get anyone banned.

You can control them with `lilac_infected_damage` and `lilac_survivor_damage`: `0` = disabled, `1` = log only, `3` or more = ban on that detection.

If a legitimate player gets flagged, set the module to log-only and [open an issue](https://github.com/Ferks-FK/sm-plugin-lilac/issues) with the log line attached. This can happen on servers with plugins that change damage or weapon speed.

**Q: Why does Lilac ignore some detections?**\
A: To avoid false positives, some detections are ignored when the player has a bad connection (`lilac_network_veto`, `lilac_loss_fix`), was just teleported or spawned, or is a ghost in L4D2.\
The Speedhack check also pauses itself while the server's own tick rate is abnormal (server lag), which is logged as `speedhack detection paused`.\
Also, the first detection of some modules (like Aimbot and Aimlock) is not logged, to avoid flagging one-off events.

**Q: A detection is banning legitimate players, what can I do?**\
A: Set that module to log-only (`1`, or a negative value for Bhop, Macro, etc.) and check the log and the demo before banning.\
If you think there is a bug, please [open an issue](https://github.com/Ferks-FK/sm-plugin-lilac/issues) with the log lines attached.

## Non-Steam versions / CS:S v34 / CS:S v91 / ETC...
Non-Steam versions (IE: Cracks) **ARE NOT SUPPORTED!**\
I am sorry to say, but non-steam versions aren't supported.\
This is because of technical problems with cracks, as they tend to be of older versions of the game, which means they'll have bugs that can conflict with some cheat detections.\
And I just don't want to support piracy.\
I also just don't want to download sketchy unofficial cracked versions of games...

So Little Anti-Cheat may not work out of the box for cracked versions of games.\
That said, I've decided to be a little helpful based on feedback from others.

For Non-Steam/Cracked version of CS:S (like v34 or v91), Angle-Cheat detections won't work.\
You can fix this by updating these ConVars: `lilac_angles 0` and `lilac_angles_patch 0`.\
These **HAVE** to be disabled.

### Credits / Special Thanks to:
 - J_Tanzanite, for writing the original Little Anti-Cheat.
 - The [SRCDSLAB](https://github.com/srcdslab/sm-plugin-lilac) contributors, whose fork this repository is based on.
 - Azalty, for being (rightly) stubborn regarding an issue and for contributing database logging.
 - foon, for fixing sourcebans++ not working (https://forums.alliedmods.net/showthread.php?p=2689297#post2689297).
 - Bottiger, for fixing this plugin not working in CS:GO and general criticisms.
 - MAGNAT2645 for suggesting a cleaner method of handling convar changes.
 - Larry/LarryBrains for informing me of false Angle-Cheat detections in L4D2.
 - [VintagePC](https://github.com/vintagepc) for SourceIRC support and basepath fix.
 - Erik Minekus, for the [REST in Pawn](https://github.com/ErikMinekus/sm-ripext) extension used by the Discord reports (its include files are bundled).

### Current languages supported:
 - Simplified Chinese (by [RoyZ](https://github.com/RoyZ-CSGO) ^-^, and apples194)
 - Traditional Chinese.
 - Dutch (by snowy UwU OwO EwE).
 - Danish (by kS the Man / ksgoescoding c:).
 - Norwegian (by me, the translations could be better).
 - French (by Rasi / GreenGuyRasi).
 - Finnish (By [Veeti](https://forums.alliedmods.net/member.php?u=317665)).
 - English (by me lol duh hue hue hue).
 - Russian (by an awesome person c:).
 - Czech (by luk27official and someone else).
 - Brazilian Portuguese by [SheepyChris](https://github.com/SheepyChris), [Tiagoquix](https://github.com/Tiagoquix) and [Crashzk](https://github.com/crashzk).
 - German (by two humble nice Germans c:).
 - Spanish (by ALEJANDRO ^-^).
 - Ukrainian (by panikajo ;D).
 - Polish by [qawery](https://github.com/qawery-just-sad).
 - Turkish (by ShiroNje and R3nzTheCodeGOD).
 - Hungarian (by The Solid Lad).
 - Swedish (by Teamkiller324).
 - Latvian (by rcon420).
 - Romanian (by rigE08).


I do hope to add more languages in the future.\
But at least you can add or improve on the translations already provided.\
My friends who did some of the translations were told by me that the translations don't have to be perfect.\
Just understandable to those who don't speak English too well.

### Optional:
 - Sourcebans++
 - MaterialAdmin
 - SourceBans (old)
 - SourceIRC
 - [AutoRecorder](https://github.com/Ferks-FK/sm-plugins/tree/development/autorecorder)
 - REST in Pawn (for Discord reports)
 - Updater

<details>
<summary>See old Closing notes from J_Tanzanite (before SRCDSLAB fork)</summary>

I wish to thank everyone who participated in this project, it's been an interesting ride.\
As fun as it has been, I think it's time to make it official: I quit.

As some can tell, I've become fairly inactive as of late,\
as fun and interesting as this project initially was to me years ago,\
I simply don't wish to work on it anymore. Frankly, games don't interest me anymore, I've moved on.

Originally, I was planning on handing this repo over to someone else to maintain,\
and handing them some of the private detection methods I developed years ago,\
and while I did start that process, I've come to change my mind.

It would be a decision that the users of Lilac had no say in,\
and given that the surface area of attack grows the more people are brought on,\
I decided it would just be best to leave this repo as it is.\
Thus, I've decided to just archive this project.

I've done my fair share, and fixed some wrongs.\
At the end of the day, all projects come to an end at some point,\
and I think this project has served its purpose, at least as far as I've cared to carry it.

## Going forward
If you are still in dire need of an anti-cheat for TF2, look to: github.com/sapphonie/StAC-tf2

While it's not perfect (nothing is), and we have some ideological differences in how we write code - their project is good.\
On the other hand, if you still wish to use Lilac, find a fork of the project that is active by people you trust.\
Or make one yourself, it's easier than you think.

As for the private detection methods?\
I wouldn't worry about it, developers are creative and will figure it out,\
and they'll figure new patterns out too.

Thanks for everything, and farewell.
</details>
