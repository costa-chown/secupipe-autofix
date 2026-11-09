#!/usr/bin/env bash
# Secupipe Autofix: holt offene Fix-Aufträge bei Secupipe ab, hebt die betroffenen Pakete auf die
# gefixte Version, prüft Build und Tests, lässt bei Fehlern optional einen KI-Agenten (Claude Code)
# den Code anpassen und öffnet je Paket einen Pull Request bzw. Merge Request.
#
# Läuft im Container auf dem CI-Runner des Kunden, im ausgecheckten Repository (Arbeitsverzeichnis).
# Quellcode verlässt den Runner nicht; an Secupipe gehen nur Status, PR-Link und das Ende des Protokolls.
#
# Umgebung
#   SECUPIPE_TOKEN     Pipeline-Token (Pflicht)
#   SECUPIPE_API       Standard https://api.secupipe.com/v1
#   AUTO               optional: Aufträge für alle offenen Befunde ab diesem Schweregrad anlegen
#                      (kritisch, hoch, mittel, niedrig)
#   CHECK_CMD          optional: eigener Prüfbefehl statt Build/Tests je Ökosystem
#   GITHUB_TOKEN       GitHub: Token mit contents: write und pull-requests: write
#   GITLAB_TOKEN       GitLab: Projekt-Token mit api und write_repository (CI_JOB_TOKEN reicht nicht)
#   REPO               Repository für Secupipe, Standard GITHUB_REPOSITORY bzw. CI_PROJECT_PATH
#   BASE_BRANCH        Zielbranch der PRs, Standard der ausgecheckte Branch
#   DRY_RUN=1          nichts pushen und keinen PR öffnen (Test)
#   KI-Agent (nur mit Modul KI): ANTHROPIC_API_KEY oder CLAUDE_CODE_USE_BEDROCK/CLAUDE_CODE_USE_VERTEX
#   KI_MODEL, KI_MAX_TURNS (40, im Modus agent 60), KI_BUDGET_USD (5)
#   Der Modus (update, update_ki, agent) kommt aus den Einstellungen in Secupipe.
set -euo pipefail

API=${SECUPIPE_API:-https://api.secupipe.com/v1}
REPO=${REPO:-${GITHUB_REPOSITORY:-${CI_PROJECT_PATH:-}}}
WORK=$(mktemp -d)
LOG=$WORK/lauf.log

info() { printf '\033[1;34m→\033[0m %s\n' "$*"; }
warn() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::$*"; else printf '\033[1;33m!\033[0m %s\n' "$*"; fi; }
fail() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$*"; else printf '\033[1;31m✗\033[0m %s\n' "$*"; fi; exit 1; }

[ -n "${SECUPIPE_TOKEN:-}" ] || fail "SECUPIPE_TOKEN fehlt. In Secupipe unter Pipelines ein Token erzeugen und als Secret hinterlegen."
[ -n "$REPO" ] || fail "REPO fehlt (z. B. acme/shop), genauso geschrieben wie beim SBOM-Upload (pipeline=…)."
git rev-parse --git-dir >/dev/null 2>&1 || fail "Kein Git-Repository im Arbeitsverzeichnis $(pwd)."
git config --global --add safe.directory "$(pwd)"

sp() { # Methode, Pfad, [JSON-Body]
  curl -sS --fail-with-body --retry 3 -X "$1" -H "Authorization: Bearer $SECUPIPE_TOKEN" -H "Content-Type: application/json" \
    ${3:+--data "$3"} "$API$2"
}
urlenc() { jq -rn --arg v "$1" '$v|@uri'; }
gruppe() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::group::$*" || echo "── $* ──"; }
gruppe_ende() { [ -z "${GITHUB_ACTIONS:-}" ] || echo "::endgroup::"; }

# ---------- Aufträge holen ----------

if [ -n "${AUTO:-}" ]; then
  n=$(sp POST "/ci/fixes/auto?repo=$(urlenc "$REPO")&ab=$(urlenc "$AUTO")" | jq -r .angelegt)
  info "Automatik ab $AUTO: $n neue Aufträge"
fi
sp POST "/ci/fixes/claim?repo=$(urlenc "$REPO")" > "$WORK/jobs.json"
total=$(jq length "$WORK/jobs.json")
if [ "$total" = 0 ]; then
  info "Keine offenen Fix-Aufträge für $REPO."
  exit 0
fi
info "$total Fix-Aufträge für $REPO"

# Aufträge, die noch nicht gemeldet sind; bei Abbruch als fehlgeschlagen melden
declare -A OFFEN=()
for id in $(jq -r '.[].id' "$WORK/jobs.json"); do OFFEN[$id]=1; done
report() { # status, art, pr_url, log, ids…
  local status=$1 art=$2 pr=$3 log=$4; shift 4
  local body
  body=$(jq -n --arg s "$status" --arg a "$art" --arg p "$pr" --arg l "$log" '{status:$s, art:$a, prUrl:$p, log:$l} | with_entries(select(.value != ""))')
  for id in "$@"; do
    sp PUT "/ci/fixes/$id" "$body" >/dev/null || warn "Status für Auftrag $id nicht gemeldet"
    unset "OFFEN[$id]"
  done
}
abbruch() {
  if [ "${#OFFEN[@]}" -gt 0 ]; then
    report fehlgeschlagen "" "" "Lauf abgebrochen. $(tail -c 3000 "$LOG" 2>/dev/null)" "${!OFFEN[@]}"
  fi
}
trap abbruch EXIT

# ---------- Git und Plattform ----------

BASE=${BASE_BRANCH:-${GITHUB_HEAD_REF:-}}
[ -n "$BASE" ] || BASE=${GITHUB_REF_NAME:-${CI_COMMIT_BRANCH:-${CI_DEFAULT_BRANCH:-}}}
[ -n "$BASE" ] || BASE=$(git rev-parse --abbrev-ref HEAD)
BASE_SHA=$(git rev-parse HEAD)
git config user.name "${GIT_AUTHOR_NAME:-Secupipe Autofix}"
git config user.email "${GIT_AUTHOR_EMAIL:-autofix@secupipe.com}"

if [ -n "${GITHUB_ACTIONS:-}" ]; then
  PLATTFORM=github
  GH_API=${GITHUB_API_URL:-https://api.github.com}
elif [ -n "${GITLAB_CI:-}" ]; then
  PLATTFORM=gitlab
else
  PLATTFORM=${PLATTFORM:-github}
  GH_API=${GITHUB_API_URL:-https://api.github.com}
fi

push_branch() { # branch
  [ -n "${DRY_RUN:-}" ] && { info "DRY_RUN: kein Push von $1"; return; }
  if [ "$PLATTFORM" = gitlab ]; then
    [ -n "${GITLAB_TOKEN:-}" ] || fail "GITLAB_TOKEN fehlt (Projekt-Token mit api und write_repository)."
    git push --force "https://oauth2:${GITLAB_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" "HEAD:refs/heads/$1"
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    git push --force "https://x-access-token:${GITHUB_TOKEN}@${GITHUB_SERVER_URL#https://}/${GITHUB_REPOSITORY:-$REPO}.git" "HEAD:refs/heads/$1"
  else
    git push --force origin "HEAD:refs/heads/$1"
  fi
}

open_pr() { # branch, titel, body-datei, draft(true/false) → PR-URL
  if [ -n "${DRY_RUN:-}" ]; then echo "https://example.invalid/dry-run/$1"; return; fi
  local res
  if [ "$PLATTFORM" = gitlab ]; then
    local titel=$2
    [ "$4" = true ] && titel="Draft: $2"
    local api="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests"
    res=$(curl -sS -H "PRIVATE-TOKEN: $GITLAB_TOKEN" -G "$api" --data-urlencode "source_branch=$1" --data-urlencode state=opened | jq -r '.[0].web_url // empty')
    if [ -z "$res" ]; then
      res=$(jq -n --arg s "$1" --arg t "$BASE" --arg ti "$titel" --rawfile d "$3" '{source_branch:$s, target_branch:$t, title:$ti, description:$d, remove_source_branch:true}' |
        curl -sS --fail-with-body -H "PRIVATE-TOKEN: $GITLAB_TOKEN" -H "Content-Type: application/json" --data @- "$api" | jq -r .web_url)
    fi
  else
    local owner=${REPO%%/*} repo=${GITHUB_REPOSITORY:-$REPO}
    local auth=(-H "Authorization: Bearer ${GITHUB_TOKEN:?GITHUB_TOKEN fehlt}" -H "Accept: application/vnd.github+json")
    res=$(curl -sS "${auth[@]}" "$GH_API/repos/$repo/pulls?state=open&head=$owner:$1" | jq -r '.[0].html_url // empty')
    if [ -z "$res" ]; then
      res=$(jq -n --arg h "$1" --arg b "$BASE" --arg t "$2" --rawfile d "$3" --argjson dr "$4" '{head:$h, base:$b, title:$t, body:$d, draft:$dr}' |
        curl -sS --fail-with-body "${auth[@]}" --data @- "$GH_API/repos/$repo/pulls" | jq -r .html_url)
    fi
  fi
  echo "$res"
}

# ---------- Updates je Ökosystem ----------

# purl zerlegen: typ, name (dekodiert, mit Namespace)
purl_typ() { local p=${1#pkg:}; echo "${p%%/*}"; }
purl_name() {
  local p=${1#pkg:*/}; p=${p%%@*}; p=${p%%\?*}
  printf '%b' "${p//%/\\x}"
}

GEAENDERT=() # Verzeichnisse mit Änderungen, für die Prüfung

# npm_ziel: erste nicht als veraltet markierte Version ab der gefixten Version (gleiche Hauptversion)
npm_ziel() { # name, version
  local major=${2%%.*} out
  out=$(npm view "$1@>=$2 <$((major + 1))" version deprecated --json 2>/dev/null |
    jq -r 'if type == "array" then . else [.] end | map(select(.deprecated == null)) | .[0].version // empty' 2>/dev/null) || true
  echo "${out:-$2}"
}

update_npm() { # name, version
  local name=$1 ver=$2 dir found=0
  while IFS= read -r f; do
    dir=$(dirname "$f")
    if jq -e --arg n "$name" '(.dependencies // {}) + (.devDependencies // {}) + (.optionalDependencies // {}) | has($n)' "$f" >/dev/null; then
      local dev=""
      jq -e --arg n "$name" '(.devDependencies // {}) | has($n)' "$f" >/dev/null && dev="--save-dev"
      # feste Version bleibt fest, sonst ^Version wie npm
      local spec pin="" want="^$ver"
      spec=$(jq -r --arg n "$name" '((.dependencies // {}) + (.devDependencies // {}) + (.optionalDependencies // {}))[$n]' "$f")
      if [[ $spec =~ ^=?[0-9] ]]; then pin="--save-exact"; want=$ver; fi
      info "npm: $dir: $name@$want (direkte Abhängigkeit, bisher $spec)"
      (cd "$dir" && npm install --no-audit --no-fund --ignore-scripts $dev $pin "$name@$want")
    elif [ -f "$dir/package-lock.json" ] && jq -e --arg n "$name" '.packages | to_entries | any(.key | endswith("node_modules/" + $n))' "$dir/package-lock.json" >/dev/null; then
      info "npm: $dir: $name über overrides auf $ver (transitive Abhängigkeit)"
      (cd "$dir" && npm pkg set "overrides.$name=^$ver" && npm install --no-audit --no-fund --ignore-scripts)
    else
      continue
    fi
    found=1
    GEAENDERT+=("npm:$dir")
  done < <(git ls-files '*package.json' | grep -v node_modules/)
  [ "$found" = 1 ]
}

update_go() { # modul, version
  local mod=$1 ver=$2 dir found=0
  [[ $ver == v* ]] || ver="v$ver"
  if [ "$mod" = stdlib ] || [ "$mod" = toolchain ]; then
    while IFS= read -r f; do
      dir=$(dirname "$f")
      info "go: $dir: toolchain go${ver#v}"
      (cd "$dir" && go mod edit -toolchain="go${ver#v}")
      found=1; GEAENDERT+=("go:$dir")
    done < <(git ls-files '*go.mod')
    [ "$found" = 1 ]; return
  fi
  while IFS= read -r f; do
    dir=$(dirname "$f")
    grep -q "$mod " "$dir/go.mod" "$dir/go.sum" 2>/dev/null || continue
    info "go: $dir: $mod@$ver"
    (cd "$dir" && go get "$mod@$ver" && go mod tidy)
    found=1; GEAENDERT+=("go:$dir")
  done < <(git ls-files '*go.mod')
  [ "$found" = 1 ]
}

update_pypi() { # name, version: feste Versionen in requirements*.txt
  local name=$1 ver=$2 found=0 f
  while IFS= read -r f; do
    if grep -qiE "^${name//-/[-_]}[[:space:]]*==" "$f"; then
      info "pip: $f: $name==$ver"
      sed -i -E "s/^(${name//-/[-_]})[[:space:]]*==[^;[:space:]]*/\1==$ver/I" "$f"
      found=1; GEAENDERT+=("pip:$(dirname "$f")")
    fi
  done < <(git ls-files '*requirements*.txt')
  [ "$found" = 1 ]
}

pruefen() { # → 0 wenn Build und Tests grün
  if [ -n "${CHECK_CMD:-}" ]; then
    info "Prüfung: $CHECK_CMD"
    bash -c "$CHECK_CMD"; return
  fi
  local e dir
  for e in $(printf '%s\n' "${GEAENDERT[@]}" | sort -u); do
    dir=${e#*:}
    case ${e%%:*} in
      npm) info "Prüfung npm in $dir"
           (cd "$dir" && npm ci --no-audit --no-fund && npm run build --if-present && npm run test --if-present) || return 1 ;;
      go)  info "Prüfung go in $dir"
           (cd "$dir" && go build ./... && go vet ./... && go test ./...) || return 1 ;;
      pip) info "Prüfung pip in $dir: nur Auflösung der Abhängigkeiten"
           (cd "$dir" && python3 -m pip install --dry-run -q -r requirements.txt) || return 1 ;;
    esac
  done
}

KI_VERFUEGBAR=0
if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${CLAUDE_CODE_USE_BEDROCK:-}" ] || [ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]; then
  KI_VERFUEGBAR=1
fi

ki_fix() { # name, alt, neu, cves, fehlerdatei
  info "KI-Agent passt den Code an ($1 $2 → $3)"
  local prompt
  prompt=$(cat <<EOF
Du arbeitest in einem Git-Repository auf einem CI-Runner. Ziel: die Sicherheitslücken $4 schließen,
indem das Paket $1 von Version $2 auf $3 (oder neuer) aktualisiert wird, und den Code so anpassen,
dass Build und Tests wieder durchlaufen.

Regeln:
- Ändere nur, was für das Update nötig ist (API-Änderungen, Importe, Typen, Konfiguration). Kein Refactoring.
- Prüfe die Migrationshinweise bzw. das Changelog des Pakets in node_modules, im Modul-Cache oder in den Typdefinitionen.
- Führe Build und Tests aus, bis sie grün sind. Schalte keine Tests ab und schwäche keine Prüfungen ab.
- Keine Commits, kein Push: das übernimmt das Skript.
- Ende mit einer kurzen Zusammenfassung auf Deutsch: was du geändert hast und warum.

Bisheriger Fehler (Ende des Protokolls):
$(tail -c 6000 "$5")
EOF
)
  local args=(-p "$prompt" --permission-mode acceptEdits --max-turns "${KI_MAX_TURNS:-40}" --max-budget-usd "${KI_BUDGET_USD:-5}"
    --allowedTools "Read Edit Write Glob Grep Bash(npm *) Bash(npx *) Bash(node *) Bash(go *) Bash(python3 *) Bash(pip *) Bash(mvn *) Bash(gradle *) Bash(./gradlew *) Bash(git diff*) Bash(git status*) Bash(ls *) Bash(cat *)")
  [ -n "${KI_MODEL:-}" ] && args+=(--model "$KI_MODEL")
  claude "${args[@]}" > "$WORK/ki.txt" 2>&1 || { cat "$WORK/ki.txt"; return 1; }
  cat "$WORK/ki.txt"
}

# ki_agent: Modus »KI-Agent zuerst«. Der Agent bekommt das bereits versuchte Update und dessen Prüfergebnis,
# prüft, ob die Lücke im Code überhaupt erreichbar ist, passt den Code an und schreibt sein Ergebnis nach
# .secupipe-ergebnis.json: {"ergebnis": "fix" | "nicht_betroffen", "justification", "begruendung", "konfidenz"}.
ERGEBNIS=.secupipe-ergebnis.json
ki_agent() { # name, alt, neu, cves, gruppe-json, update-status (gruen|rot|keins)
  info "KI-Agent arbeitet zuerst ($1 $2 → $3, Update: $6)"
  local prompt befunde fehler=""
  befunde=$(jq -r '.[] | "- \(.cve) (\(.schwere)): \(.titel)\n  \((.beschreibung // "") | .[0:600])\n  Details: https://osv.dev/vulnerability/\(.quelle // .cve)"' <<<"$5")
  [ "$6" = rot ] && fehler="Fehler nach dem Update (Ende des Protokolls):
$(tail -c 5000 "$LOG")"
  prompt=$(cat <<EOF
Du bist ein Sicherheits-Agent in einem Git-Repository auf einem CI-Runner. Secupipe hat im Paket $1 (Version $2)
diese Schwachstellen gefunden; behoben in $3:

$befunde

Stand: Das Skript hat das Paket bereits auf $3 gehoben, soweit es das Ökosystem kennt (Build und Tests: $6).
Die Änderungen liegen ungespeichert im Arbeitsverzeichnis (git diff).

Aufgabe:
1. Prüfe, wo und wie das Projekt das Paket nutzt (Importe, Aufrufe der betroffenen Funktionen laut Beschreibung).
2. Bevorzuge das Update: Passe den Code an, bis Build und Tests grün sind (API-Änderungen, Importe, Typen).
   Ist das Paket noch nicht aktualisiert (anderes Ökosystem), aktualisiere es selbst mit dem Paketmanager.
3. Nur wenn das Update ohne größere Umbauten nicht möglich ist UND du belegen kannst, dass der verwundbare Code
   im Projekt nicht erreichbar oder nicht ausnutzbar ist: stelle alle geänderten Dateien mit Edit wieder her
   und melde "nicht_betroffen".

Regeln: Kein Refactoring, keine Tests abschalten, keine Prüfungen abschwächen. Keine Commits, kein Push.

Schreibe zum Schluss die Datei $ERGEBNIS im Wurzelverzeichnis des Repositorys mit genau diesem JSON:
{"ergebnis": "fix" oder "nicht_betroffen",
 "justification": nur bei nicht_betroffen eine von component_not_present, vulnerable_code_not_present,
                  vulnerable_code_not_in_execute_path, vulnerable_code_cannot_be_controlled_by_adversary,
                  inline_mitigations_already_exist,
 "begruendung": "Deutsch, 2 bis 5 Sätze mit Belegen (Dateien, Funktionen)",
 "konfidenz": 0.0 bis 1.0}
Ende danach mit einer kurzen Zusammenfassung auf Deutsch: was du geprüft und geändert hast.

$fehler
EOF
)
  rm -f "$ERGEBNIS"
  local args=(-p "$prompt" --permission-mode acceptEdits --max-turns "${KI_MAX_TURNS:-60}" --max-budget-usd "${KI_BUDGET_USD:-5}"
    --allowedTools "Read Edit Write Glob Grep Bash(npm *) Bash(npx *) Bash(node *) Bash(go *) Bash(python3 *) Bash(pip *) Bash(mvn *) Bash(gradle *) Bash(./gradlew *) Bash(git diff*) Bash(git status*) Bash(git grep*) Bash(git log*) Bash(ls *) Bash(cat *)")
  [ -n "${KI_MODEL:-}" ] && args+=(--model "$KI_MODEL")
  claude "${args[@]}" > "$WORK/ki.txt" 2>&1 || { cat "$WORK/ki.txt"; return 1; }
  cat "$WORK/ki.txt"
}

# ---------- je Paket ein PR ----------

# Gruppen: gleicher Paket-purl (ohne Version) → höchste gefixte Version
jq -c 'group_by(.purl | sub("@.*$"; "")) | .[]' "$WORK/jobs.json" > "$WORK/gruppen.jsonl"
fehler=0
while IFS= read -r g; do
  mapfile -t ids < <(jq -r ".[].id" <<<"$g")
  purl=$(jq -r '.[0].purl' <<<"$g")
  alt=$(jq -r '.[0].version' <<<"$g")
  neu=$(jq -r '.[].fixVersion' <<<"$g" | sort -V | tail -1)
  cves=$(jq -r '[.[].cve] | unique | join(", ")' <<<"$g")
  ki_erlaubt=$(jq -r 'any(.[]; .kiErlaubt // .ki)' <<<"$g")
  modus=$(jq -r '.[0].modus // "update_ki"' <<<"$g")
  typ=$(purl_typ "$purl"); name=$(purl_name "$purl")
  if [ "$typ" = npm ]; then
    ziel=$(npm_ziel "$name" "$neu")
    [ "$ziel" = "$neu" ] || info "npm: $name $neu ist als veraltet markiert, nehme $ziel"
    neu=$ziel
  fi
  slug=$(echo "$name" | tr -c 'a-zA-Z0-9.\n-' '-' | sed 's/^-*//')
  branch="secupipe/fix-$slug-$neu"
  : > "$LOG"
  gruppe "$name $alt → $neu ($cves)"
  {
    git checkout -q -f -B "$branch" "$BASE_SHA"
    git clean -qfd
    GEAENDERT=()
    art=update ok=0 entwurf=false
    case $typ in
      npm)    update_npm "$name" "$neu" && ok=1 ;;
      golang) update_go "$name" "$neu" && ok=1 ;;
      pypi)   update_pypi "$name" "$neu" && ok=1 ;;
      *)      warn "Ökosystem $typ: kein automatisches Update, nur mit KI-Agent" ;;
    esac
    if [ "$modus" = agent ] && [ "$ki_erlaubt" = true ] && [ "$KI_VERFUEGBAR" = 1 ]; then
      stand=keins
      if [ "$ok" = 1 ]; then if pruefen; then stand=gruen; else stand=rot; fi; fi
      if ki_agent "$name" "$alt" "$neu" "$cves" "$g" "$stand"; then
        if [ "$(jq -r '.ergebnis // empty' "$ERGEBNIS" 2>/dev/null)" = nicht_betroffen ]; then
          info "KI-Agent: nicht betroffen, schlägt VEX-Bewertung vor"
        elif pruefen; then
          info "Build und Tests grün nach KI-Agent"
        else
          warn "Nach KI-Agent nicht grün: PR als Entwurf"
        fi
      else
        warn "KI-Agent abgebrochen: PR als Entwurf"
      fi
    elif [ "$ok" = 1 ] && pruefen; then
      info "Build und Tests grün nach Update"
    elif [ "$ki_erlaubt" = true ] && [ "$KI_VERFUEGBAR" = 1 ]; then
      art=ki
      if ki_fix "$name" "$alt" "$neu" "$cves" "$LOG" && pruefen; then
        info "Build und Tests grün nach KI-Anpassung"; ok=1
      else
        warn "Auch nach KI-Anpassung nicht grün: PR als Entwurf"; entwurf=true; ok=1
      fi
    elif [ "$ok" = 1 ]; then
      warn "Build oder Tests schlagen nach dem Update fehl: PR als Entwurf"
      [ "$ki_erlaubt" = true ] || echo "Hinweis: Mit dem Modul KI passt ein KI-Agent den Code automatisch an."
      [ "$ki_erlaubt" = true ] && [ "$KI_VERFUEGBAR" = 0 ] && echo "Hinweis: Für den KI-Agenten ANTHROPIC_API_KEY als Secret hinterlegen."
      entwurf=true
    fi
  } 2>&1 | tee -a "$LOG"
  # Variablen aus der Pipe-Subshell zurückholen
  art=$(grep -qE "KI-Agent (passt|arbeitet)" "$LOG" && echo ki || echo update)
  entwurf=$(grep -q "PR als Entwurf" "$LOG" && echo true || echo false)

  # KI-Agent hält das Projekt für nicht betroffen: VEX-Vorschlag statt PR (Freigabe in Secupipe)
  if grep -q "KI-Agent: nicht betroffen" "$LOG"; then
    vex=$(jq -c '{justification, begruendung, konfidenz: (.konfidenz // 0.5)}' "$ERGEBNIS")
    rm -f "$ERGEBNIS"
    body=$(jq -n --argjson v "$vex" --arg l "$(tail -c 3000 "$WORK/ki.txt")" '{status:"vex", art:"ki", vex:$v, log:$l}')
    for id in "${ids[@]}"; do
      sp PUT "/ci/fixes/$id" "$body" >/dev/null || warn "VEX-Vorschlag für $id nicht gemeldet"
      unset "OFFEN[$id]"
    done
    info "VEX-Vorschlag an Secupipe gemeldet (Freigabe dort)"
    git checkout -q -f "$BASE_SHA"; git clean -qfd
    gruppe_ende
    continue
  fi
  rm -f "$ERGEBNIS"

  if git diff --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    warn "$name: keine Änderung möglich (Paket nicht gefunden oder Ökosystem nicht unterstützt)"
    report fehlgeschlagen "" "" "$(tail -c 3000 "$LOG")" "${ids[@]}"
    fehler=1
    gruppe_ende
    continue
  fi

  git add -A
  git reset -q -- node_modules 2>/dev/null || true
  git commit -q -m "fix(deps): $name $alt → $neu" -m "Schließt $cves (gefunden von Secupipe)."
  push_branch "$branch" 2>&1 | tee -a "$LOG"

  {
    echo "## Sicherheitsupdate: \`$name\` $alt → $neu"
    echo
    echo "Secupipe hat in **$REPO** folgende Schwachstellen gefunden:"
    echo
    jq -r '.[] | "- **\(.cve)** (\(.schwere)): \(.titel)"' <<<"$g" | sort -u
    echo
    if [ "$art" = ki ]; then
      echo "Ein KI-Agent hat das Update auf dem CI-Runner geprüft und den Code angepasst:"
      echo
      echo '```'; tail -c 4000 "$WORK/ki.txt" 2>/dev/null; echo '```'
    else
      echo "Nur die Abhängigkeit wurde aktualisiert."
    fi
    echo
    if [ "$entwurf" = true ]; then
      echo "> ⚠️ Build oder Tests sind noch nicht grün. Bitte prüfen und von Hand fertigstellen."
      echo; echo '<details><summary>Protokoll</summary>'; echo; echo '```'; tail -c 6000 "$LOG"; echo '```'; echo '</details>'
    fi
    echo
    echo "Bitte prüfen und mergen. Nach dem nächsten SBOM-Upload gilt der Befund in Secupipe als behoben."
  } > "$WORK/pr.md"
  pr=$(open_pr "$branch" "Sicherheitsupdate: $name $alt → $neu" "$WORK/pr.md" "$entwurf")
  info "PR: $pr"
  if [ "$entwurf" = true ]; then
    report fehlgeschlagen "$art" "$pr" "$(tail -c 3000 "$LOG")" "${ids[@]}"
    fehler=1
  else
    report pr_offen "$art" "$pr" "$(tail -c 3000 "$LOG")" "${ids[@]}"
  fi
  gruppe_ende
done < "$WORK/gruppen.jsonl"

git checkout -q -f "$BASE_SHA" 2>/dev/null || true
[ "$fehler" = 0 ] || warn "Nicht alle Fixes sind grün; Entwürfe bitte prüfen."
exit 0
