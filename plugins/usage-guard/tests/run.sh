#!/usr/bin/env bash
# Kjører hooken mot fixtures i en isolert HOME. Bruk: tests/run.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
G="$HERE/../scripts/usage-guard.sh"
T="$(mktemp -d)"; export HOME="$T"; export USAGE_GUARD_STATE_DIR="$T/state"; export USAGE_GUARD_CACHE_TTL=0
pass=0; fail=0
check(){ # name mode fixture prompt expect_rc expect_substr
  local name="$1" mode="$2" fx="$3" prompt="$4" erc="$5" esub="$6"
  local out rc
  out="$(printf '{"session_id":"s1","prompt":"%s","tool_name":"Bash"}' "$prompt" | USAGE_GUARD_FIXTURE="$HERE/fixtures/$fx.json" bash "$G" "$mode" 2>&1)"; rc=$?
  if [ "$rc" = "$erc" ] && { [ -z "$esub" ] && [ -z "$out" ] || printf '%s' "$out" | grep -qF -- "$esub"; }; then
    pass=$((pass+1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf '  FAIL %s (rc=%s)\n%s\n' "$name" "$rc" "$out"
  fi
}
check "lavt forbruk: stille"             prompt low            "hei"             0 ""
check "80-99: advarsel"                  prompt warn           "hei"             0 "⚠️ Usage guard: 85%"
check "slash alltid gjennom"             prompt limit          "/usage"          0 ""
check "grense nådd: blokker"             prompt limit          "hei"             2 "skriv  !overage-ok"
check "7d-grense: blokker"               prompt limit7d        "hei"             2 "Ukesgrensen er nådd"
check "tool ved grense: deny"            tool   limit          ""                0 '"permissionDecision":"deny"'
check "beløp uten personlig grense"      prompt limit          "hei"             2 "brukt 40.82 USD denne måneden"
check "beløp med personlig grense"       prompt limit_with_cap "hei"             2 "brukt 312.50 av 800.00 USD"
check "reset-tid vises"                  prompt limit          "hei"             2 "resettes 02.10 kl."
check "credits av: ingen blokkering"     prompt limit_disabled "hei"             0 ""
check "bekreft med !overage-ok"          prompt limit          "fiks !overage-ok" 0 "✅ Bekreftet"
check "etter bekreftelse: påminnelse"    prompt limit          "hei"             0 "💳 Du kjører på usage credits"
check "tool etter bekreftelse: ok"       tool   limit          ""                0 ""
rm -f "$USAGE_GUARD_STATE_DIR"/ack-*
check "ny økt krever nytt valg"          prompt limit          "hei"             2 "⛔"
check "api-feil: fail open"              prompt broken         "hei"             0 ""
printf '\n%d ok, %d feilet\n' "$pass" "$fail"; rm -rf "$T"; [ "$fail" -eq 0 ]
