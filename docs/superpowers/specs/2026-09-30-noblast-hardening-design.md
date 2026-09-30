# No Blast — Étape 1 : fork, durcissement et audit

Date : 2026-09-30
Statut : proposé

## Contexte

No Blast est un fork de [HeyMac](https://github.com/iharshitmaurya/HeyMac) (MIT) : verrouillage d'apps et
déverrouillage de l'écran de session par reconnaissance faciale, 100 % local, macOS 14+, Apple Silicon.

Usage principal visé : **App Lock**. Le déverrouillage de l'écran de session est conservé et durci.

Ce spec couvre l'étape 1 sur 3 :

1. Fork, durcissement, audit prod (ce document).
2. Batterie de tests et CI (spec séparé).
3. Alerte SMS avec photo de l'intrus (spec séparé).

## Ce qu'a demandé l'utilisateur

- Appliquer toutes les recommandations de l'analyse, **sauf la signature** du code.
- Garder le déverrouillage de l'écran de session, en le durcissant.
- Nom : **No Blast**, bundle ID `io.oshoez.noblast`.
- Garder le modèle ArcFace (InsightFace, non commercial) : le dépôt est open source et non commercial.
- Dépôt public `OshOEz/no-blast`, initialisé avec l'outillage OshO (repo-init).
- Branches `dev`, `staging`, `prod`, sur le modèle des autres dépôts de l'utilisateur.
- Relecture « carrée » avec la rigueur d'une app de prod : skill audit-loop.

## Hypothèses (à corriger si besoin)

- Aucune migration de données HeyMac → No Blast : c'est une nouvelle app, jamais installée sous ce nom.
- Les autres dépôts n'ont aucune protection de branche active côté GitHub. Les « mêmes règles » sont donc
  interprétées comme le flux `feature/* → dev → staging → prod` par PR, renforcé par des rulesets (disponibles
  gratuitement puisque le dépôt est public).
- Le compte a un seul contributeur : aucune approbation de PR n'est exigée (GitHub interdit d'approuver sa propre PR).

## 1. Dépôt et branches

- `OshOEz/no-blast`, public, créé avec `gh`. Ce n'est pas un fork GitHub.
- `prod`, `staging` et `dev` démarrent sur le premier commit de l'auteur (`0113c8e`, squelette de 85 lignes).
  Branche par défaut : `dev`.
- La branche `hardening` contient le reste de l'historique d'origine, puis nos commits. La PR `hardening → dev`
  couvre donc toute l'app, et l'audit relit tout le code, pas seulement nos changements.
- Rulesets sur `dev`, `staging` et `prod` :
  - PR obligatoire (0 approbation requise) ;
  - force-push et suppression interdits ;
  - statut CI requis : ajouté à l'étape 2, quand la CI existe.
- Merge : merge commit uniquement, pour garder l'historique et l'attribution de l'auteur d'origine. Branche
  supprimée après le merge.
- repo-init : graphe code-review-graph et hook pre-commit.
- Le `.gitignore` d'origine ignore `docs/` : cette règle est retirée pour que les specs et plans soient versionnés.

## 2. Renommage en No Blast

| Élément | Avant | Après |
|---|---|---|
| Nom affiché | Hey Mac | No Blast |
| Bundle ID | `com.heymac.app` | `io.oshoez.noblast` |
| Produit / exécutable | `HeyMac` | `NoBlast` |
| Modules | `HeyMacCore`, `HeyMacEngine`, `HeyMacApp` | `NoBlastCore`, `NoBlastEngine`, `NoBlastApp` |
| Cibles de test | `HeyMac*Tests` | `NoBlast*Tests` |
| Bundle de ressources | `HeyMac_HeyMacCore.bundle` | `NoBlast_NoBlastCore.bundle` |
| Service Keychain | `com.heymac.sessionkey` | `io.oshoez.noblast.sessionkey` |
| Agent de lancement | `com.heymac.app.agent(.plist)` | `io.oshoez.noblast.agent(.plist)` |
| Données | `~/Library/Application Support/HeyMac` | `~/Library/Application Support/NoBlast` |
| Log | `~/Library/Logs/HeyMac.log` | `~/Library/Logs/NoBlast.log` |
| Identité de signature locale | `FaceUnlock Local Signing` | `No Blast Local Signing` |
| Copyright | Harshit Maurya | Harshit Maurya + OshOEz (LICENSE MIT d'origine conservé) |

Critère : `git grep -i -E "heymac|hey mac"` ne renvoie plus que les mentions d'attribution (README, LICENSE,
THIRD_PARTY_NOTICES).

## 3. Mises à jour (Sparkle)

- Nouvelle paire de clés EdDSA générée avec `generate_keys` de Sparkle. La clé privée reste dans le Keychain de
  l'utilisateur, la clé publique va dans `SUPublicEDKey`.
- `SUFeedURL` = `https://github.com/OshOEz/no-blast/releases/latest/download/appcast.xml`.
- `release.sh` : cible `OshOEz/no-blast`, étape Homebrew supprimée. Les noms de DMG suivent le renommage.

## 4. Durcissement du déverrouillage de l'écran de session

### 4.1 Nombre de scans limité par verrouillage

Aujourd'hui, un scan sans reconnaissance relance immédiatement une nouvelle fenêtre de 30 s. La caméra reste donc
allumée tant que l'écran verrouillé est affiché.

Nouveau comportement :

- Au plus **3 fenêtres de scan** par verrouillage.
- Une fois les 3 fenêtres épuisées, la caméra reste éteinte jusqu'à un **signal de présence** :
  - une entrée clavier, souris ou trackpad postérieure à l'épuisement (`CGEventSource.secondsSinceLastEventType`
    sur `combinedSessionState`) ;
  - ou un réveil de l'écran (passage « écran en veille » → « écran allumé »).
- Un signal de présence ouvre une nouvelle série de 3 fenêtres.
- Le déverrouillage de la session remet tout à zéro.
- Les causes « pas de tentative » existantes restent inchangées : pause, réglage désactivé, mot de passe rejeté,
  Accessibilité manquante, écran en veille.

L'horloge d'inactivité est injectée dans `LockScreenEnvironment` pour être testable.

### 4.2 Vérification de l'état de l'écran

- Session ouverte : vérification toutes les **2 s** au lieu de 250 ms. Une notification `com.apple.screenIsLocked`
  déclenche une vérification immédiate. La vérification lente reste en filet de sécurité, au cas où une
  notification serait manquée.
- Écran verrouillé : vérification toutes les 250 ms, comme aujourd'hui.
- Inchangé : la double vérification « l'écran est bien verrouillé » avant et après le réveil de l'écran, juste
  avant de taper le mot de passe.

### 4.3 Risques résiduels, documentés et non corrigés ici

- Signature ad-hoc : une règle de signature limitée à l'identifiant permet à un binaire local signé avec le même
  identifiant de lire la clé du Keychain. Se corrige par la signature, hors périmètre.
- Le mot de passe tapé via des événements clavier système peut être capturé par un keylogger qui a la permission
  Surveillance de l'entrée.

## 5. Performance

- `build-app.sh` compile les modèles (`.mlpackage` → `.mlmodelc`, via `xcrun coremlcompiler compile`) dans le
  bundle de ressources de l'app.
- Au chargement, `ModelResources` utilise le `.mlmodelc` s'il existe. Sinon il compile le `.mlpackage`, comme
  aujourd'hui (`swift run` et tests).
- `NoBlastRuntime`, qui charge les modèles, est construit **hors du thread principal** au lancement :
  - pendant le chargement, le menu affiche « Chargement des modèles… » ;
  - le moteur de l'écran de session démarre dès que les modèles sont prêts ;
  - si App Lock demande une authentification avant ce moment, la reconnaissance faciale est ignorée et l'app
    passe directement à Touch ID ou au mot de passe (comportement existant quand `faceMatcher` renvoie `nil`).
- `--self-check` et `verify-app.sh` vérifient que les `.mlmodelc` sont présents dans le bundle.

## 6. README et documentation

- App Lock décrit comme une protection **dissuasive**, avec ses limites :
  - l'app protégée tourne toujours et ses fichiers restent lisibles ;
  - `screencapture -l <id>` peut capturer une fenêtre sous le voile ;
  - `launchctl` depuis le Terminal (qui ne peut pas être verrouillé) arrête la protection.
- Suppression de l'affirmation « rejette les masques ». Description exacte du modèle anti-photo : une seule image
  RVB, sans capteur de profondeur.
- Mention de la licence non commerciale des poids ArcFace dans `THIRD_PARTY_NOTICES.md`.
- Section « Risques résiduels » reprenant le §4.3.
- Liens d'installation et de téléchargement mis à jour vers `OshOEz/no-blast`.

## 7. Tests (étape 1)

La suite existante (81 tests) doit passer. Nouveaux tests unitaires, avec l'environnement injecté :

- 3 fenêtres sans reconnaissance → pas de 4ᵉ scan sans signal de présence.
- Entrée utilisateur après épuisement → nouvelle série de scans.
- Réveil de l'écran après épuisement → nouvelle série de scans.
- Déverrouillage → remise à zéro du compteur.
- Résolution des modèles : `.mlmodelc` préféré, repli sur `.mlpackage`.

La batterie complète (tests App Lock, intégration, CI) relève de l'étape 2.

## 8. Audit

- Skill audit-loop sur la PR `hardening → dev`, 3 tours maximum.
- Issues P0 et P1 uniquement, fermées par l'auditeur après vérification.
- Pas de merge sans accord explicite de l'utilisateur.

## Critères de succès

1. `OshOEz/no-blast` existe, public, avec `dev`, `staging` et `prod` protégées. La PR `hardening → dev` est ouverte.
2. `swift build -c release` et `swift test` passent. `scripts/build-app.sh` produit `NoBlast.app`, et
   `verify-app.sh` le valide.
3. Plus aucune référence technique à HeyMac, sauf l'attribution.
4. Un Mac verrouillé, écran allumé, sans personne devant : au plus 3 × 30 s de caméra, puis caméra éteinte.
5. L'audit se termine avec 0 issue P0/P1 ouverte, ou avec une escalade présentée à l'utilisateur.

## Hors périmètre

- Signature du code et notarisation.
- Remplacement du modèle ArcFace.
- Portage Windows. Pour que l'alerte fonctionne pareil sur les deux plateformes, l'étape 3 privilégiera un envoi de
  SMS par API HTTP plutôt que par l'app Messages.
- CI et batterie de tests étendue (étape 2).
- Alerte SMS (étape 3).
