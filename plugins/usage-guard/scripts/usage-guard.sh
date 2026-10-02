#!/usr/bin/env bash
# usage-guard.sh prompt|tool
#
# prompt (UserPromptSubmit):
#   < WARN %            : stille
#   WARN..99 %          : systemMessage-advarsel, prompten går gjennom
#   >= 100 % + credits  : prompten avvises til brukeren svarer med !overage-ok
#                         (gjelder resten av økten), deretter påminnelse per prompt
# tool (PreToolUse):
#   >= 100 % + credits uten bekreftelse: verktøykallet nektes med forklaring,
#   slik at en pågående agentisk tur også stopper og ber om valget.
#
# Feiler alltid åpent: ingen data, gamle data eller feil => ingen blokkering.
# Slash-kommandoer går alltid gjennom. Credits av for kontoen => ingenting å
# vokte, Claude Code stopper selv ved grensen.
set -uo pipefail

MODE="${1:-prompt}"
WARN="${USAGE_GUARD_WARN:-80}"
LIMIT="${USAGE_GUARD_LIMIT:-100}"
STALE="${USAGE_GUARD_STALE:-1800}"
STATE_DIR="${USAGE_GUARD_STATE_DIR:-$HOME/.claude/state/usage-guard}"
ACK_WORD="!overage-ok"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v jq >/dev/null 2>&1 || exit 0
input="$(cat)"
session="$(printf '%s' "$input" | jq -r '.session_id // "nosession"')"
ack_file="$STATE_DIR/ack-$session"
mkdir -p "$STATE_DIR" 2>/dev/null || true

prompt=""
if [ "$MODE" = "prompt" ]; then
  prompt="$(printf '%s' "$input" | jq -r '.prompt // .user_input // ""')"
  case "$prompt" in /*) exit 0 ;; esac
fi

usage="$("$HERE/fetch-usage.sh" 2>/dev/null)" || exit 0
[ -z "$usage" ] && exit 0

IFS=$'\t' read -r five seven extra_enabled extra_used extra_limit currency at seven_resets five_resets <<<"$(
  printf '%s' "$usage" | jq -r '[ (.five|floor), (.seven|floor), (.extra_enabled|tostring),
    (.extra_used // "?"), (.extra_limit // "?"), (.currency // ""), (.at|floor),
    (.seven_resets // ""), (.five_resets // "") ] | @tsv'
)"
now="$(date +%s)"
[ $(( now - at )) -gt "$STALE" ] && exit 0

worst="$five"; window="5-timersgrensen"; resets="$five_resets"
if [ "$seven" -gt "$five" ]; then worst="$seven"; window="ukesgrensen"; resets="$seven_resets"; fi
[ "$worst" -lt "$WARN" ] && exit 0

fmt_reset() { [ -z "$1" ] && return; date -r "${1%%.*}" '+%a %d.%m kl. %H:%M' 2>/dev/null || date -d "@${1%%.*}" '+%a %d.%m kl. %H:%M' 2>/dev/null || true; }
reset_txt="$(fmt_reset "$resets")"
credits_txt="usage credits"
[ "$extra_used" != "?" ] && credits_txt="usage credits (brukt ${extra_used} av ${extra_limit} ${currency} denne måneden)"

sysmsg() { jq -n --arg m "$1" '{systemMessage: $m}'; }

if [ "$worst" -lt "$LIMIT" ]; then
  [ "$MODE" = "prompt" ] && sysmsg "⚠️ Usage guard: ${worst}% av ${window} brukt (5t ${five}% / 7d ${seven}%). Ved 100 % stoppes økten og du må velge om du vil fortsette på usage credits."
  exit 0
fi

# Grensen er nådd.
if [ "$extra_enabled" != "true" ]; then exit 0; fi   # Claude Code stopper selv, ingen credits i spill

if [ "$MODE" = "prompt" ] && printf '%s' "$prompt" | grep -qF -- "$ACK_WORD"; then
  date +%s > "$ack_file"
  sysmsg "✅ Bekreftet: resten av denne økten kjører på ${credits_txt}. Ny økt krever nytt valg."
  exit 0
fi

if [ -f "$ack_file" ]; then
  [ "$MODE" = "prompt" ] && sysmsg "💳 Du kjører på ${credits_txt}. ${window^} resettes ${reset_txt:-snart}."
  exit 0
fi

msg="⛔ ${window^} er nådd (5t ${five}% / 7d ${seven}%)${reset_txt:+, resettes ${reset_txt}}.
Fortsetter du nå, faktureres alt videre som ${credits_txt}, utenfor abonnementet.
  • Vent til grensen resettes, eller
  • skriv  ${ACK_WORD}  i prompten for å fortsette på usage credits ut denne økten."

if [ "$MODE" = "prompt" ]; then
  printf '%s\n' "$msg" >&2
  exit 2
fi

jq -n --arg r "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r},systemMessage:$r}'
exit 0
