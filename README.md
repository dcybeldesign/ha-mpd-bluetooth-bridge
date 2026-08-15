# MPD JBL Bridge

Add-on Home Assistant (HAOS) maison qui fait tourner un serveur [MPD](https://www.musicpd.org/)
dont la sortie audio est forcée vers une enceinte Bluetooth appairée sur le Raspberry Pi
(ici une JBL Flip 3), et expose ce serveur MPD à [Music Assistant](https://www.music-assistant.io/)
via son fournisseur natif "MPD Players".

## Pourquoi cet add-on

Music Assistant ne peut pas cibler directement un sink PulseAudio Bluetooth via son
fournisseur "Local Audio Out" : le sélecteur de sortie audio des add-ons HAOS ne liste
que le matériel physique (jack/HDMI), pas les périphériques Bluetooth appairés
dynamiquement. Cet add-on contourne la limitation en faisant tourner un petit serveur
MPD dédié, configuré pour sortir sur le sink Bluetooth — Music Assistant s'y connecte
ensuite via le protocole MPD, un mécanisme officiellement supporté.

## Fonctionnement

- `run.sh` calcule le nom du sink PulseAudio à partir de l'adresse MAC Bluetooth
  configurée (`options.bluetooth_mac`), génère `/etc/mpd.conf` à partir du modèle
  `mpd.conf.template`, connecte l'enceinte via `bluetoothctl`, puis démarre MPD.
- Une boucle de fond vérifie toutes les 30 secondes que l'enceinte est toujours
  connectée et la reconnecte automatiquement si besoin (mise en veille, coupure...).
- MPD expose le port `6600/tcp` (protocole MPD standard), utilisable directement
  dans Music Assistant via son fournisseur "MPD Players".

## Installation

1. Copier ce dossier dans `/addons/mpd_jbl_bridge` sur ton instance Home Assistant.
2. Dans Home Assistant : **Paramètres → Applications → Magasin d'applications**,
   actualiser (⋮ → Rechercher des mises à jour) pour que l'add-on local apparaisse.
3. L'installer, vérifier/modifier l'adresse Bluetooth cible dans l'onglet
   **Configuration**, puis le démarrer.
4. Dans Music Assistant : **Paramètres → Fournisseurs de lecteurs → Add a player
   provider → MPD Players**, et renseigner le nom d'hôte interne de l'add-on
   (visible dans Contrôles → *Nom d'hôte* sur la page Info de l'add-on, format
   `local-mpd-jbl-bridge:6600`) — **pas** l'adresse IP externe du Pi, qui ne
   fonctionne pas depuis un autre conteneur (limitation Docker classique).

## Configuration

| Option | Description | Défaut |
|---|---|---|
| `bluetooth_mac` | Adresse MAC de l'enceinte Bluetooth cible | `FC:A8:9A:CC:54:23` |

## Prérequis

- Un Raspberry Pi (ou autre hôte HAOS) avec un adaptateur Bluetooth fonctionnel.
- L'enceinte Bluetooth déjà appairée au système au préalable (`bluetoothctl pair`),
  cet add-on gère uniquement la (re)connexion, pas le premier appairage.

## Licence

Usage personnel — sans garantie.
