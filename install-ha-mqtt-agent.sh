#!/usr/bin/env bash
# install-ha-mqtt-agent.sh
# Usage:
#   sudo bash install-ha-mqtt-agent.sh -install    # install/upgrade
#   sudo bash install-ha-mqtt-agent.sh -uninstall  # remove everything
set -euo pipefail

# Bump this on every functional change - it's printed at the end of
# -install and is the only place the version is tracked now that it's
# no longer in the filename.
SCRIPT_VERSION="15"

ACTION="${1:- -install}"

# ---- Config ----
# Set these via environment variables, or drop a .env file next to this
# script (gitignored) with MQTT_HOST/MQTT_PORT/MQTT_USER/MQTT_PASS set.
# Only required for -install; -uninstall doesn't touch the broker.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # .env is intentionally gitignored/optional, not present in the repo
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"

MQTT_PORT="${MQTT_PORT:-1883}"
if [[ "$ACTION" != *uninstall* ]]; then
  MQTT_HOST="${MQTT_HOST:?set MQTT_HOST (env var or .env file)}"
  MQTT_USER="${MQTT_USER:?set MQTT_USER (env var or .env file)}"
  MQTT_PASS="${MQTT_PASS:?set MQTT_PASS (env var or .env file)}"
fi

# Heartbeat & expiry (seconds)
HEARTBEAT_INTERVAL=30      # metrics timer
SENSOR_EXPIRE=120          # sensors stale timeout (cpu/ram/disk/updates/ip)

# Where update checks download this script from, to compare SCRIPT_VERSION
# against what's installed. Override via env var/.env if ever needed.
UPDATE_URL="${UPDATE_URL:-https://jackwent.co.uk/downloads/ha-agent/install-ha-mqtt-agent.sh}"

LOG_DIR="/var/log/mqtt-agent"
LOG_FILE="$LOG_DIR/agent.log"
MAX_LOG_BYTES=$((1024*1024))  # 1 MiB

DEVICE_ID="$(hostname -s || hostname)"
# Capitalize the device name's first letter for nicer sensor labels
DEVICE_NAME="$(printf '%s' "$DEVICE_ID" | sed 's/^./\u&/')"

ensure_logs() {
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE"
  # truncate if too big
  if [ -f "$LOG_FILE" ]; then
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || wc -c <"$LOG_FILE")
    if [ "${size:-0}" -gt "$MAX_LOG_BYTES" ]; then
      : > "$LOG_FILE"
    fi
  fi
}

write_common_lib() {
  install -d -m 0755 /usr/local/lib/ha-mqtt-agent
  cat > /usr/local/lib/ha-mqtt-agent/common.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="/var/log/mqtt-agent"
LOG_FILE="$LOG_DIR/agent.log"
MAX_LOG_BYTES=${LOG_MAX_BYTES:-1048576}

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
# truncate if too big
if [ -f "$LOG_FILE" ]; then
  size=$(stat -c%s "$LOG_FILE" 2>/dev/null || wc -c <"$LOG_FILE")
  if [ "${size:-0}" -gt "$MAX_LOG_BYTES" ]; then
    : > "$LOG_FILE"
  fi
fi

# Redirect all stdout/stderr to the log
exec >>"$LOG_FILE" 2>&1

log() {
  # usage: log "message"
  echo "$(date -Is) [$0] $*"
}
EOF
  chmod +x /usr/local/lib/ha-mqtt-agent/common.sh
}

install_all() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends jq mosquitto-clients apt-show-versions coreutils gawk logrotate iproute2 util-linux psmisc curl

  # Migration: this service was renamed ha-mqtt-reboot-listener ->
  # ha-mqtt-command-listener when the agent-update feature was added (it now
  # handles more than just reboots). Clean up the old name on any host
  # upgrading from that version so it doesn't linger alongside the new one.
  if [ -f /etc/systemd/system/ha-mqtt-reboot-listener.service ]; then
    systemctl disable --now ha-mqtt-reboot-listener.service 2>/dev/null || true
    rm -f /etc/systemd/system/ha-mqtt-reboot-listener.service
    rm -f /usr/local/bin/ha-mqtt-reboot-listener.sh
  fi

  ensure_logs
  install -d -m 0755 /usr/local/bin
  install -d -m 0755 /usr/local/lib/ha-mqtt-agent
  install -d -m 0700 /etc/ha-mqtt-agent
  # Belt-and-braces for -upgrade on a device installed by an older version of
  # this script (which created this directory as 0755): install -d doesn't
  # reliably re-chmod a directory that already exists, so force it here too.
  chmod 0700 /etc/ha-mqtt-agent
  install -d -m 0755 /run/ha-mqtt-agent

  # env file - contains MQTT_PASS in plaintext, so lock it down to root-only
  # before writing any content (systemd's EnvironmentFile= is read by the
  # manager process, always root, so this doesn't need to be readable by
  # whatever User= a service later runs as).
  install -m 0600 /dev/null /etc/ha-mqtt-agent/env
  cat > /etc/ha-mqtt-agent/env <<EOF
MQTT_HOST="$MQTT_HOST"
MQTT_PORT="$MQTT_PORT"
MQTT_USER="$MQTT_USER"
MQTT_PASS="$MQTT_PASS"
HEARTBEAT_INTERVAL="$HEARTBEAT_INTERVAL"
SENSOR_EXPIRE="$SENSOR_EXPIRE"
AGENT_VERSION="$SCRIPT_VERSION"
AGENT_UPDATE_URL="$UPDATE_URL"
# device id/name default to host at runtime
EOF

  # Persist a copy of this installer itself, so the update-check/update-apply
  # scripts have a fixed, known path to compare against and re-run - the
  # script as originally invoked might have been a one-off download that
  # isn't sitting anywhere stable on disk.
  install -m 0755 "${BASH_SOURCE[0]}" /usr/local/lib/ha-mqtt-agent/installer.sh

  # common lib (logging)
  write_common_lib

  # metrics (publishes heartbeat + metrics + cached updates + per-iface IPs every run)
  cat > /usr/local/bin/ha-mqtt-metrics.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/ha-mqtt-agent/common.sh
log "starting metrics script"
source /etc/ha-mqtt-agent/env

HOSTNAME_SHORT="$(hostname -s || hostname)"
DEVICE_ID="$HOSTNAME_SHORT"
DEVICE_NAME="$(printf '%s' "$HOSTNAME_SHORT" | sed 's/^./\u&/')"
BASE="servers/$DEVICE_ID"
HEARTBEAT_TOPIC="$BASE/heartbeat"
STATE_TOPIC="$BASE/state"
UPDATES_TOPIC="$BASE/updates"
RUNDIR="/run/ha-mqtt-agent"; mkdir -p "$RUNDIR"
CACHE="$RUNDIR/updates.cache"

# CPU usage over ~0.5s
read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
total1=$((user+nice+system+idle+iowait+irq+softirq+steal))
idle1=$idle
sleep 0.5
read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
total2=$((user+nice+system+idle+iowait+irq+softirq+steal))
idle2=$idle
totald=$((total2-total1))
idled=$((idle2-idle1))
cpu_used=$(( (1000*(totald-idled)/totald + 5)/10 ))

# RAM used %
mem_used_pct="$(free | awk '/Mem:/{printf("%.1f", $3*100/$2)}')"

# Swap used % (0 if no swap configured, rather than dividing by zero)
swap_used_pct="$(free | awk '/Swap:/{ if ($2>0) printf("%.1f", $3*100/$2); else print "0.0" }')"

# Load average (1/5/15 min)
read -r load1 load5 load15 _ < /proc/loadavg

# Reboot required (Debian/Ubuntu apt flag file)
if [ -f /var/run/reboot-required ]; then reboot_required=true; else reboot_required=false; fi

# Failed systemd units
failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l | tr -d '[:space:]')"
[ -z "${failed_units:-}" ] && failed_units=0

# Disk for /
read -r total used free <<<"$(df -B1 / | awk 'NR==2{print $2, $3, $4}')"
disk_free_gb=$(awk -v f="$free" 'BEGIN {printf "%.1f", f/1024/1024/1024}')
disk_total_gb=$(awk -v t="$total" 'BEGIN {printf "%.1f", t/1024/1024/1024}')

payload="$(jq -nc --arg host "$DEVICE_NAME" \
  --argjson cpu "$cpu_used" \
  --argjson ram "$mem_used_pct" \
  --argjson swap "$swap_used_pct" \
  --argjson load1 "$load1" \
  --argjson load5 "$load5" \
  --argjson load15 "$load15" \
  --arg reboot_required "$reboot_required" \
  --argjson failed_units "$failed_units" \
  --argjson disk_free_gb "$disk_free_gb" \
  --argjson disk_total_gb "$disk_total_gb" \
  --arg agent_version "${AGENT_VERSION:-unknown}" \
  '{host:$host, cpu:$cpu, ram:$ram, swap:$swap, load1:$load1, load5:$load5, load15:$load15, reboot_required:$reboot_required, failed_units:$failed_units, disk_free_gb:$disk_free_gb, disk_total_gb:$disk_total_gb, agent_version:$agent_version}')"

mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$STATE_TOPIC" -m "$payload" || log "ERROR publishing metrics"

# Per-interface IPv4s (first address per interface), only 'up' and global
# Publish to servers/<host>/ip/<iface>
while IFS= read -r line; do
  iface_raw="$(echo "$line" | awk '{print $2}')"
  iface="${iface_raw%%@*}"  # strip @ifindex
  ipaddr="$(echo "$line" | awk '{print $4}' | cut -d'/' -f1)"
  # sanitize iface name for topic (and trim trailing _)
  safe_iface="$(echo "$iface" | tr -c 'A-Za-z0-9_' '_' | sed 's/_\+$//')"
  [ -n "$ipaddr" ] && mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "$BASE/ip/$safe_iface" -m "$iface: $ipaddr" || true
done < <(ip -o -4 addr show scope global up | awk '!seen[$2]++')

# Re-publish cached updates (so sensor expires with heartbeat if agent dies)
if [ -f "$CACHE" ]; then
  cached="$(tr -d '[:space:]' < "$CACHE")"
  if [[ "$cached" =~ ^[0-9]+$ ]]; then
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$UPDATES_TOPIC" -m "$cached" || log "ERROR publishing cached updates"
    log "published cached updates: $cached"
  fi
fi

# Heartbeat (non-retained)
mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$HEARTBEAT_TOPIC" -m "online" || true
EOF
  chmod +x /usr/local/bin/ha-mqtt-metrics.sh

  # updates (hourly real count; single-instance lock; waits for apt locks; writes cache; non-retained publish)
  cat > /usr/local/bin/ha-mqtt-updates.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/ha-mqtt-agent/common.sh
log "starting updates script"
source /etc/ha-mqtt-agent/env

HOSTNAME_SHORT="$(hostname -s || hostname)"
DEVICE_ID="$HOSTNAME_SHORT"
BASE="servers/$DEVICE_ID"
UPDATES_TOPIC="$BASE/updates"
RUNDIR="/run/ha-mqtt-agent"; mkdir -p "$RUNDIR"
CACHE="$RUNDIR/updates.cache"
LOCK="$RUNDIR/updates.lock"

# ensure only one updates run at a time
exec 200>"$LOCK"
if ! flock -n 200; then
  log "another updates run is active, exiting"
  exit 0
fi

wait_for_apt_locks() {
  local tries=0
  local max_tries=40   # ~10 minutes at 15s
  local sleep_s=15
  while [ $tries -lt $max_tries ]; do
    local blocked=0
    for f in /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock; do
      if fuser "$f" >/dev/null 2>&1; then
        blocked=1
        log "apt lock on $f; waiting ${sleep_s}s (try $((tries+1))/$max_tries)"
      fi
    done
    [ $blocked -eq 0 ] && return 0
    tries=$((tries+1))
    sleep "$sleep_s"
  done
  log "apt appears locked for too long; proceeding anyway"
  return 0
}

export DEBIAN_FRONTEND=noninteractive

log "waiting for apt locks (if any)..."
wait_for_apt_locks

log "running apt-get update..."
if apt-get update -qq -o Acquire::Retries=3; then
  log "apt-get update complete"
else
  log "apt-get update failed (continuing to count upgrades)"
fi

count="$(apt-show-versions -u -b | sed '/^No .* upgrades/d' | wc -l | tr -d '[:space:]' || echo 0)"
[ -z "${count:-}" ] && count=0
echo "$count" > "$CACHE"
log "updates pending: $count (cached at $CACHE)"

mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$UPDATES_TOPIC" -m "$count" || log "ERROR publishing updates"
EOF
  chmod +x /usr/local/bin/ha-mqtt-updates.sh

  # agent self-update (downloads UPDATE_URL, sanity-checks it, replaces the
  # persisted installer copy, and re-runs -upgrade - called by the command
  # listener below on receipt of the update command)
  cat > /usr/local/bin/ha-mqtt-agent-update.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/ha-mqtt-agent/common.sh
log "starting agent self-update"
source /etc/ha-mqtt-agent/env

INSTALLER_PATH="/usr/local/lib/ha-mqtt-agent/installer.sh"
TMP_SCRIPT="$(mktemp)"
trap 'rm -f "$TMP_SCRIPT"' EXIT

if ! curl -fsSL --max-time 30 -o "$TMP_SCRIPT" "$AGENT_UPDATE_URL"; then
  log "ERROR: failed to download updated installer from $AGENT_UPDATE_URL"
  exit 1
fi

if ! bash -n "$TMP_SCRIPT"; then
  log "ERROR: downloaded installer failed syntax check, aborting update"
  exit 1
fi

if ! grep -q '^SCRIPT_VERSION=' "$TMP_SCRIPT"; then
  log "ERROR: downloaded installer has no SCRIPT_VERSION line, aborting update"
  exit 1
fi

install -m 0755 "$TMP_SCRIPT" "$INSTALLER_PATH"
log "downloaded and validated new installer, running -upgrade"
MQTT_HOST="$MQTT_HOST" MQTT_PORT="$MQTT_PORT" MQTT_USER="$MQTT_USER" MQTT_PASS="$MQTT_PASS" \
  bash "$INSTALLER_PATH" -upgrade
EOF
  chmod +x /usr/local/bin/ha-mqtt-agent-update.sh

  # command listener (long-running subscriber, not a timer - HA button/update
  # presses are a single non-retained MQTT message, so something has to be
  # actively subscribed at the moment one's sent or it's missed entirely).
  # Handles both the reboot button and the agent-update button.
  cat > /usr/local/bin/ha-mqtt-command-listener.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/ha-mqtt-agent/common.sh
log "starting command listener"
source /etc/ha-mqtt-agent/env

HOSTNAME_SHORT="$(hostname -s || hostname)"
DEVICE_ID="$HOSTNAME_SHORT"
REBOOT_TOPIC="servers/$DEVICE_ID/reboot/set"
UPDATE_TOPIC="servers/$DEVICE_ID/agent_update/set"

log "listening for commands on $REBOOT_TOPIC and $UPDATE_TOPIC"

mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -v -t "$REBOOT_TOPIC" -t "$UPDATE_TOPIC" | while IFS=' ' read -r topic _; do
  case "$topic" in
    "$REBOOT_TOPIC")
      log "reboot command received via MQTT - rebooting now"
      systemctl reboot
      ;;
    "$UPDATE_TOPIC")
      log "update command received via MQTT"
      /usr/local/bin/ha-mqtt-agent-update.sh || log "ERROR: agent update failed"
      ;;
  esac
done
EOF
  chmod +x /usr/local/bin/ha-mqtt-command-listener.sh

  # update check (downloads UPDATE_URL, compares its SCRIPT_VERSION against
  # what's installed, publishes the result - read-only, never applies
  # anything itself; that's ha-mqtt-agent-update.sh's job)
  cat > /usr/local/bin/ha-mqtt-update-check.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/ha-mqtt-agent/common.sh
log "starting update check"
source /etc/ha-mqtt-agent/env

HOSTNAME_SHORT="$(hostname -s || hostname)"
DEVICE_ID="$HOSTNAME_SHORT"
UPDATE_STATE_TOPIC="servers/$DEVICE_ID/agent_update"

installed_version="${AGENT_VERSION:-unknown}"
latest_version="$installed_version"

TMP_SCRIPT="$(mktemp)"
trap 'rm -f "$TMP_SCRIPT"' EXIT

if curl -fsSL --max-time 20 -o "$TMP_SCRIPT" "$AGENT_UPDATE_URL"; then
  remote_version="$(grep -m1 '^SCRIPT_VERSION=' "$TMP_SCRIPT" | sed -E 's/^SCRIPT_VERSION="?([^"[:space:]]*)"?.*/\1/')"
  if [ -n "$remote_version" ]; then
    latest_version="$remote_version"
    log "update check: installed=$installed_version latest=$latest_version"
  else
    log "WARN: could not parse SCRIPT_VERSION from downloaded script, reporting up to date"
  fi
else
  log "WARN: failed to download $AGENT_UPDATE_URL for update check, reporting up to date"
fi

payload="$(jq -nc --arg installed "$installed_version" --arg latest "$latest_version" '{installed_version:$installed, latest_version:$latest}')"
mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$UPDATE_STATE_TOPIC" -r -m "$payload" || log "ERROR publishing update check result"
EOF
  chmod +x /usr/local/bin/ha-mqtt-update-check.sh

  # discovery (uses heartbeat for availability + expire_after for ALL sensors including updates and IPs)
  cat > /usr/local/bin/ha-mqtt-discovery.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/ha-mqtt-agent/common.sh
log "starting discovery script"
source /etc/ha-mqtt-agent/env

HOSTNAME_SHORT="$(hostname -s || hostname)"
DEVICE_ID="$HOSTNAME_SHORT"
DEVICE_NAME="$(printf '%s' "$HOSTNAME_SHORT" | sed 's/^./\u&/')"
HEARTBEAT_TOPIC="servers/$DEVICE_ID/heartbeat"
STATE_TOPIC="servers/$DEVICE_ID/state"

device_json="$(jq -nc --arg id "$DEVICE_ID" --arg name "$DEVICE_NAME" '{identifiers:[$id],manufacturer:"DIY",model:"Linux Server",name:$name}')"

pub_cfg_sensor() {
  local object="$1"; shift
  local body="$1"; shift
  local topic="homeassistant/sensor/$DEVICE_ID/$object/config"
  local tries=0
  until mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -r -m "$body"; do
    tries=$((tries+1))
    log "WARN: publish $object discovery failed (attempt $tries)"
    if [ $tries -ge 5 ]; then
      log "ERROR: giving up on $object discovery after $tries attempts"
      return 0
    fi
    sleep 2
  done
  log "published discovery for $object"
}

pub_cfg_binary_sensor() {
  local object="$1"; shift
  local body="$1"; shift
  local topic="homeassistant/binary_sensor/$DEVICE_ID/$object/config"
  local tries=0
  until mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -r -m "$body"; do
    tries=$((tries+1))
    log "WARN: publish $object discovery failed (attempt $tries)"
    if [ $tries -ge 5 ]; then
      log "ERROR: giving up on $object discovery after $tries attempts"
      return 0
    fi
    sleep 2
  done
  log "published discovery for $object"
}

pub_cfg_button() {
  local object="$1"; shift
  local body="$1"; shift
  local topic="homeassistant/button/$DEVICE_ID/$object/config"
  local tries=0
  until mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -r -m "$body"; do
    tries=$((tries+1))
    log "WARN: publish $object discovery failed (attempt $tries)"
    if [ $tries -ge 5 ]; then
      log "ERROR: giving up on $object discovery after $tries attempts"
      return 0
    fi
    sleep 2
  done
  log "published discovery for $object"
}

pub_cfg_update() {
  local object="$1"; shift
  local body="$1"; shift
  local topic="homeassistant/update/$DEVICE_ID/$object/config"
  local tries=0
  until mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -r -m "$body"; do
    tries=$((tries+1))
    log "WARN: publish $object discovery failed (attempt $tries)"
    if [ $tries -ge 5 ]; then
      log "ERROR: giving up on $object discovery after $tries attempts"
      return 0
    fi
    sleep 2
  done
  log "published discovery for $object"
}

# Agent Online (sensor with expire_after so it becomes Unavailable)
agent_online_cfg="$(jq -nc \
  --arg name "Agent Online" \
  --arg obj "agent_online" \
  --arg def_ent "sensor.${DEVICE_ID}_agent_online" \
  --arg uid "${DEVICE_ID}_agent_online" \
  --arg stat "$HEARTBEAT_TOPIC" \
  --argjson dev "$device_json" \
  --argjson exp ${SENSOR_EXPIRE:-120} \
  '{name:$name, obj_id:$obj, def_ent_id:$def_ent, uniq_id:$uid, stat_t:$stat, avty_t:$stat, pl_avail:"online", pl_not_avail:"offline", exp_aft:$exp, icon:"mdi:lan-connect", dev:$dev}')"

agent_version_cfg="$(jq -nc \
  --arg name "Agent Version" \
  --arg obj "agent_version" \
  --arg def_ent "sensor.${DEVICE_ID}_agent_version" \
  --arg uid "${DEVICE_ID}_agent_version" \
  --arg stat "$STATE_TOPIC" \
  --arg avail "$HEARTBEAT_TOPIC" \
  --argjson dev "$device_json" \
  --argjson exp ${SENSOR_EXPIRE:-120} \
  '{name:$name, obj_id:$obj, def_ent_id:$def_ent, uniq_id:$uid, stat_t:$stat, val_tpl:"{{ value_json.agent_version }}", icon:"mdi:tag", avty_t:$avail, pl_avail:"online", pl_not_avail:"offline", exp_aft:$exp, dev:$dev, entity_category:"diagnostic"}')"

# Reboot button - momentary command, no state/expire_after (buttons aren't a
# value that goes stale, they're a one-shot action). dev_cla "restart" is
# HA's built-in device class for exactly this.
reboot_button_cfg="$(jq -nc \
  --arg name "Reboot Host" \
  --arg obj "reboot" \
  --arg def_ent "button.${DEVICE_ID}_reboot" \
  --arg uid "${DEVICE_ID}_reboot" \
  --arg cmd "servers/$DEVICE_ID/reboot/set" \
  --arg avail "$HEARTBEAT_TOPIC" \
  --argjson dev "$device_json" \
  '{name:$name, obj_id:$obj, def_ent_id:$def_ent, uniq_id:$uid, cmd_t:$cmd, dev_cla:"restart", avty_t:$avail, pl_avail:"online", pl_not_avail:"offline", dev:$dev}')"

# Agent update - HA's native "update" entity: shows installed vs latest
# version and gets a built-in "Install" action wired to cmd_t automatically,
# no separate sensor+button needed. State payload must be exactly
# {installed_version, latest_version} for HA to parse it without a
# value_template.
agent_update_cfg="$(jq -nc \
  --arg name "Agent Update" \
  --arg obj "agent_update" \
  --arg def_ent "update.${DEVICE_ID}_agent_update" \
  --arg uid "${DEVICE_ID}_agent_update" \
  --arg stat "servers/$DEVICE_ID/agent_update" \
  --arg cmd "servers/$DEVICE_ID/agent_update/set" \
  --arg avail "$HEARTBEAT_TOPIC" \
  --argjson dev "$device_json" \
  '{name:$name, obj_id:$obj, def_ent_id:$def_ent, uniq_id:$uid, stat_t:$stat, cmd_t:$cmd, payload_install:"install", avty_t:$avail, pl_avail:"online", pl_not_avail:"offline", dev:$dev, entity_category:"config"}')"

cpu_cfg="$(jq -nc \
  --arg name "CPU Usage" \
  --arg obj "cpu" \
  --arg def_ent "sensor.${DEVICE_ID}_cpu" \
  --arg uid "${DEVICE_ID}_cpu" \
  --arg stat "$STATE_TOPIC" \
  --arg avail "$HEARTBEAT_TOPIC" \
  --argjson dev "$device_json" \
  --argjson exp ${SENSOR_EXPIRE:-120} \
  '{name:$name, obj_id:$obj, def_ent_id:$def_ent, uniq_id:$uid, stat_t:$stat, val_tpl:"{{ value_json.cpu }}", unit_of_meas:"%", dev_cla:"power_factor", avty_t:$avail, pl_avail:"online", pl_not_avail:"offline", exp_aft:$exp, dev:$dev}')"

ram_cfg="$(jq -nc \
  --arg name "RAM Used %" \
  --arg obj "ram" \
  --arg def_ent "sensor.${DEVICE_ID}_ram" \
  --arg uid "${DEVICE_ID}_ram" \
  --arg stat "$STATE_TOPIC" \
  --arg avail "$HEARTBEAT_TOPIC" \
  --argjson dev "$device_json" \
  --argjson exp ${SENSOR_EXPIRE:-120} \
  '{name:$name, obj_id:$obj, def_ent_id:$def_ent, uniq_id:$uid, stat_t:$stat, val_tpl:"{{ value_json.ram }}", unit_of_meas:"%", dev_cla:"power_factor", avty_t:$avail, pl_avail:"online", pl_not_avail:"offline", exp_aft:$exp, dev:$dev}')"

swap_cfg="$(jq -nc \
  --arg name "Swap Used %" \
  --arg obj "swap" \
  --arg def_ent "sensor.${DEVICE_ID}_swap" \
  --arg uid "${DEVICE_ID}_swap" \
  --arg stat "$STATE_TOPIC" \
  --arg avail "$HEARTBEAT_TOPIC" \
  --argjson dev "$device_json" \
  --argjson exp ${SENSOR_EXPIRE:-120} \
  '{name:$name, obj_id:$obj, def_ent_id:$def_ent, uniq_id:$uid, stat_t:$stat, val_tpl:"{{ value_json.swap }}", unit_of_meas:"%", dev_cla:"power_factor", avty_t:$avail, pl_avail:"online", pl_not_avail:"offline", exp_aft:$exp, dev:$dev, entity_category:"diagnostic"}')"

load1_cfg="$(jq -nc \
  --arg name "Load Average (1m)" \
  --arg obj "load1" \
  --arg def_ent "sensor.${DEVICE_ID}_load1" \
  --arg uid "${DEVICE_ID}_load1" \
  --arg stat "$STATE_TOPIC" \
  --arg avail "$HEARTBEAT_TOPIC" \
  --argjson dev "$device_json" \
  --argjson exp ${SENSOR_EXPIRE:-120} \
  '{name:$name, obj_id:$obj, def_ent_id:$def_ent, uniq_id:$uid, stat_t:$stat, val_tpl:"{{ value_json.load1 }}", stat_cla:"measurement", icon:"mdi:chart-line", avty_t:$avail, pl_avail:"online", pl_not_avail:"offline", exp_aft:$exp, dev:$dev, entity_category:"diagnostic"}')"

load5_cfg="$(jq -nc \
  --arg name "Load Average (5m)" \
  --arg obj "load5" \
  --arg def_ent "sensor.${DEVICE_ID}_load5" \
  --arg uid "${DEVICE_ID}_load5" \
  --arg stat "$STATE_TOPIC" \
  --arg avail "$HEARTBEAT_TOPIC" \
  --argjson dev "$device_json" \
  --argjson exp ${SENSOR_EXPIRE:-120} \
  '{name:$name, obj_id:$obj, def_ent_id:$def_ent, uniq_id:$uid, stat_t:$stat, val_tpl:"{{ value_json.load5 }}", stat_cla:"measurement", icon:"mdi:chart-line", avty_t:$avail, pl_avail:"online", pl_not_avail:"offline", exp_aft:$exp, dev:$dev, entity_category:"diagnostic"}')"

load15_cfg="$(jq -nc \
  --arg name "Load Average (15m)" \
  --arg obj "load15" \
  --arg def_ent "sensor.${DEVICE_ID}_load15" \
  --arg uid "${DEVICE_ID}_load15" \
  --arg stat "$STATE_TOPIC" \
  --arg avail "$HEARTBEAT_TOPIC" \
  --argjson dev "$device_json" \
  --argjson exp ${SENSOR_EXPIRE:-120} \
  '{name:$name, obj_id:$obj, def_ent_id:$def_ent, uniq_id:$uid, stat_t:$stat, val_tpl:"{{ value_json.load15 }}", stat_cla:"measurement", icon:"mdi:chart-line", avty_t:$avail, pl_avail:"online", pl_not_avail:"offline", exp_aft:$exp, dev:$dev, entity_category:"diagnostic"}')"

failed_units_cfg="$(jq -nc \
  --arg name "Failed Units" \
  --arg obj "failed_units" \
  --arg def_ent "sensor.${DEVICE_ID}_failed_units" \
  --arg uid "${DEVICE_ID}_failed_units" \
  --arg stat "$STATE_TOPIC" \
  --arg avail "$HEARTBEAT_TOPIC" \
  --argjson dev "$device_json" \
  --argjson exp ${SENSOR_EXPIRE:-120} \
  '{name:$name, obj_id:$obj, def_ent_id:$def_ent, uniq_id:$uid, stat_t:$stat, val_tpl:"{{ value_json.failed_units }}", unit_of_meas:"units", icon:"mdi:alert-circle", avty_t:$avail, pl_avail:"online", pl_not_avail:"offline", exp_aft:$exp, dev:$dev, entity_category:"diagnostic"}')"

reboot_required_cfg="$(jq -nc \
  --arg name "Reboot Required" \
  --arg obj "reboot_required" \
  --arg def_ent "binary_sensor.${DEVICE_ID}_reboot_required" \
  --arg uid "${DEVICE_ID}_reboot_required" \
  --arg stat "$STATE_TOPIC" \
  --arg avail "$HEARTBEAT_TOPIC" \
  --argjson dev "$device_json" \
  --argjson exp ${SENSOR_EXPIRE:-120} \
  '{name:$name, obj_id:$obj, def_ent_id:$def_ent, uniq_id:$uid, stat_t:$stat, val_tpl:"{{ value_json.reboot_required }}", pl_on:"true", pl_off:"false", dev_cla:"problem", avty_t:$avail, pl_avail:"online", pl_not_avail:"offline", exp_aft:$exp, dev:$dev, entity_category:"diagnostic"}')"

disk_free_cfg="$(jq -nc \
  --arg name "Disk Free" \
  --arg obj "disk_free" \
  --arg def_ent "sensor.${DEVICE_ID}_disk_free" \
  --arg uid "${DEVICE_ID}_disk_free" \
  --arg stat "$STATE_TOPIC" \
  --arg avail "$HEARTBEAT_TOPIC" \
  --argjson dev "$device_json" \
  --argjson exp ${SENSOR_EXPIRE:-120} \
  '{name:$name, obj_id:$obj, def_ent_id:$def_ent, uniq_id:$uid, stat_t:$stat, val_tpl:"{{ value_json.disk_free_gb }}", unit_of_meas:"GB", stat_cla:"measurement", avty_t:$avail, pl_avail:"online", pl_not_avail:"offline", exp_aft:$exp, dev:$dev}')"

disk_total_cfg="$(jq -nc \
  --arg name "Disk Total" \
  --arg obj "disk_total" \
  --arg def_ent "sensor.${DEVICE_ID}_disk_total" \
  --arg uid "${DEVICE_ID}_disk_total" \
  --arg stat "$STATE_TOPIC" \
  --arg avail "$HEARTBEAT_TOPIC" \
  --argjson dev "$device_json" \
  --argjson exp ${SENSOR_EXPIRE:-120} \
  '{name:$name, obj_id:$obj, def_ent_id:$def_ent, uniq_id:$uid, stat_t:$stat, val_tpl:"{{ value_json.disk_total_gb }}", unit_of_meas:"GB", avty_t:$avail, pl_avail:"online", pl_not_avail:"offline", exp_aft:$exp, dev:$dev}')"

updates_cfg="$(jq -nc \
  --arg name "Updates Pending" \
  --arg obj "updates" \
  --arg def_ent "sensor.${DEVICE_ID}_updates" \
  --arg uid "${DEVICE_ID}_updates" \
  --arg stat "servers/$DEVICE_ID/updates" \
  --arg avail "$HEARTBEAT_TOPIC" \
  --argjson dev "$device_json" \
  --argjson exp ${SENSOR_EXPIRE:-120} \
  '{name:$name, obj_id:$obj, def_ent_id:$def_ent, uniq_id:$uid, stat_t:$stat, unit_of_meas:"updates", icon:"mdi:package-up", avty_t:$avail, pl_avail:"online", pl_not_avail:"offline", exp_aft:$exp, dev:$dev, entity_category:"diagnostic"}')"

pub_cfg_sensor "agent_online" "$agent_online_cfg"
pub_cfg_sensor "agent_version" "$agent_version_cfg"
pub_cfg_button "reboot" "$reboot_button_cfg"
pub_cfg_update "agent_update" "$agent_update_cfg"
pub_cfg_sensor "cpu" "$cpu_cfg"
pub_cfg_sensor "ram" "$ram_cfg"
pub_cfg_sensor "swap" "$swap_cfg"
pub_cfg_sensor "load1" "$load1_cfg"
pub_cfg_sensor "load5" "$load5_cfg"
pub_cfg_sensor "load15" "$load15_cfg"
pub_cfg_sensor "failed_units" "$failed_units_cfg"
pub_cfg_binary_sensor "reboot_required" "$reboot_required_cfg"
pub_cfg_sensor "disk_free" "$disk_free_cfg"
pub_cfg_sensor "disk_total" "$disk_total_cfg"
pub_cfg_sensor "updates" "$updates_cfg"

# Per-interface IP sensors (discovered dynamically)
# We'll publish sensor for each active global IPv4 interface, name: "IP (<iface>)"
while IFS= read -r line; do
  iface_raw="$(echo "$line" | awk '{print $2}')"
  iface="${iface_raw%%@*}"  # strip @ifindex
  ipaddr="$(echo "$line" | awk '{print $4}' | cut -d'/' -f1)"
  [ -z "$ipaddr" ] && continue
  safe_iface="$(echo "$iface" | tr -c 'A-Za-z0-9_' '_' | sed 's/_\+$//')"
  name="IP ($iface)"
  uid="${DEVICE_ID}_ip_${safe_iface}"
  stat="servers/$DEVICE_ID/ip/$safe_iface"
  obj="ip_${safe_iface}"
  def_ent="sensor.${DEVICE_ID}_${obj}"

  ip_cfg="$(jq -nc \
    --arg name "$name" \
    --arg obj "$obj" \
    --arg def_ent "$def_ent" \
    --arg uid "$uid" \
    --arg stat "$stat" \
    --arg avail "$HEARTBEAT_TOPIC" \
    --argjson dev "$device_json" \
    --argjson exp ${SENSOR_EXPIRE:-120} \
    '{name:$name, obj_id:$obj, def_ent_id:$def_ent, uniq_id:$uid, stat_t:$stat, avty_t:$avail, pl_avail:"online", pl_not_avail:"offline", exp_aft:$exp, icon:"mdi:ip-network", dev:$dev, entity_category:"diagnostic"}')"

  pub_cfg_sensor "ip_${safe_iface}" "$ip_cfg"
done < <(ip -o -4 addr show scope global up | awk '!seen[$2]++')
EOF
  chmod +x /usr/local/bin/ha-mqtt-discovery.sh

  # systemd units (ensure /run/ha-mqtt-agent exists automatically; and preserve it after stop)
  cat > /etc/systemd/system/ha-mqtt-metrics.service <<'EOF'
[Unit]
Description=Publish Linux metrics to MQTT (HA)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ha-mqtt-metrics.sh
EnvironmentFile=/etc/ha-mqtt-agent/env
RuntimeDirectory=ha-mqtt-agent
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ReadWritePaths=/var/log/mqtt-agent
EOF

  cat > /etc/systemd/system/ha-mqtt-metrics.timer <<EOF
[Unit]
Description=Run HA MQTT metrics every ${HEARTBEAT_INTERVAL}s

[Timer]
OnBootSec=20s
OnUnitActiveSec=${HEARTBEAT_INTERVAL}s
Unit=ha-mqtt-metrics.service

[Install]
WantedBy=timers.target
EOF

  cat > /etc/systemd/system/ha-mqtt-updates.service <<'EOF'
[Unit]
Description=Publish updates count to MQTT (HA)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ha-mqtt-updates.sh
EnvironmentFile=/etc/ha-mqtt-agent/env
RuntimeDirectory=ha-mqtt-agent
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes
NoNewPrivileges=yes
ProtectSystem=yes
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
EOF

  cat > /etc/systemd/system/ha-mqtt-updates.timer <<'EOF'
[Unit]
Description=Run updates publisher hourly

[Timer]
OnBootSec=2m
OnUnitActiveSec=1h
Unit=ha-mqtt-updates.service

[Install]
WantedBy=timers.target
EOF

  cat > /etc/systemd/system/ha-mqtt-discovery.service <<'EOF'
[Unit]
Description=Publish Home Assistant MQTT Discovery configs
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ha-mqtt-discovery.sh
EnvironmentFile=/etc/ha-mqtt-agent/env
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ReadWritePaths=/var/log/mqtt-agent

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/ha-mqtt-command-listener.service <<'EOF'
[Unit]
Description=Listen for MQTT reboot/agent-update commands (HA)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ha-mqtt-command-listener.sh
EnvironmentFile=/etc/ha-mqtt-agent/env
Restart=always
RestartSec=10
NoNewPrivileges=yes
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ReadWritePaths=/var/log/mqtt-agent

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/ha-mqtt-update-check.service <<'EOF'
[Unit]
Description=Check for HA MQTT Agent installer updates
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ha-mqtt-update-check.sh
EnvironmentFile=/etc/ha-mqtt-agent/env
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ReadWritePaths=/var/log/mqtt-agent
EOF

  cat > /etc/systemd/system/ha-mqtt-update-check.timer <<'EOF'
[Unit]
Description=Run HA MQTT Agent update check at boot and hourly

[Timer]
OnBootSec=1m
OnUnitActiveSec=1h
Unit=ha-mqtt-update-check.service

[Install]
WantedBy=timers.target
EOF

  # logrotate
  cat > /etc/logrotate.d/mqtt-agent <<'EOF'
/var/log/mqtt-agent/agent.log {
  size 1M
  rotate 3
  missingok
  notifempty
  compress
  delaycompress
  copytruncate
  create 0640 root adm
}
EOF

  systemctl daemon-reload
  systemctl enable --now ha-mqtt-discovery.service
  systemctl enable --now ha-mqtt-command-listener.service
  systemctl enable --now ha-mqtt-metrics.timer
  systemctl enable --now ha-mqtt-updates.timer
  systemctl enable --now ha-mqtt-update-check.timer

  # enable --now on an already-running Type=simple service does NOT restart
  # it, so on -upgrade the listener would otherwise keep executing whatever
  # code was in memory from before the upgrade rewrote its script on disk.
  systemctl restart ha-mqtt-command-listener.service

  # Seed sensors immediately
  /usr/local/bin/ha-mqtt-metrics.sh || true
  /usr/local/bin/ha-mqtt-updates.sh || true

  local action_label="Installation"
  [[ "$ACTION" == *upgrade* ]] && action_label="Upgrade"
  echo "$action_label complete.
Version: $SCRIPT_VERSION
Device: $DEVICE_NAME
Broker: $MQTT_HOST:$MQTT_PORT
Metrics every ${HEARTBEAT_INTERVAL}s; sensors expire after ${SENSOR_EXPIRE}s if no data.
RuntimeDirectory preserved across job exits to avoid /run deletions mid-run.
Updates handle apt locks and prevent overlapping runs.
Logs: $LOG_FILE (rotated at ~1MiB)"
}

uninstall_all() {
  set +e
  systemctl disable --now ha-mqtt-metrics.timer ha-mqtt-updates.timer ha-mqtt-update-check.timer ha-mqtt-discovery.service ha-mqtt-command-listener.service 2>/dev/null
  systemctl stop ha-mqtt-metrics.service ha-mqtt-updates.service ha-mqtt-update-check.service 2>/dev/null
  systemctl daemon-reload

  rm -f /etc/systemd/system/ha-mqtt-metrics.service
  rm -f /etc/systemd/system/ha-mqtt-metrics.timer
  rm -f /etc/systemd/system/ha-mqtt-updates.service
  rm -f /etc/systemd/system/ha-mqtt-updates.timer
  rm -f /etc/systemd/system/ha-mqtt-update-check.service
  rm -f /etc/systemd/system/ha-mqtt-update-check.timer
  rm -f /etc/systemd/system/ha-mqtt-discovery.service
  rm -f /etc/systemd/system/ha-mqtt-command-listener.service

  rm -f /usr/local/bin/ha-mqtt-metrics.sh
  rm -f /usr/local/bin/ha-mqtt-updates.sh
  rm -f /usr/local/bin/ha-mqtt-discovery.sh
  rm -f /usr/local/bin/ha-mqtt-command-listener.sh
  rm -f /usr/local/bin/ha-mqtt-update-check.sh
  rm -f /usr/local/bin/ha-mqtt-agent-update.sh

  rm -rf /usr/local/lib/ha-mqtt-agent
  rm -rf /etc/ha-mqtt-agent
  rm -f /etc/logrotate.d/mqtt-agent
  rm -rf /var/log/mqtt-agent
  rm -rf /run/ha-mqtt-agent

  systemctl daemon-reload
  echo "Uninstall complete."
}

case "$ACTION" in
  -install|--install|install)
    install_all
    ;;
  -upgrade|--upgrade|upgrade)
    # install_all() unconditionally rewrites every file/unit it manages, so
    # this is the exact same full re-deploy as -install - the separate name
    # just makes intent clear when running this against an existing device
    # on an older version, rather than a fresh host.
    install_all
    ;;
  -uninstall|--uninstall|uninstall)
    uninstall_all
    ;;
  *)
    echo "Usage: $0 [-install|--install|install] | [-upgrade|--upgrade|upgrade] | [-uninstall|--uninstall|uninstall]"
    exit 2
    ;;
esac
