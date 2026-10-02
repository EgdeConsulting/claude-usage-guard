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
# Krav: bash 3.2+, sed, grep, awk (macOS, Linux, Windows med Git Bash). Ingen jq.
# Feiler alltid åpent: ingen data, gamle data eller feil => ingen blokkering.
set -u

MODE="${1:-prompt}"
WARN="${USAGE_GUARD_WARN:-80}"
LIMIT="${USAGE_GUARD_LIMIT:-100}"
STALE="${USAGE_GUARD_STALE:-1800}"
STATE_DIR="${USAGE_GUARD_STATE_DIR:-$HOME/.claude/state/usage-guard}"
ACK_WORD="!overage-ok"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

input="$(cat)"
flat="$(printf '%s' "$input" | tr -d '\n')"
session="$(printf '%s' "$flat" | sed -nE 's/.*"session_id" *: *"([^"]*)".*/\1/p' | tr -cd 'A-Za-z0-9_.-')"
[ -z "$session" ] && session=nosession
ack_file="$STATE_DIR/ack-$session"
mkdir -p "$STATE_DIR" 2>/dev/null || true

if [ "$MODE" = "prompt" ]; then
  # Slash-kommandoer (/usage, /usage-credits, /clear ...) går alltid gjennom.
  printf '%s' "$flat" | grep -qE '"(prompt|user_input)" *: *"/' && exit 0
fi

usage="$("$HERE/fetch-usage.sh" 2>/dev/null)" || exit 0
[ -z "$usage" ] && exit 0
five=0; seven=0; five_resets=""; seven_resets=""; extra_enabled=false; extra_used=""; extra_limit=""; currency=""; at=0
while IFS='=' read -r k v; do
  case "$k" in five|seven|at) v="$(printf '%s' "$v" | tr -cd '0-9')"; [ -z "$v" ] && v=0 ;; esac
  case "$k" in five|seven|five_resets|seven_resets|extra_enabled|extra_used|extra_limit|currency|at) eval "$k=\"\$v\"" ;; esac
done <<EOF_USAGE
$usage
EOF_USAGE

now="$(date +%s)"
[ $(( now - at )) -gt "$STALE" ] && exit 0

worst="$five"; window="5-timersgrensen"; Window="5-timersgrensen"; resets="$five_resets"
if [ "$seven" -gt "$five" ]; then worst="$seven"; window="ukesgrensen"; Window="Ukesgrensen"; resets="$seven_resets"; fi

# JSON-escaping uten jq: backslash, anførselstegn, linjeskift.
jstr() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'NR>1{printf "\\n"}{printf "%s",$0}'; }
sysmsg() { printf '{"systemMessage":"%s"}\n' "$(jstr "$1")"; }

# Credits kan forbrukes uten at noen grense er nådd (f.eks. modeller som
# faktureres som usage credits). Si fra når beløpet øker mellom to prompter.
if [ "$MODE" = "prompt" ] && [ -n "$extra_used" ]; then
  last_file="$STATE_DIR/last-used-$session"
  last="$(cat "$last_file" 2>/dev/null || true)"
  printf '%s' "$extra_used" > "$last_file"
  if [ -n "$last" ] && [ "$worst" -lt "$LIMIT" ]; then
    delta="$(awk -v a="$extra_used" -v b="$last" 'BEGIN { d = a - b; if (d > 0.004) printf "%.2f", d }')"
    [ -n "$delta" ] && sysmsg "💳 Usage credits i bruk: +${delta} ${currency} siden forrige prompt, ${extra_used} ${currency} denne måneden. Dette faktureres utenfor abonnementet selv om grensene ikke er nådd (5t ${five}% / 7d ${seven}%)."
  fi
fi

[ "$worst" -lt "$WARN" ] && exit 0

fmt_reset() {
  # ISO ("2026-10-02T11:10:00.239+00:00"), epoch eller tomt -> lokal tid, ellers UTC-tekst.
  local v="$1" epoch=""
  case "$v" in
    '') return ;;
    *T*) local iso="${v%%.*}"; iso="${iso%%+*}"; iso="${iso%Z}"
         epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "$iso" '+%s' 2>/dev/null || date -u -d "${iso}Z" '+%s' 2>/dev/null || true)"
         [ -z "$epoch" ] && { printf '%s UTC' "$(printf '%s' "$iso" | sed -E 's/T/ /; s/:[0-9]{2}$//')"; return; } ;;
    *) epoch="$v" ;;
  esac
  date -r "$epoch" '+%d.%m kl. %H:%M' 2>/dev/null || date -d "@$epoch" '+%d.%m kl. %H:%M' 2>/dev/null || true
}
reset_txt="$(fmt_reset "$resets")"
credits_txt="usage credits"
if [ -n "$extra_used" ]; then
  if [ -n "$extra_limit" ]; then credits_txt="usage credits (brukt ${extra_used} av ${extra_limit} ${currency} denne måneden)"
  else credits_txt="usage credits (brukt ${extra_used} ${currency} denne måneden)"; fi
fi

if [ "$worst" -lt "$LIMIT" ]; then
  [ "$MODE" = "prompt" ] && sysmsg "⚠️ Usage guard: ${worst}% av ${window} brukt (5t ${five}% / 7d ${seven}%). Ved 100 % stoppes økten og du må velge om du vil fortsette på usage credits."
  exit 0
fi

# Grensen er nådd. Uten credits stopper Claude Code selv, ingenting å vokte.
[ "$extra_enabled" = "true" ] || exit 0

if [ "$MODE" = "prompt" ] && printf '%s' "$flat" | grep -qF -- "$ACK_WORD"; then
  date +%s > "$ack_file"
  sysmsg "✅ Bekreftet: resten av denne økten kjører på ${credits_txt}. Ny økt krever nytt valg."
  exit 0
fi

if [ -f "$ack_file" ]; then
  [ "$MODE" = "prompt" ] && sysmsg "💳 Du kjører på ${credits_txt}. ${Window} resettes ${reset_txt:-snart}."
  exit 0
fi

msg="⛔ ${Window} er nådd (5t ${five}% / 7d ${seven}%)${reset_txt:+, resettes ${reset_txt}}.
Fortsetter du nå, faktureres alt videre som ${credits_txt}, utenfor abonnementet.
  • Vent til grensen resettes, eller
  • skriv  ${ACK_WORD}  i prompten for å fortsette på usage credits ut denne økten."

if [ "$MODE" = "prompt" ]; then
  printf '%s\n' "$msg" >&2
  exit 2
fi
r="$(jstr "$msg")"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"},"systemMessage":"%s"}\n' "$r" "$r"
exit 0
