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

- Follows the `UniversalControl` log live (`log stream`, category `CONN`). It does not poll and uses almost no CPU while idle.
- When the connection list goes empty, it starts a timer.
- If UC reconnects on its own within the **grace period** (15 s by default), it does nothing.
- If not, it restarts `rapportd` and `sharingd` and shows a notification.
- If the link is still down, it retries after **1, 2, 5 and then every 10 minutes**, so it does not hammer the system while the other Mac is asleep or away.
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

The installer copies the script to `~/.local/bin/uc-watchdog.sh`, installs the LaunchAgent `~/Library/LaunchAgents/local.uc-watchdog.plist` and starts it. It needs no `sudo`. Run `./install.sh` again after changing the script or the settings.

## Usage

There is nothing to do. It runs in the background from login. To see what it is doing:

```bash
tail -f ~/Library/Logs/uc-watchdog.log
```

Example output:

```
2026-09-28 10:54:56 start (grace=15s, pid 46377)
2026-09-28 12:46:44 down
2026-09-28 12:47:00 fix #1 (down for 16s)
2026-09-28 12:47:25 reconnected after 41s
2026-09-28 14:22:49 down
2026-09-28 14:22:51 reconnected after 2s
```

The second drop recovered on its own in 2 s, so the watchdog left it alone.

Check that it is running:

```bash
launchctl print gui/$(id -u)/local.uc-watchdog | grep state
```

## Configuration

Edit the `EnvironmentVariables` block in `uc-watchdog.plist`, then run `./install.sh` again.

| Variable | Default | Meaning |
|---|---|---|
| `UC_GRACE` | `15` | Seconds to wait for UC to recover on its own before restarting the daemons |
| `UC_NOTIFY` | `1` | `1` shows a notification on each fix, `0` stays silent |
| `UC_LOG` | `~/Library/Logs/uc-watchdog.log` | Log file path |

About `UC_GRACE`: in real use, drops that recover on their own did so in 1 to 14 s. A lower value restarts daemons that did not need it; a higher one makes every real drop last longer. 15 s worked well.

## Uninstall

```bash
./uninstall.sh
```

This removes the LaunchAgent and the script. It keeps the logs.

## How it works

The script matches two kinds of lines from `UniversalControl` (category `CONN`):

| Log line | Meaning |
|---|---|
| `... update connections: [XXXXXXXX (disconnecting)] -> []` | The peer is gone: start the timer |
| `... update connections: [XXXXXXXX (connecting)] -> [XXXXXXXX (connected)]` | The peer is back: reset |

The fix is `killall rapportd sharingd`. Both run as your user, and launchd restarts them at once. `log stream` feeds a FIFO so the loop can read with a timeout and detect if the stream dies (bash 3.2's `read -t` cannot tell a timeout from EOF). If the stream dies, the script exits and launchd starts it again.

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

- **`killall universalcontrold`**: on Monterey that process does not exist. The process is called `UniversalControl`, and restarting it is not needed.
- **`killall useractivityd`**: it ignores the signal (same PID before and after), so it has no effect.
- **Software KVMs (Barrier, Synergy)** as a replacement: problems with Accessibility (TCC) permissions, SSL certificates and mDNS on machines with several network interfaces. Not worth it.

**Tip that did help:** move Bluetooth keyboards and mice to a cable or a USB receiver. An old Bluetooth 4.0 radio shared with input devices misses more Continuity advertisements.

## Functional requirements

| ID | Requirement |
|---|---|
| FR-1 | Detect a Universal Control disconnect from the unified log within 5 s of it being logged. |
| FR-2 | Take no action if UC reconnects on its own within `UC_GRACE` seconds. |
| FR-3 | After `UC_GRACE` seconds down, restart `rapportd` and `sharingd`. |
| FR-4 | While still down, retry with backoff: 60 s, 120 s, 300 s, then every 600 s. |
| FR-5 | Reset the retry counter once UC reports a connected peer. |
| FR-6 | Log start, drop, fix and reconnection events with timestamps, and cap the log near 1 MB. |
| FR-7 | Optionally show a macOS notification on each fix (`UC_NOTIFY`). |
| FR-8 | Start at login and restart automatically if the process or the log stream dies. |
| FR-9 | Run as the logged-in user: no root, no third-party dependencies, only the tools that ship with macOS (bash 3.2). |
| FR-10 | Install and uninstall with a single command each. |

## Acceptance criteria

| ID | Given / When / Then |
|---|---|
| AC-1 | **Given** the watchdog is installed, **when** the user logs in, **then** `launchctl print gui/$(id -u)/local.uc-watchdog` shows `state = running` and the log shows `start`. |
| AC-2 | **Given** UC is connected, **when** the peer drops and comes back within 15 s, **then** the log shows `down` and `reconnected`, and no `fix`. |
| AC-3 | **Given** UC is connected, **when** the peer stays down for 15 s, **then** the log shows `fix #1` and `rapportd` and `sharingd` get new PIDs. |
| AC-4 | **Given** the fix did not bring UC back, **when** the peer stays down, **then** fixes #2, #3 and #4 happen about 1, 2 and 5 min after the previous one, and later ones every 10 min. |
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

**Is it safe?** It only restarts two user-level Apple daemons that macOS restarts by itself right away. It changes no system files and needs no root.

**Does it use battery or CPU?** Almost none. It waits on `log stream` and wakes every 5 s only to check a timer.

**Will it keep restarting things while my MacBook is closed?** Only with backoff, at most once every 10 minutes once the retries are used up. It does nothing while UC is connected.

**Does it fix Sidecar or AirDrop?** It is built and tested for Universal Control only. Restarting `sharingd` can also wake up AirDrop and Handoff, but that is a side effect.

## License

[MIT](LICENSE)
