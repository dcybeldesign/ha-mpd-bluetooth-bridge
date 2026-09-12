#!/usr/bin/env bash
# ============================================================
# action.cgi — Actions de la page d'appairage (POST)
# ============================================================
# Reçoit un corps JSON {action, mac, name} et exécute une seule action :
# - scan        : recherche d'enceintes (en arrière-plan, voir btui.sh) ;
# - pair        : appairage + trust + connexion (en arrière-plan) ;
# - forget      : supprime l'appairage d'un appareil ;
# - set_primary : enregistre l'enceinte comme enceinte principale
#                 (bluetooth_mac/speaker_name), puis redémarre l'add-on ;
# - add_extra   : l'ajoute à extra_speakers, puis redémarre l'add-on.
# Toute donnée venant du navigateur est validée ici avant usage : adresse
# MAC au format strict, nom sans caractère qui casserait la configuration.

set -euo pipefail
# Même mode strict que run.sh (voir le commentaire en tête de run.sh).

# shellcheck source=/dev/null
source /opt/btui/lib/btui.sh

require_ingress
require_method POST
read_json_body

action=$(jq -r '.action // ""' <<<"${BTUI_BODY}")
mac=$(jq -r '.mac // ""' <<<"${BTUI_BODY}")
mac="${mac^^}"
# Majuscules : c'est la forme qu'affiche bluetoothctl et celle qu'utilise
# PulseAudio dans le nom du sink (bluez_sink.AA_BB_...), calculé par run.sh
# directement à partir de bluetooth_mac.
name=$(jq -r '.name // ""' <<<"${BTUI_BODY}")

require_mac() {
    if ! valid_mac "${mac}"; then
        http_error "400 Bad Request" "Invalid Bluetooth MAC address."
    fi
}

require_name() {
    # Espaces en début/fin retirés.
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    if [ -z "${name}" ] || ((${#name} > 64)); then
        http_error "400 Bad Request" "The name must be 1 to 64 characters long."
    fi
    # Guillemets et antislash refusés : le nom finit entre guillemets dans
    # /etc/mpd.conf (voir mpd.conf.template, name "${SPEAKER_NAME}"), où ils
    # rendraient la configuration MPD invalide au redémarrage.
    case "${name}" in
        *\"* | *\\*)
            http_error "400 Bad Request" "The name can't contain quotes or backslashes."
            ;;
    esac
    if [[ "${name}" =~ [[:cntrl:]] ]]; then
        http_error "400 Bad Request" "The name can't contain control characters."
    fi
}

require_idle() {
    if job_alive; then
        http_error "409 Conflict" "Another Bluetooth operation is still running, wait for it to finish."
    fi
}

# apply_and_restart <nouvelles options complètes>
apply_and_restart() {
    if ! options_apply "$1"; then
        http_error "502 Bad Gateway" "The Supervisor rejected the new configuration: ${BTUI_API_ERROR}"
    fi
    http_json "200 OK" '{"ok":true,"restarting":true}'
    schedule_restart
}

case "${action}" in
    scan)
        if ! job_start scan ""; then
            http_error "409 Conflict" "Another Bluetooth operation is still running, wait for it to finish."
        fi
        http_json "200 OK" '{"ok":true}'
        ;;

    pair)
        require_mac
        if ! job_start pair "${mac}"; then
            http_error "409 Conflict" "Another Bluetooth operation is still running, wait for it to finish."
        fi
        http_json "200 OK" '{"ok":true}'
        ;;

    forget)
        require_mac
        require_idle
        bluetoothctl remove "${mac}" >/dev/null 2>&1 || true
        devices_update "${mac}"
        if bt_is_paired "${mac}"; then
            http_error "500 Internal Server Error" "Could not forget ${mac}."
        fi
        http_json "200 OK" '{"ok":true}'
        ;;

    set_primary)
        require_mac
        require_name
        require_idle
        # Remplace l'enceinte principale ; si cette enceinte était déjà
        # listée dans extra_speakers, elle en est retirée (sinon run.sh la
        # connecterait deux fois, avec deux media_player identiques).
        apply_and_restart "$(jq -c --arg mac "${mac}" --arg name "${name}" '
            .bluetooth_mac = $mac
            | .speaker_name = $name
            | .extra_speakers = ((.extra_speakers // []) | map(select((.mac | ascii_upcase) != $mac)))
        ' <<<"$(options_json)")"
        ;;

    add_extra)
        require_mac
        require_name
        require_idle
        options=$(options_json)
        primary=$(jq -r '(.bluetooth_mac // "") | ascii_upcase' <<<"${options}")
        if [ -z "${primary}" ]; then
            # En mode configuration (bluetooth_mac vide), run.sh ignore
            # extra_speakers : l'enceinte ajoutée ne servirait à rien.
            http_error "409 Conflict" "Set a primary speaker first."
        fi
        if [ "${primary}" = "${mac}" ]; then
            http_error "409 Conflict" "This speaker is already the primary speaker."
        fi
        if jq -e --arg mac "${mac}" 'any((.extra_speakers // [])[]; (.mac | ascii_upcase) == $mac)' >/dev/null <<<"${options}"; then
            http_error "409 Conflict" "This speaker is already an extra speaker."
        fi
        apply_and_restart "$(jq -c --arg mac "${mac}" --arg name "${name}" \
            '.extra_speakers = ((.extra_speakers // []) + [{mac: $mac, name: $name}])' <<<"${options}")"
        ;;

    *)
        http_error "400 Bad Request" "Unknown action."
        ;;
esac
