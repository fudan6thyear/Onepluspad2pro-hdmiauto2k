#!/system/bin/sh

MODDIR=${0%/*}
MODULE_ID=hdmi_auto_resolution
LOGFILE="$MODDIR/hdmi_auto_resolution.log"
STATEFILE="$MODDIR/current_profile"
LOCKDIR="$MODDIR/.lock"
LOCK_PID_FILE="$LOCKDIR/pid"
LOCK_BOOT_FILE="$LOCKDIR/boot_id"
LOCK_START_FILE="$LOCKDIR/start_time"
BOOT_ID_FILE="/proc/sys/kernel/random/boot_id"
CONFIG_FILE="$MODDIR/config.sh"
LOCK_ACQUIRED=0

HDMI_SIZE="1440x2560"
HDMI_DENSITY="420"
DEFAULT_SIZE="auto"
DEFAULT_DENSITY="auto"
POLL_INTERVAL="3"

log() {
  printf '%s %s\n' "$(/system/bin/date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOGFILE"
}

load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
}

is_external_connector() {
  case "$1" in
    *eDP*|*EDP*|*DSI*|*LVDS*|*Virtual*|*virtual*)
      return 1
      ;;
    *HDMI*|*hdmi*|*DP-*|*dp-*|*DisplayPort*|*displayport*|*TYPEC*|*typec*|*USB-C*|*usb-c*)
      return 0
      ;;
  esac
  return 1
}

get_wm_value() {
  local key="$1"
  /system/bin/wm "$key" 2>/dev/null | awk -F': ' '
    /Physical '"$key"'/ { physical = $2 }
    /Override '"$key"'/ { override = $2 }
    END {
      if (physical != "") {
        print physical
      } else if (override != "") {
        print override
      }
    }
  '
}

get_effective_wm_value() {
  local key="$1"
  /system/bin/wm "$key" 2>/dev/null | awk -F': ' '
    /Physical '"$key"'/ { physical = $2 }
    /Override '"$key"'/ { override = $2 }
    END {
      if (override != "") {
        print override
      } else if (physical != "") {
        print physical
      }
    }
  '
}

get_physical_wm_value() {
  local key="$1"
  /system/bin/wm "$key" 2>/dev/null | awk -F': ' '
    /Physical '"$key"'/ {
      print $2
      exit
    }
  '
}

resolve_value() {
  local configured="$1"
  local detected="$2"

  case "$configured" in
    ""|auto|AUTO)
      printf '%s\n' "$detected"
      ;;
    *)
      printf '%s\n' "$configured"
      ;;
  esac
}

resolve_defaults() {
  local physical_size
  local physical_density

  physical_size="$(get_wm_value size)"
  physical_density="$(get_wm_value density)"

  DEFAULT_SIZE="$(resolve_value "$DEFAULT_SIZE" "$physical_size")"
  DEFAULT_DENSITY="$(resolve_value "$DEFAULT_DENSITY" "$physical_density")"

  [ -n "$DEFAULT_SIZE" ] || DEFAULT_SIZE="reset"
  [ -n "$DEFAULT_DENSITY" ] || DEFAULT_DENSITY="reset"
}

external_drm_connectors() {
  local entries
  local path
  local connector
  local status
  local found=1

  entries="$(ls /sys/class/drm/*/status 2>/dev/null)"
  [ -n "$entries" ] || return 1

  for path in $entries; do
    [ -f "$path" ] || continue
    connector=$(basename "$(dirname "$path")")
    is_external_connector "$connector" || continue
    status="$(cat "$path" 2>/dev/null)"
    [ "$status" = "connected" ] || continue
    printf '%s\n' "$connector"
    found=0
  done

  return "$found"
}

has_external_cmd_display() {
  local dump

  dump="$(/system/bin/cmd display get-displays 2>/dev/null)"
  [ -n "$dump" ] || return 1

  printf '%s\n' "$dump" | awk '
    BEGIN { found = 0 }
    /^Display id [1-9][0-9]*:/ { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

has_external_dumpsys() {
  local dump

  dump="$(/system/bin/dumpsys display 2>/dev/null)"
  [ -n "$dump" ] || return 1

  printf '%s\n' "$dump" | awk '
    BEGIN { found = 0 }
    {
      line = toupper($0)
      if ($0 ~ /Display Id=[1-9][0-9]*/) {
        found = 1
      }
      if ($0 ~ /DisplayInfo\{/ && $0 ~ /displayId [1-9][0-9]*/) {
        found = 1
      }
      if (line ~ /DISPLAYVIEWPORT\{TYPE=EXTERNAL/) {
        found = 1
      }
      if ((line ~ /TYPE EXTERNAL/ || line ~ /TYPE=EXTERNAL/) &&
          ($0 ~ /DisplayInfo\{/ || $0 ~ /DisplayDeviceInfo\{/)) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  '
}

is_external_output_active() {
  external_drm_connectors >/dev/null 2>&1 && return 0
  has_external_cmd_display && return 0
  has_external_dumpsys && return 0
  return 1
}

is_wm_state_applied() {
  local key="$1"
  local requested="$2"
  local current
  local physical

  current="$(get_effective_wm_value "$key")"
  case "$requested" in
    ""|reset|RESET)
      physical="$(get_physical_wm_value "$key")"
      [ -n "$physical" ] || return 1
      [ "$current" = "$physical" ]
      ;;
    *)
      [ "$current" = "$requested" ]
      ;;
  esac
}

run_wm_command() {
  local key="$1"
  local value="$2"
  local fallback

  case "$value" in
    ""|reset|RESET)
      /system/bin/wm "$key" reset >/dev/null 2>&1 && return 0
      fallback="$(get_physical_wm_value "$key")"
      [ -n "$fallback" ] || fallback="$(get_wm_value "$key")"
      [ -n "$fallback" ] || return 1
      /system/bin/wm "$key" "$fallback" >/dev/null 2>&1
      ;;
    *)
      /system/bin/wm "$key" "$value" >/dev/null 2>&1
      ;;
  esac

  is_wm_state_applied "$key" "$value"
}

apply_profile() {
  local profile="$1"
  local size
  local density
  local size_ok=0
  local density_ok=0

  if [ "$profile" = "hdmi" ]; then
    size="$HDMI_SIZE"
    density="$HDMI_DENSITY"
  else
    size="$DEFAULT_SIZE"
    density="$DEFAULT_DENSITY"
  fi

  run_wm_command size "$size" && size_ok=1
  run_wm_command density "$density" && density_ok=1

  if [ "$size_ok" = "1" ] && [ "$density_ok" = "1" ]; then
    printf '%s\n' "$profile" > "$STATEFILE"
    log "Applied profile=$profile size=$size density=$density"
    return 0
  fi

  log "Failed to apply profile=$profile size=$size density=$density"
  return 1
}

current_profile() {
  [ -f "$STATEFILE" ] && cat "$STATEFILE" 2>/dev/null && return 0
  printf 'unknown\n'
}

wait_for_boot() {
  local i=0
  while [ "$(/system/bin/getprop sys.boot_completed)" != "1" ]; do
    i=$((i + 1))
    [ "$i" -ge 120 ] && break
    sleep 2
  done
  sleep 10
}

get_boot_id() {
  cat "$BOOT_ID_FILE" 2>/dev/null
}

get_process_start_time() {
  local pid="$1"
  [ -r "/proc/$pid/stat" ] || return 1
  awk '{ print $22 }' "/proc/$pid/stat" 2>/dev/null
}

write_lock_metadata() {
  local boot_id
  local start_time

  printf '%s\n' "$$" > "$LOCK_PID_FILE"

  boot_id="$(get_boot_id)"
  [ -z "$boot_id" ] || printf '%s\n' "$boot_id" > "$LOCK_BOOT_FILE"

  start_time="$(get_process_start_time "$$")"
  [ -z "$start_time" ] || printf '%s\n' "$start_time" > "$LOCK_START_FILE"
}

is_lock_active() {
  local pid
  local lock_boot_id
  local current_boot_id
  local recorded_start_time
  local current_start_time

  [ -d "$LOCKDIR" ] || return 1

  pid="$(cat "$LOCK_PID_FILE" 2>/dev/null)"
  [ -n "$pid" ] || return 1

  current_boot_id="$(get_boot_id)"
  lock_boot_id="$(cat "$LOCK_BOOT_FILE" 2>/dev/null)"
  if [ -n "$current_boot_id" ] && [ -n "$lock_boot_id" ] && [ "$current_boot_id" != "$lock_boot_id" ]; then
    return 1
  fi

  kill -0 "$pid" 2>/dev/null || return 1

  recorded_start_time="$(cat "$LOCK_START_FILE" 2>/dev/null)"
  current_start_time="$(get_process_start_time "$pid")"
  if [ -n "$recorded_start_time" ] && [ -n "$current_start_time" ] && [ "$recorded_start_time" != "$current_start_time" ]; then
    return 1
  fi

  return 0
}

acquire_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then
    LOCK_ACQUIRED=1
    write_lock_metadata
    return 0
  fi

  if is_lock_active; then
    return 1
  fi

  rm -rf "$LOCKDIR" 2>/dev/null
  mkdir "$LOCKDIR" 2>/dev/null || return 1
  LOCK_ACQUIRED=1
  write_lock_metadata
  log "Recovered stale lock"
  return 0
}

cleanup_lock() {
  [ "$LOCK_ACQUIRED" = "1" ] || return 0
  rm -f "$LOCK_PID_FILE" "$LOCK_BOOT_FILE" "$LOCK_START_FILE" 2>/dev/null
  rmdir "$LOCKDIR" 2>/dev/null
}

trap cleanup_lock EXIT

acquire_lock || exit 0
load_config
wait_for_boot
resolve_defaults
log "Service started"
log "Resolved defaults size=$DEFAULT_SIZE density=$DEFAULT_DENSITY"

while true; do
  if is_external_output_active; then
    [ "$(current_profile)" = "hdmi" ] || apply_profile "hdmi"
  else
    [ "$(current_profile)" = "default" ] || apply_profile "default"
  fi
  sleep "$POLL_INTERVAL"
done
