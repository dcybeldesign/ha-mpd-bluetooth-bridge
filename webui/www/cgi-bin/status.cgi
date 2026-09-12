#!/usr/bin/env bash
# ============================================================
# status.cgi — État courant de la page d'appairage (GET)
# ============================================================
# Appelé en boucle par index.html (toutes les 2 s pendant une opération,
# toutes les 10 s sinon). Renvoie en JSON :
# - les enceintes déjà configurées dans l'add-on (bluetooth_mac +
#   extra_speakers) avec leur état Bluetooth (Paired/Trusted/Connected) ;
# - l'opération en cours ou la dernière terminée (scan, appairage) ;
# - le dernier résultat de scan.
# Ne modifie jamais rien : toutes les actions passent par action.cgi.

set -euo pipefail
# Même mode strict que run.sh (voir le commentaire en tête de run.sh).

# shellcheck source=/dev/null
source /opt/btui/lib/btui.sh

require_ingress
require_method GET

options=$(options_json)

# speaker_json <primary|extra> <mac> <nom configuré>
speaker_json() {
    bt_device_json "${2^^}" | jq -c --arg role "$1" --arg name "$3" \
        '. + {role: $role, device_name: .name, name: $name}'
}

speakers=()
primary_mac=$(jq -r '.bluetooth_mac // ""' <<<"${options}")
if [ -n "${primary_mac}" ]; then
    speakers+=("$(speaker_json primary "${primary_mac}" "$(jq -r '.speaker_name // ""' <<<"${options}")")")
fi
while IFS=$'\t' read -r mac name; do
    if valid_mac "${mac}"; then
        speakers+=("$(speaker_json extra "${mac}" "${name}")")
    fi
done < <(jq -r '(.extra_speakers // [])[] | [.mac // "", .name // ""] | @tsv' <<<"${options}")

busy=false
if job_alive; then
    busy=true
fi

# --slurpfile plutôt que --argjson pour la liste des appareils : elle peut
# être longue, et un argument de commande est limité en taille.
job_file="${BTUI_JOB_FILE}"
[ -s "${job_file}" ] || job_file=/dev/null
devices_file="${BTUI_DEVICES_FILE}"
[ -s "${devices_file}" ] || devices_file=/dev/null

http_json "200 OK" "$(
    printf '%s\n' "${speakers[@]}" | jq -cs \
        --argjson busy "${busy}" \
        --argjson setup_mode "$([ -n "${primary_mac}" ] && echo false || echo true)" \
        --slurpfile job "${job_file}" \
        --slurpfile devices "${devices_file}" \
        '{
            ok: true,
            setup_mode: $setup_mode,
            busy: $busy,
            speakers: .,
            job: (($job[0] // null)
                | if . != null and .state == "running" and ($busy | not)
                  then .state = "error" | .message = "The operation was interrupted, try again."
                  else . end),
            devices: ($devices[0] // [])
        }'
)"
