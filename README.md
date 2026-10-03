# HA MQTT Agent

A single bash installer that turns any Debian/Ubuntu Linux host into a lightweight
monitoring agent for Home Assistant, publishing system metrics over MQTT with
[Home Assistant MQTT Discovery](https://www.home-assistant.io/integrations/mqtt/#mqtt-discovery)
so sensors show up automatically — no YAML configuration needed on the HA side.

## What it monitors

Per host, the agent publishes and auto-discovers these entities in Home Assistant:

| Sensor | Source | Update interval |
|---|---|---|
| Agent Online | heartbeat topic (used as the `availability` topic for every other sensor) | every `HEARTBEAT_INTERVAL` |
| Agent Version | installed `SCRIPT_VERSION` | every `HEARTBEAT_INTERVAL` |
| Hostname | `hostname -s` (capitalized) | every `HEARTBEAT_INTERVAL` |
| OS Version | `PRETTY_NAME` from `/etc/os-release` (e.g. `Ubuntu 24.04.1 LTS`), falling back to `uname -sr` | every `HEARTBEAT_INTERVAL` |
| Default Gateway | `ip route show default` | every `HEARTBEAT_INTERVAL` |
| DNS Server 1 / DNS Server 2 | first two `nameserver` lines in `/etc/resolv.conf` | every `HEARTBEAT_INTERVAL` |
| CPU Usage (%) | `/proc/stat` delta over ~0.5s | every `HEARTBEAT_INTERVAL` |
| RAM Used (%) | `free` | every `HEARTBEAT_INTERVAL` |
| Swap Used (%) | `free` (0 if no swap configured) | every `HEARTBEAT_INTERVAL` |
| Load Average (1m / 5m / 15m) | `/proc/loadavg` | every `HEARTBEAT_INTERVAL` |
| Failed Units | `systemctl --failed` count | every `HEARTBEAT_INTERVAL` |
| Reboot Required | `/var/run/reboot-required` flag file (binary sensor) | every `HEARTBEAT_INTERVAL` |
| Disk Free / Disk Total (GB) | `df /` | every `HEARTBEAT_INTERVAL` |
| Disk Free (%) | `df /` | every `HEARTBEAT_INTERVAL` |
| Updates Pending | `apt-show-versions -u -b` count | hourly |
| IP (`<iface>`) | one sensor per active global IPv4 interface - excludes Docker-managed interfaces (`docker*`, `br-*`), only physical NICs | every `HEARTBEAT_INTERVAL` |
| Reboot Host (button) | pressing it publishes to `servers/<hostname>/reboot/set`, which a dedicated listener service publishes an offline heartbeat and an up-to-date Config Update state, then runs `systemctl reboot` | on press |
| Config Update (update entity) | compares the installed `SCRIPT_VERSION` against the copy at `UPDATE_URL`; HA's built-in "Install" action downloads it, replaces the persisted installer, and runs `-upgrade` | checked at boot + hourly |

All sensors use `expire_after` tied to the heartbeat, so they flip to "unavailable"
in Home Assistant if the agent stops publishing (host down, service crashed, etc.)
instead of silently showing stale values. The reboot button and update entity's
install action are stateless commands (no `expire_after` concept applies).

**Security note on the reboot button and Config Update:** anyone able to publish
to `servers/<hostname>/reboot/set` or `servers/<hostname>/agent_update/set` on
your MQTT broker can reboot that host, or make it download and run a script
from `UPDATE_URL` as root — there's no confirmation or extra auth built into
the agent itself, since MQTT has no per-host access-control concept the agent
could enforce. The actual safeguards are (1) your MQTT broker's own ACLs, (2)
`UPDATE_URL` being a source you trust (the update script does check the
download's syntax and that it has a `SCRIPT_VERSION` line before applying it,
but that's a sanity check against a corrupted download, not a defense against
a malicious one), and (3) enabling HA's built-in "confirmation" option on
these entities' dashboard cards, which prompts before actually sending the
command. Worth doing all three, especially on hosts you'd rather not reboot or
auto-update by accident.

## Requirements

- Debian/Ubuntu-based host (uses `apt-get`/`apt-show-versions`), root access
- Network access to an MQTT broker (tested against Home Assistant's built-in Mosquitto broker)
- Outbound internet access for the hourly `apt-get update` used to count pending updates

The installer installs its own dependencies (`jq`, `mosquitto-clients`,
`apt-show-versions`, `logrotate`, `iproute2`, `curl`, etc.) via `apt-get`.

## Configuration

The script needs `MQTT_HOST`, `MQTT_USER`, and `MQTT_PASS` (and optionally
`MQTT_PORT`, default `1883`) at install time. These are **not** hardcoded in the
script — provide them either as environment variables, or in a `.env` file placed
next to the script (this file is gitignored and must never be committed):

```bash
# .env
MQTT_HOST="homeassistant.example.com"
MQTT_PORT="1883"
MQTT_USER="mqtt"
MQTT_PASS="your-mqtt-password"
```

`-uninstall` doesn't touch the broker and doesn't require any of these to be set.

Other tunables live near the top of the script and can be edited directly if needed:

- `HEARTBEAT_INTERVAL` (default `30`s) — how often metrics/heartbeat are published
- `SENSOR_EXPIRE` (default `120`s) — how long before a sensor is marked unavailable with no update
- `SCRIPT_VERSION` — bump this on every functional change to the script; it's published as the "Agent Version" sensor and printed at the end of `-install`, since the version is no longer in the filename
- `UPDATE_URL` (default `https://jackwent.co.uk/downloads/ha-agent/ha-mqtt-agent.sh`) — where update checks download this script from to compare `SCRIPT_VERSION`

## Usage

```bash
# fresh install
sudo bash ha-mqtt-agent.sh -install

# upgrade an existing device to whatever version this script is
# (same idempotent full re-deploy as -install, just a clearer name for it)
sudo bash ha-mqtt-agent.sh -upgrade

# remove everything the installer created
sudo bash ha-mqtt-agent.sh -uninstall
```

Device ID/name are derived from the host's own hostname at runtime — no per-host
edits to the script are needed beyond the shared MQTT config.

## How it works

Running `-install` writes and enables the following on the target host:

- `/etc/ha-mqtt-agent/env` — resolved MQTT config for the generated scripts to source
- `/usr/local/lib/ha-mqtt-agent/common.sh` — shared logging helper (redirects stdout/stderr to the log file)
- `/usr/local/lib/ha-mqtt-agent/installer.sh` — a persisted copy of this installer itself, so update checks/updates have a stable path to compare against and re-run, independent of wherever the script was originally downloaded to
- `/usr/local/bin/ha-mqtt-metrics.sh` — publishes heartbeat, CPU/RAM/swap/load/disk state, reboot-required and failed-units flags, and per-interface IPs
- `/usr/local/bin/ha-mqtt-updates.sh` — counts pending apt upgrades (lock-safe, single-instance via `flock`, waits out apt/dpkg locks) and caches the result
- `/usr/local/bin/ha-mqtt-discovery.sh` — publishes the retained Home Assistant MQTT Discovery config for every sensor
- `/usr/local/bin/ha-mqtt-command-listener.sh` — stays subscribed to the reboot and agent-update command topics and acts on receipt (`systemctl reboot`, or runs `ha-mqtt-agent-update.sh`)
- `/usr/local/bin/ha-mqtt-update-check.sh` — downloads `UPDATE_URL`, compares its `SCRIPT_VERSION` against what's installed, publishes the result (read-only, never applies anything)
- `/usr/local/bin/ha-mqtt-agent-update.sh` — downloads `UPDATE_URL`, sanity-checks it (syntax, has a `SCRIPT_VERSION` line), replaces the persisted installer, and runs `-upgrade`
- systemd units: `ha-mqtt-metrics.timer` (every `HEARTBEAT_INTERVAL`s), `ha-mqtt-updates.timer` (hourly), `ha-mqtt-update-check.timer` (at boot + hourly), `ha-mqtt-discovery.service` (runs once at boot/enable), `ha-mqtt-command-listener.service` (long-running, `Restart=always` - a command topic message is a single non-retained publish, so something has to be actively subscribed when it arrives or it's missed)
- `/etc/logrotate.d/mqtt-agent` — rotates `/var/log/mqtt-agent/agent.log` at ~1 MiB, keeping 3 rotations

### MQTT topic layout

```
servers/<hostname>/heartbeat        # "online", non-retained, availability topic for all sensors
servers/<hostname>/state            # JSON: {host, cpu, ram, swap, load1, load5, load15,
                                     #        reboot_required, failed_units, disk_free_gb,
                                     #        disk_total_gb, disk_free_pct, agent_version, gateway,
                                     #        dns1, dns2, os_version}
servers/<hostname>/updates          # pending update count
servers/<hostname>/ip/<iface>       # "<iface>: <ip>" per active interface
servers/<hostname>/reboot/set       # command topic - any message here triggers `systemctl reboot`
servers/<hostname>/agent_update     # retained JSON: {installed_version, latest_version}
servers/<hostname>/agent_update/set # command topic - any message here triggers the self-update
homeassistant/sensor/<hostname>/<object>/config          # retained HA discovery configs
homeassistant/binary_sensor/<hostname>/<object>/config   # retained HA discovery configs (Reboot Required)
homeassistant/button/<hostname>/<object>/config          # retained HA discovery config (Reboot Host)
homeassistant/update/<hostname>/<object>/config           # retained HA discovery config (Config Update)
```

## Logs

`/var/log/mqtt-agent/agent.log`, rotated by logrotate at ~1 MiB (3 rotations kept).
The installer also self-truncates the log on install if it's already oversized.
