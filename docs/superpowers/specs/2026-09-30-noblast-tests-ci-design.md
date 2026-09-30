# No Blast — Étape 2 : batterie de tests, CI et release automatique

Date : 2026-09-30
Statut : proposé
Précédent : `2026-09-30-noblast-hardening-design.md` (étape 1, mergée dans `dev`)

## Ce qu'a demandé l'utilisateur

- Une batterie de tests et une CI « importante ».
- Périmètre CI choisi : **contrôle des PR + release automatique** sur tag.
- Approche de test d'App Lock choisie : **extraire le cœur logique** dans `NoBlastEngine` (option A).
- Usage principal de l'app : App Lock.

## Hypothèses

- GitHub Actions, runners macOS Apple Silicon (gratuits : dépôt public).
- La CI n'a ni caméra, ni Accessibilité, ni Touch ID, ni trousseau utilisateur : les tests automatiques n'en
  dépendent pas et **n'écrivent jamais dans un vrai trousseau**.
- Aucun changement de fonctionnalité visible dans cette étape (refactor à comportement identique + tests + CI).

## État de départ (mesuré le 2026-09-30 sur `dev` @ 8014345)

- 94 tests, tous verts.
- Couverture de lignes : `NoBlastCore` 90,1 %, `NoBlastEngine` 50,6 %, `NoBlastApp` non mesurée.
- Toute la logique d'App Lock vit dans `Sources/NoBlastApp/AppLock/AppLockController.swift` (~270 lignes, AppKit),
  sans aucun test.

## 1. Cœur d'App Lock extrait

Nouveau fichier `Sources/NoBlastEngine/AppLock/AppLockCore.swift`.

### 1.1 Décisions déplacées dans le cœur

Toutes les décisions prises aujourd'hui par `AppLockController` :

- app verrouillée candidate → épisode démarré, ou mise en file si un épisode est en cours (pas de doublon par pid) ;
- app déjà déverrouillée (session active) → ignorée ;
- fin d'authentification :
  - réussite → session ouverte selon la règle de reverrouillage de l'app (défaut `.afterMinutes(5)`), voile retiré,
    app ré-affichée et activée, activation tardive de cette app ignorée une fois, épisode suivant de la file ;
  - annulation / refus → le voile reste, avec le message (`needsAuth`) ;
  - résultat arrivé pour un épisode qui n'est plus actif → ignoré ;
- « Réessayer » → authentification relancée pour la même app ;
- « Quit App » → authentification annulée, app cachée puis terminée, voile retiré, épisode suivant ;
- autre app régulière activée pendant un épisode → abandon **proposé** ; l'abandon n'a lieu que si, au moment de la
  confirmation, le même épisode est toujours actif et l'autre app toujours au premier plan ; sinon il est annulé
  (activation transitoire) ; en cas d'abandon : voile retiré, app verrouillée cachée, épisode suivant ;
  la feuille système Touch ID (app non régulière) et No Blast lui-même ne déclenchent jamais l'abandon ;
- app terminée → session révoquée, retirée de la file ; si c'était l'épisode actif : voile retiré, épisode suivant ;
- veille, écran en veille, verrouillage de l'écran, changement d'utilisateur → toutes les sessions révoquées,
  app de l'épisode cachée, file vidée, voile retiré ;
- app verrouillée non déverrouillée passée en arrière-plan → cachée, sauf si elle est cachée déjà, si elle est
  l'épisode actif ou en file, ou si elle a été lancée il y a moins de 5 s ;
- focus perdu / regagné → transmis à `SessionBook` (règles `.everyTime`, `.afterFocusLossMinutes`) ;
- `authorize(reason:)` (quitter No Blast, désactiver App Lock, retirer une app) → refusé si un épisode est actif,
  sinon chaîne visage → Touch ID / mot de passe ;
- `protectsQuit` = App Lock activé et au moins une app verrouillée.

### 1.2 Interfaces

- Entrée : `RunningApp` (valeur) = `pid: Int32`, `bundleID: String?`, `name: String`, `isRegular: Bool`,
  `isHidden: Bool`, `launchedAt: Date?`. Événements : méthodes du cœur (`candidate`, `activated`, `deactivated`,
  `terminated`, `backgroundLocked`, `authFinished`, `retry`, `quitActiveApp`, `confirmSwitchAway`, `revokeAll`,
  `start`, `stop`, `authorize`).
- Sortie : protocole `AppLockEffects` — `presentShield(for:)`, `setShieldPhase(_:)`, `dismissShield()`,
  `startAuthentication(for:)` / `cancelAuthentication()`, `hide(_:)`, `unhideAndActivate(_:)`, `terminate(_:)`,
  `scheduleSwitchAwayCheck(lockedPID:otherPID:)`, `notchScanning()`, `notchFinish(success:)`, `notchCancel()`,
  `log(_:)`.
- Dépendances possédées : `SessionBook`, `LockedAppStore`, horloge injectée (`now: () -> Date`), pid de No Blast
  injecté.

### 1.3 Ce qui reste dans `NoBlastApp`

- `AppWatcher` : traduit les notifications `NSWorkspace` en `RunningApp` + événements du cœur.
- `AppLockController` : implémente `AppLockEffects` avec les vrais objets (`ShieldController`,
  `NotchOverlayController`, `NSRunningApplication`, `AuthCoordinator`), et porte les deux délais :
  - 0,35 s avant `confirmSwitchAway` ;
  - 450 ms entre `notchFinish(success: true)` et le retrait du voile.
  Ces délais n'appellent que le cœur ; ils ne décident rien.
- `ShieldController`, `AppWindowShield`, `WindowTracker`, `ShieldView` : inchangés.

### 1.4 Garantie de non-régression

Chaque branche de décision actuelle d'`AppLockController` a un test dans le cœur **avant** d'y être déplacée.
Après le refactor, les 5 contrôles manuels de la checklist (§3) sont refaits sur un Mac réel.

### 1.5 Scénarios de test minimum

1. Une app verrouillée qui s'active ouvre un épisode (voile + authentification + island).
2. Deux apps verrouillées : la seconde attend et démarre après la première.
3. Même pid candidat deux fois → un seul épisode, pas de doublon en file.
4. Réussite → session selon la règle, voile retiré, app activée ; l'activation tardive de cette app n'abandonne pas
   l'épisode suivant.
5. Annulation puis « Réessayer » → nouvelle authentification pour la même app.
6. Refus → message affiché, voile maintenu.
7. Résultat d'authentification pour un épisode abandonné → ignoré.
8. Cmd-Tab vers une autre app, confirmé → abandon, app cachée, épisode suivant.
9. Activation transitoire (plus au premier plan à la confirmation) → pas d'abandon.
10. Activation d'une app non régulière (Touch ID) ou de No Blast → pas d'abandon proposé.
11. L'app se termine pendant son épisode → voile retiré, épisode suivant, session révoquée.
12. L'app se termine pendant qu'elle est en file → retirée de la file.
13. Verrouillage de l'écran pendant un épisode → tout révoqué, app cachée, file vidée.
14. `.everyTime` : focus perdu → reverrouillée au retour.
15. `.afterMinutes(5)` : toujours déverrouillée à 4 min 59, reverrouillée à 5 min, indépendamment du focus.
16. `.afterFocusLossMinutes(5)` : retour avant 5 min → reste déverrouillée ; après → reverrouillée.
17. App de la liste de sécurité (Terminal, Finder…) → jamais candidate.
18. Arrière-plan : app verrouillée cachée ; épargnée si lancée il y a < 5 s, si en file, ou déjà cachée.
19. `authorize` refusé pendant un épisode ; accordé sinon selon la chaîne ; `protectsQuit` suit le réglage.
20. `stop()` → tout retiré, aucune session conservée ; `start()` deux fois → un seul démarrage.

## 2. Autres tests

1. `EngineController` : centre de notifications injecté (défaut : `DistributedNotificationCenter.default()`) ;
   la notification `com.apple.screenIsLocked` appelle `poke()` ; l'observateur est retiré à `stop()` ;
   `start()` sans configuration terminée ne démarre rien.
2. `KeystrokeInjector` : la séquence de touches (caractères accentués, emoji, espace, Entrée finale) est testée
   sans poster d'événement (fonction de construction de la séquence rendue interne-testable).
3. `LockedAppStore` : données corrompues → liste vide sans crash ; JSON enregistré par la version actuelle relu à
   l'identique (fixture versionnée).
4. `AppLog` : écritures concurrentes depuis plusieurs threads → aucune ligne perdue ni entremêlée.
5. Chaîne de reconnaissance avec les vrais modèles et les fixtures existantes : vérifiée en CI (CPU).

Non testés automatiquement : caméra réelle, Touch ID, frappe réelle, trousseau réel → checklist manuelle (§3).

## 3. Checklist manuelle de release

`docs/RELEASE-CHECKLIST.md`, à dérouler avant chaque tag :

1. Installation depuis le DMG de la CI, assistant complet (caméra, enrôlement, test).
2. App Lock sur Notes : voile puis déverrouillage par le visage ; Cmd-Tab pendant le voile ; « Quit App ».
3. Écran de session : `⌃⌘Q`, déverrouillage par le visage.
4. Limite de scans : verrouillé, personne devant → au plus 3 × 30 s de caméra.
5. Taper son mot de passe pendant un scan → No Blast ne tape pas par-dessus.
6. Clé Sparkle présente dans le secret `release` (et hors du Mac seulement dans ce secret).

## 4. Seuil de couverture

- `scripts/coverage-gate.sh` : lance `swift test --enable-code-coverage`, lit la couverture de lignes par cible
  avec `llvm-cov` (un binaire de test par cible), échoue sous les seuils.
- Seuils : `NoBlastCore` ≥ 88 % ; `NoBlastEngine` = couverture mesurée en fin d'étape, arrondie à l'entier
  inférieur, et **au moins 70 %**. `NoBlastApp` non mesurée.
- Exclus de la mesure, car ils ne peuvent pas tourner en CI (caméra, Touch ID) : `CameraCapture.swift`,
  `LocalSystemAuth.swift`.
- Pourquoi pas 75 % : estimation faite en écrivant le plan — le code lié au matériel (caméra, frappe réelle,
  Keychain réel, chemins `live`) représente environ 300 lignes d'`NoBlastEngine` qu'aucun test automatique ne doit
  exécuter (les tests n'écrivent jamais dans un vrai trousseau).
- Les seuils sont écrits dans le script ; on ne les baisse que par une PR explicite.

## 5. CI (`.github/workflows/ci.yml`)

- Déclencheurs : `pull_request` vers `dev`, `staging`, `prod` ; `push` sur ces branches.
- Runner : image macOS Apple Silicon la plus récente dont le Xcode compile le paquet (vérifiée au premier run ;
  Xcode sélectionné explicitement).
- Job `test` : build release ; tests + seuil de couverture ; `scripts/tests/*.sh` ; `shellcheck scripts/*.sh
  scripts/tests/*.sh` ; `bash -n scripts/release.sh`.
- Job `package` (après `test`) : `build-app.sh` (version `0.0.0-ci`) → `verify-app.sh` (inclut `--self-check`) ;
  `NoBlast --render-ui` ; artefacts : DMG et PNG (7 jours).
- Concurrence : une nouvelle exécution sur la même branche/PR annule la précédente.
- Ruleset `protected-branches` : statuts `test` et `package` requis.

## 6. Release automatique (`.github/workflows/release.yml`)

- Déclencheur : push d'un tag `v*`.
- Refus si le commit du tag n'est pas un ancêtre de `origin/prod`.
- Environnement GitHub `release`, restreint aux tags `v*`, contenant le secret `SPARKLE_ED_PRIVATE_KEY`.
- Étapes : tests ; `build-app.sh X.Y.Z` (version prise du tag, sans le `v`) ; signature Sparkle du DMG ;
  `appcast.xml` ; `gh release create vX.Y.Z` avec `NoBlast-X.Y.Z.dmg`, `NoBlast.dmg`, `appcast.xml`.
- `release.sh` : accepte `SPARKLE_ED_KEY_FILE` (fichier de clé) ; sinon le trousseau local comme aujourd'hui.
  La clé n'est jamais écrite dans les logs ; le fichier temporaire est supprimé en fin de job.
- Ruleset sur les tags `v*` : suppression et déplacement interdits.
- Action unique de l'utilisateur : exporter la clé (`generate_keys --account io.oshoez.noblast -x <fichier>`),
  `gh secret set SPARKLE_ED_PRIVATE_KEY --env release < <fichier>`, puis effacer le fichier.

## Critères de succès

1. `AppLockController` ne contient plus de décision : uniquement du câblage AppKit et les deux délais.
2. Les 20 scénarios du §1.5 et les tests du §2 passent ; tous les tests passent en local et en CI.
3. Couverture : Core ≥ 88 %, Engine ≥ son plancher (≥ 70 %), vérifiée par la CI.
4. Une PR vers `dev` ne peut pas être mergée tant que `test` et `package` ne sont pas verts.
5. Le DMG et les captures d'écran sont téléchargeables depuis chaque PR.
6. Le workflow de release est en place et vérifié à sec (syntaxe, garde `prod`, signature avec un fichier de clé) ;
   la première vraie release (`v0.1.0` sur `prod`) le valide de bout en bout, après que l'utilisateur a posé le secret.
7. La checklist manuelle est refaite une fois après le refactor, sans régression.

## Hors périmètre

- Signature Developer ID et notarisation.
- Tests d'interface de bout en bout (XCUITest).
- Comparaison pixel à pixel des captures d'écran.
- Lint / formatage du code existant.
- Alerte SMS (étape 3).
