#!/usr/bin/env bash
# Kjører hooken mot fixtures i en isolert HOME. Bruk: tests/run.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
G="$HERE/../scripts/usage-guard.sh"
T="$(mktemp -d)"; export HOME="$T"; export USAGE_GUARD_STATE_DIR="$T/state"; export USAGE_GUARD_CACHE_TTL=0
pass=0; fail=0
# Genererte fixtures (relativ tid) ligger i $T/fx og vinner over tests/fixtures.
mkdir -p "$T/fx"
fxpath(){ if [ -f "$T/fx/$1.json" ]; then printf '%s' "$T/fx/$1.json"; else printf '%s' "$HERE/fixtures/$1.json"; fi; }
iso(){ date -u -r "$1" '+%Y-%m-%dT%H:%M:%S.239929+00:00' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%S.239929+00:00'; }
mkwarn(){ # name five_reset_epoch: warn.json med 5t-reset satt
  sed "s/2026-10-02T11:10:00.239929+00:00/$(iso "$2")/" "$HERE/fixtures/warn.json" > "$T/fx/$1.json"
}
RESET=$(( $(date +%s) / 60 * 60 + 3600 ))   # vinduet slutter om ca. én time
mkwarn warn_live        "$RESET"
mkwarn warn_jitter      $(( RESET - 2 ))
mkwarn warn_next_window $(( RESET + 18000 ))
check(){ # name mode fixture prompt expect_rc expect_substr [session]
  local name="$1" mode="$2" fx="$3" prompt="$4" erc="$5" esub="$6" sid="${7:-s1}"
  local out rc
  out="$(printf '{"session_id":"%s","prompt":"%s","tool_name":"Bash"}' "$sid" "$prompt" | USAGE_GUARD_FIXTURE="$(fxpath "$fx")" bash "$G" "$mode" 2>&1)"; rc=$?
  if [ "$rc" = "$erc" ] && { if [ -z "$esub" ]; then [ -z "$out" ]; else printf '%s' "$out" | grep -qF -- "$esub"; fi; }; then
    pass=$((pass+1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf '  FAIL %s (rc=%s)\n%s\n' "$name" "$rc" "$out"
  fi
}
check "session: status med reset"       session low            ""              0 "📊 Claude-forbruk: 5t 3% · resettes"
check "session: viser credits"           session low            ""              0 "usage credits 40.82 USD"
check "advarsel inneholder reset-tid"    prompt warn            "hei"           0 "7d 40% · resettes"
check "lavt forbruk: stille"             prompt low            "hei"             0 ""
check "credits øker under grensen: første"  prompt low_used_a "hei"           0 ""
check "credits øker under grensen: varsel"  prompt low_used_b "hei"           0 "💳 Usage credits i bruk: +0.47 USD"
check "credits uendret: stille"             prompt low_used_b "hei"           0 ""
rm -f "$USAGE_GUARD_STATE_DIR"/warned-*
check "80-99: advarsel"                  prompt warn_live      "hei"             0 "⚠️ Usage guard: 85%"
check "80-99: kun én gang per vindu"     prompt warn_live      "hei"             0 ""
check "80-99: ikke i ny økt heller"      prompt warn_live      "hei"             0 "" s2
check "80-99: jitter i reset-tid = samme vindu" prompt warn_jitter "hei"         0 ""
# Statuslinje-fallback (oauth feiler): samme vindu, med og uten reset-tid.
mkdir -p "$HOME/.claude/state"; LS="$HOME/.claude/state/rate-limits.json"
printf '{"five_hour":85,"seven_day":40,"at":%s}' "$(date +%s)" > "$LS"
check "80-99: fallback uten reset-tid er stille" prompt broken "hei"             0 ""
check "80-99: tilbake på oauth er stille"  prompt warn_live      "hei"             0 ""
printf '{"five_hour":85,"seven_day":40,"five_resets":%s,"at":%s}' "$RESET" "$(date +%s)" > "$LS"
check "80-99: fallback med reset-tid er stille" prompt broken "hei"              0 ""
printf '%s' $(( $(date +%s) - 1000 )) > "$USAGE_GUARD_STATE_DIR/warned-5-timersgrensen"
printf '{"five_hour":85,"seven_day":40,"at":%s}' "$(date +%s)" > "$LS"
check "80-99: vindu over, ukjent reset varsler" prompt broken "hei"             0 "⚠️ Usage guard: 85%"
printf '%s' "$RESET" > "$USAGE_GUARD_STATE_DIR/warned-5-timersgrensen"
rm -f "$LS"
check "80-99: nytt vindu varsler igjen"  prompt warn_next_window "hei"         0 "⚠️ Usage guard: 85%"
check "slash alltid gjennom"             prompt limit          "/usage"          0 ""
check "grense nådd: blokker"             prompt limit          "hei"             2 "skriv  !overage-ok"
check "7d-grense: blokker"               prompt limit7d        "hei"             2 "Ukesgrensen er nådd"
check "tool ved grense: deny"            tool   limit          ""                0 '"permissionDecision":"deny"'
check "beløp uten personlig grense"      prompt limit          "hei"             2 "brukt 40.82 USD denne måneden"
check "beløp med personlig grense"       prompt limit_with_cap "hei"             2 "brukt 312.50 av 800.00 USD"
check "reset-tid vises"                  prompt limit          "hei"             2 " kl. "
check "credits av: ingen blokkering"     prompt limit_disabled "hei"             0 ""
check "bekreft med !overage-ok"          prompt limit          "fiks !overage-ok" 0 "✅ Bekreftet"
check "etter bekreftelse: påminnelse"    prompt limit          "hei"             0 "💳 Du kjører på usage credits"
check "tool etter bekreftelse: ok"       tool   limit          ""                0 ""
rm -f "$USAGE_GUARD_STATE_DIR"/ack-*
check "ny økt krever nytt valg"          prompt limit          "hei"             2 "⛔"
check "api-feil: fail open"              prompt broken         "hei"             0 ""
printf '\n%d ok, %d feilet\n' "$pass" "$fail"; rm -rf "$T"; [ "$fail" -eq 0 ]
