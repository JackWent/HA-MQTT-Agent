#!/usr/bin/env bash
# install-ha-mqtt-agent.sh
# Usage:
#   sudo bash install-ha-mqtt-agent.sh -install    # install/upgrade
#   sudo bash install-ha-mqtt-agent.sh -uninstall  # remove everything
set -euo pipefail

# Bump this on every functional change - it's printed at the end of
# -install and is the only place the version is tracked now that it's
# no longer in the filename.
SCRIPT_VERSION="14"

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
  apt-get install -y --no-install-recommends jq mosquitto-clients apt-show-versions coreutils gawk logrotate iproute2 util-linux psmisc

  ensure_logs
  install -d -m 0755 /usr/local/bin
  install -d -m 0755 /usr/local/lib/ha-mqtt-agent
  install -d -m 0700 /etc/ha-mqtt-agent
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
# device id/name default to host at runtime
EOF

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
  systemctl enable --now ha-mqtt-metrics.timer
  systemctl enable --now ha-mqtt-updates.timer

  # Seed sensors immediately
  /usr/local/bin/ha-mqtt-metrics.sh || true
  /usr/local/bin/ha-mqtt-updates.sh || true

  echo "Installation complete.
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
  systemctl disable --now ha-mqtt-metrics.timer ha-mqtt-updates.timer ha-mqtt-discovery.service 2>/dev/null
  systemctl stop ha-mqtt-metrics.service ha-mqtt-updates.service 2>/dev/null
  systemctl daemon-reload

  rm -f /etc/systemd/system/ha-mqtt-metrics.service
  rm -f /etc/systemd/system/ha-mqtt-metrics.timer
  rm -f /etc/systemd/system/ha-mqtt-updates.service
  rm -f /etc/systemd/system/ha-mqtt-updates.timer
  rm -f /etc/systemd/system/ha-mqtt-discovery.service

  rm -f /usr/local/bin/ha-mqtt-metrics.sh
  rm -f /usr/local/bin/ha-mqtt-updates.sh
  rm -f /usr/local/bin/ha-mqtt-discovery.sh

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
  -uninstall|--uninstall|uninstall)
    uninstall_all
    ;;
  *)
    echo "Usage: $0 [-install|--install|install] | [-uninstall|--uninstall|uninstall]"
    exit 2
    ;;
esac
