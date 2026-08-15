# ============================================================
# Dockerfile — Recette de construction de l'image du conteneur
# ============================================================
# Ce fichier décrit, étape par étape, comment fabriquer l'image Docker
# qui fera tourner notre add-on. Le Supervisor HAOS lit ce fichier et
# exécute chaque instruction dans l'ordre pour construire l'image.

ARG BUILD_FROM=homeassistant/aarch64-base:3.18
# Valeur par défaut utilisée uniquement pour un build manuel/local hors
# Supervisor. En conditions normales, le Supervisor HAOS choisit lui-même
# la bonne image parmi celles listées dans build.yaml, selon l'architecture
# réelle de l'hôte (Raspberry Pi, PC/NUC amd64, etc.) — voir build.yaml.
# Cette image de base contient déjà Alpine Linux + "bashio", un petit
# utilitaire shell qui permet de lire facilement les options définies
# dans config.yaml (ex: bluetooth_mac).
FROM ${BUILD_FROM}

# --- Installation des paquets nécessaires ---
# Alpine utilise "apk" comme gestionnaire de paquets (équivalent d'apt).
RUN apk add --no-cache \
        mpd \
        # Music Player Daemon : le serveur audio que Music Assistant pilotera.
        pulseaudio-utils \
        # Fournit "pactl"/"paplay" : nécessaire pour que MPD puisse parler
        # au serveur audio partagé du Supervisor (celui qui voit le sink
        # Bluetooth de l'enceinte).
        bluez \
        # Fournit "bluetoothctl" (le paquet "bluez-deprecated" ne contient
        # QUE les anciens outils type hcitool/hciconfig, pas bluetoothctl —
        # erreur détectée après un premier essai raté) : utilisé par notre
        # script pour connecter/reconnecter automatiquement l'enceinte si
        # elle se met en veille.
        gettext
        # Fournit "envsubst" : petit outil pour remplacer des variables
        # (ex: ${BLUETOOTH_SINK}) dans notre fichier mpd.conf.template
        # au démarrage, sans dépendance lourde comme Python.

# --- Copie de nos fichiers dans l'image ---
COPY run.sh /run.sh
COPY mpd.conf.template /etc/mpd.conf.template
# On copie un "modèle" (template) de config MPD, pas la config finale :
# le nom exact du sink Bluetooth dépend de l'adresse MAC configurée par
# l'utilisateur (options.bluetooth_mac), donc il est généré à chaque
# démarrage par run.sh, pas figé une fois pour toutes à la construction.

RUN chmod a+x /run.sh
# Rend le script exécutable (obligatoire, sinon le conteneur refusera
# de le lancer).

RUN mkdir -p /var/lib/mpd/playlists /var/lib/mpd/music
# Crée les dossiers de travail attendus par MPD (playlists, bibliothèque
# musicale locale — vide ici, puisque toute la musique vient de Music
# Assistant en streaming, pas d'un dossier local).
# Pas de "chown mpd:mpd" ici : le paquet Alpine "mpd" ne crée pas cet
# utilisateur système automatiquement, et les add-ons HAOS tournent de
# toute façon en root par défaut (conteneur isolé, sans risque ici) —
# donc mpd.conf ne définit pas non plus de directive "user".

CMD [ "/run.sh" ]
# Commande lancée au démarrage du conteneur : notre script fait TOUT
# (génération de la config, connexion Bluetooth, lancement de MPD).
# Rappel : dans config.yaml on a mis "init: false", donc pas de système
# d'init intermédiaire — /run.sh est le tout premier et unique processus.
