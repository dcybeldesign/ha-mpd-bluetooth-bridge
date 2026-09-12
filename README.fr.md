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
- **Page d'appairage** (ingress Home Assistant, panneau **Bluetooth
  Audio** dans le menu latéral) : une petite page web servie par `httpd`
  de busybox, avec des scripts shell qui pilotent `bluetoothctl`. Elle
  recherche les appareils audio Bluetooth Classic, les appaire, leur fait
  confiance, puis enregistre l'enceinte choisie dans la configuration de
  l'add-on via l'API du Supervisor.
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
- Une enceinte Bluetooth que vous pouvez mettre en mode appairage. Pas
  besoin de terminal : le panneau **Bluetooth Audio** de l'add-on la
  trouve et l'appaire, voir
  [Appairer votre enceinte](#appairer-votre-enceinte-première-installation)
  ci-dessous. Seules les enceintes qui demandent un code PIN nécessitent
  encore la [procédure manuelle](#appairage-manuel-solution-de-repli),
  qui demande un accès terminal à l'hôte.
- [Music Assistant](https://www.music-assistant.io/) n'est nécessaire que
  si vous comptez utiliser la sortie MPD optionnelle (`enable_mpd`). Le
  `media_player` natif fonctionne sans lui.

## Appairer votre enceinte (première installation)

À faire une fois par enceinte, directement depuis la page d'appairage de
l'add-on.

**1. Installez et démarrez l'add-on** (voir [Installation](#installation)
ci-dessous). Lors d'une première installation, laissez `bluetooth_mac`
vide : l'add-on démarre alors en *mode configuration*, avec uniquement sa
page d'appairage.

**2. Ouvrez la page d'appairage.** Cliquez sur **Bluetooth Audio** dans le
menu latéral de Home Assistant, ou sur **Ouvrir l'interface web** dans
l'onglet Info de l'add-on. Elle n'est accessible qu'aux administrateurs de
Home Assistant. La page elle-même est en anglais, comme les journaux de
l'add-on.

**3. Mettez votre enceinte en mode appairage.**
Ça varie selon le modèle, généralement en maintenant le bouton
d'alimentation ou Bluetooth quelques secondes jusqu'à ce qu'un voyant
clignote. Vérifiez le manuel de votre enceinte en cas de doute. Si
l'enceinte est connectée à un téléphone, déconnectez-la d'abord : beaucoup
d'enceintes n'acceptent qu'une connexion à la fois.

**4. Cliquez sur Scan.** Au bout d'environ 30 secondes, les appareils
audio Bluetooth à proximité s'affichent par leur nom. Les téléphones, TV
et autres appareils non audio sont masqués, sauf si vous cochez *Show
non-audio devices*.

**5. Cliquez sur Pair à côté de votre enceinte.** L'add-on l'appaire, lui
fait confiance ("trust") et la connecte. Vous devriez entendre un son de
connexion sur l'enceinte, et ses badges *Paired*, *Trusted* et
*Connected* passent au vert. *Trusted* est ce qui permet ensuite la
reconnexion automatique de l'add-on.

**6. Cliquez sur Set as primary**, puis confirmez le nom à afficher dans
Home Assistant. L'add-on enregistre l'enceinte dans sa propre
configuration (`bluetooth_mac` et `speaker_name`) et redémarre tout seul ;
le `media_player` natif apparaît ensuite comme décrit dans
[Sortie media_player native](#sortie-media_player-native-dlnaupnp). Pour
une autre enceinte, appairez-la de la même façon puis cliquez plutôt sur
**Add as extra**, voir [Plusieurs enceintes](#plusieurs-enceintes).

### Appairage manuel (solution de repli)

Si la page d'appairage n'arrive pas à appairer votre enceinte
(typiquement un ancien modèle qui demande un code PIN), appairez-la une
fois à la main depuis un terminal, puis renseignez son adresse MAC dans
l'option `bluetooth_mac` de l'add-on.

**1. Ouvrez un terminal sur votre hôte Home Assistant.**
Si taper des commandes dans Home Assistant est nouveau pour vous, allez
dans **Paramètres → Applications** (appelé "Add-ons" sur les versions de
Home Assistant antérieures au renommage mi-2026) → **Magasin
d'applications**, cherchez l'add-on officiel **"Terminal & SSH"**,
installez-le, démarrez-le, puis ouvrez-le depuis le menu latéral. Ça vous
donne une invite de commande directement dans Home Assistant, pas besoin
d'un client SSH séparé.

**2. Mettez votre enceinte en mode appairage**, comme à l'étape 3
ci-dessus.

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

**5. Renseignez cette adresse MAC** dans l'option `bluetooth_mac` de
l'add-on (onglet Configuration), puis démarrez ou redémarrez l'add-on. La
page d'appairage l'affichera ensuite avec ses badges *Paired*, *Trusted*
et *Connected*.

## Installation

Le plus rapide : cliquez sur le bouton ci-dessous, il ouvre votre instance
Home Assistant avec l'URL de ce dépôt déjà pré-remplie, il ne reste plus
qu'à confirmer l'ajout.

[![Ajouter le dépôt sur mon Home Assistant][add-repo-shield]][add-repo-badge]

1. Si vous n'avez pas utilisé le bouton ci-dessus, ajoutez manuellement
   l'URL GitHub de ce dépôt comme dépôt d'add-ons personnalisé dans Home
   Assistant (**Paramètres → Applications → Magasin d'applications →
   ⋮ (menu en haut à droite) → Dépôts**, collez l'URL, fermez), ou copiez
   manuellement ce dossier vers `/addons/bluetooth_audio_bridge` sur votre
   hôte si vous n'utilisez pas la méthode par dépôt.
2. Actualisez le magasin d'applications (même menu ⋮ → Rechercher des
   mises à jour) pour que l'add-on apparaisse. Il sera listé sous une
   section nommée d'après ce dépôt (ou sous "Applications locales" si
   vous avez copié le dossier manuellement).
3. Cliquez sur l'add-on, installez-le, puis démarrez-le. Lors d'une
   première installation, laissez `bluetooth_mac` vide et suivez
   [Appairer votre enceinte](#appairer-votre-enceinte-première-installation)
   depuis le panneau **Bluetooth Audio** de l'add-on. Si vous avez déjà
   appairé l'enceinte à la main, renseignez d'abord son adresse MAC dans
   l'onglet **Configuration** (voir [Configuration](#configuration)).
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
| `bluetooth_mac` | Adresse MAC de l'enceinte Bluetooth principale (format `AA:BB:CC:DD:EE:FF`). Remplie automatiquement quand vous choisissez une enceinte sur la page d'appairage ; laissez-la vide lors d'une première installation pour démarrer en mode configuration (page d'appairage uniquement). | *(vide)* |
| `speaker_name` | Nom cosmétique des sorties (MPD et le nom affiché du `media_player`). | `Bluetooth Speaker` |
| `reconnect_interval` | Secondes entre deux vérifications de la connexion Bluetooth (10-300). | `30` |
| `enable_mpd` | Démarre ou non le serveur MPD. La connexion Bluetooth et le `media_player` natif ne sont pas affectés dans un cas comme dans l'autre ; désactivez cette option si vous ne voulez que le `media_player` natif et n'utilisez pas Music Assistant. | `true` |
| `default_volume` | Volume (%) restauré automatiquement si le sink PulseAudio de l'enceinte est détecté muet ou à 0% (sinon reste silencieux indéfiniment, y compris après un redémarrage). N'écrase jamais un volume que vous avez choisi tant qu'il n'est pas à 0%. | `70` |
| `extra_speakers` | Liste optionnelle d'enceintes supplémentaires (`mac` + `name` chacune), ajoutables directement depuis l'onglet Configuration. Voir [Plusieurs enceintes](#plusieurs-enceintes). | *(vide)* |

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

## Plusieurs enceintes

Vous n'êtes pas limité à une seule enceinte Bluetooth. L'option
`extra_speakers` (une liste d'entrées `{mac, name}`, ajoutables depuis la
page d'appairage avec **Add as extra**, ou directement depuis l'onglet
Configuration de l'add-on — pas besoin d'éditer du YAML) permet
d'enregistrer des enceintes supplémentaires en
plus de la principale (`bluetooth_mac`/`speaker_name`). Chaque enceinte
obtient :

- sa propre connexion Bluetooth, surveillée et reconnectée
  indépendamment des autres ;
- son propre sink PulseAudio ;
- sa propre entité `media_player` native dans Home Assistant, pour
  choisir précisément vers quelle enceinte envoyer un appel
  `play_media`/`tts.speak`.

Ça donne plusieurs sorties sélectionnables indépendamment, pas une
lecture multi-room synchronisée : chaque enceinte joue ce qu'on lui
envoie, de son côté — il n'y a pas de mécanisme intégré pour envoyer le
même son, en synchro, à plusieurs enceintes en même temps.

MPD (et donc le fournisseur "MPD Players" de Music Assistant) reste
attaché uniquement à l'enceinte principale : il n'y a pas de moyen propre
d'exposer plusieurs sorties MPD comme des entités `media_player`
distinctes, donc les enceintes supplémentaires ne sont accessibles que
via le chemin `media_player` natif.

**Music Assistant affiche des enceintes supplémentaires avec un nom
générique ou dupliqué** (par exemple deux enceintes toutes les deux
nommées "Bluetooth Speaker") : c'est un souci de nommage/cache propre à
la découverte DLNA de Music Assistant lui-même, pas quelque chose que cet
add-on contrôle — Home Assistant affiche déjà le bon nom de son côté
(`speaker_name` pour l'enceinte principale, ou le `name` renseigné dans
`extra_speakers`). Si Music Assistant confond deux lecteurs, renommez-les
directement là-bas : **Music Assistant → Paramètres → Lecteurs →
sélectionnez le lecteur → l'icône crayon** à côté de son nom.

**Changer d'enceinte principale déplace son entité.** La sortie
`media_player` native de l'enceinte principale écoute toujours sur le
port 49494, et Home Assistant rattache l'entité à cette adresse. Si vous
définissez une autre enceinte comme principale, l'entité existante passe
sur cette enceinte et peut prendre son nom. Les enceintes supplémentaires
écoutent chacune sur un port fixe dérivé de leur adresse MAC, donc leurs
entités restent attachées à elles quel que soit l'ordre de la liste.

Si vous ajoutez une enceinte pendant que l'add-on tourne déjà et que son
entité `media_player` n'apparaît pas au bout de quelques minutes, essayez
un **redémarrage complet de Home Assistant Core** (Paramètres > Système >
Redémarrer, pas seulement l'add-on) — ça force un nouveau scan SSDP et a
fiablement fait apparaître l'entité lors de nos tests.

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
conditions réelles, plus un retour communautaire sur un **Chromebox**
(x86, image `amd64`, avec un dongle USB Bluetooth 6.0) qui fonctionne
bien. Ça *devrait* marcher sans modification sur toute installation HAOS
avec un adaptateur Bluetooth fonctionnel (autres modèles de Pi,
installations x86 type NUC, etc.), mais ce n'est pas encore testé
partout. Si vous l'essayez sur un autre matériel, un retour (positif ou
négatif) via une issue est le bienvenu.

## Remarque sécurité

Au-delà de l'accès `host_network` déjà couvert
[plus haut](#accès-réseau-host_network-à-lire-avant-dinstaller), le
serveur MPD lui-même (si `enable_mpd` est activé) n'a aucune
authentification et est accessible depuis votre réseau local (pas depuis
Internet, sauf si vous l'avez vous-même exposé). C'est volontaire pour
garder l'installation simple, en partant du principe que votre réseau
Home Assistant est déjà de confiance. N'exposez pas ce port vers
l'extérieur sans ajouter vos propres protections devant.

La page d'appairage n'est accessible qu'à travers l'ingress de Home
Assistant, donc derrière votre connexion Home Assistant, et uniquement
pour les administrateurs. Comme l'add-on utilise `host_network`, son
serveur web n'écoute volontairement que sur l'adresse du réseau interne
du Supervisor et refuse tout autre client que le proxy ingress du
Supervisor : il n'est pas joignable depuis votre réseau local.

## Dépannage

- **L'add-on ne démarre pas / plante immédiatement** : regardez l'onglet
  Journal de l'add-on. Une adresse `bluetooth_mac` mal formatée fait
  échouer la validation de la config avant même que le conteneur
  démarre. Vérifiez que vous avez bien copié l'adresse complète avec des
  `:` (deux-points), pas des tirets ni sans séparateur. Une adresse vide
  est acceptée : l'add-on démarre alors en mode configuration, voir
  [Appairer votre enceinte](#appairer-votre-enceinte-première-installation).
- **"Failed to open audio output" / pas de son côté MPD, mais l'add-on
  tourne** : ça signifie presque toujours que l'enceinte n'est pas
  vraiment *appairée et de confiance ("trusted")*. Être "à portée" ou
  "allumée" ne suffit pas. Ouvrez le panneau **Bluetooth Audio** de
  l'add-on : les badges *Paired*, *Trusted* et *Connected* de l'enceinte
  doivent tous être verts. Sinon, cliquez sur **Pair** à côté d'elle (sur
  une enceinte déjà appairée, ça refait seulement le "trust", sans
  refaire l'appairage), ou reprenez la section
  [Appairer votre enceinte](#appairer-votre-enceinte-première-installation).
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
  seule** : vérifiez que son badge *Trusted* est vert sur la page
  d'appairage. Sans ça, HAOS n'autorise pas la reconnexion automatique
  dont dépend cet add-on. Cliquer sur **Pair** sur une enceinte déjà
  appairée refait seulement le "trust", sans refaire tout l'appairage
  (ou lancez `trust AA:BB:CC:DD:EE:FF` dans `bluetoothctl`).
- **L'appairage échoue depuis la page d'appairage** : vérifiez que
  l'enceinte est en mode appairage *au moment où vous cliquez sur Pair*
  (beaucoup d'enceintes en sortent au bout d'une ou deux minutes), proche
  de l'hôte, et déconnectée de tout téléphone. Les enceintes qui
  demandent un code PIN ne peuvent pas être appairées depuis la page :
  utilisez l'[appairage manuel](#appairage-manuel-solution-de-repli). Le
  message d'erreur affiché sur la page, ainsi que l'onglet Journal de
  l'add-on, indiquent la raison remontée par le Bluetooth.
- **Le panneau Bluetooth Audio ne s'ouvre pas ou affiche une erreur** :
  cherchez une ligne `Starting the pairing web UI` dans l'onglet Journal
  de l'add-on. Si une erreur sur l'adresse ou le port ingress apparaît à
  la place, redémarrez l'add-on ; le pont audio lui-même continue de
  fonctionner dans tous les cas.
- **Un autre add-on audio Bluetooth est installé** (par exemple Bluetooth
  Audio Manager) : ne laissez pas deux add-ons gérer la même enceinte.
  Chacun la reconnecte de son côté et ils finissent par se disputer la
  connexion.
- **Music Assistant affiche le lecteur MPD comme indisponible** :
  vérifiez que `enable_mpd` est activé et que vous avez bien utilisé le
  *nom d'hôte interne* de l'add-on, pas l'adresse IP de l'hôte (voir
  étape 5 de l'Installation).
- **L'entité `media_player` d'une enceinte supplémentaire ajoutée
  n'apparaît jamais** : même cause que ci-dessus, mais spécifiquement
  après avoir ajouté une enceinte à une installation déjà en cours de
  fonctionnement — essayez un redémarrage complet de **Core** Home
  Assistant (pas seulement l'add-on), voir
  [Plusieurs enceintes](#plusieurs-enceintes).
- **Grésillements, saccades ou micro-coupures du son, notamment sur un
  Raspberry Pi 4** : le Bluetooth et le Wi-Fi intégrés du Pi 4 partagent
  la même antenne et la même bande 2.4GHz, ce qui provoque couramment ce
  genre de défaut en usage réel — c'est une limite matérielle, pas
  quelque chose que cet add-on peut corriger côté logiciel. Un dongle
  Bluetooth USB externe bon marché avec sa propre antenne (par exemple à
  base du chipset CSR8510, très répandu) contourne le problème de façon
  fiable : BlueZ le prend en charge automatiquement comme contrôleur
  supplémentaire, aucun changement de configuration nécessaire ici.
  Lancez `bluetoothctl list` pour confirmer qu'il est bien actif comme
  contrôleur `[default]`.
- **Une enceinte renommée dans l'add-on garde l'ancien nom sur son entité
  `media_player`** : c'est le fonctionnement de l'intégration DLNA de
  Home Assistant, pas quelque chose que l'add-on contrôle. Le nom de
  l'entité est fixé une seule fois, quand Home Assistant découvre
  l'enceinte, puis n'est plus jamais mis à jour. L'add-on garde le même
  identifiant pour une enceinte (dérivé de son adresse MAC), donc Home
  Assistant voit toujours le même appareil. Renommez l'entité
  directement dans Home Assistant (**Paramètres → Appareils et services
  → Entités**), ou supprimez l'entrée **DLNA Digital Media Renderer** de
  cette enceinte pour que Home Assistant la redécouvre avec le nouveau
  nom (son identifiant d'entité peut alors changer, vérifiez vos
  automatisations).

## Comment ce projet a été fait

L'idée, les tests sur du matériel réel et les décisions de comportement
sont de moi. Le code, ainsi que l'essentiel du texte anglais du dépôt
(l'anglais n'étant pas ma langue), ont été écrits avec Claude, un
assistant IA, depuis le tout premier commit. Seuls quelques commits
portent explicitement une ligne `Co-Authored-By` à ce titre ; l'habitude
de l'ajouter est venue plus tard et n'a pas été appliquée rétroactivement
au reste de l'historique.

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

[add-repo-shield]: https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg
[add-repo-badge]: https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fdcybeldesign%2Fha-mpd-bluetooth-bridge
