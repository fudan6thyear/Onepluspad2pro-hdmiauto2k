#!/system/bin/sh

MODDIR=${0%/*}
MODULE_ID=hdmi_auto_resolution
LOGFILE="$MODDIR/hdmi_auto_resolution.log"
STATEFILE="$MODDIR/current_profile"
LOCKDIR="/dev/.${MODULE_ID}.lock"

HDMI_SIZE="1440x2560"
HDMI_DENSITY="160"
DEFAULT_SIZE="2400x3392"
DEFAULT_DENSITY="420"
POLL_INTERVAL="3"

log() {
  printf '%s %s\n' "$(/system/bin/date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOGFILE"
}

has_external_drm_status() {
  local path
  local connector
  local status

  for path in /sys/class/drm/*/status; do
    [ -f "$path" ] || continue
    connector=$(basename "$(dirname "$path")")
    case "$connector" in
      *eDP*|*EDP*|*DSI*|*LVDS*)
        continue
        ;;
      *HDMI*|*hdmi*|*DP-*|*dp-*|*DisplayPort*|*displayport*|*TYPEC*|*typec*|*USB-C*|*usb-c*)
        status="$(cat "$path" 2>/dev/null)"
        [ "$status" = "connected" ] && return 0
        ;;
    esac
  done

  return 1
}

has_external_dumpsys() {
  local dump

  dump="$(
    /system/bin/dumpsys display 2>/dev/null
    /system/bin/cmd display get-displays 2>/dev/null
  )"
  [ -n "$dump" ] || return 1

  printf '%s\n' "$dump" | awk '
    BEGIN { found = 0 }
    {
      line = toupper($0)
      if (line ~ /TYPE[ =]EXTERNAL/ ||
          line ~ /FLAG_PRESENTATION/ ||
          line ~ /DISPLAYPORT/ ||
          line ~ /HDMI/ ||
          line ~ /TOUCH EXTERNAL/) {
        found = 1
      }
      if (line ~ /LOGICALDISPLAY\{/ &&
          line ~ /DISPLAYID[ =][1-9]/ &&
          line ~ /ISENABLED=TRUE/) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  '
}

is_external_output_active() {
  has_external_drm_status && return 0
  has_external_dumpsys && return 0
  return 1
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

  /system/bin/wm size "$size" >/dev/null 2>&1 && size_ok=1
  /system/bin/wm density "$density" >/dev/null 2>&1 && density_ok=1

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

cleanup_lock() {
  rmdir "$LOCKDIR" 2>/dev/null
}

trap cleanup_lock EXIT

mkdir "$LOCKDIR" 2>/dev/null || exit 0
wait_for_boot
log "Service started"

while true; do
  if is_external_output_active; then
    [ "$(current_profile)" = "hdmi" ] || apply_profile "hdmi"
  else
    [ "$(current_profile)" = "default" ] || apply_profile "default"
  fi
  sleep "$POLL_INTERVAL"
done
