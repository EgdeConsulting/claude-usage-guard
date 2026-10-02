#!/usr/bin/env bash
# usage-guard.sh prompt|tool|session
#
# session (SessionStart): viser forbruk, reset-tidspunkt og credits ved oppstart.
# prompt (UserPromptSubmit):
#   credits øker under grensen : kort linje med beløp per prompt
#   WARN..99 %                 : systemMessage-advarsel én gang per grensevindu, prompten går gjennom
#   >= 100 % + credits         : prompten avvises til brukeren svarer med !overage-ok
#                                (gjelder resten av økten), deretter påminnelse per prompt
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

# ---------- input ----------
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

# ---------- forbruksdata ----------
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

# ---------- hjelpere ----------
to_epoch() {
  local v="$1"
  case "$v" in
    '') return ;;
    *T*) local iso="${v%%.*}"; iso="${iso%%+*}"; iso="${iso%Z}"
         date -j -u -f '%Y-%m-%dT%H:%M:%S' "$iso" '+%s' 2>/dev/null || date -u -d "${iso}Z" '+%s' 2>/dev/null || true ;;
    *) printf '%s' "$v" | tr -cd '0-9' ;;
  esac
}
lt() { date -r "$1" "+$2" 2>/dev/null || date -d "@$1" "+$2" 2>/dev/null; }   # lokal tid, BSD/GNU
fmt_reset() {
  local epoch; epoch="$(to_epoch "$1")"; [ -z "$epoch" ] && return
  local clock day today tomorrow left rel
  clock="$(lt "$epoch" '%H:%M')"; day="$(lt "$epoch" '%Y%m%d')"
  today="$(date '+%Y%m%d')"; tomorrow="$(date -v+1d '+%Y%m%d' 2>/dev/null || date -d tomorrow '+%Y%m%d' 2>/dev/null)"
  left=$(( (epoch - now) / 60 )); [ "$left" -lt 0 ] && left=0
  if [ "$left" -ge 60 ]; then rel="om $((left/60))t $((left%60))m"; else rel="om ${left}m"; fi
  if [ "$day" = "$today" ]; then printf 'i dag kl. %s (%s)' "$clock" "$rel"
  elif [ "$day" = "$tomorrow" ]; then printf 'i morgen kl. %s (%s)' "$clock" "$rel"
  else printf '%s kl. %s (%s)' "$(lt "$epoch" '%d.%m')" "$clock" "$rel"; fi
}
# JSON-escaping uten jq: backslash, anførselstegn, linjeskift.
jstr() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'NR>1{printf "\\n"}{printf "%s",$0}'; }
sysmsg() { printf '{"systemMessage":"%s"}\n' "$(jstr "$1")"; }

# ---------- avledet status ----------
worst="$five"; window="5-timersgrensen"; Window="5-timersgrensen"; resets="$five_resets"
if [ "$seven" -gt "$five" ]; then worst="$seven"; window="ukesgrensen"; Window="Ukesgrensen"; resets="$seven_resets"; fi
reset_txt="$(fmt_reset "$resets")"
five_txt="$(fmt_reset "$five_resets")"; seven_txt="$(fmt_reset "$seven_resets")"
status_txt="5t ${five}%${five_txt:+ · resettes ${five_txt}} | 7d ${seven}%${seven_txt:+ · resettes ${seven_txt}}"
credits_txt="usage credits"
if [ -n "$extra_used" ]; then
  if [ -n "$extra_limit" ]; then credits_txt="usage credits (brukt ${extra_used} av ${extra_limit} ${currency} denne måneden)"
  else credits_txt="usage credits (brukt ${extra_used} ${currency} denne måneden)"; fi
fi

# ---------- session: alltid status ----------
if [ "$MODE" = "session" ]; then
  c="ingen usage credits brukt"
  [ -n "$extra_used" ] && c="usage credits ${extra_used} ${currency} denne måneden"
  [ "$extra_enabled" = "true" ] || c="usage credits er av for kontoen"
  sysmsg "📊 Claude-forbruk: ${status_txt} | ${c}"
  exit 0
fi

# ---------- credits i bruk under grensen ----------
# Credits kan forbrukes uten at noen grense er nådd (f.eks. modeller som
# faktureres som usage credits). Si fra når beløpet øker mellom to prompter.
if [ "$MODE" = "prompt" ] && [ -n "$extra_used" ]; then
  last_file="$STATE_DIR/last-used-$session"
  last="$(cat "$last_file" 2>/dev/null || true)"
  printf '%s' "$extra_used" > "$last_file"
  if [ -n "$last" ] && [ "$worst" -lt "$LIMIT" ]; then
    delta="$(awk -v a="$extra_used" -v b="$last" 'BEGIN { d = a - b; if (d > 0.004) printf "%.2f", d }')"
    [ -n "$delta" ] && sysmsg "💳 Usage credits i bruk: +${delta} ${currency} siden forrige prompt, ${extra_used} ${currency} denne måneden. Dette faktureres utenfor abonnementet selv om grensene ikke er nådd. ${status_txt}."
  fi
fi

[ "$worst" -lt "$WARN" ] && exit 0

# ---------- 80-99 %: advarsel ----------
if [ "$worst" -lt "$LIMIT" ]; then
  [ "$MODE" = "prompt" ] || exit 0
  # Én advarsel per grensevindu, på tvers av økter: nøkkelen er vindu + reset-minutt.
  reset_min="$(to_epoch "$resets")"; [ -n "$reset_min" ] && reset_min=$(( reset_min / 60 ))
  warned_file="$STATE_DIR/warned-${window}-${reset_min:-ukjent}"
  [ -f "$warned_file" ] && exit 0
  rm -f "$STATE_DIR"/warned-* 2>/dev/null || true
  : > "$warned_file" 2>/dev/null || true
  sysmsg "⚠️ Usage guard: ${worst}% av ${window} brukt. ${status_txt}. Ved 100 % stoppes økten og du må velge om du vil fortsette på usage credits."
  exit 0
fi

# ---------- 100 %: grensen er nådd ----------
# Uten credits stopper Claude Code selv, ingenting å vokte.
[ "$extra_enabled" = "true" ] || exit 0

if [ "$MODE" = "prompt" ] && printf '%s' "$flat" | grep -qF -- "$ACK_WORD"; then
  date +%s > "$ack_file"
  sysmsg "✅ Bekreftet: resten av denne økten kjører på ${credits_txt}. Ny økt krever nytt valg. ${status_txt}."
  exit 0
fi

if [ -f "$ack_file" ]; then
  [ "$MODE" = "prompt" ] && sysmsg "💳 Du kjører på ${credits_txt}. ${Window} resettes ${reset_txt:-snart}. ${status_txt}."
  exit 0
fi

msg="⛔ ${Window} er nådd${reset_txt:+, resettes ${reset_txt}}. ${status_txt}.
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
