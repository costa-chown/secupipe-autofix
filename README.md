# Secupipe Autofix

Container-Job für die CI/CD-Pipeline: holt offene Fix-Aufträge aus [Secupipe](https://secupipe.com) ab, hebt die
betroffenen Pakete auf die gefixte Version, lässt Build und Tests laufen und öffnet je Paket einen Pull Request
(GitHub) bzw. Merge Request (GitLab). Schlägt das fehl, passt optional ein KI-Agent (Claude Code) den Code an.

**Alles läuft auf deinem Runner.** Secupipe bekommt keinen Quellcode, nur Status, PR-Link und das Ende des
Protokolls. Den Schlüssel für den KI-Agenten hinterlegst du selbst. Gemergt wird nie automatisch.

## Modus (Einstellungen in Secupipe)

| Modus | Was passiert |
|---|---|
| Nur Versions-Update | Update, Build und Tests; bei Fehlern PR-Entwurf mit Protokoll. Ohne KI. |
| Update, KI bei Fehlern (Standard) | Wie oben; bricht das Update etwas, passt der KI-Agent den Code an. |
| KI-Agent zuerst | Der Agent prüft jeden Auftrag: Nutzung des Pakets, Erreichbarkeit der Lücke, Code-Anpassung, Zusammenfassung im PR. Ist das Update nicht sinnvoll machbar und die Lücke nicht erreichbar, meldet er »nicht betroffen« als VEX-Vorschlag; gültig erst nach Freigabe in Secupipe. |

Die KI-Stufen brauchen das Modul KI und einen eigenen Schlüssel in der Pipeline.

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

## Code-Scan: eigenen Code mit KI prüfen

Das Image enthält einen zweiten Befehl, `secupipe-codescan`. Ein KI-Agent (Claude Code) prüft den eigenen Quellcode
im ausgecheckten Repository auf Schwachstellen, etwa Injection, fehlende Rechteprüfung, Zugriff auf Daten anderer
Mandanten oder fest eingetragene Geheimnisse. Die Befunde erscheinen in Secupipe unter Schwachstellen, neben den
Befunden aus dem SBOM-Abgleich: mit Frist, VEX-Bewertung, Alarm und Jira. Der Code-Scan braucht das Modul KI.

**Secupipe bekommt keinen Quellcode.** Gemeldet werden je Befund nur CWE, Datei, Zeile, Funktion, Beschreibung und
Empfehlung. Der Agent darf nur lesen: Er ändert keine Dateien, führt keinen Code des Repositorys aus und hat über
seine Werkzeuge keinen Netzzugriff. Der Quellcode geht an den KI-Anbieter, dessen Schlüssel du hinterlegst
(Anthropic, oder Bedrock/Vertex in einer EU-Region).

So läuft ein Scan ab:

1. Der Job holt die bekannten Code-Befunde des Repositorys bei Secupipe ab.
2. **Suche:** Der Agent prüft den Code nach Risiko (Eingänge aus dem Netz, Anmeldung, Datenbank, Dateien, Kryptografie)
   und prüft jeden bekannten Befund erneut: noch vorhanden oder behoben.
3. **Nachprüfung:** Ein zweiter Durchgang versucht, jeden neuen Befund zu widerlegen, und streicht Fehlalarme.
4. Befunde ab 60 % Konfidenz gehen an Secupipe. Neue Befunde beginnen »in Prüfung«.

Dieselbe Stelle wird nicht doppelt angelegt: Secupipe erkennt sie an CWE, Datei und Funktion, auch wenn der Agent sie
anders formuliert oder die Zeile sich verschiebt. Einen als »nicht betroffen« bewerteten Befund (Fehlalarm) meldet der
Agent nicht erneut. Hält der Agent einen Befund für behoben, wird das in Secupipe ein Vorschlag am Befund; gültig ist
er erst, wenn ein Mensch ihn freigibt. Ein Befund gilt nicht als behoben, nur weil ein Lauf ihn nicht mehr nennt.

```yaml
# .github/workflows/secupipe-codescan.yml
name: Secupipe Code-Scan
on:
  pull_request:              # nur geänderte Dateien
  schedule:
    - cron: '23 3 * * 1'     # montags das ganze Repository
  workflow_dispatch:
permissions:
  contents: read
jobs:
  codescan:
    runs-on: ubuntu-latest
    container: ghcr.io/costa-chown/secupipe-autofix:1
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0
      - run: secupipe-codescan
        env:
          SECUPIPE_TOKEN: ${{ secrets.SECUPIPE_TOKEN }}
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          REPO: ${{ github.repository }}
          FAIL_ON: hoch
```

In GitHub Actions erscheinen neue Befunde zusätzlich als Hinweis an der Zeile im Pull Request.

GitLab CI: derselbe Job wie beim Autofix, mit `script: [secupipe-codescan]` und den Regeln
`$CI_PIPELINE_SOURCE == "merge_request_event"` (geänderte Dateien) und `"schedule"` (ganzes Repository).
Andere CI-Systeme und lokal:

```bash
docker run --rm -v "$PWD:/repo" -w /repo --entrypoint secupipe-codescan \
  -e SECUPIPE_TOKEN -e ANTHROPIC_API_KEY -e REPO=acme/shop \
  ghcr.io/costa-chown/secupipe-autofix:1
```

| Variable | Bedeutung |
|---|---|
| `SECUPIPE_TOKEN`, `REPO` | wie beim Autofix |
| `ANTHROPIC_API_KEY` | Schlüssel für den Agenten (alternativ `CLAUDE_CODE_USE_BEDROCK` / `CLAUDE_CODE_USE_VERTEX`) |
| `UMFANG` | `voll` = ganzes Repository, `diff` = nur geänderte Dateien. Standard: `diff` in Pull/Merge Requests, sonst `voll` |
| `DIFF_BASE` | Vergleichsstand für `diff`, Standard der Zielbranch des Pull/Merge Requests |
| `PFADE` | nur diese Verzeichnisse prüfen, z. B. `"src api"` |
| `FAIL_ON` | Lauf schlägt fehl, wenn offene Code-Befunde ab diesem Schweregrad vorliegen |
| `MIN_KONFIDENZ` | Befunde unter diesem Wert nicht melden, Standard `0.6` |
| `PRUEFEN=0` | Nachprüfung auslassen (halbe Kosten, mehr Fehlalarme) |
| `DRY_RUN=1` | nichts an Secupipe melden, Ergebnis nur ausgeben |
| `KI_MODEL`, `KI_MAX_TURNS` (120), `KI_BUDGET_USD` (10) | Grenzen je Durchgang |

## Umgebung (Autofix)

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
