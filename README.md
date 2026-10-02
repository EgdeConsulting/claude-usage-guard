# claude-usage-guard

Claude Code-plugin som gjør overgangen til usage credits (merforbruk utenfor abonnementet) til et eksplisitt valg.

## Oppførsel

| Forbruk (5t eller 7d) | UserPromptSubmit | PreToolUse |
|---|---|---|
| under 80 % | stille | stille |
| 80 til 99 % | gul advarsel per prompt | stille |
| 100 % og credits på | prompten avvises med forklaring og valg | verktøykall nektes med samme forklaring |
| etter `!overage-ok` | kort påminnelse per prompt | slipper gjennom |

- Bekreftelsen gjelder resten av økten (per `session_id`). Ny økt krever nytt valg.
- Slash-kommandoer går alltid gjennom.
- Er usage credits slått av for kontoen, gjør pluginen ingenting. Claude Code stopper selv.
- Feiler alltid åpent: ingen nett, gamle data eller ukjent format gir ingen blokkering.

Data hentes fra `api.anthropic.com/api/oauth/usage` med brukerens egen Claude Code-innlogging (nøkkelring på macOS, `~/.claude/.credentials.json` ellers) og caches i 60 sekunder.

Terskler: `USAGE_GUARD_WARN` (80), `USAGE_GUARD_LIMIT` (100), `USAGE_GUARD_STALE` (1800 s).

## Distribusjon til hele organisasjonen

1. Repoet ligger på `github.com/EgdeConsulting/claude-usage-guard` (privat). Teamet `devs` har lesetilgang. Medlemmer må ha GitHub-innlogging i git lokalt (`gh auth login` eller SSH) for at Claude Code skal kunne klone det.
2. Som Owner: claude.ai > Admin Settings > Claude Code > Managed settings. Lim inn innholdet i `managed-settings.example.json` med riktig `repo`.
3. Ved neste oppstart registreres marketplacet og pluginen installeres hos alle. Medlemmer kan ikke slå den av.
4. Verifiser hos ett medlem med `claude doctor` (linjen `Managed settings (remote)`) og `/plugin`.

Alternativ uten GitHub-tilgang: distribuer `managed-settings.json` og plugin-mappen via MDM (Intune/Jamf) til `/Library/Application Support/ClaudeCode/`.

## Lokal test

```
bash plugins/usage-guard/tests/run.sh
claude plugin marketplace add EgdeConsulting/claude-usage-guard
claude plugin install usage-guard@egde-claude
```
