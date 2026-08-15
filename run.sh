#!/usr/bin/with-contenv bashio
# ============================================================
# run.sh — Script de démarrage de l'add-on
# ============================================================
# Rôle : préparer la config MPD avec le bon sink Bluetooth, s'assurer
# que la JBL est connectée, puis lancer MPD. Une boucle de fond
# surveille la connexion Bluetooth et la rétablit automatiquement
# si la JBL se déconnecte (mise en veille, coupure, etc.).
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
# Récupère l'adresse MAC saisie par l'utilisateur dans l'onglet
# "Configuration" de l'add-on (ex: FC:A8:9A:CC:54:23). Si l'utilisateur
# change d'enceinte plus tard, il modifie juste ce champ — pas besoin
# de toucher au code.

bashio::log.info "Adresse Bluetooth cible : ${BT_MAC}"

# --- 2. Calcul du nom du sink PulseAudio correspondant ---
# PulseAudio nomme les sinks Bluetooth en remplaçant les ":" par des "_"
# et en les collant au format bluez_sink.<MAC>.a2dp_sink.
# Exemple : FC:A8:9A:CC:54:23  ->  FC_A8_9A_CC_54_23
BT_MAC_UNDERSCORE=$(echo "${BT_MAC}" | tr ':' '_')
BLUETOOTH_SINK="bluez_sink.${BT_MAC_UNDERSCORE}.a2dp_sink"

bashio::log.info "Sink PulseAudio calculé : ${BLUETOOTH_SINK}"

# --- 3. Génération du fichier mpd.conf final ---
# On remplace {{BLUETOOTH_SINK}} dans le modèle par la vraie valeur
# calculée ci-dessus, et on écrit le résultat dans /etc/mpd.conf.
export BLUETOOTH_SINK
envsubst '${BLUETOOTH_SINK}' < /etc/mpd.conf.template > /etc/mpd.conf

bashio::log.info "Fichier /etc/mpd.conf généré."

# --- 4. Connexion (ou reconnexion) Bluetooth à la JBL ---
# Fonction réutilisée aussi bien au démarrage que dans la boucle de
# surveillance plus bas.
connect_speaker() {
    bashio::log.info "Tentative de connexion à la JBL (${BT_MAC})..."
    bluetoothctl power on
    bluetoothctl connect "${BT_MAC}" \
        && bashio::log.info "JBL connectée." \
        || bashio::log.warning "Échec de connexion à la JBL — nouvelle tentative dans la boucle de surveillance."
}

# On tente une première connexion avant même de démarrer MPD, pour que
# le sink existe déjà quand MPD essaiera de s'y attacher.
connect_speaker

# --- 5. Boucle de surveillance Bluetooth (tourne en tâche de fond) ---
# Vérifie toutes les 30 secondes si la JBL est toujours connectée ;
# si elle ne l'est plus (mise en veille, hors de portée...), on relance
# une connexion automatiquement, sans intervention manuelle.
(
    while true; do
        sleep 30
        if ! bluetoothctl info "${BT_MAC}" | grep -q "Connected: yes"; then
            bashio::log.warning "JBL déconnectée, tentative de reconnexion..."
            connect_speaker
        fi
    done
) &
# Le "&" final lance cette boucle en arrière-plan : le script continue
# immédiatement à l'étape suivante sans attendre que la boucle se termine
# (elle ne se termine jamais, c'est voulu).

# --- 6. Lancement de MPD au premier plan ---
bashio::log.info "Démarrage de MPD..."
exec mpd --no-daemon /etc/mpd.conf
# "exec" remplace ce script par le processus MPD : MPD devient le
# processus principal du conteneur (utile pour que le Supervisor sache
# si l'add-on plante et doive être redémarré). "--no-daemon" empêche
# MPD de se détacher en arrière-plan, ce qui est nécessaire pour rester
# le processus principal du conteneur au lieu de le laisser croire
# que le conteneur s'est arrêté.
