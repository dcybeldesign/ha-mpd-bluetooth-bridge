# Bluetooth Audio Bridge

Un add-on Home Assistant (HAOS) qui connecte n'importe quelle enceinte
Bluetooth A2DP appairée avec l'hôte et l'expose de deux façons :

1. Une **entité `media_player` native** (DLNA/UPnP), utilisable
   directement depuis des automatisations, des scripts, ou n'importe
   quelle intégration Home Assistant, sans serveur de musique.
2. Un **serveur [MPD](https://www.musicpd.org/) optionnel** qui relie
   cette même enceinte à [Music Assistant](https://www.music-assistant.io/)
   via son fournisseur natif **MPD Players** (l'objectif d'origine de cet
   add-on).

Les deux peuvent tourner en même temps sur la même enceinte.

*[Read in English](README.md)*

## Pourquoi cet add-on

Le sélecteur de sortie audio des add-ons HAOS ne liste que le matériel
physique (jack/HDMI), jamais les périphériques Bluetooth appairés
dynamiquement avec l'hôte. Home Assistant n'a pas non plus de mécanisme
natif pour transformer "une enceinte Bluetooth appairée avec l'hôte" en
entité `media_player`. Cet add-on comble les deux manques : il expose
l'enceinte comme une vraie entité `media_player`, et, si vous utilisez
aussi Music Assistant, garde le pont MPD d'origine disponible comme
sortie secondaire optionnelle.

## Fonctionnement

- **`media_player` natif** : [gmrender-resurrect](https://github.com/hzeller/gmrender-resurrect)
  expose le sink PulseAudio Bluetooth comme un renderer DLNA/UPnP.
  L'intégration native `dlna_dmr` de Home Assistant le découvre
  automatiquement sur le réseau local (SSDP), aucune configuration
  manuelle d'entité n'est nécessaire.
- **Serveur MPD optionnel** (`enable_mpd`, activé par défaut) : `run.sh`
  calcule le nom du sink à partir de l'adresse MAC Bluetooth configurée,
  génère `/etc/mpd.conf`, connecte l'enceinte via `bluetoothctl`, puis
  démarre MPD. Le fournisseur "MPD Players" de Music Assistant s'y
  connecte via le port standard du protocole MPD (`6600/tcp`).
- Une boucle de fond vérifie la connexion Bluetooth toutes les
  `reconnect_interval` secondes (30s par défaut) et reconnecte
  automatiquement l'enceinte si elle se déconnecte (mise en veille, hors
  de portée...).
- Les deux sorties partagent le même sink PulseAudio et peuvent tourner
  simultanément ; PulseAudio mixe nativement plusieurs clients sur un
  seul sink.

## Accès réseau (`host_network`), à lire avant d'installer

Cet add-on demande `host_network: true`. Contrairement à la plupart des
add-ons, il ne tourne pas dans le réseau bridge isolé de Docker : il
utilise directement la pile réseau de l'hôte, le même niveau d'accès que
des add-ons comme Tailscale ou Terminal & SSH.

**Pourquoi c'est nécessaire** : le `media_player` natif repose sur SSDP
(un protocole de découverte basé sur le multicast) pour être trouvé
automatiquement par Home Assistant. Le trafic multicast ne traverse pas
correctement le réseau bridge par défaut de Docker : le réseau hôte est
une exigence du protocole DLNA/UPnP lui-même, pas un choix de confort
propre à ce projet.

**Conséquence concrète** : pendant qu'il tourne, cet add-on est visible
sur (et peut voir) tout votre réseau local, pas seulement les ports qu'il
déclare explicitement. Si ce n'est pas acceptable sur votre réseau, cet
add-on n'est pas adapté à votre cas : il n'existe actuellement aucun
moyen d'obtenir la découverte automatique DLNA/UPnP sans `host_network`.

## Prérequis

- Un hôte Home Assistant OS avec un adaptateur Bluetooth fonctionnel.
  Développé et testé sur un **Raspberry Pi 4** (Bluetooth 5.0 intégré).
  Voir [Portabilité](#portabilité-au-delà-du-raspberry-pi-4) ci-dessous
  pour les autres matériels.
- Un accès terminal/shell à cet hôte (voir l'étape 1 de
  [Appairer votre enceinte](#appairer-votre-enceinte-première-installation)
  ci-dessous si vous ne l'avez pas encore).
- L'enceinte cible doit déjà être **appairée** avec l'hôte au préalable.
  Cet add-on gère uniquement la connexion/reconnexion d'un appareil déjà
  appairé, pas le premier appairage. Guide complet ci-dessous.
- [Music Assistant](https://www.music-assistant.io/) n'est nécessaire que
  si vous comptez utiliser la sortie MPD optionnelle (`enable_mpd`). Le
  `media_player` natif fonctionne sans lui.

## Appairer votre enceinte (première installation)

À faire une fois par enceinte, **avant** d'installer l'add-on. L'add-on ne
peut que reconnecter une enceinte que Home Assistant connaît déjà, il ne
peut pas faire le premier appairage à votre place.

**1. Ouvrez un terminal sur votre hôte Home Assistant.**
Si taper des commandes dans Home Assistant est nouveau pour vous, allez
dans **Paramètres → Applications** (appelé "Add-ons" sur les versions de
Home Assistant antérieures au renommage mi-2026) → **Magasin
d'applications**, cherchez l'add-on officiel **"Terminal & SSH"**,
installez-le, démarrez-le, puis ouvrez-le depuis le menu latéral. Ça vous
donne une invite de commande directement dans Home Assistant, pas besoin
d'un client SSH séparé.

**2. Mettez votre enceinte en mode appairage.**
Ça varie selon le modèle, généralement en maintenant le bouton
d'alimentation ou Bluetooth quelques secondes jusqu'à ce qu'un voyant
clignote. Vérifiez le manuel de votre enceinte en cas de doute.

**3. Dans le terminal, lancez le scan :**
```
bluetoothctl
power on
agent on
scan on
```
Après quelques secondes, des lignes défilent, du genre :
```
[NEW] Device AA:BB:CC:DD:EE:FF Nom de mon enceinte
```
Repérez la ligne dont le nom correspond à votre enceinte, et notez
l'adresse juste avant le nom (la chaîne au format `AA:BB:CC:DD:EE:FF`,
c'est son adresse MAC). Ignorez les autres appareils qui apparaissent :
des téléphones, TV ou autres gadgets Bluetooth à proximité remontent
souvent aussi. Vous ne voulez que celui qui correspond au nom de votre
enceinte.

**4. Appairez, faites confiance, et connectez avec cette adresse :**
```
scan off
pair AA:BB:CC:DD:EE:FF
trust AA:BB:CC:DD:EE:FF
connect AA:BB:CC:DD:EE:FF
quit
```
(remplacez `AA:BB:CC:DD:EE:FF` par l'adresse notée à l'étape 3)
- `pair` doit répondre `Pairing successful`. La plupart des enceintes
  Bluetooth s'appairent sans code PIN ; si la vôtre en demande un,
  vérifiez son manuel, c'est souvent `0000` ou inscrit sur l'appareil.
- `trust` est ce qui permet à la reconnexion automatique de l'add-on de
  fonctionner ensuite. Ne sautez pas cette étape.
- `connect` confirme que la liaison fonctionne tout de suite. Vous devriez
  entendre un son de connexion sur l'enceinte.

**5. Gardez cette adresse MAC sous la main.** Vous la collerez dans
l'option `bluetooth_mac` de l'add-on à l'étape suivante.

## Installation

1. Ajoutez l'URL GitHub de ce dépôt comme dépôt d'add-ons personnalisé
   dans Home Assistant (**Paramètres → Applications → Magasin
   d'applications → ⋮ (menu en haut à droite) → Dépôts**, collez l'URL,
   fermez), ou copiez manuellement ce dossier vers
   `/addons/bluetooth_audio_bridge` sur votre hôte si vous n'utilisez pas
   la méthode par dépôt.
2. Actualisez le magasin d'applications (même menu ⋮ → Rechercher des
   mises à jour) pour que l'add-on apparaisse. Il sera listé sous une
   section nommée d'après ce dépôt (ou sous "Applications locales" si
   vous avez copié le dossier manuellement).
3. Cliquez sur l'add-on, installez-le, ouvrez l'onglet **Configuration**
   et renseignez l'adresse MAC Bluetooth de votre enceinte notée plus
   haut (obligatoire, voir [Configuration](#configuration)), puis
   démarrez-le.
4. L'entité `media_player` native devrait apparaître automatiquement dans
   Home Assistant en quelques minutes, voir
   [Sortie media_player native](#sortie-media_player-native-dlnaupnp)
   ci-dessous si ce n'est pas le cas.
5. **Seulement si vous voulez la sortie MPD** (`enable_mpd`, activée par
   défaut) : dans Music Assistant, allez dans **Paramètres →
   Fournisseurs de lecteurs**. Le fournisseur **MPD Players** est une
   entrée unique et partagée : si vous ne l'avez pas encore configuré,
   cliquez sur **Add a player provider → MPD Players**. S'il est déjà
   configuré (par exemple à cause d'un autre add-on de pont MPD), ouvrez
   simplement l'entrée **MPD Players** existante au lieu d'en recréer une
   deuxième. Dans les deux cas, ajoutez le **nom d'hôte interne** de
   l'add-on suivi de `:6600` dans le champ **MPD Servers**. Ce champ
   prend une adresse par ligne : s'il y a déjà une adresse renseignée,
   ajoutez la nouvelle sur sa propre ligne en dessous plutôt que de
   remplacer l'existante ou de les séparer par une virgule. Pour trouver
   ce nom d'hôte, ouvrez l'onglet **Info** de cet add-on dans Home
   Assistant et regardez sous *Contrôles → Nom d'hôte*. Copiez exactement
   cette valeur (elle ressemble typiquement à `local-<quelque chose>` ou
   un préfixe généré suivi du nom de l'add-on, selon la méthode
   d'installation, donc vérifiez toujours la valeur réelle affichée chez
   vous plutôt que de deviner). **N'utilisez pas** l'adresse IP
   externe/LAN de l'hôte ici : un conteneur ne peut généralement pas
   rejoindre un autre conteneur via l'IP externe de l'hôte (limitation
   Docker classique dite "hairpin NAT"). Seul le nom d'hôte interne
   fonctionne de façon fiable.

## Configuration

| Option | Description | Défaut |
|---|---|---|
| `bluetooth_mac` | Adresse MAC de l'enceinte Bluetooth (format `AA:BB:CC:DD:EE:FF`). **Obligatoire.** | *(aucune, à renseigner)* |
| `speaker_name` | Nom cosmétique des sorties (MPD et le nom affiché du `media_player`). | `Bluetooth Speaker` |
| `reconnect_interval` | Secondes entre deux vérifications de la connexion Bluetooth (10-300). | `30` |
| `enable_mpd` | Démarre ou non le serveur MPD. La connexion Bluetooth et le `media_player` natif ne sont pas affectés dans un cas comme dans l'autre ; désactivez cette option si vous ne voulez que le `media_player` natif et n'utilisez pas Music Assistant. | `true` |
| `default_volume` | Volume (%) restauré automatiquement si le sink PulseAudio de l'enceinte est détecté muet ou à 0% (sinon reste silencieux indéfiniment, y compris après un redémarrage). N'écrase jamais un volume que vous avez choisi tant qu'il n'est pas à 0%. | `70` |

## Sortie `media_player` native (DLNA/UPnP)

Une fois l'add-on démarré et l'enceinte appairée, Home Assistant devrait
la découvrir tout seul en quelques minutes (scan SSDP périodique) comme
une entité `media_player` nommée d'après `speaker_name`. Si elle
n'apparaît toujours pas après quelques minutes, déclenchez un scan
manuel : **Paramètres → Appareils et services → Ajouter une intégration
→ DLNA Digital Media Renderer**.

Une fois l'entité créée, vous pouvez lui envoyer du son comme à
n'importe quel `media_player` : depuis la carte lecteur multimédia, un
script, ou une automatisation utilisant le service `tts.speak` ou
`media_player.play_media` avec `media_player_entity_id` ciblant cette
entité.

## Voice PE

**Ce qui marche aujourd'hui** : puisque l'entité `media_player` native
existe, les annonces scriptées envoyées à travers elle, par exemple une
automatisation appelant `tts.speak` avec `media_player_entity_id` réglé
sur l'entité de cet add-on, jouent sur votre enceinte Bluetooth
exactement comme sur n'importe quel autre `media_player`. Ça fonctionne
que l'automatisation ait été déclenchée par un Voice PE ou autre chose.

**Ce qui ne marche pas (encore)** : une réponse conversationnelle en
direct, la réponse à une question posée directement à un Voice PE, ne
peut pas être redirigée vers un `media_player` différent. Le pipeline
Assist de Home Assistant est conçu pour répondre sur le même appareil qui
a capté la voix ; séparer capture et réponse demanderait de modifier le
firmware ESPHome du Voice PE lui-même, ce qui sort du périmètre de cet
add-on. Voir
[home-assistant/discussions#689](https://github.com/orgs/home-assistant/discussions/689)
pour suivre l'avancement en amont ; à l'heure où ces lignes sont écrites,
la discussion est toujours ouverte sans solution native.

Ceci n'a pas été vérifié sur du vrai matériel Voice PE. Les retours de
quiconque l'essaie, positifs ou négatifs, sont les bienvenus via une
issue.

## Portabilité au-delà du Raspberry Pi 4

Rien dans cet add-on n'est intrinsèquement spécifique au Raspberry Pi. Le
Bluetooth (`bluetoothctl` via le D-Bus de l'hôte) et l'audio (serveur
PulseAudio partagé du Supervisor) sont fournis de la même façon par HAOS
quel que soit le matériel sous-jacent. Des images multi-architecture sont
construites pour `aarch64`, `amd64`, `armv7`, `armhf` et `i386` (voir
`build.yaml`).

Ceci dit, seul le fonctionnement sur Raspberry Pi 4 a été vérifié en
conditions réelles. Ça *devrait* marcher sans modification sur toute
installation HAOS avec un adaptateur Bluetooth fonctionnel (autres
modèles de Pi, installations x86 type NUC, etc.), mais ce n'est pas
encore testé partout. Si vous l'essayez sur un autre matériel, un retour
(positif ou négatif) via une issue est le bienvenu.

## Remarque sécurité

Au-delà de l'accès `host_network` déjà couvert
[plus haut](#accès-réseau-host_network-à-lire-avant-dinstaller), le
serveur MPD lui-même (si `enable_mpd` est activé) n'a aucune
authentification et est accessible depuis votre réseau local (pas depuis
Internet, sauf si vous l'avez vous-même exposé). C'est volontaire pour
garder l'installation simple, en partant du principe que votre réseau
Home Assistant est déjà de confiance. N'exposez pas ce port vers
l'extérieur sans ajouter vos propres protections devant.

## Dépannage

- **L'add-on ne démarre pas / plante immédiatement** : regardez l'onglet
  Journal de l'add-on. Une adresse `bluetooth_mac` absente ou mal
  formatée fait échouer la validation de la config avant même que le
  conteneur démarre. Vérifiez que vous avez bien copié l'adresse complète
  avec des `:` (deux-points), pas des tirets ni sans séparateur.
- **"Failed to open audio output" / pas de son côté MPD, mais l'add-on
  tourne** : ça signifie presque toujours que l'enceinte n'est pas
  vraiment *appairée et de confiance ("trusted")*. Être "à portée" ou
  "allumée" ne suffit pas. Reprenez la section
  [Appairer votre enceinte](#appairer-votre-enceinte-première-installation)
  et vérifiez que les commandes `pair` ET `trust` ont bien réussi (pas
  seulement `connect`). Vous pouvez vérifier l'état à tout moment avec
  `bluetoothctl info AA:BB:CC:DD:EE:FF` dans un terminal : cherchez
  `Paired: yes`, `Trusted: yes` et `Connected: yes` dans le résultat.
- **L'entité `media_player` n'apparaît jamais** : vérifiez que
  `host_network: true` n'a pas été désactivé par erreur dans l'onglet
  Réseau de l'add-on, puis essayez le scan manuel décrit dans
  [Sortie media_player native](#sortie-media_player-native-dlnaupnp).
  Vérifiez aussi le journal de l'add-on pour une ligne confirmant le
  démarrage de `gmediarender` ; si elle manque, l'add-on ne s'est pas
  construit correctement, ouvrez une issue avec le journal de build.
- **Le son s'est arrêté après une perte de connexion prolongée de
  l'enceinte (batterie faible par exemple), même si elle semble
  reconnectée maintenant** : l'add-on vérifie que le sink audio
  PulseAudio existe toujours et force à nouveau le profil `a2dp_sink`
  s'il a disparu, ce qui peut arriver après une rafale de
  déconnexions/reconnexions Bluetooth rapprochées. Si ça persiste,
  redémarrer l'add-on contourne le problème en attendant.
- **Mon enceinte se déconnecte sans arrêt / ne se reconnecte pas toute
  seule** : vérifiez que `trust` a bien été exécuté pendant l'appairage
  (étape 4). Sans ça, HAOS n'autorise pas la reconnexion automatique
  dont dépend cet add-on. Vous pouvez relancer `trust
  AA:BB:CC:DD:EE:FF` dans `bluetoothctl` à tout moment sans refaire tout
  l'appairage.
- **Music Assistant affiche le lecteur MPD comme indisponible** :
  vérifiez que `enable_mpd` est activé et que vous avez bien utilisé le
  *nom d'hôte interne* de l'add-on, pas l'adresse IP de l'hôte (voir
  étape 5 de l'Installation).

## Avertissement

Ce projet est un partage libre et gratuit, réalisé sur mon temps
personnel. Je ne suis pas responsable des problèmes que son utilisation
pourrait causer (matériel, logiciel, ou autre), y compris tout ce qui
touche à l'accès réseau élargi que `host_network: true` accorde à cet
add-on (voir
[Accès réseau](#accès-réseau-host_network-à-lire-avant-dinstaller)
plus haut). Vous l'utilisez, l'installez et l'adaptez entièrement sous
votre propre responsabilité. Les fichiers sont libres d'utilisation, de
partage et de modification. Si vous réutilisez ou vous appuyez sur ce
travail, une mention de mon nom est appréciée (voir ci-dessous), mais
rien ici n'est fourni avec une quelconque garantie.

## Soutenir ce projet

Si cet add-on vous a été utile, vous pouvez soutenir son développement :

- [GitHub Sponsors](https://github.com/sponsors/dcybeldesign)
- [Buy Me a Coffee](https://buymeacoffee.com/dcybeldesign)

## Auteur

[dcybeldesign](https://github.com/dcybeldesign)

## Licence

[MIT](LICENSE)
