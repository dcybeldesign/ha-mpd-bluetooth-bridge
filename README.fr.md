# Bluetooth Speaker MPD Bridge

Un add-on Home Assistant (HAOS) qui fait tourner un serveur
[MPD](https://www.musicpd.org/) (Music Player Daemon) dont la sortie audio
est forcée vers une enceinte Bluetooth appairée avec l'hôte, et expose ce
serveur MPD à [Music Assistant](https://www.music-assistant.io/) via son
fournisseur natif **MPD Players**.

*[Read in English](README.md)*

## Pourquoi cet add-on

Le fournisseur natif **Local Audio Out** de Music Assistant ne peut pas
cibler directement un sink PulseAudio Bluetooth. Le sélecteur de sortie
audio des add-ons HAOS ne liste que le matériel physique (jack/HDMI),
jamais les périphériques Bluetooth appairés dynamiquement. Cet add-on
contourne la limitation en faisant tourner un petit serveur MPD dédié,
configuré pour sortir directement sur le sink Bluetooth. Music Assistant
s'y connecte ensuite via le protocole MPD standard, officiellement
supporté.

## Fonctionnement

- `run.sh` calcule le nom du sink PulseAudio à partir de l'adresse MAC
  Bluetooth configurée, génère `/etc/mpd.conf` à partir du modèle
  `mpd.conf.template`, connecte l'enceinte via `bluetoothctl`, puis
  démarre MPD.
- Une boucle de fond vérifie la connexion Bluetooth toutes les
  `reconnect_interval` secondes (30s par défaut) et reconnecte
  automatiquement l'enceinte si elle se déconnecte (mise en veille, hors
  de portée...).
- MPD expose le port `6600/tcp` (port standard du protocole MPD), auquel
  le fournisseur "MPD Players" de Music Assistant se connecte directement.

## Prérequis

- Un hôte Home Assistant OS avec un adaptateur Bluetooth fonctionnel.
  Développé et testé sur un **Raspberry Pi 4** (Bluetooth 5.0 intégré).
  Voir [Portabilité](#portabilité-au-delà-du-raspberry-pi-4) ci-dessous
  pour les autres matériels.
- Un accès terminal/shell à cet hôte (voir l'étape 1 de
  [Appairer ton enceinte](#appairer-ton-enceinte-première-installation)
  ci-dessous si tu ne l'as pas encore).
- L'enceinte cible doit déjà être **appairée** avec l'hôte au préalable.
  Cet add-on gère uniquement la connexion/reconnexion d'un appareil déjà
  appairé, pas le premier appairage. Guide complet ci-dessous.
- L'add-on [Music Assistant](https://www.music-assistant.io/) installé et
  démarré.

## Appairer ton enceinte (première installation)

À faire une fois par enceinte, **avant** d'installer l'add-on. L'add-on ne
peut que reconnecter une enceinte que Home Assistant connaît déjà, il ne
peut pas faire le premier appairage à ta place.

**1. Ouvre un terminal sur ton hôte Home Assistant.**
Si taper des commandes dans Home Assistant est nouveau pour toi, va dans
**Paramètres → Applications** (aussi appelé "Add-ons" selon la version de
Home Assistant) → **Magasin d'applications**, cherche l'add-on officiel
**"Terminal & SSH"**, installe-le, démarre-le, puis ouvre-le depuis le
menu latéral. Ça te donne une invite de commande directement dans Home
Assistant, pas besoin d'un client SSH séparé.

**2. Mets ton enceinte en mode appairage.**
Ça varie selon le modèle, généralement en maintenant le bouton
d'alimentation ou Bluetooth quelques secondes jusqu'à ce qu'un voyant
clignote. Vérifie le manuel de ton enceinte en cas de doute.

**3. Dans le terminal, lance le scan :**
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
Repère la ligne dont le nom correspond à ton enceinte, et note l'adresse
juste avant le nom (la chaîne au format `AA:BB:CC:DD:EE:FF`, c'est son
adresse MAC). Ignore les autres appareils qui apparaissent : des
téléphones, TV ou autres gadgets Bluetooth à proximité remontent souvent
aussi. Tu ne veux que celui qui correspond au nom de ton enceinte.

**4. Appaire, fais confiance, et connecte avec cette adresse :**
```
scan off
pair AA:BB:CC:DD:EE:FF
trust AA:BB:CC:DD:EE:FF
connect AA:BB:CC:DD:EE:FF
quit
```
(remplace `AA:BB:CC:DD:EE:FF` par l'adresse notée à l'étape 3)
- `pair` doit répondre `Pairing successful`. La plupart des enceintes
  Bluetooth s'appairent sans code PIN ; si la tienne en demande un,
  vérifie son manuel, c'est souvent `0000` ou inscrit sur l'appareil.
- `trust` est ce qui permet à la reconnexion automatique de l'add-on de
  fonctionner ensuite. Ne saute pas cette étape.
- `connect` confirme que la liaison fonctionne tout de suite. Tu devrais
  entendre un son de connexion sur l'enceinte.

**5. Garde cette adresse MAC sous la main.** Tu la colleras dans l'option
`bluetooth_mac` de l'add-on à l'étape suivante.

## Installation

1. Ajoute l'URL GitHub de ce dépôt comme dépôt d'add-ons personnalisé dans
   Home Assistant (**Paramètres → Applications → Magasin d'applications →
   ⋮ (menu en haut à droite) → Dépôts**, colle l'URL, ferme), ou copie
   manuellement ce dossier vers `/addons/mpd_bluetooth_bridge` sur ton
   hôte si tu n'utilises pas la méthode par dépôt.
2. Actualise le magasin d'add-ons (même menu ⋮ → Rechercher des mises à
   jour) pour que l'add-on apparaisse. Il sera listé sous une section
   nommée d'après ce dépôt (ou sous "Applications locales" si tu as copié
   le dossier manuellement).
3. Clique sur l'add-on, installe-le, ouvre l'onglet **Configuration** et
   renseigne l'adresse MAC Bluetooth de ton enceinte notée plus haut
   (obligatoire, voir [Configuration](#configuration)), puis démarre-le.
4. Dans Music Assistant, va dans **Paramètres → Fournisseurs de
   lecteurs**. Le fournisseur **MPD Players** est une entrée unique et
   partagée : si tu ne l'as pas encore configuré, clique sur **Add a
   player provider → MPD Players**. S'il est déjà configuré (par exemple
   à cause d'un autre add-on de pont MPD), ouvre simplement l'entrée
   **MPD Players** existante au lieu d'en recréer une deuxième. Dans les
   deux cas, ajoute le **nom d'hôte interne** de l'add-on suivi de
   `:6600` dans le champ **MPD Servers**. Ce champ prend une adresse par
   ligne : s'il y a déjà une adresse renseignée, ajoute la nouvelle sur
   sa propre ligne en dessous plutôt que de remplacer l'existante ou de
   les séparer par une virgule. Pour trouver ce nom d'hôte, ouvre
   l'onglet **Info** de cet add-on dans Home Assistant et regarde sous
   *Contrôles → Nom d'hôte*. Copie exactement cette valeur (elle
   ressemble typiquement à `local-<quelque chose>` ou un préfixe généré
   suivi du nom de l'add-on, selon la méthode d'installation, donc
   vérifie toujours la valeur réelle affichée chez toi plutôt que de
   deviner). **N'utilise pas** l'adresse IP externe/LAN de l'hôte ici :
   un conteneur ne peut généralement pas rejoindre un autre conteneur via
   l'IP externe de l'hôte (limitation Docker classique dite "hairpin
   NAT"). Seul le nom d'hôte interne fonctionne de façon fiable.

## Configuration

| Option | Description | Défaut |
|---|---|---|
| `bluetooth_mac` | Adresse MAC de l'enceinte Bluetooth (format `AA:BB:CC:DD:EE:FF`). **Obligatoire.** | *(aucune, à renseigner)* |
| `speaker_name` | Nom cosmétique affiché côté MPD. | `Bluetooth Speaker` |
| `reconnect_interval` | Secondes entre deux vérifications de la connexion Bluetooth (10-300). | `30` |

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
encore testé partout. Si tu l'essaies sur un autre matériel, un retour
(positif ou négatif) via une issue est le bienvenu.

## Remarque sécurité

Le serveur MPD n'a aucune authentification et est accessible depuis ton
réseau local (pas depuis Internet, sauf si tu l'as toi-même exposé). C'est
volontaire pour garder l'installation simple, en partant du principe que
ton réseau Home Assistant est déjà de confiance. N'expose pas ce port
vers l'extérieur sans ajouter tes propres protections devant.

## Dépannage

- **L'add-on ne démarre pas / plante immédiatement** : regarde l'onglet
  Journal de l'add-on. Une adresse `bluetooth_mac` absente ou mal
  formatée fait échouer la validation de la config avant même que le
  conteneur démarre. Vérifie que tu as bien copié l'adresse complète
  avec des `:` (deux-points), pas des tirets ni sans séparateur.
- **"Failed to open audio output" / pas de son, mais l'add-on tourne** :
  ça signifie presque toujours que l'enceinte n'est pas vraiment
  *appairée et de confiance ("trusted")*. Être "à portée" ou "allumée" ne
  suffit pas. Reprends la section
  [Appairer ton enceinte](#appairer-ton-enceinte-première-installation)
  et vérifie que les commandes `pair` ET `trust` ont bien réussi (pas
  seulement `connect`). Tu peux vérifier l'état à tout moment avec
  `bluetoothctl info AA:BB:CC:DD:EE:FF` dans un terminal : cherche
  `Paired: yes`, `Trusted: yes` et `Connected: yes` dans le résultat.
- **Mon enceinte se déconnecte sans arrêt / ne se reconnecte pas toute
  seule** : vérifie que `trust` a bien été exécuté pendant l'appairage
  (étape 4). Sans ça, HAOS n'autorise pas la reconnexion automatique
  dont dépend cet add-on. Tu peux relancer `trust AA:BB:CC:DD:EE:FF`
  dans `bluetoothctl` à tout moment sans refaire tout l'appairage.
- **Music Assistant affiche le lecteur MPD comme indisponible** :
  vérifie que tu as bien utilisé le *nom d'hôte interne* de l'add-on, pas
  l'adresse IP de l'hôte (voir étape 4 de l'Installation).

## Avertissement

Ce projet est un partage libre et gratuit, réalisé sur mon temps
personnel. Je ne suis pas responsable des problèmes que son utilisation
pourrait causer (matériel, logiciel, ou autre). Tu l'utilises, l'installes
et l'adaptes entièrement sous ta propre responsabilité. Les fichiers sont
libres d'utilisation, de partage et de modification. Si tu réutilises ou
t'appuies sur ce travail, une mention de mon nom est appréciée (voir
ci-dessous), mais rien ici n'est fourni avec une quelconque garantie.

## Soutenir ce projet

Si cet add-on t'a été utile, tu peux soutenir son développement :

- [GitHub Sponsors](https://github.com/sponsors/dcybeldesign)
- [Buy Me a Coffee](https://buymeacoffee.com/dcybeldesign)

## Auteur

[dcybeldesign](https://github.com/dcybeldesign)

## Licence

[MIT](LICENSE)
