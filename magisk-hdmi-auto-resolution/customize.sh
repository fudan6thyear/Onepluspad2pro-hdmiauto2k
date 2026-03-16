SKIPMOUNT=true
PROPFILE=false
POSTFSDATA=false
LATESTARTSERVICE=true

print_modname() {
  ui_print "*******************************"
  ui_print " HDMI Auto Resolution Switch "
  ui_print "*******************************"
}

on_install() {
  ui_print "- Installing module files"
}

set_permissions() {
  set_perm_recursive "$MODPATH" 0 0 0755 0644
  set_perm "$MODPATH/service.sh" 0 0 0755
  set_perm "$MODPATH/uninstall.sh" 0 0 0755
}
