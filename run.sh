#!/usr/bin/with-contenv bashio
# ============================================================
# run.sh — Script de démarrage de l'add-on
# ============================================================
# Rôle : préparer la config MPD avec le bon sink Bluetooth, s'assurer
# que l'enceinte configurée est connectée, puis lancer MPD. Une boucle
# de fond surveille la connexion Bluetooth et la rétablit automatiquement
# si l'enceinte se déconnecte (mise en veille, coupure, etc.).
#
# La ligne "#!/usr/bin/with-contenv bashio" (au lieu d'un simple bash)
# permet d'utiliser directement les fonctions "bashio::..." fournies
# par l'image de base des add-ons Home Assistant, notamment pour lire
# les options définies dans config.yaml.

set -euo pipefail
# -e : arrête immédiatement le script si une commande échoue de façon
# inattendue (évite de continuer dans un état incohérent).
# -u : arrête le script si une variable non définie est utilisée.
# -o pipefail : dans un pipe (cmd1 | cmd2), remonte l'échec de cmd1 même
# si cmd2 réussit (sans ça, seul le code de sortie de cmd2 compte).
# Suggéré par un lecteur sur le forum officiel HA (2026-08-22) ; vérifié
# avant application que bashio active déjà ces trois options en interne
# (voir lib/bashio sur github.com/hassio-addons/bashio) et qu'aucune
# variable de ce script n'est lue avant d'être assignée.

mkdir -p /var/lib/mpd/playlists /var/lib/mpd/music
# Recréé au démarrage du conteneur (pas seulement à la construction de
# l'image) : sur le premier essai, MPD plantait avec "Failed to open
# '/var/lib/mpd/database': No such file or directory" — ces dossiers
# doivent exister au moment où MPD démarre, pas seulement au moment du
# build de l'image (un volume ou une réinitialisation du système de
# fichiers du conteneur peut repartir de zéro).

# --- 1. Lecture de la configuration utilisateur ---
BT_MAC=$(bashio::config 'bluetooth_mac')
# Adresse MAC de l'enceinte, saisie par l'utilisateur dans l'onglet
# "Configuration" de l'add-on (ex: AA:BB:CC:DD:EE:FF), ou écrite
# automatiquement par la page d'appairage (2.4.0, voir étape 1ter). Peut
# être vide depuis 2.4.0 (première installation, avant tout appairage) :
# voir le mode configuration, étape 1quater.

SPEAKER_NAME=$(bashio::config 'speaker_name')
# Nom cosmétique de l'enceinte, affiché côté MPD (n'affecte pas le
# fonctionnement). Par défaut "Bluetooth Speaker" si non renseigné.

RECONNECT_INTERVAL=$(bashio::config 'reconnect_interval')
# Intervalle (en secondes) entre deux vérifications de la connexion
# Bluetooth par la boucle de surveillance (voir étape 5). Par défaut 30s.

ENABLE_MPD=$(bashio::config 'enable_mpd')
# Par défaut true (voir config.yaml) : préserve le chemin MPD/Music
# Assistant existant. La connexion Bluetooth (étapes 1 à 4bis) reste
# nécessaire dans tous les cas — seule la génération de mpd.conf et le
# lancement de MPD (étapes 3 et 6) sont conditionnés par cette option.

DEFAULT_VOLUME=$(bashio::config 'default_volume')
# Volume (%) restauré automatiquement si le sink PulseAudio de l'enceinte
# est détecté muet ou à 0% (voir ensure_audio_sink, étape 4bis). Par défaut
# 70 (voir config.yaml).

# --- 1ter. Page d'appairage Bluetooth (ingress, 2.4.0) ---
# Petit serveur web (httpd de busybox-extras) qui sert la page ouverte
# depuis le panneau "Bluetooth Audio" de Home Assistant (voir webui/) :
# scan, appairage, et choix de l'enceinte écrit directement dans la
# configuration de l'add-on. Lancé AVANT toute connexion Bluetooth et même
# sans enceinte configurée : c'est justement cette page qui permet d'en
# appairer une sans terminal.
#
# Sécurité — le point le plus important de cette étape : l'add-on tourne
# en host_network (voir config.yaml), donc écouter sur 0.0.0.0 exposerait
# cette page, sans aucune authentification, à tout le réseau local. On
# écoute donc UNIQUEMENT sur l'adresse interne par laquelle le Supervisor
# joint l'add-on (en host_network, bashio::addon.ip_address renvoie la
# passerelle du réseau interne hassio), sur le port attribué par le
# Supervisor (ingress_port: 0 dans config.yaml). httpd.conf n'accepte en
# plus que le proxy ingress lui-même (172.30.32.2). Côté navigateur, on
# passe par la session Home Assistant (panneau réservé aux administrateurs).
INGRESS_IP=$(bashio::addon.ip_address) || INGRESS_IP=""
INGRESS_PORT=$(bashio::addon.ingress_port) || INGRESS_PORT=""
if bashio::var.has_value "${INGRESS_IP}" && bashio::var.has_value "${INGRESS_PORT}"; then
    mkdir -p /tmp/btui
    bashio::log.info "Starting the pairing web UI on ${INGRESS_IP}:${INGRESS_PORT} (Home Assistant ingress only)..."
    busybox-extras httpd -f -p "${INGRESS_IP}:${INGRESS_PORT}" -h /opt/btui/www -c /opt/btui/httpd.conf &
    # "-f" (premier plan) + "&" : même principe que gmediarender plus bas,
    # le processus reste un enfant du conteneur au lieu de se détacher.
else
    # Jamais bloquant : sans page d'appairage, le pont audio lui-même
    # (connexion, MPD, media_player) doit continuer de fonctionner
    # exactement comme avant pour une enceinte déjà configurée.
    bashio::log.error "Could not read the ingress address/port from the Supervisor: pairing web UI not started." || true
fi

# --- 1quater. Mode configuration (aucune enceinte choisie, 2.4.0) ---
# bluetooth_mac peut désormais rester vide (voir schema dans config.yaml) :
# c'est l'état d'une première installation, avant d'avoir appairé une
# enceinte depuis la page ci-dessus. Tout ce qui suit (sink PulseAudio,
# MPD, gmediarender, boucles de surveillance) n'a aucun sens sans
# enceinte : on s'arrête là, en gardant le conteneur (et donc la page
# d'appairage) en vie. extra_speakers est ignoré dans ce mode. Choisir une
# enceinte depuis la page écrit la configuration puis redémarre l'add-on,
# qui repasse alors par le chemin normal ci-dessous.
# bashio::config.has_value plutôt qu'un test sur ${BT_MAC} : si l'option
# est carrément retirée de la configuration (champ facultatif vidé dans
# l'interface de Home Assistant), bashio::config renvoie la chaîne "null"
# et non une chaîne vide (vérifié dans lib/config.sh de bashio) — un test
# sur ${BT_MAC} laisserait alors passer une adresse "null".
if ! bashio::config.has_value 'bluetooth_mac'; then
    bashio::log.warning "No speaker configured yet (bluetooth_mac is empty): open the \"Bluetooth Audio\" panel in the Home Assistant sidebar to scan for, pair and select a speaker."
    exec tail -f /dev/null
fi

bashio::log.info "Target speaker: ${SPEAKER_NAME} (${BT_MAC})"

# --- 1bis. Enceintes supplémentaires (multi-enceintes, 2.3.0) ---
# `extra_speakers` est une liste optionnelle d'objets {mac, name} (voir
# config.yaml) — vide par défaut, donc ce bloc ne change rien pour qui ne
# l'utilise pas. On construit un tableau SPEAKERS_MAC[]/SPEAKERS_NAME[] qui
# commence TOUJOURS par la "première" enceinte historique (bluetooth_mac/
# speaker_name), pour que l'indice 0 reste celle utilisée par MPD plus bas
# (étape 3/6) sans rien changer à ce chemin existant.
SPEAKERS_MAC=("${BT_MAC}")
SPEAKERS_NAME=("${SPEAKER_NAME}")
EXTRA_SPEAKERS_COUNT=$(bashio::config 'extra_speakers|length')
for ((i = 0; i < EXTRA_SPEAKERS_COUNT; i++)); do
    SPEAKERS_MAC+=("$(bashio::config "extra_speakers[${i}].mac")")
    SPEAKERS_NAME+=("$(bashio::config "extra_speakers[${i}].name")")
done
if ((EXTRA_SPEAKERS_COUNT > 0)); then
    bashio::log.info "${EXTRA_SPEAKERS_COUNT} extra speaker(s) configured (${#SPEAKERS_MAC[@]} total)."
fi

# --- 1bis-2. Pré-calcul de l'UUID et du port DLNA de chaque enceinte (2.4.1) ---
# Fait une seule fois ici, dans l'ordre des enceintes, plutôt que dans la
# boucle de démarrage du renderer (ancienne étape 5bis) : depuis cette
# version, c'est monitor_speaker (étape 5) qui démarre/arrête/relance le
# renderer de SA propre enceinte (voir issue #6 — l'entité media_player
# restait "disponible" alors que l'enceinte était éteinte, gmediarender
# continuant de répondre sur le réseau quoi qu'il arrive). Il lui faut donc
# connaître à l'avance l'UUID et le port de son enceinte, calculés une
# seule fois pour éviter qu'une reconnexion ne fasse changer l'un ou
# l'autre en cours de route.
SPEAKERS_UUID=()
SPEAKERS_PORT=()
used_ports=()
for i in "${!SPEAKERS_MAC[@]}"; do
    mac_hash=$(echo -n "${SPEAKERS_MAC[i]}" | md5sum | cut -c1-32)
    SPEAKERS_UUID+=("${mac_hash:0:8}-${mac_hash:8:4}-${mac_hash:12:4}-${mac_hash:16:4}-${mac_hash:20:12}")
    if ((i == 0)); then
        port=49494
    else
        port=$((49500 + 16#${mac_hash:0:4} % 10000))
        while [[ " ${used_ports[*]} " == *" ${port} "* ]]; do
            port=$((port + 1))
        done
    fi
    used_ports+=("${port}")
    SPEAKERS_PORT+=("${port}")
done

# --- 2. Calcul du nom du sink PulseAudio correspondant ---
# PulseAudio nomme les sinks Bluetooth en remplaçant les ":" par des "_"
# et en les collant au format bluez_sink.<MAC>.a2dp_sink.
# Exemple : AA:BB:CC:DD:EE:FF  ->  AA_BB_CC_DD_EE_FF
# Fonction (plutôt qu'un calcul en ligne) car nécessaire pour CHAQUE
# enceinte du tableau ci-dessus depuis le multi-enceintes, pas seulement
# la première.
sink_for_mac() {
    local mac_underscore
    mac_underscore=$(echo "$1" | tr ':' '_')
    echo "bluez_sink.${mac_underscore}.a2dp_sink"
}
card_for_mac() {
    local mac_underscore
    mac_underscore=$(echo "$1" | tr ':' '_')
    echo "bluez_card.${mac_underscore}"
}

BLUETOOTH_SINK=$(sink_for_mac "${BT_MAC}")
BLUETOOTH_CARD=$(card_for_mac "${BT_MAC}")
# Ces deux variables restent celles de la PREMIÈRE enceinte uniquement :
# c'est ce que MPD utilise (étape 3), et MPD ne gère qu'une seule enceinte
# dans cette version (voir schema de extra_speakers dans config.yaml pour
# le détail de ce choix).

bashio::log.info "Computed PulseAudio sink: ${BLUETOOTH_SINK}"

# --- 3. Génération du fichier mpd.conf final (si MPD activé) ---
# On remplace ${BLUETOOTH_SINK} et ${SPEAKER_NAME} dans le modèle par les
# vraies valeurs calculées ci-dessus, et on écrit le résultat dans
# /etc/mpd.conf. Attention à la syntaxe : envsubst ne reconnaît QUE
# `$VAR`/`${VAR}` (pas de `{{VAR}}` façon Jinja/Mustache — un bug de ce
# type, avec le template utilisant {{BLUETOOTH_SINK}}, avait fait
# échouer silencieusement toute lecture audio lors du développement
# initial : MPD tentait de se connecter à un sink qui n'existait pas).
if bashio::var.true "${ENABLE_MPD}"; then
    export BLUETOOTH_SINK SPEAKER_NAME
    envsubst '${BLUETOOTH_SINK} ${SPEAKER_NAME}' < /etc/mpd.conf.template > /etc/mpd.conf
    bashio::log.info "/etc/mpd.conf generated."
else
    bashio::log.info "enable_mpd is false: skipping mpd.conf generation."
fi

# --- 4. Connexion (ou reconnexion) Bluetooth à l'enceinte ---
# Fonction réutilisée aussi bien au démarrage que dans la boucle de
# surveillance plus bas. Paramétrée par mac/name (2.3.0, multi-enceintes) :
# une seule définition, appelée pour chaque enceinte du tableau
# SPEAKERS_MAC[]/SPEAKERS_NAME[], au lieu d'une copie par enceinte.
connect_speaker() {
    local mac="$1" name="$2"
    bashio::log.info "Connecting to ${name} (${mac})..."
    # "|| true" sur les trois lignes ci-dessous : avec "set -e" en tête de
    # script, la moindre commande qui renvoie un code non nul (y compris
    # bashio::log.* lui-même, ou "bluetoothctl power on" seul, qui n'était
    # pas protégé jusqu'ici contrairement à "connect" juste en dessous) tue
    # tout le conteneur immédiatement — sans le moindre message d'erreur,
    # juste après le log "Connecting to...". C'est exactement le crash
    # silencieux et systématique observé en 2026-09 (voir vault, incident
    # du 2026-09-01) : un échec de connexion à l'enceinte ne doit jamais
    # faire tomber le script, seulement être loggé et retenté par la boucle
    # de surveillance (étape 5).
    bluetoothctl power on || true
    if bluetoothctl connect "${mac}"; then
        bashio::log.info "${name} connected." || true
    else
        bashio::log.warning "Failed to connect to ${name} — will retry in the monitoring loop." || true
    fi
}

# --- 4bis. Garde-fou : forcer le profil et le volume audio si besoin ---
# Cas observé en conditions réelles : après une série rapprochée de
# déconnexions/reconnexions Bluetooth (typiquement une enceinte à
# batterie faible), BlueZ finit par rapporter la connexion comme stable
# ("Connected: yes"), mais le profil de la carte PulseAudio correspondante
# reste bloqué sur "off" au lieu de repasser sur "a2dp_sink" — le sink
# audio n'existe alors plus du tout, et MPD n'a nulle part où streamer,
# sans qu'aucune erreur visible n'apparaisse côté Bluetooth. Ce n'est pas
# un bug de ce script mais un comportement du module PulseAudio Bluetooth
# lui-même : on ne peut pas empêcher que ça arrive, seulement le détecter
# et s'en remettre automatiquement.
ensure_audio_sink() {
    local sink="$1" card="$2"
    # Paramétrée par sink/card (2.3.0, multi-enceintes) : DEFAULT_VOLUME
    # reste une variable globale partagée entre toutes les enceintes — un
    # seul réglage de config pour toutes (voir config.yaml), pas de volume
    # par enceinte dans cette version, pour rester simple.
    # Sortie capturée PUIS cherchée, jamais "commande | grep -q" (2.4.0) :
    # avec "set -o pipefail" en tête de script, grep -q s'arrête dès la
    # première correspondance, la commande en amont peut alors être tuée par
    # SIGPIPE en écrivant la suite de sa sortie, et tout le pipe est lu comme
    # un échec alors que la ligne cherchée était bien là. Même règle dans
    # monitor_speaker plus bas, et même précaution que webui/lib/btui.sh.
    local sinks
    sinks=$(pactl list short sinks 2>/dev/null) || true
    if ! grep -q "${sink}" <<<"${sinks}"; then
        # Le sink attendu n'existe pas : on force le profil. Sans effet si la
        # carte PulseAudio n'a pas encore été créée par BlueZ (juste après une
        # connexion très récente) — la boucle de surveillance réessaiera au
        # prochain passage.
        if pactl set-card-profile "${card}" a2dp_sink 2>/dev/null; then
            bashio::log.warning "Bluetooth audio sink was missing, forced PulseAudio profile back to a2dp_sink."
        fi
        return
    fi

    # Le sink existe mais peut être silencieux (muet, ou volume à 0%) sans
    # qu'aucune erreur ne remonte côté Bluetooth ou PulseAudio — signalé par
    # un utilisateur (GitHub issue #1) : ce volume/mute au niveau du sink
    # (matériel) est un réglage distinct du volume interne de gmediarender
    # (qui ne contrôle que son propre flux, voir étape 5bis) — rien dans ce
    # script ne le touchait jusqu'ici. Deux vérifications séparées :
    # `set-sink-volume` seul ne démute pas un sink déjà muet.
    local mute
    mute=$(pactl get-sink-mute "${sink}" 2>/dev/null) || true
    if grep -q "^Mute: yes" <<<"${mute}"; then
        if pactl set-sink-mute "${sink}" 0 2>/dev/null; then
            bashio::log.warning "Bluetooth audio sink was muted, unmuted it."
        fi
    fi

    # Volume brut du premier canal, extrait avant le premier "/" de la
    # sortie de `get-sink-volume` : plus fiable qu'un grep sur "0%", qui
    # matcherait aussi "100%" (qui se termine littéralement par "0%").
    local raw_volume
    raw_volume=$(pactl get-sink-volume "${sink}" 2>/dev/null \
        | awk -F'/' '/Volume:/ { gsub(/[^0-9]/, "", $1); print $1; exit }') || true
    if [ "${raw_volume:-}" = "0" ]; then
        if pactl set-sink-volume "${sink}" "${DEFAULT_VOLUME}%" 2>/dev/null; then
            bashio::log.warning "Bluetooth audio sink was silent (0% volume), reset to ${DEFAULT_VOLUME}%."
        fi
    fi
    # N'écrase jamais un volume non nul choisi par l'utilisateur (ex. 20%) :
    # seul le silence total (0% ou muet) déclenche une correction, pas de
    # reset périodique intrusif à chaque passage de la boucle.
}

# On tente une première connexion avant même de démarrer MPD, pour que
# le sink existe déjà quand MPD essaiera de s'y attacher.
# Boucle sur SPEAKERS_MAC[]/SPEAKERS_NAME[] (2.3.0, multi-enceintes) : avec
# une seule enceinte configurée (cas par défaut), ce tableau ne contient que
# l'indice 0 et cette boucle se comporte exactement comme l'appel unique
# d'avant.
for i in "${!SPEAKERS_MAC[@]}"; do
    # "|| true" : filet de sécurité supplémentaire, au cas où connect_speaker
    # retournerait quand même un code non nul pour une raison non couverte
    # ci-dessus — un appel de fonction "nu" comme celui-ci est justement ce
    # qui déclenche "set -e" si son code de sortie est non nul.
    connect_speaker "${SPEAKERS_MAC[i]}" "${SPEAKERS_NAME[i]}" || true
done
sleep 2
# Laisse le temps à PulseAudio d'enregistrer la/les carte(s) Bluetooth après
# la connexion avant de vérifier/forcer leur profil.
for i in "${!SPEAKERS_MAC[@]}"; do
    ensure_audio_sink "$(sink_for_mac "${SPEAKERS_MAC[i]}")" "$(card_for_mac "${SPEAKERS_MAC[i]}")"
done

# --- 5. Boucle de surveillance Bluetooth (tourne en tâche de fond) ---
# Vérifie périodiquement (intervalle configurable, voir RECONNECT_INTERVAL)
# si l'enceinte est toujours connectée ; si elle ne l'est plus (mise en
# veille, hors de portée...), on relance une connexion automatiquement,
# sans intervention manuelle.
# Paramétrée par mac/name/sink/card (2.3.0, multi-enceintes) : UNE instance
# de cette boucle est lancée en tâche de fond PAR enceinte (voir plus bas),
# chacune surveillant uniquement la sienne — la déconnexion/reconnexion
# d'une enceinte n'a donc aucune raison de se mélanger avec celle d'une
# autre côté logique applicative (la contention possible reste au niveau du
# radio Bluetooth physique lui-même, voir vault : test du 2026-09-06).
monitor_speaker() {
    local mac="$1" name="$2" sink="$3" card="$4" uuid="$5" port="$6"
    local info renderer_pid=""
    # renderer_pid est une variable LOCALE à cette fonction : chaque appel de
    # monitor_speaker tourne dans son propre processus (le "&" au moment de
    # l'appel, plus bas), donc le renderer_pid d'une enceinte ne peut pas se
    # mélanger avec celui d'une autre, même si le nom de la variable est le
    # même partout.

    is_connected() {
        local i
        i=$(bluetoothctl info "${mac}" 2>/dev/null) || true
        grep -q "Connected: yes" <<<"${i}"
    }

    start_renderer() {
        # Corrige la GitHub issue #6 : avant cette version, gmediarender
        # tournait en continu quelle que soit la connexion Bluetooth, donc
        # HA voyait toujours un renderer qui répond et gardait l'entité
        # "disponible" même enceinte éteinte. Démarré ici (donc uniquement
        # quand on sait l'enceinte connectée) plutôt que dans une boucle à
        # part comme avant 2.4.1.
        bashio::log.info "Starting the DLNA renderer for ${name} (uuid=${uuid}, port=${port})..." || true
        gmediarender \
            --gstout-audiosink=pulsesink \
            --gstout-audiodevice="${sink}" \
            --friendly-name="${name}" \
            --uuid="${uuid}" \
            --port="${port}" \
            --logfile=stdout \
            &
        renderer_pid=$!
    }

    stop_renderer() {
        # Appelé uniquement quand l'enceinte est détectée déconnectée : c'est
        # cet arrêt qui rend le renderer injoignable et qui doit faire passer
        # l'entité media_player à "indisponible" côté Home Assistant.
        if [ -n "${renderer_pid}" ] && kill -0 "${renderer_pid}" 2>/dev/null; then
            kill "${renderer_pid}" 2>/dev/null || true
            wait "${renderer_pid}" 2>/dev/null || true
            bashio::log.warning "Stopped the DLNA renderer for ${name} while disconnected." || true
        fi
        renderer_pid=""
    }

    # Démarrage initial : on vérifie l'état réel plutôt que de supposer que
    # la connexion faite plus haut (avant le lancement de cette boucle en
    # tâche de fond) a réussi — une enceinte éteinte au démarrage de l'add-on
    # ne doit pas se voir attribuer un renderer qui tournerait dans le vide.
    if is_connected; then
        start_renderer
    else
        bashio::log.warning "${name} not connected at startup, DLNA renderer not started yet." || true
    fi

    while true; do
        sleep "${RECONNECT_INTERVAL}"
        # Sortie capturée puis cherchée (2.4.0, voir ensure_audio_sink) : le
        # pipe "bluetoothctl info | grep -q" sous pipefail signalait une
        # enceinte pourtant connectée comme déconnectée toutes les ~30 s,
        # puis relançait une connexion qui échouait forcément (constaté sur
        # un Raspberry Pi 4 le 2026-09-12, BlueZ 5.66 de l'image Alpine 3.18).
        if is_connected; then
            # Reconnectée depuis le dernier passage (ou renderer mort tout
            # seul, ex. crash de gmediarender) : le relancer.
            if [ -z "${renderer_pid}" ] || ! kill -0 "${renderer_pid}" 2>/dev/null; then
                start_renderer
            fi
        else
            bashio::log.warning "${name} disconnected, attempting to reconnect..." || true
            stop_renderer
            connect_speaker "${mac}" "${name}" || true
            sleep 2
            if is_connected; then
                start_renderer
            fi
        fi
        # Vérifié à chaque passage, pas seulement après une reconnexion :
        # le profil PulseAudio peut rester bloqué sur "off" alors que
        # Bluetooth se dit déjà connecté depuis un moment (voir 4bis).
        ensure_audio_sink "${sink}" "${card}"
    done
}
for i in "${!SPEAKERS_MAC[@]}"; do
    monitor_speaker \
        "${SPEAKERS_MAC[i]}" \
        "${SPEAKERS_NAME[i]}" \
        "$(sink_for_mac "${SPEAKERS_MAC[i]}")" \
        "$(card_for_mac "${SPEAKERS_MAC[i]}")" \
        "${SPEAKERS_UUID[i]}" \
        "${SPEAKERS_PORT[i]}" &
    # Le "&" final lance cette boucle en arrière-plan : le script continue
    # immédiatement à l'étape suivante sans attendre qu'elle se termine
    # (elle ne se termine jamais, c'est voulu) — une par enceinte.
done

# --- 5bis. Media_player natif (renderer DLNA/UPnP) ---
# Depuis 2.4.1, gmediarender n'est plus démarré ici en une seule fois pour
# toute la durée de vie du conteneur : c'est monitor_speaker (étape 5,
# fonctions start_renderer/stop_renderer) qui le démarre, l'arrête et le
# relance pour SA propre enceinte, selon l'état réel de la connexion
# Bluetooth — voir la GitHub issue #6 (l'entité media_player restait
# "disponible" côté Home Assistant même enceinte éteinte, gmediarender
# continuant de répondre sur le réseau quoi qu'il arrive). L'UUID et le
# port de chaque enceinte restent calculés une seule fois (étape 1bis-2,
# SPEAKERS_UUID[]/SPEAKERS_PORT[]) pour qu'ils ne changent jamais en cours
# de route, y compris à travers plusieurs déconnexions/reconnexions.
if ! command -v gmediarender >/dev/null 2>&1; then
    bashio::log.error "gmediarender binary NOT FOUND — compilation Dockerfile probablement en échec silencieux, voir le journal de build."
fi
# Garde-fou de diagnostic (2026-08-20) : le premier build de gmediarender
# n'a produit aucune trace dans les logs (ni succès ni erreur) et HA n'a
# détecté aucun nouveau renderer DLNA — cette vérification confirme noir sur
# blanc si le binaire existe réellement avant de creuser plus loin, même si
# le démarrage effectif se fait maintenant dans monitor_speaker.
# Partage volontairement le même sink PulseAudio que MPD (si activé) :
# PulseAudio mixe plusieurs sources sur un même sink nativement, donc les
# deux peuvent en principe coexister sans conflit technique — à vérifier en
# usage réel si les deux jouent en même temps (voir "Inconnues techniques"
# dans le vault du projet).

# --- 6. Lancement du processus principal ---
if bashio::var.true "${ENABLE_MPD}"; then
    bashio::log.info "Starting MPD..."
    exec mpd --no-daemon /etc/mpd.conf
    # "exec" remplace ce script par le processus MPD : MPD devient le
    # processus principal du conteneur (utile pour que le Supervisor sache
    # si l'add-on plante et doive être redémarré). "--no-daemon" empêche
    # MPD de se détacher en arrière-plan, ce qui est nécessaire pour rester
    # le processus principal du conteneur au lieu de le laisser croire
    # que le conteneur s'est arrêté.
else
    bashio::log.info "enable_mpd is false: MPD not started, keeping the container alive for the Bluetooth connection and the native media_player (gmediarender, étape 5bis)."
    exec tail -f /dev/null
    # Garde un processus au premier plan sans rien faire : la boucle de
    # surveillance Bluetooth (étape 5) et gmediarender (étape 5bis)
    # continuent de tourner en tâche de fond dans les deux cas.
fi
