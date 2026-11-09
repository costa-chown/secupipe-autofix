# Secupipe Autofix

Container-Job für die CI/CD-Pipeline: holt offene Fix-Aufträge aus [Secupipe](https://secupipe.com) ab, hebt die
betroffenen Pakete auf die gefixte Version, lässt Build und Tests laufen und öffnet je Paket einen Pull Request
(GitHub) bzw. Merge Request (GitLab). Schlägt das fehl, passt optional ein KI-Agent (Claude Code) den Code an.

**Alles läuft auf deinem Runner.** Secupipe bekommt keinen Quellcode, nur Status, PR-Link und das Ende des
Protokolls. Den Schlüssel für den KI-Agenten hinterlegst du selbst. Gemergt wird nie automatisch.

## Ablauf

1. In Secupipe beim Befund **Fix-PR erstellen** klicken, oder `AUTO=hoch` setzen: dann legt der Job selbst
   Aufträge für alle offenen Befunde ab diesem Schweregrad an.
2. Der Job (z. B. stündlich) holt die Aufträge für sein Repository (`REPO`, wie `pipeline=…` beim SBOM-Upload).
3. Je Paket: Branch `secupipe/fix-<paket>-<version>`, Update, Build und Tests.
   - grün → Pull Request
   - rot und Modul KI gebucht und Schlüssel vorhanden → KI-Agent passt den Code an, dann erneut Build und Tests
   - weiter rot → Pull Request als Entwurf mit Protokoll
4. Status und PR-Link erscheinen in Secupipe beim Befund. Nach dem nächsten SBOM-Upload gilt der Befund als behoben.

Automatisch unterstützt: npm (direkt und transitiv über `overrides`, veraltete Versionen werden übersprungen),
Go-Module, feste Versionen in `requirements*.txt`. Andere Ökosysteme über den KI-Agenten.

## GitHub Actions

```yaml
# .github/workflows/secupipe-autofix.yml
name: Secupipe Autofix
on:
  schedule:
    - cron: '17 * * * *'
  workflow_dispatch:
permissions:
  contents: write
  pull-requests: write
jobs:
  autofix:
    runs-on: ubuntu-latest
    container: ghcr.io/costa-chown/secupipe-autofix:1
    steps:
      - uses: actions/checkout@v5
      - run: secupipe-autofix
        env:
          SECUPIPE_TOKEN: ${{ secrets.SECUPIPE_TOKEN }}
          GITHUB_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          AUTO: hoch
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

In den Repository-Einstellungen unter *Actions → General* „Allow GitHub Actions to create and approve pull requests“
einschalten. PRs mit `github.token` starten keine weiteren Workflows; für CI auf dem PR ein Token einer GitHub App
übergeben.

## GitLab CI

```yaml
secupipe-autofix:
  image:
    name: ghcr.io/costa-chown/secupipe-autofix:1
    entrypoint: [""]
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule" || $CI_PIPELINE_SOURCE == "web"
  variables:
    GIT_DEPTH: "0"
    REPO: $CI_PROJECT_PATH
    AUTO: hoch
  script:
    - secupipe-autofix
```

Variablen: `SECUPIPE_TOKEN`, `GITLAB_TOKEN` (Projekt-Token mit `api` und `write_repository`), optional `ANTHROPIC_API_KEY`.

## Andere CI-Systeme

```bash
docker run --rm -v "$PWD:/repo" -w /repo \
  -e SECUPIPE_TOKEN -e GITHUB_TOKEN -e ANTHROPIC_API_KEY -e PLATTFORM=github \
  -e REPO=acme/shop -e BASE_BRANCH=main \
  ghcr.io/costa-chown/secupipe-autofix:1
```

## Umgebung

| Variable | Bedeutung |
|---|---|
| `SECUPIPE_TOKEN` | Pipeline-Token aus Secupipe (Pflicht) |
| `REPO` | Repository wie beim SBOM-Upload (`pipeline=…`) |
| `AUTO` | Aufträge ab Schweregrad anlegen: `kritisch`, `hoch`, `mittel`, `niedrig` |
| `CHECK_CMD` | eigener Prüfbefehl statt Build/Tests je Ökosystem |
| `BASE_BRANCH` | Zielbranch, Standard der ausgecheckte Branch |
| `DRY_RUN=1` | nichts pushen, keinen PR öffnen |
| `ANTHROPIC_API_KEY` | KI-Agent (alternativ `CLAUDE_CODE_USE_BEDROCK` / `CLAUDE_CODE_USE_VERTEX` mit EU-Region) |
| `KI_MODEL`, `KI_MAX_TURNS` (40), `KI_BUDGET_USD` (5) | Grenzen für den KI-Agenten |

Der KI-Agent darf nur Dateien lesen und ändern sowie Build-Werkzeuge (npm, go, pip, mvn, gradle) ausführen;
committen und pushen übernimmt das Skript.
