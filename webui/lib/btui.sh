#!/usr/bin/env bash
# ============================================================
# btui.sh — Fonctions partagées de la page d'appairage Bluetooth
# ============================================================
# Ce fichier n'est pas exécuté directement : il est "sourcé" par les deux
# scripts CGI (www/cgi-bin/status.cgi et action.cgi), eux-mêmes servis par
# le petit serveur web httpd de busybox-extras lancé par run.sh (étape
# 1ter). Il regroupe tout ce qui touche au Bluetooth (bluetoothctl), aux
# réponses HTTP, aux opérations longues en arrière-plan et à l'API du
# Supervisor, pour que les deux CGI restent courts et lisibles.
#
# Pourquoi du bash + bluetoothctl plutôt qu'un vrai backend (Python, D-Bus
# natif...) : même philosophie que le reste du projet — s'appuyer sur les
# outils déjà présents dans l'image (bluetoothctl via le paquet bluez, jq
# et curl déjà fournis avec bashio par l'image de base) sans ajouter de
# langage ni de dépendance lourde à maintenir.
#
# Rangé HORS de la racine web (/opt/btui/lib, pas /opt/btui/www) : httpd ne
# peut donc jamais le servir tel quel comme un fichier téléchargeable.

# --- Constantes ---
BTUI_STATE_DIR="/tmp/btui"
# État volatil de la page : opération en cours, dernier résultat de scan,
# journal de la dernière session bluetoothctl. Volontairement dans /tmp et
# pas dans /data : rien de tout ça n'a besoin de survivre à un redémarrage
# de l'add-on. La seule information persistante, l'enceinte choisie, est
# écrite dans la configuration officielle de l'add-on via le Supervisor.
BTUI_JOB_FILE="${BTUI_STATE_DIR}/job.json"
BTUI_DEVICES_FILE="${BTUI_STATE_DIR}/devices.json"
BTUI_SESSION_LOG="${BTUI_STATE_DIR}/bluetoothctl.log"
BTUI_LOCK_DIR="${BTUI_STATE_DIR}/lock"

BTUI_OPTIONS_FILE="/data/options.json"
# Fichier où le Supervisor écrit les options validées de l'add-on — celui
# que lit aussi bashio::config dans run.sh.

BTUI_INGRESS_CLIENT_IP="172.30.32.2"
# Adresse du proxy ingress du Supervisor : la documentation officielle des
# add-ons impose de refuser toute autre adresse. Vérifié ici EN PLUS de
# httpd.conf (défense en profondeur) : si httpd.conf venait à être modifié
# par erreur, les scripts refuseraient quand même d'agir.

BTUI_MAC_REGEX='^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
# Même format que le schema de bluetooth_mac dans config.yaml. Toute adresse
# venant du navigateur est validée avec ça AVANT d'être passée à
# bluetoothctl (pas d'argument arbitraire transmis à une commande).

BTUI_SCAN_SECONDS=30
BTUI_PAIR_TIMEOUT=30
# Durées volontairement bornées : un scan Bluetooth occupe la même radio
# que celle utilisée en parallèle par l'intégration "bluetooth" de Home
# Assistant pour ses capteurs BLE. On ne scanne donc jamais en continu,
# seulement à la demande et pendant un temps limité.

# ============================================================
# Réponses HTTP (CGI)
# ============================================================

# http_json <statut> <corps JSON>
# Un CGI doit écrire lui-même ses en-têtes. httpd de busybox convertit une
# première ligne "Status: 403 Forbidden" en vraie ligne de statut HTTP
# (vérifié dans networking/httpd.c) ; sans elle, il répond 200 par défaut.
http_json() {
    printf 'Status: %s\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n%s\n' "$1" "$2"
}

# http_error <statut> <message> — répond une erreur JSON et termine le CGI.
http_error() {
    http_json "$1" "$(jq -cn --arg error "$2" '{ok: false, error: $error}')"
    exit 0
}

require_ingress() {
    if [ "${REMOTE_ADDR:-}" != "${BTUI_INGRESS_CLIENT_IP}" ]; then
        http_error "403 Forbidden" "Only reachable through Home Assistant ingress."
    fi
}

require_method() {
    if [ "${REQUEST_METHOD:-}" != "$1" ]; then
        http_error "405 Method Not Allowed" "Use $1."
    fi
}

# read_json_body — lit le corps POST dans la variable BTUI_BODY.
# Pas de "$(read_json_body)" : dans une substitution de commande, le
# http_error/exit en cas de corps invalide ne terminerait que le
# sous-shell, pas le CGI. httpd de busybox transmet le corps sur l'entrée
# standard en se basant uniquement sur Content-Length (pas de "chunked") —
# ce que l'ingress du Supervisor fournit bien, tant que "ingress_stream"
# n'est pas activé dans config.yaml.
read_json_body() {
    local length="${CONTENT_LENGTH:-0}"
    BTUI_BODY=""
    if [[ "${length}" =~ ^[0-9]+$ ]] && ((length > 0 && length <= 4096)); then
        BTUI_BODY=$(head -c "${length}")
    fi
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"${BTUI_BODY}"; then
        http_error "400 Bad Request" "Expected a JSON object body."
    fi
}

valid_mac() {
    [[ "${1:-}" =~ ${BTUI_MAC_REGEX} ]]
}

# ============================================================
# Bluetooth (bluetoothctl)
# ============================================================
# Comme run.sh, tout passe par bluetoothctl sur le D-Bus de l'hôte
# (host_dbus: true dans config.yaml) : scan, pair et trust utilisent
# exactement le même accès que le "connect" déjà utilisé par run.sh, aucune
# permission supplémentaire n'est nécessaire.

bt_info() {
    bluetoothctl info "$1" 2>/dev/null || true
}

# info_flag <sortie de bt_info> <Propriété> — affiche true/false.
# La sortie est d'abord capturée dans une variable plutôt que passée
# directement dans un pipe "bluetoothctl info | grep -q" : avec
# "set -o pipefail", grep -q qui s'arrête au premier résultat peut faire
# échouer bluetoothctl (SIGPIPE) et donc tout le pipe, et une propriété
# pourtant présente serait lue comme absente.
info_flag() {
    if grep -q "^[[:space:]]*$2: yes" <<<"$1"; then echo true; else echo false; fi
}

# info_field <sortie de bt_info> <Champ> — affiche la valeur (ex: Name).
info_field() {
    awk -v field="$2" '
        { line = $0; sub(/^[ \t]+/, "", line) }
        index(line, field ": ") == 1 { print substr(line, length(field) + 3); exit }
    ' <<<"$1"
}

bt_is_known() {
    grep -q "Paired:" <<<"$(bt_info "$1")"
}

bt_is_paired() {
    [ "$(info_flag "$(bt_info "$1")" Paired)" = true ]
}

# bt_device_json <mac> [sortie de bt_info] — état d'un appareil en JSON.
bt_device_json() {
    local mac="$1" info name
    if [ $# -ge 2 ]; then info="$2"; else info=$(bt_info "${mac}"); fi
    name=$(info_field "${info}" Name)
    [ -n "${name}" ] || name=$(info_field "${info}" Alias)
    jq -cn \
        --arg mac "${mac}" \
        --arg name "${name}" \
        --argjson known "$(grep -q 'Paired:' <<<"${info}" && echo true || echo false)" \
        --argjson paired "$(info_flag "${info}" Paired)" \
        --argjson trusted "$(info_flag "${info}" Trusted)" \
        --argjson connected "$(info_flag "${info}" Connected)" \
        --argjson audio "$(grep -qE '^[[:space:]]*(UUID: Audio Sink|Icon: audio-)' <<<"${info}" && echo true || echo false)" \
        '{mac: $mac, name: $name, known: $known, paired: $paired, trusted: $trusted, connected: $connected, audio: $audio}'
}

# bt_devices_json — liste JSON des appareils Bluetooth Classic nommés.
# BlueZ garde en mémoire tous les appareils vus récemment, y compris les
# (très nombreux) appareils BLE que l'intégration "bluetooth" de HA voit
# passer. On écarte donc d'emblée les appareils sans nom (inutilisables
# pour l'utilisateur, et c'est l'essentiel du bruit BLE), puis on ne garde
# que ceux qui ont une classe Bluetooth Classic, un profil audio, ou qui
# sont déjà appairés. Le champ "audio" permet à la page de n'afficher que
# les enceintes par défaut.
bt_devices_json() {
    local mac name info
    local -a devices=()
    while read -r _ mac name; do
        valid_mac "${mac}" || continue
        # Sans nom, BlueZ affiche l'adresse avec des tirets à la place.
        if [ -z "${name}" ] || [ "${name}" = "${mac//:/-}" ]; then
            continue
        fi
        info=$(bt_info "${mac}")
        if grep -qE '^[[:space:]]*(Class:|UUID: Audio Sink|Icon: audio-|Paired: yes)' <<<"${info}"; then
            devices+=("$(bt_device_json "${mac}" "${info}")")
        fi
    done < <(bluetoothctl devices 2>/dev/null || true)
    if ((${#devices[@]} == 0)); then
        echo '[]'
        return
    fi
    printf '%s\n' "${devices[@]}" | jq -cs '.'
}

# devices_update <mac> — met à jour (ou retire) un appareil dans le
# dernier résultat de scan, après un appairage ou un "forget".
devices_update() {
    local entry tmp="${BTUI_DEVICES_FILE}.$$.tmp"
    entry=$(bt_device_json "$1")
    [ -s "${BTUI_DEVICES_FILE}" ] || echo '[]' >"${BTUI_DEVICES_FILE}"
    jq -c --argjson entry "${entry}" \
        'map(select(.mac != $entry.mac)) + (if $entry.known then [$entry] else [] end)' \
        "${BTUI_DEVICES_FILE}" >"${tmp}" && mv -f "${tmp}" "${BTUI_DEVICES_FILE}"
}

# bt_scan_session <secondes> [mac]
# Scan Bluetooth Classic, suivi d'un appairage si une adresse est donnée.
#
# Tout se passe dans UNE SEULE session bluetoothctl, alimentée ligne par
# ligne sur son entrée standard, et non en plusieurs appels séparés
# (bluetoothctl scan on, puis bluetoothctl pair...) — trois raisons,
# vérifiées dans le code de BlueZ :
# - BlueZ rattache un scan au client D-Bus qui l'a lancé et l'arrête dès
#   que ce client se termine ;
# - un appareil découvert mais non appairé est oublié ~30 s après la fin
#   du scan ("TemporaryTimeout"), trop court pour enchaîner sereinement ;
# - en mode non interactif, bluetoothctl n'enregistre aucun "agent"
#   d'appairage. On en déclare donc un explicitement, en NoInputNoOutput :
#   le mode "Just Works" des enceintes, sans écran ni clavier.
# "transport bredr" limite le scan au Bluetooth Classic (les enceintes
# A2DP), pour déranger le moins possible les scans BLE de Home Assistant.
# Limite connue : les enceintes (anciennes) qui exigent un code PIN ne
# peuvent pas être appairées ainsi — procédure manuelle dans le README.
bt_scan_session() {
    local seconds="$1" mac="${2:-}"
    mkdir -p "${BTUI_STATE_DIR}"
    : >"${BTUI_SESSION_LOG}"
    {
        # Laisse à bluetoothctl le temps de récupérer l'adaptateur sur
        # D-Bus : des commandes envoyées trop tôt échouent avec "No
        # default controller available".
        sleep 2
        echo "power on"
        echo "agent NoInputNoOutput"
        echo "default-agent"
        echo "menu scan"
        echo "transport bredr"
        echo "back"
        echo "scan on"
        local i
        for ((i = 0; i < seconds; i++)); do
            sleep 1
            # Appairage : inutile d'attendre la fin du scan dès que BlueZ
            # connaît l'appareil visé.
            if [ -n "${mac}" ] && bt_is_known "${mac}"; then
                break
            fi
        done
        echo "scan off"
        if [ -n "${mac}" ]; then
            echo "pair ${mac}"
            for ((i = 0; i < BTUI_PAIR_TIMEOUT; i++)); do
                sleep 1
                if bt_is_paired "${mac}" || grep -q "Failed to pair" "${BTUI_SESSION_LOG}"; then
                    break
                fi
            done
        fi
        echo "quit"
    } | bluetoothctl >"${BTUI_SESSION_LOG}" 2>&1 || true
}

# ============================================================
# Opérations longues en arrière-plan (scan, appairage)
# ============================================================
# Un scan ou un appairage prend jusqu'à une minute : bien trop long pour
# une requête HTTP qui attendrait la fin. Le CGI lance donc l'opération en
# arrière-plan et répond aussitôt ; la page suit l'avancement en relisant
# job.json toutes les 2 s (status.cgi). Une seule opération à la fois : un
# deuxième scan ou appairage lancé en même temps se gênerait sur la radio.

# job_alive — vrai si une opération tourne encore.
job_alive() {
    local pid
    [ -d "${BTUI_LOCK_DIR}" ] || return 1
    # Verrou tout juste créé, PID pas encore écrit : considéré actif.
    pid=$(cat "${BTUI_LOCK_DIR}/pid" 2>/dev/null) || return 0
    [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null
}

# job_set <état> <message> — met à jour l'opération en cours.
job_set() {
    local tmp="${BTUI_JOB_FILE}.$$.tmp"
    jq -c --arg state "$1" --arg message "$2" \
        '.state = $state | .message = $message | .updated = now' \
        "${BTUI_JOB_FILE}" >"${tmp}" && mv -f "${tmp}" "${BTUI_JOB_FILE}"
}

# job_on_exit — filet de sécurité (trap EXIT de l'opération) : si elle
# s'arrête sans avoir écrit d'état final (commande en échec sous
# "set -e"...), la page affiche une erreur au lieu de tourner indéfiniment,
# et le verrou est toujours libéré.
job_on_exit() {
    local rc=$?
    if [ "$(jq -r '.state' "${BTUI_JOB_FILE}" 2>/dev/null)" = "running" ]; then
        job_set error "Unexpected failure (exit code ${rc}), see the add-on log." || true
    fi
    rm -rf "${BTUI_LOCK_DIR}"
}

# job_start <scan|pair> <mac> — lance job_<type> en arrière-plan.
# Retourne 1 si une autre opération tourne déjà.
job_start() {
    local type="$1" mac="$2"
    mkdir -p "${BTUI_STATE_DIR}"
    # mkdir est atomique : c'est le verrou (pas besoin de flock).
    if ! mkdir "${BTUI_LOCK_DIR}" 2>/dev/null; then
        if job_alive; then
            return 1
        fi
        # Verrou orphelin (opération tuée brutalement) : on le récupère.
        rm -rf "${BTUI_LOCK_DIR}"
        mkdir "${BTUI_LOCK_DIR}" 2>/dev/null || return 1
    fi
    echo "$$" >"${BTUI_LOCK_DIR}/pid"
    jq -cn --arg id "$(date +%s)-$$" --arg type "${type}" --arg mac "${mac}" \
        '{id: $id, type: $type, mac: $mac, state: "running", message: "Starting...", started: now, updated: now}' \
        >"${BTUI_JOB_FILE}.$$.tmp" && mv -f "${BTUI_JOB_FILE}.$$.tmp" "${BTUI_JOB_FILE}"
    # stdin/stdout détachés : httpd considère la réponse du CGI terminée
    # dès que sa sortie standard est fermée, sans attendre l'opération.
    # stderr est gardé : il remonte dans le journal de l'add-on.
    (
        trap job_on_exit EXIT
        "job_${type}" "${mac}"
    ) </dev/null >/dev/null &
    echo "$!" >"${BTUI_LOCK_DIR}/pid"
}

job_scan() {
    local count
    job_set running "Scanning for ${BTUI_SCAN_SECONDS} seconds... Keep your speaker in pairing mode."
    bt_scan_session "${BTUI_SCAN_SECONDS}"
    job_set running "Reading scan results..."
    bt_devices_json >"${BTUI_DEVICES_FILE}.$$.tmp"
    mv -f "${BTUI_DEVICES_FILE}.$$.tmp" "${BTUI_DEVICES_FILE}"
    count=$(jq '[.[] | select(.audio)] | length' "${BTUI_DEVICES_FILE}")
    job_set done "Scan finished: ${count} audio device(s) found."
}

job_pair() {
    local mac="$1" info reason
    # Jamais de "pair" sur un appareil déjà appairé : selon la version de
    # bluetoothctl, ça peut d'abord SUPPRIMER l'appairage existant. Un
    # appareil appairé mais pas "trusted" passe directement à l'étape trust.
    if ! bt_is_paired "${mac}"; then
        job_set running "Pairing with ${mac}... Keep the speaker in pairing mode (this can take up to a minute)."
        bt_scan_session "${BTUI_SCAN_SECONDS}" "${mac}"
        if ! bt_is_paired "${mac}"; then
            reason=$(grep -o 'org\.bluez\.Error\.[A-Za-z]*' "${BTUI_SESSION_LOG}" | tail -n 1) || true
            echo "[pairing web UI] Pairing with ${mac} failed${reason:+ (${reason})}." >&2
            job_set error "Pairing with ${mac} failed${reason:+ (${reason})}. Put the speaker in pairing mode, keep it close to the host and try again. Speakers that ask for a PIN code must be paired manually (see the add-on documentation)."
            return 0
        fi
    fi
    job_set running "Paired. Trusting and connecting..."
    # "trust" est ce qui autorise la reconnexion automatique de run.sh
    # (voir README, dépannage) : c'est l'étape la plus souvent oubliée lors
    # d'un appairage manuel, d'où son automatisation ici.
    bluetoothctl trust "${mac}" >/dev/null 2>&1 || true
    bluetoothctl connect "${mac}" >/dev/null 2>&1 || true
    devices_update "${mac}"
    info=$(bt_info "${mac}")
    if [ "$(info_flag "${info}" Trusted)" != true ]; then
        job_set error "Paired, but ${mac} could not be marked as trusted: automatic reconnection will not work. Click Pair again."
    elif [ "$(info_flag "${info}" Connected)" != true ]; then
        job_set done "Paired and trusted, but not connected right now. You can still select it: the add-on reconnects it automatically."
    else
        job_set done "Paired, trusted and connected. Now set it as the primary speaker or add it as an extra one."
    fi
}

# ============================================================
# Configuration de l'add-on (API du Supervisor)
# ============================================================
# Le Supervisor fournit SUPERVISOR_TOKEN à tout add-on, et les routes
# /addons/self/options et /addons/self/restart font partie des appels
# qu'un add-on peut toujours faire sur lui-même (liste "api_bypass" du
# Supervisor) : pas besoin de "hassio_api: true" dans config.yaml, donc
# aucun droit supplémentaire demandé.

supervisor_api() {
    local -a args=(-sS --max-time 20 -X "$1" -H "Authorization: Bearer ${SUPERVISOR_TOKEN:-}")
    if [ -n "${3:-}" ]; then
        args+=(-H "Content-Type: application/json" --data "$3")
    fi
    curl "${args[@]}" "http://supervisor$2"
}

options_json() {
    cat "${BTUI_OPTIONS_FILE}" 2>/dev/null || echo '{}'
}

# options_apply <options JSON complètes> — retourne 1 et remplit
# BTUI_API_ERROR en cas de refus. Attention : POST /addons/self/options
# REMPLACE tout l'objet options (pas de fusion clé par clé) — l'appelant
# doit donc toujours partir des options actuelles complètes.
options_apply() {
    local response
    response=$(supervisor_api POST /addons/self/options "$(jq -cn --argjson options "$1" '{options: $options}')") || response=""
    if [ "$(jq -r '.result // empty' 2>/dev/null <<<"${response}")" = "ok" ]; then
        return 0
    fi
    BTUI_API_ERROR=$(jq -r '.message // empty' 2>/dev/null <<<"${response}") || true
    [ -n "${BTUI_API_ERROR:-}" ] || BTUI_API_ERROR="no valid response from the Supervisor"
    return 1
}

# schedule_restart — redémarre l'add-on 2 s plus tard, en arrière-plan,
# pour que la réponse HTTP ait le temps de repartir vers la page avant que
# le conteneur (et donc ce serveur web) ne s'arrête.
schedule_restart() {
    (
        sleep 2
        supervisor_api POST /addons/self/restart >/dev/null 2>&1 || true
    ) </dev/null >/dev/null 2>&1 &
}
