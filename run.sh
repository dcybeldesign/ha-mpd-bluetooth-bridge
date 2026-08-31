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
# "Configuration" de l'add-on (ex: AA:BB:CC:DD:EE:FF). Champ obligatoire
# (voir schema dans config.yaml) : aucune valeur par défaut n'est fournie,
# chaque utilisateur doit renseigner l'adresse de SA propre enceinte.

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

bashio::log.info "Target speaker: ${SPEAKER_NAME} (${BT_MAC})"

# --- 2. Calcul du nom du sink PulseAudio correspondant ---
# PulseAudio nomme les sinks Bluetooth en remplaçant les ":" par des "_"
# et en les collant au format bluez_sink.<MAC>.a2dp_sink.
# Exemple : AA:BB:CC:DD:EE:FF  ->  AA_BB_CC_DD_EE_FF
BT_MAC_UNDERSCORE=$(echo "${BT_MAC}" | tr ':' '_')
BLUETOOTH_SINK="bluez_sink.${BT_MAC_UNDERSCORE}.a2dp_sink"
BLUETOOTH_CARD="bluez_card.${BT_MAC_UNDERSCORE}"

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
# surveillance plus bas.
connect_speaker() {
    bashio::log.info "Connecting to ${SPEAKER_NAME} (${BT_MAC})..."
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
    if bluetoothctl connect "${BT_MAC}"; then
        bashio::log.info "${SPEAKER_NAME} connected." || true
    else
        bashio::log.warning "Failed to connect to ${SPEAKER_NAME} — will retry in the monitoring loop." || true
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
    if ! pactl list short sinks 2>/dev/null | grep -q "${BLUETOOTH_SINK}"; then
        # Le sink attendu n'existe pas : on force le profil. Sans effet si la
        # carte PulseAudio n'a pas encore été créée par BlueZ (juste après une
        # connexion très récente) — la boucle de surveillance réessaiera au
        # prochain passage.
        if pactl set-card-profile "${BLUETOOTH_CARD}" a2dp_sink 2>/dev/null; then
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
    if pactl get-sink-mute "${BLUETOOTH_SINK}" 2>/dev/null | grep -q "^Mute: yes"; then
        if pactl set-sink-mute "${BLUETOOTH_SINK}" 0 2>/dev/null; then
            bashio::log.warning "Bluetooth audio sink was muted, unmuted it."
        fi
    fi

    # Volume brut du premier canal, extrait avant le premier "/" de la
    # sortie de `get-sink-volume` : plus fiable qu'un grep sur "0%", qui
    # matcherait aussi "100%" (qui se termine littéralement par "0%").
    local raw_volume
    raw_volume=$(pactl get-sink-volume "${BLUETOOTH_SINK}" 2>/dev/null \
        | awk -F'/' '/Volume:/ { gsub(/[^0-9]/, "", $1); print $1; exit }') || true
    if [ "${raw_volume:-}" = "0" ]; then
        if pactl set-sink-volume "${BLUETOOTH_SINK}" "${DEFAULT_VOLUME}%" 2>/dev/null; then
            bashio::log.warning "Bluetooth audio sink was silent (0% volume), reset to ${DEFAULT_VOLUME}%."
        fi
    fi
    # N'écrase jamais un volume non nul choisi par l'utilisateur (ex. 20%) :
    # seul le silence total (0% ou muet) déclenche une correction, pas de
    # reset périodique intrusif à chaque passage de la boucle.
}

# On tente une première connexion avant même de démarrer MPD, pour que
# le sink existe déjà quand MPD essaiera de s'y attacher.
# "|| true" : filet de sécurité supplémentaire, au cas où connect_speaker
# retournerait quand même un code non nul pour une raison non couverte
# ci-dessus — un appel de fonction "nu" comme celui-ci est justement ce
# qui déclenche "set -e" si son code de sortie est non nul.
connect_speaker || true
sleep 2
# Laisse le temps à PulseAudio d'enregistrer la carte Bluetooth après la
# connexion avant de vérifier/forcer son profil.
ensure_audio_sink

# --- 5. Boucle de surveillance Bluetooth (tourne en tâche de fond) ---
# Vérifie périodiquement (intervalle configurable, voir RECONNECT_INTERVAL)
# si l'enceinte est toujours connectée ; si elle ne l'est plus (mise en
# veille, hors de portée...), on relance une connexion automatiquement,
# sans intervention manuelle.
(
    while true; do
        sleep "${RECONNECT_INTERVAL}"
        if ! bluetoothctl info "${BT_MAC}" | grep -q "Connected: yes"; then
            bashio::log.warning "${SPEAKER_NAME} disconnected, attempting to reconnect..." || true
            connect_speaker || true
            sleep 2
        fi
        # Vérifié à chaque passage, pas seulement après une reconnexion :
        # le profil PulseAudio peut rester bloqué sur "off" alors que
        # Bluetooth se dit déjà connecté depuis un moment (voir 4bis).
        ensure_audio_sink
    done
) &
# Le "&" final lance cette boucle en arrière-plan : le script continue
# immédiatement à l'étape suivante sans attendre que la boucle se termine
# (elle ne se termine jamais, c'est voulu).

# --- 5bis. Lancement du media_player natif (renderer DLNA/UPnP) ---
# Tourne en tâche de fond, INDÉPENDAMMENT de ENABLE_MPD : c'est la nouvelle
# capacité de ce projet (media_player natif, voir le vault "HA - Bluetooth
# A2DP natif + Voice PE"). gmediarender expose l'enceinte comme un renderer
# DLNA/UPnP ; Home Assistant le détecte automatiquement via l'intégration
# core "dlna_dmr" (découverte réseau SSDP, aucune config manuelle côté HA).
# Nécessite "host_network: true" dans config.yaml (voir commentaire associé)
# pour que la découverte SSDP fonctionne.
if command -v gmediarender >/dev/null 2>&1; then
    # Sans --uuid, gmediarender retombe sur une valeur FIXE codée en dur
    # ("GMediaRender-1_0-000-000-002"), identique pour toute installation.
    # Découvert en testant une deuxième instance en parallèle (voir vault,
    # "Test d'installation réelle") : Home Assistant déduplique les
    # renderers DLNA par UUID, donc deux enceintes différentes sur deux
    # installations de cet add-on se retrouveraient fusionnées en une
    # seule entité media_player. On dérive ici un UUID stable à partir de
    # bluetooth_mac (même enceinte → même UUID à chaque redémarrage,
    # enceintes différentes → UUID différents).
    BT_MAC_HASH=$(echo -n "${BT_MAC}" | md5sum | cut -c1-32)
    GMEDIARENDER_UUID="${BT_MAC_HASH:0:8}-${BT_MAC_HASH:8:4}-${BT_MAC_HASH:12:4}-${BT_MAC_HASH:16:4}-${BT_MAC_HASH:20:12}"
    bashio::log.info "gmediarender binary found ($(command -v gmediarender)), starting with uuid=${GMEDIARENDER_UUID}..."
    gmediarender \
        --gstout-audiosink=pulsesink \
        --gstout-audiodevice="${BLUETOOTH_SINK}" \
        --friendly-name="${SPEAKER_NAME}" \
        --uuid="${GMEDIARENDER_UUID}" \
        --logfile=stdout \
        &
else
    bashio::log.error "gmediarender binary NOT FOUND — compilation Dockerfile probablement en échec silencieux, voir le journal de build."
fi
# Garde-fou de diagnostic (2026-08-20) : le premier build de gmediarender
# n'a produit aucune trace dans les logs (ni succès ni erreur) et HA n'a
# détecté aucun nouveau renderer DLNA — ce bloc sert à confirmer noir sur
# blanc si le binaire existe réellement avant de creuser plus loin.
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
