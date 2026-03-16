#!/system/bin/sh

size="$(
  /system/bin/wm size 2>/dev/null | awk -F': ' '
    /Physical size/ {
      print $2
      exit
    }
  '
)"

density="$(
  /system/bin/wm density 2>/dev/null | awk -F': ' '
    /Physical density/ {
      print $2
      exit
    }
  '
)"

/system/bin/wm size reset >/dev/null 2>&1
[ -n "$density" ] && /system/bin/wm density "$density" >/dev/null 2>&1
[ -n "$size" ] || exit 0
/system/bin/wm size "$size" >/dev/null 2>&1
