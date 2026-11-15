# Quik

[中文](README.md) · [English](README.en.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · [日本語](README.ja.md)

Un moniteur de blocages macOS qui vit dans la barre des menus. Il répond à deux questions : le système est-il bloqué maintenant, et qu'est-ce qui le cause.

Swift natif, aucune dépendance tierce. Le coût mesuré en régime stable est de 0,8 % d'un cœur (0,07 % de 12 cœurs), pour environ 25 Mo de mémoire résidente. La méthode se trouve dans `docs/metric-validation.md`. L'interface de l'application est actuellement en chinois.

## Installation

Téléchargez `Quik-<version>.dmg` depuis [Releases](https://github.com/lesliechowsh/quik/releases/latest), ouvrez-le, puis glissez Quik dans Applications. Nécessite macOS 14 ou ultérieur, sur Apple Silicon et Intel.

Les versions publiées sont signées avec un Developer ID et notariées par Apple. Le premier lancement n'affiche donc aucun avertissement. Une compilation depuis les sources est signée ad-hoc ; son premier lancement demande Réglages Système > Confidentialité et sécurité > « Ouvrir quand même ».

Pour publier, définissez `QUIK_SIGN_IDENTITY` et `QUIK_NOTARY_PROFILE` ; `scripts/package.sh` signe, notarise et agrafe le ticket.

## Compilation et exécution

Nécessite Xcode 26 et `xcodegen`.

```bash
brew install xcodegen
scripts/build.sh
scripts/run.sh
```

`scripts/run.sh` ouvre une fenêtre flottante dans le coin supérieur droit de l'écran. Elle affiche le score, l'état et le principal suspect. Cliquez dessus pour ouvrir le panneau, qui se déploie sous la fenêtre flottante et ne s'allonge que vers le bas quand le mode change. Faites-la glisser pour la déplacer ; la position est mémorisée. La fenêtre n'active pas l'application, ne prend pas le focus et reste visible sur tous les espaces de travail.

Un clic droit sur la fenêtre flottante, ou le bouton « 隐藏悬浮窗 » (masquer la fenêtre flottante) en bas à droite du panneau, la range. Le choix est enregistré dans le réglage `hudVisible` et survit à un redémarrage. Pour la faire revenir, utilisez le bouton du panneau, ou faites un clic droit sur l'élément de la barre des menus et cochez « 显示悬浮窗 » (afficher la fenêtre flottante).

L'icône du Dock reflète aussi l'état. En mode simple, elle affiche l'état et le nom du principal suspect, et passe à l'orange ou au rouge quand le système bloque. Le mode avancé place le score dans la moitié supérieure et le libellé d'état juste en dessous. La taille de police suit le nombre de chiffres, 70 points pour deux chiffres et 52 pour trois, afin que « 100 » reste entier au lieu d'être tronqué en « 1… ». Cliquez sur l'icône du Dock pour ouvrir le panneau.

Un élément de barre des menus apparaît également :

- `● 12` en vert ou sans couleur, le système est fluide.
- `▲ Slack Helper 44%` en orange, le système est ralenti. Le texte qui suit est le principal suspect et sa part d'un cœur.
- `■ Slack Helper 44%` en rouge, le système est bloqué.

Quand la barre des menus manque de place, macOS repousse l'élément sous le menu de l'application. La fenêtre flottante n'est pas concernée et porte donc le signal permanent. Cliquez sur l'élément ou sur la fenêtre flottante pour ouvrir le panneau. Le panneau montre le score de blocage, son attribution (CPU, mémoire, disque, latence de réponse, thermique), les 5 principaux suspects, et les actions disponibles pour chacun : échantillonner 3 secondes, ouvrir le Moniteur d'activité, quitter.

Le mode simple est celui par défaut. Il répond à trois choses : est-ce que ça bloque, qui est responsable, faut-il le quitter. Le score, le détail de l'attribution, le graphique d'historique et l'entrée d'échantillonnage se trouvent derrière le « mode avancé », basculé en bas à droite du panneau.

Les suspects sont affichés comme l'application, pas comme le nom de l'exécutable. `Slack Helper (Renderer)` apparaît comme « Slack · 页面渲染 » (moteur de rendu), et le Dock comme la fenêtre flottante utilisent le même nom. Les processus en ligne de commande sans application propriétaire sont distingués par leur dossier de travail, par exemple « node · exécuté dans le dossier my-project ». Quitter Slack quitte Slack lui-même, pas le processus auxiliaire.

Le rapport `sample` est écrit dans un dossier temporaire et ouvert automatiquement. Il contient 3 secondes de piles d'appels et montre la fonction dans laquelle le processus est bloqué. Cette entrée n'apparaît qu'en mode avancé.

## Assistant IA

Une fois l'installation faite, un assistant IA (Claude Code, Cursor, etc.) peut aussi répondre à « est-ce que la machine bloque maintenant ». Pendant qu'il tourne, Quik place tout seul l'outil en ligne de commande dans `~/.local/bin/quik` ; rien à faire. Pour apprendre cela à votre assistant, ouvrez le panneau et cliquez sur « 安装到 AI 助手 » (installer pour l'assistant IA) : le prompt est copié automatiquement, collez-le dans votre assistant. Le prompt embarque le fichier de compétence complet, et l'assistant l'enregistre dans son propre répertoire. Le prompt et le fichier de compétence ne référencent que `quik` et `~/.local/bin/quik`, sans aucun chemin de votre machine ; les coller n'importe où ne révèle rien de votre arborescence. Une seule installation, ensuite cela vit avec Quik.

`quik` affiche un résumé lisible, `quik --json` un JSON exploitable par une machine, et le code de sortie donne le verdict : 0 fluide, 1 ralenti, 2 bloqué, 3 pas de données. Chaque seconde, l'application réécrit atomiquement `~/Library/Application Support/Quik/status.json`, mesuré à 516 octets ; le fichier est supprimé à la fermeture, et des données de plus de 5 secondes comptent comme périmées. Le fichier de compétence apprend à l'assistant à citer le résumé tout fait et à ne pas relancer top ni un échantillonnage de son côté. Pour arrêter, supprimez le dossier `quik` dans le répertoire de compétences de l'assistant ainsi que `~/.local/bin/quik`.

## Vérification

```bash
# Tests unitaires : décision, hystérésis, classement, stabilité d'affichage
xcodebuild -project Quik.xcodeproj -scheme Quik -configuration Debug -derivedDataPath build test

# Boucle d'interface : injecte des états fixes, capture le vrai panneau, vérifie le texte par OCR
scripts/ui-check.sh

# Boucle de mesure : surcharge CPU contrôlée, vérifie la sonde et la décision
# Mesure des oscillations : cycles de 6 s à pleine charge / 6 s au repos, compte les changements d'état et de classement (scripts/flap-check.sh)
scripts/verify-experience.sh
```

```bash
# Boucle de la fenêtre flottante : reste masquée ou affichée après redémarrage, se range et revient en cours d'exécution
scripts/verify-hud.sh

# Boucle de l'action quitter : envoie un signal à un vrai processus et vérifie qu'il s'arrête
scripts/verify-quit.sh
```

```bash
# Boucle du paquet : monte le DMG, vérifie les architectures, la signature et la cible du glisser-déposer, puis le lance une fois
scripts/verify-package.sh

# Boucle de l'agent : fichier d'état, installation dans ~/.local/bin, les deux sorties du CLI, péremption et nettoyage à la fermeture
scripts/verify-agent.sh
```

Les étapes de publication sont dans `docs/distribution.md`.

`scripts/ui-check.sh` écrit les captures et le texte OCR dans `/tmp/quik-ui`. Il vérifie cinq choses : le texte du panneau, les rectangles du panneau et de la fenêtre flottante restant à l'écran, le texte de l'icône du Dock restant dans la tuile, le rendu correct des deux modes, et la vue « 安装到 AI 助手 » affichée avec le prompt copié dans le presse-papiers sans aucun chemin de machine. Toute assertion en échec renvoie un code de sortie non nul.

La position de la fenêtre est vérifiée séparément, car une capture par identifiant de fenêtre prouve que le contenu est bon, pas que la fenêtre est à l'écran. Une première version plaçait le panneau au-dessus du haut de l'écran ; la capture du contenu était parfaite et le contrôle passait quand même.

Le contrôle d'icône lit des PNG exportés par l'application, issus du même rendu `ImageRenderer` que celui dessiné par le Dock. Il vérifie une tuile carrée, des pixels de texte qui ne touchent pas le bord, et un texte plus haut que la moitié de la tuile. Le mode avancé ajoute deux contraintes mesurables : l'écart vertical entre le score et le libellé reste sous 12 % du côté de la tuile, et le bas du libellé se trouve à au moins 20 pixels du bas de la tuile. Un test unitaire rend aussi un score de 100 et le relit avec Vision, si bien qu'un score à trois chiffres tronqué fait échouer la compilation.

## Limites de mesure

Quik mesure la contention système, pas le temps de frame de l'interface d'une autre application. macOS n'offre aucune interface publique permettant à un processus de lire de l'extérieur les blocages du thread principal d'un autre processus.

Le panneau indique donc « qui utilise les ressources » et « le système peut-il encore ordonnancer les threads interactifs à temps », pas « cette application est figée ». Quand le CPU est saturé mais que la latence de réponse est normale, Quik signale un ralentissement, pas un blocage. Une pression mémoire critique ou une température critique fait exception : le noyau gèle déjà des applications ou réduit la fréquence, et Quik signale alors un blocage directement.

La correspondance complète entre charge et état, ainsi que la base de la courbe de décision, se trouvent dans `docs/metric-validation.md`.

## Arborescence

```
Sources/Core/       moteur de décision, deltas, sonde d'expérience, historique, fichier d'état agent
Sources/Probe/      échantillonnage mach, sysctl, libproc, IOKit et pont C
Sources/UI/         barre des menus, panneau, actions, états de prévisualisation
Sources/CLI/        outil en ligne de commande quik
Sources/Resources/  fichier de compétence pour assistant IA livré avec l'app
Sources/App/        point d'entrée
Tests/              tests unitaires
scripts/            compilation, contrôles d'interface, expériences de mesure
docs/               journal de décision et validation des mesures
```

## Licence

MIT. Voir `LICENSE`.
