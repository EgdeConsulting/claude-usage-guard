#!/usr/bin/env bash
# Henter forbruksstatus for den innloggede claude.ai-kontoen og skriver
# key=value-linjer til stdout (five, seven, five_resets, seven_resets,
# extra_enabled, extra_used, extra_limit, currency, source, at).
#
# Krav: bash 3.2+, curl, sed, grep, awk. Ingen jq. Kjører på macOS, Linux og
# Windows (Git Bash). Innlogging leses fra macOS-nøkkelring eller
# ~/.claude/.credentials.json (Linux/Windows).
#
# Kilde 1: /api/oauth/usage (samme som /usage i Claude Code).
# Kilde 2: ~/.claude/state/rate-limits.json fra en statuslinje, hvis 1 feiler.
# Svaret caches CACHE_TTL sekunder. USAGE_GUARD_FIXTURE=<fil> leser rått svar fra fil.
set -u

CACHE_TTL="${USAGE_GUARD_CACHE_TTL:-60}"
STATE_DIR="${USAGE_GUARD_STATE_DIR:-$HOME/.claude/state/usage-guard}"
CACHE="$STATE_DIR/usage.env"
ENDPOINT="${USAGE_GUARD_ENDPOINT:-https://api.anthropic.com/api/oauth/usage}"
LEGACY_STATE="$HOME/.claude/state/rate-limits.json"

mkdir -p "$STATE_DIR" 2>/dev/null || true
now="$(date +%s)"

# Trekker ut første forekomst av "key": <verdi> fra en JSON-streng. Verdi uten anførselstegn.
jget() { printf '%s' "$2" | tr -d '\n' | sed -nE 's/.*"'"$1"'" *: *"?([^",}]*)"?.*/\1/p' | head -1; }
# Henter innholdet av et objekt "key": { ... } (ett nivå).
jobj() { printf '%s' "$2" | tr -d '\n' | sed -nE 's/.*"'"$1"'" *: *(\{[^}]*\}).*/\1/p' | head -1; }
# Minste enhet -> beløp med desimaler ("4082", 2 -> "40.82"). Tom ved null/ugyldig.
money() { case "$1" in ''|null) printf '' ;; *) printf '%s' "$1" | awk -v dp="$2" '/^[0-9]+(\.[0-9]+)?$/ { printf "%.*f", dp, $1 / (10 ^ dp) }' ;; esac; }
# BSD sed leser etiketter til linjeslutt, derfor separate -e for t-hoppet.
num() { case "$1" in ''|null) printf '0' ;; *) printf '%s' "$1" | sed -E -e 's/^([0-9]+)(\.[0-9]+)?$/\1/' -e 't' -e 's/.*/0/' ;; esac; }

if [ -z "${USAGE_GUARD_FIXTURE:-}" ] && [ -f "$CACHE" ]; then
  cached_at="$(sed -nE 's/^at=([0-9]+)$/\1/p' "$CACHE")"
  if [ -n "$cached_at" ] && [ $(( now - cached_at )) -lt "$CACHE_TTL" ]; then cat "$CACHE"; exit 0; fi
fi

read_token() {
  if [ -n "${USAGE_GUARD_TOKEN:-}" ]; then printf '%s' "$USAGE_GUARD_TOKEN"; return; fi
  local raw=""
  case "$(uname -s)" in
    Darwin) raw="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)" ;;
  esac
  [ -z "$raw" ] && [ -f "$HOME/.claude/.credentials.json" ] && raw="$(cat "$HOME/.claude/.credentials.json")"
  jget accessToken "$raw"
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

emit() {
  printf 'five=%s\nseven=%s\nfive_resets=%s\nseven_resets=%s\nextra_enabled=%s\nextra_used=%s\nextra_limit=%s\ncurrency=%s\nsource=%s\nat=%s\n' "$@"
}

out=""
if printf '%s' "$raw" | grep -qE '"(five_hour|seven_day)"'; then
  fh="$(jobj five_hour "$raw")"; sd="$(jobj seven_day "$raw")"; ex="$(jobj extra_usage "$raw")"
  five="$(num "$(jget utilization "$fh")")"; seven="$(num "$(jget utilization "$sd")")"
  fr="$(jget resets_at "$fh" | tr -cd '0-9TZ:.+-')"; sr="$(jget resets_at "$sd" | tr -cd '0-9TZ:.+-')"
  en="$(jget is_enabled "$ex")"; [ "$en" = "true" ] || en=false
  # used_credits og monthly_limit kommer i minste enhet (øre/cent); decimal_places sier hvor mange.
  dp="$(jget decimal_places "$ex" | tr -cd '0-9')"; [ -z "$dp" ] && dp=2
  used="$(money "$(jget used_credits "$ex")" "$dp")"; lim="$(money "$(jget monthly_limit "$ex")" "$dp")"
  cur="$(jget currency "$ex" | tr -cd 'A-Za-z')"
  out="$(emit "$five" "$seven" "${fr:-}" "${sr:-}" "$en" "${used:-}" "${lim:-}" "${cur:-}" oauth "$now")"
elif [ -f "$LEGACY_STATE" ]; then
  ls="$(cat "$LEGACY_STATE")"
  out="$(emit "$(num "$(jget five_hour "$ls")")" "$(num "$(jget seven_day "$ls")")" "" "" true "" "" "" statusline "$(num "$(jget at "$ls")")")"
fi

[ -z "$out" ] && exit 1
printf '%s\n' "$out" > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"
printf '%s\n' "$out"
