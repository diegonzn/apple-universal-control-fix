# Apple Universal Control Fix: auto-reconnect when Universal Control keeps disconnecting between your MacBook, iMac and other Macs (OpenCore Legacy Patcher friendly)

`uc-watchdog` is a small LaunchAgent that watches Universal Control and **automatically reconnects it when the link to your other Mac drops**, for example between an iMac and a MacBook Pro or MacBook Air. No more opening Terminal to run `killall rapportd sharingd` by hand. Plain bash, no dependencies, no root, no kernel extensions.

It was built for older Macs running a newer macOS through [OpenCore Legacy Patcher](https://github.com/dortania/OpenCore-Legacy-Patcher) (OCLP), where Universal Control technically works but drops again and again. It should help any Mac with the same symptoms.

## Symptoms this fixes

- Universal Control keeps disconnecting; the cursor stops crossing from your iMac or Mac mini to your MacBook, or the other way around.
- The other Mac disappears from **System Settings > Displays** for a while and then comes back, or does not.
- It works right after `killall rapportd sharingd` (or a reboot), then drops again minutes or hours later.
- You use an older Mac (2012 to 2015 era, Bluetooth 4.0) patched with OCLP, paired with a newer Mac.

## Why this exists

On a 2013 iMac running macOS Monterey through OCLP, paired with an Apple Silicon MacBook Pro, Universal Control dropped several times an hour. Reading the unified log showed why:

1. Universal Control only keeps a peer while it keeps hearing that peer's **Bluetooth LE advertisement** (Continuity "Nearby Info"). The old Mac's Bluetooth stack misses those advertisements from time to time.
2. When that happens, UC schedules a *device expiration* (`DISC: Scheduling Device Expiration in 45s`) and then tears the session down (`update connections: [...] -> []`).
3. Sometimes it recovers on its own within seconds. Often it does not, until `rapportd` and `sharingd` (the Continuity daemons that handle device discovery and BLE scanning) are restarted.

Restarting those two daemons by hand works, but you have to notice the drop, open Terminal and type the command, several times a day. This watchdog does that for you, only when it is needed.

## What it does

- Follows the `UniversalControl` log live (`log stream`). It does not poll and uses almost no CPU while idle.
- When the connection list goes empty, it starts a timer.
- If UC reconnects on its own within the **grace period** (5 s by default), it does nothing.
- If not, it restarts `rapportd` and shows a notification. `sharingd` is left alone on this first try, because restarting it also breaks Handoff and Universal Clipboard for several minutes (see [Why sharingd is restarted last](#why-sharingd-is-restarted-last)).
- If the link is still down 20 s later, it restarts `rapportd` **and** `sharingd`, then retries after **1, 2, 5 and then every 10 minutes**, so it does not hammer the system while the other Mac is asleep or away. Retries are silent: you get one notification when the link drops and one more if the other Mac still has not answered after about 8 minutes (usually because it is off or asleep).
- It also watches for two problems where the link stays up but UC gets slow or refuses to cross, and restarts `UniversalControl` when they show up (see [Link storms and memory](#link-storms-and-memory)).
- It logs every drop, fix and reconnection with timestamps to `~/Library/Logs/uc-watchdog.log`.
- launchd starts it at login and restarts it if it ever exits.

## Requirements

- macOS with Universal Control (Monterey 12.3 or later). **Tested on macOS Monterey 12.7.x** (OCLP, iMac 14,x) paired with an Apple Silicon MacBook Pro. Other versions have not been tested yet; see [Compatibility](#compatibility).
- Universal Control already set up and working between your Macs (same Apple ID, Bluetooth and Wi-Fi on, Handoff enabled).
- Install it **on the Mac that loses the connection**, usually the older one. Installing it on both is harmless.

## Install

```bash
git clone https://github.com/diegonzn/apple-universal-control-fix.git
cd apple-universal-control-fix
./install.sh
```

The installer copies the script to `~/.local/bin/uc-watchdog.sh`, installs the LaunchAgent `~/Library/LaunchAgents/local.uc-watchdog.plist` and starts it. It needs no `sudo`.

It also builds a tiny notification helper, `~/.local/share/uc-watchdog/UC Watchdog.app`, so notifications show the UC Watchdog icon instead of the Script Editor one. This needs `swiftc`, which comes with the Command Line Tools (already there if you have `git`). Without it the watchdog falls back to plain notifications. Run `./install.sh` again after changing the script or the settings.

## Usage

There is nothing to do. It runs in the background from login. To see what it is doing:

```bash
tail -f ~/Library/Logs/uc-watchdog.log
```

Example output:

```
2026-09-28 10:54:56 start (grace=5s, storm>60/min, mem>200MB, pid 46377)
2026-09-28 12:46:44 down
2026-09-28 12:46:49 fix #1 (rapportd, down for 5s)
2026-09-28 12:47:25 reconnected after 41s
2026-09-28 14:22:49 down
2026-09-28 14:22:51 reconnected after 2s
2026-09-29 09:46:44 bounce: other Mac rejected the pointer, it came back
2026-09-29 20:27:31 restart UniversalControl: link storm, 7670 link activations in 60s
2026-09-29 22:40:12 restart UniversalControl: memory 721 MB (limit 200 MB)
```

The second drop recovered on its own in 2 s, so the watchdog left it alone. A `fix #2` line reads `(rapportd+sharingd, ...)`: the first restart was not enough.

A `bounce` line means the pointer crossed to the other Mac but that Mac refused it (UC logs `TargetReply status=2 ... REJECTED`), so it jumped back to this screen. The link itself stays up, so the watchdog does not act on it; the line is there so you can match it to what you saw. The reason for the refusal is only logged on the other Mac. To see it, run this there while you reproduce the bounce:

```bash
/usr/bin/log stream --style compact --predicate 'process == "UniversalControl" AND category IN {"EVNT","CONN"}'
```

Check that it is running:

```bash
launchctl print gui/$(id -u)/local.uc-watchdog | grep state
```

## Configuration

Edit the `EnvironmentVariables` block in `uc-watchdog.plist`, then run `./install.sh` again.

| Variable | Default | Meaning |
|---|---|---|
| `UC_GRACE` | `5` | Seconds to wait for UC to recover on its own before restarting the daemons |
| `UC_NOTIFY` | `1` | `1` notifies when the link drops and once more if it stays down, `0` stays silent |
| `UC_STORM_MAX` | `60` | Rapport link activations per minute that count as a link storm (normal is a handful) |
| `UC_MEM_MAX` | `200` | MB of memory for the `UniversalControl` process before it gets restarted (normal is 20 to 40) |
| `UC_LOG` | `~/Library/Logs/uc-watchdog.log` | Log file path |

About `UC_GRACE`: in real use, only 5 of 21 drops recovered on their own (in 1, 1, 2, 9 and 14 s); the other 16 needed the fix anyway. By the time UC reports the drop it has already missed the other Mac's BLE advertisements for 45 s, so waiting longer rarely pays off: each second of grace is added to almost every real drop. 5 s still covers the quick self-recoveries, and restarting the daemons while the link is already down does no harm. Raise it if you see `fix` lines for drops that would have recovered on their own.

## Uninstall

```bash
./uninstall.sh
```

This removes the LaunchAgent, the script and the notification helper. It keeps the logs.

## How it works

The script matches two kinds of lines from `UniversalControl` (category `CONN`):

| Log line | Meaning |
|---|---|
| `... update connections: [XXXXXXXX (disconnecting)] -> []` | The peer is gone: start the timer |
| `... update connections: [XXXXXXXX (connecting)] -> [XXXXXXXX (connected)]` | The peer is back: reset |

Fix #1 is `killall rapportd`. Fix #2 and later are `killall rapportd sharingd`. Both daemons run as your user, and launchd restarts them at once. `log stream` feeds a FIFO so the loop can read with a timeout and detect if the stream dies (bash 3.2's `read -t` cannot tell a timeout from EOF). If the stream dies, the script exits and launchd starts it again.

### Why sharingd is restarted last

`sharingd` is not only part of Universal Control: it also runs Handoff, AirDrop and Universal Clipboard. Every time it restarts, the other Mac has to ask it again for the Handoff encryption key. Twice in one day that exchange failed for about 10 minutes (`sharingd` answered `Not wrapping key as wrapping key is unavailable` to 10 to 20 requests per minute), and during those minutes copy and paste between the Macs did not work at all. Restarting `rapportd` alone does not have that side effect, so the watchdog tries that first and only adds `sharingd` if the link is still down 20 s later.

### Link storms and memory

The watchdog also counts one more kind of log line: `Activated: CLinkClient` (subsystem `com.apple.rapport`), written each time `UniversalControl` opens a rapport link. Normally that is a few per hour. On one afternoon it was thousands per minute: a third Mac on the same Apple ID (a 2012 MacBook Pro with Universal Control turned off but Handoff on) was nearby, and `UniversalControl` tried to open a link to it, failed with `No device`, got a new discovery callback and tried again, in a loop. `rapportd` sat at 80 % CPU, the pointer took seconds to cross and keys got stuck on the other Mac. The link itself never dropped, so the old watchdog did nothing.

Two checks run once a minute:

| Check | Default | Action |
|---|---|---|
| Link activations in the last 60 s above `UC_STORM_MAX` | 60 | Restart `rapportd` and `UniversalControl` |
| `UniversalControl` memory above `UC_MEM_MAX` | 200 MB | Restart `UniversalControl` (it grew to 721 MB after a storm, from a normal 20 to 40 MB) |

`UniversalControl` is restarted with `launchctl kickstart -k gui/$UID/com.apple.ensemble`, the launchd job that owns it, so it comes back at once. These restarts happen at most once every 10 minutes and are logged as `restart UniversalControl: ...`. If UC has not reconnected 2 minutes after such a restart, the watchdog treats it as a normal drop. The lasting fix for a storm is to turn Handoff off on the third Mac, or to sign it out of iCloud.

## Real-world results

First six hours on the 2013 iMac:

| | |
|---|---|
| Drops detected | 12 |
| Recovered on their own before the grace period | 5 (1 to 14 s) |
| Needed the fix | 7, all fixed on the **first attempt** |
| Time to reconnect after the fix | 2 to 40 s, usually under 10 s |

## Why some reconnects take 20 to 40 seconds

After the fix, the Wi-Fi peer-to-peer link (AWDL) between the Macs comes back within about 2 seconds. Even so, Universal Control does not reconnect until `sharingd` has **identified a fresh BLE advertisement from the other Mac** that reports its activity level (screen on). Until then the peer shows up as `AL Unknown(0)` and UC waits. On an old Bluetooth 4.0 radio, catching that advertisement can take 2 to 40 seconds. Restarting again would not help, because it would only restart that wait.

## Things that did not help

- **`killall universalcontrold`**: on Monterey that process does not exist. The process is called `UniversalControl`. Restarting it does not help a normal drop; it is only needed after a link storm or when it has bloated (see above).
- **`killall useractivityd`**: it ignores the signal (same PID before and after), so it has no effect.
- **Software KVMs (Barrier, Synergy)** as a replacement: problems with Accessibility (TCC) permissions, SSL certificates and mDNS on machines with several network interfaces. Not worth it.

**Tip that did help:** move Bluetooth keyboards and mice to a cable or a USB receiver. An old Bluetooth 4.0 radio shared with input devices misses more Continuity advertisements.

## Functional requirements

| ID | Requirement |
|---|---|
| FR-1 | Detect a Universal Control disconnect from the unified log within 5 s of it being logged. |
| FR-2 | Take no action if UC reconnects on its own within `UC_GRACE` seconds. |
| FR-3 | After `UC_GRACE` seconds down, restart `rapportd` only. If still down 20 s later, restart `rapportd` and `sharingd`. |
| FR-4 | While still down, keep retrying with backoff: 60 s, 120 s, 300 s, then every 600 s. |
| FR-11 | Count rapport link activations per minute; above `UC_STORM_MAX`, restart `rapportd` and `UniversalControl`, at most once every 10 min. |
| FR-12 | Check `UniversalControl` memory once a minute; above `UC_MEM_MAX` MB, restart it, at most once every 10 min. |
| FR-5 | Reset the retry counter once UC reports a connected peer. |
| FR-6 | Log start, drop, fix and reconnection events with timestamps, and cap the log near 1 MB. |
| FR-7 | Optionally show a macOS notification on the first fix of an outage and once more when retries slow to every 10 min (`UC_NOTIFY`), with the UC Watchdog icon when the helper could be built. |
| FR-8 | Start at login and restart automatically if the process or the log stream dies. |
| FR-9 | Run as the logged-in user: no root, no third-party dependencies, only the tools that ship with macOS (bash 3.2). |
| FR-10 | Install and uninstall with a single command each. |

## Acceptance criteria

| ID | Given / When / Then |
|---|---|
| AC-1 | **Given** the watchdog is installed, **when** the user logs in, **then** `launchctl print gui/$(id -u)/local.uc-watchdog` shows `state = running` and the log shows `start`. |
| AC-2 | **Given** UC is connected, **when** the peer drops and comes back within 5 s, **then** the log shows `down` and `reconnected`, and no `fix`. |
| AC-3 | **Given** UC is connected, **when** the peer stays down for 5 s, **then** the log shows `fix #1 (rapportd, ...)`, `rapportd` gets a new PID and `sharingd` keeps its PID. |
| AC-4 | **Given** fix #1 did not bring UC back, **when** the peer stays down, **then** fix #2 happens about 20 s later and restarts `rapportd` and `sharingd`; fixes #3, #4 and #5 follow about 1, 2 and 5 min after the previous one, and later ones every 10 min. |
| AC-8 | **Given** UC is connected, **when** `UniversalControl` logs more than `UC_STORM_MAX` `Activated: CLinkClient` lines within a minute, **then** the log shows `restart UniversalControl: link storm, ...`, `UniversalControl` and `rapportd` get new PIDs, and this does not repeat within 10 min. |
| AC-9 | **Given** UC is connected, **when** `UniversalControl` uses more than `UC_MEM_MAX` MB, **then** the log shows `restart UniversalControl: memory ...` and the new process uses under 50 MB. |
| AC-5 | **Given** a fix happened, **when** UC reconnects, **then** the log shows `reconnected after Ns` and the next drop starts again from `fix #1`. |
| AC-6 | **Given** the `log stream` process is killed, **when** the watchdog notices (within 5 s), **then** it exits and launchd starts a new instance within 30 s. |
| AC-7 | **Given** the watchdog is installed, **when** the user runs `./uninstall.sh`, **then** the agent is no longer loaded and its plist and script are gone. |

## Compatibility

| macOS | Status |
|---|---|
| Monterey 12.7.x (OCLP, iMac 2013) | Tested, works |
| Ventura, Sonoma, Sequoia and later | Not tested yet. The log wording may differ. |

If you try it on another version, please open an issue with your macOS version, your Mac models, and a few lines from:

```bash
log stream --style compact --predicate 'process == "UniversalControl" AND category == "CONN"'
```

captured while a disconnect happens.

## FAQ

**Is it safe?** It only restarts user-level Apple processes (`rapportd`, `sharingd`, `UniversalControl`) that macOS restarts by itself right away. It changes no system files and needs no root.

**Does it use battery or CPU?** Almost none. It waits on `log stream` and wakes every 5 s only to check a timer.

**Will it keep restarting things while my MacBook is closed or off?** Only with backoff, at most once every 10 minutes once the retries are used up, and without more notifications. It does nothing while UC is connected.

**Does it fix Sidecar or AirDrop?** It is built and tested for Universal Control only. Restarting `sharingd` can also wake up AirDrop and Handoff, but that is a side effect, and it is the reason `sharingd` is only restarted when restarting `rapportd` alone was not enough.

**Copy and paste between the Macs stopped working right after a fix.** That is the Handoff key exchange restarting after `sharingd` was killed. It came back on its own within about 10 minutes both times it was observed. Since fix #1 no longer touches `sharingd`, it should be rare; if it still happens, do not restart anything, just wait.

## License

[MIT](LICENSE)
