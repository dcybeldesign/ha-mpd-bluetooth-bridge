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

bashio::log.info "Target speaker: ${SPEAKER_NAME} (${BT_MAC})"

# --- 2. Calcul du nom du sink PulseAudio correspondant ---
# PulseAudio nomme les sinks Bluetooth en remplaçant les ":" par des "_"
# et en les collant au format bluez_sink.<MAC>.a2dp_sink.
# Exemple : AA:BB:CC:DD:EE:FF  ->  AA_BB_CC_DD_EE_FF
BT_MAC_UNDERSCORE=$(echo "${BT_MAC}" | tr ':' '_')
BLUETOOTH_SINK="bluez_sink.${BT_MAC_UNDERSCORE}.a2dp_sink"

bashio::log.info "Computed PulseAudio sink: ${BLUETOOTH_SINK}"

# --- 3. Génération du fichier mpd.conf final ---
# On remplace ${BLUETOOTH_SINK} et ${SPEAKER_NAME} dans le modèle par les
# vraies valeurs calculées ci-dessus, et on écrit le résultat dans
# /etc/mpd.conf. Attention à la syntaxe : envsubst ne reconnaît QUE
# `$VAR`/`${VAR}` (pas de `{{VAR}}` façon Jinja/Mustache — un bug de ce
# type, avec le template utilisant {{BLUETOOTH_SINK}}, avait fait
# échouer silencieusement toute lecture audio lors du développement
# initial : MPD tentait de se connecter à un sink qui n'existait pas).
export BLUETOOTH_SINK SPEAKER_NAME
envsubst '${BLUETOOTH_SINK} ${SPEAKER_NAME}' < /etc/mpd.conf.template > /etc/mpd.conf

bashio::log.info "/etc/mpd.conf generated."

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

# On tente une première connexion avant même de démarrer MPD, pour que
# le sink existe déjà quand MPD essaiera de s'y attacher.
connect_speaker

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
        fi
    done
) &
# Le "&" final lance cette boucle en arrière-plan : le script continue
# immédiatement à l'étape suivante sans attendre que la boucle se termine
# (elle ne se termine jamais, c'est voulu).

# --- 6. Lancement de MPD au premier plan ---
bashio::log.info "Starting MPD..."
exec mpd --no-daemon /etc/mpd.conf
# "exec" remplace ce script par le processus MPD : MPD devient le
# processus principal du conteneur (utile pour que le Supervisor sache
# si l'add-on plante et doive être redémarré). "--no-daemon" empêche
# MPD de se détacher en arrière-plan, ce qui est nécessaire pour rester
# le processus principal du conteneur au lieu de le laisser croire
# que le conteneur s'est arrêté.
