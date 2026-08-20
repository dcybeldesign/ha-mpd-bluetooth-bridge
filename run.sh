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

set -e
# Arrête immédiatement le script si une commande échoue de façon
# inattendue (évite de continuer dans un état incohérent).

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
    bluetoothctl power on
    bluetoothctl connect "${BT_MAC}" \
        && bashio::log.info "${SPEAKER_NAME} connected." \
        || bashio::log.warning "Failed to connect to ${SPEAKER_NAME} — will retry in the monitoring loop."
}

# --- 4bis. Garde-fou : forcer le profil audio PulseAudio si besoin ---
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
    if pactl list short sinks 2>/dev/null | grep -q "${BLUETOOTH_SINK}"; then
        return
    fi
    # Le sink attendu n'existe pas : on force le profil. Sans effet si la
    # carte PulseAudio n'a pas encore été créée par BlueZ (juste après une
    # connexion très récente) — la boucle de surveillance réessaiera au
    # prochain passage.
    if pactl set-card-profile "${BLUETOOTH_CARD}" a2dp_sink 2>/dev/null; then
        bashio::log.warning "Bluetooth audio sink was missing, forced PulseAudio profile back to a2dp_sink."
    fi
}

# On tente une première connexion avant même de démarrer MPD, pour que
# le sink existe déjà quand MPD essaiera de s'y attacher.
connect_speaker
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
            bashio::log.warning "${SPEAKER_NAME} disconnected, attempting to reconnect..."
            connect_speaker
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
    bashio::log.info "gmediarender binary found ($(command -v gmediarender)), starting..."
    gmediarender \
        --gstout-audiosink=pulsesink \
        --gstout-audiodevice="${BLUETOOTH_SINK}" \
        --friendly-name="${SPEAKER_NAME}" \
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
