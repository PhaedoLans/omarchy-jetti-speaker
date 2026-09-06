#!/bin/bash
# Shared state, paths, and helpers for Jetti Speaker.
#
# Sourced by every jspeaker-* command. Defines where runtime state lives, how the
# PipeWire graph is named, and the few helpers that more than one command needs.

JSPK_ID="jetti.speaker"
JSPK_SINK="jetti_speaker"          # the virtual device apps play into
JSPK_CAL_SINK="jetti_speaker_cal"        # multichannel sink used only during calibration
JSPK_LOOPBACK_PREFIX="jsout"  # node.name prefix for the fan-out loopbacks

JSPK_RUNTIME="${XDG_RUNTIME_DIR:-/tmp}/omarchy-jetti-speaker"
JSPK_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/jetti-speaker"
JSPK_PROFILE="$JSPK_CONFIG/profile.json"
JSPK_STATUS="$JSPK_RUNTIME/status.json"
JSPK_PIDS="$JSPK_RUNTIME/pids"
JSPK_MODULES="$JSPK_RUNTIME/modules"
JSPK_CARDS="$JSPK_CONFIG/card-restore.json"

mkdir -p "$JSPK_RUNTIME" "$JSPK_CONFIG" "$JSPK_PIDS" "$JSPK_MODULES"

jspeaker_die() {
  echo "jspeaker: $*" >&2
  exit 1
}

jspeaker_have() { command -v "$1" >/dev/null 2>&1; }

for _t in pactl pw-loopback jq; do
  jspeaker_have "$_t" || jspeaker_die "missing required tool: $_t"
done

# Write JSON atomically. Every consumer (the QML FileView in particular) watches
# these files, and a half-written file parses as garbage rather than as an error.
jspeaker_write_json() {
  local target="$1" tmp
  tmp="$(mktemp "${target}.XXXXXX")" || return 1
  cat >"$tmp" || { rm -f "$tmp"; return 1; }
  jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$target"
}

# Kill a process we started, by pid file. Deliberately never pkill -f: the
# pattern would match the very script doing the killing, which takes the whole
# command down with it.
jspeaker_kill_pidfile() {
  local f="$1" pid
  [[ -f $f ]] || return 0
  pid="$(cat "$f" 2>/dev/null)"
  if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    # Only kill it if it really is one of ours; a recycled pid belongs to
    # somebody else and killing it would be somebody else's bad afternoon.
    # Ours are either a fan-out loopback or a crossover hosted by `pipewire -c`
    # reading a conf out of our own runtime directory. Nothing else qualifies,
    # so a recycled pid belonging to somebody else is left alone -- and the main
    # pipewire daemon can never match, because it does not read our conf.
    if grep -qa "pw-loopback" "/proc/$pid/cmdline" 2>/dev/null ||
      grep -qa "$JSPK_RUNTIME" "/proc/$pid/cmdline" 2>/dev/null; then
      kill "$pid" 2>/dev/null
    fi
  fi
  rm -f "$f"
}

jspeaker_unload_modulefile() {
  local f="$1" id
  [[ -f $f ]] || return 0
  id="$(cat "$f" 2>/dev/null)"
  [[ $id =~ ^[0-9]+$ ]] && pactl unload-module "$id" 2>/dev/null
  rm -f "$f"
}

# The channel positions a calibration sink uses, in order. One per speaker under
# test; the list caps how many speakers a single calibration pass can cover.
JSPK_CAL_POSITIONS=(front-left front-right rear-left rear-right front-center lfe side-left side-right)
JSPK_CAL_POSITIONS_SHORT=(FL FR RL RR FC LFE SL SR)
