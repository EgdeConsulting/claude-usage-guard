#!/usr/bin/env bash
# Henter forbruksstatus for den innloggede claude.ai-kontoen og skriver
# normalisert JSON til stdout:
#   {"five":<pct>,"seven":<pct>,"extra_enabled":bool,"extra_used":n|null,
#    "extra_limit":n|null,"extra_pct":n|null,"currency":s|null,"source":s,"at":epoch}
#
# Kilde 1: /api/oauth/usage (samme endepunkt som /usage i Claude Code).
# Kilde 2: ~/.claude/state/rate-limits.json (speilet av en statuslinje) hvis 1 feiler.
# Svaret caches i CACHE_TTL sekunder slik at PreToolUse ikke gir latens.
# USAGE_GUARD_FIXTURE=<fil> leser rått API-svar fra fil (brukes av testene).
set -uo pipefail

CACHE_TTL="${USAGE_GUARD_CACHE_TTL:-60}"
STATE_DIR="${USAGE_GUARD_STATE_DIR:-$HOME/.claude/state/usage-guard}"
CACHE="$STATE_DIR/usage.json"
ENDPOINT="${USAGE_GUARD_ENDPOINT:-https://api.anthropic.com/api/oauth/usage}"
LEGACY_STATE="$HOME/.claude/state/rate-limits.json"

mkdir -p "$STATE_DIR" 2>/dev/null || true
now="$(date +%s)"

if [ -z "${USAGE_GUARD_FIXTURE:-}" ] && [ -f "$CACHE" ]; then
  at="$(jq -r '.at // 0' "$CACHE" 2>/dev/null || echo 0)"
  if [ $(( now - ${at:-0} )) -lt "$CACHE_TTL" ]; then cat "$CACHE"; exit 0; fi
fi

read_token() {
  if [ -n "${USAGE_GUARD_TOKEN:-}" ]; then printf '%s' "$USAGE_GUARD_TOKEN"; return; fi
  local raw=""
  case "$(uname -s)" in
    Darwin) raw="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)" ;;
  esac
  [ -z "$raw" ] && [ -f "$HOME/.claude/.credentials.json" ] && raw="$(cat "$HOME/.claude/.credentials.json")"
  printf '%s' "$raw" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null
}

raw=""
if [ -n "${USAGE_GUARD_FIXTURE:-}" ]; then
  raw="$(cat "$USAGE_GUARD_FIXTURE" 2>/dev/null || true)"
else
  tok="$(read_token)"
  if [ -n "$tok" ]; then
    raw="$(curl -sS --max-time 4 -H "Authorization: Bearer $tok" -H "anthropic-beta: oauth-2025-04-20" "$ENDPOINT" 2>/dev/null || true)"
  fi
fi

normalize() {
  jq -c --argjson now "$now" '
    def pct(x): if x == null then null elif x <= 1 and (x|floor) != x then x*100 else x end;
    {
      five:  (pct(.five_hour.utilization)  // 0),
      seven: (pct(.seven_day.utilization) // 0),
      five_resets: (.five_hour.resets_at // null),
      seven_resets: (.seven_day.resets_at // null),
      extra_enabled: (.extra_usage.is_enabled // false),
      extra_used:  (.extra_usage.used_credits // null),
      extra_limit: (.extra_usage.monthly_limit // null),
      extra_pct:   (pct(.extra_usage.utilization) // null),
      currency:    (.extra_usage.currency // null),
      source: "oauth", at: $now
    }'
}

if [ -n "$raw" ] && printf '%s' "$raw" | jq -e '.five_hour or .seven_day' >/dev/null 2>&1; then
  out="$(printf '%s' "$raw" | normalize)"
elif [ -f "$LEGACY_STATE" ]; then
  out="$(jq -c --argjson now "$now" '{five:(.five_hour//0),seven:(.seven_day//0),five_resets:null,seven_resets:null,extra_enabled:true,extra_used:null,extra_limit:null,extra_pct:null,currency:null,source:"statusline",at:(.at//0|floor)}' "$LEGACY_STATE" 2>/dev/null || true)"
else
  out=""
fi

[ -z "$out" ] && exit 1
printf '%s' "$out" | tee "$CACHE.tmp" >/dev/null && mv "$CACHE.tmp" "$CACHE"
printf '%s\n' "$out"
