# Release checklist

Run before pushing a `vX.Y.Z` tag on `prod`. About 10 minutes.

## One-time setup

1. Export the Sparkle key into the `release` environment, then delete the file:

   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account io.oshoez.noblast -x /tmp/noblast-key
   gh secret set SPARKLE_ED_PRIVATE_KEY --env release --repo OshOEz/no-blast < /tmp/noblast-key
   rm /tmp/noblast-key
   ```

   The key now lives in your login Keychain and in that secret. Losing both strands every installed copy
   without updates.

## Every release

1. Install the DMG from the `prod` CI run's artifacts; go through setup (camera, enrollment, test).
2. App Lock on Notes: the blur appears, lifts when you're recognized; Cmd-Tab away while it's up; "Quit App".
3. Lock screen: `⌃⌘Q`, look at the screen, it unlocks.
4. Scan budget: lock, stay out of view ~1 min 30 s: the camera light turns on at most three times (~30 s each).
5. Start typing your password during a scan: No Blast does not type over it.
6. `git tag vX.Y.Z <prod commit> && git push origin vX.Y.Z`, then watch the Release workflow; check that the
   release has `NoBlast-X.Y.Z.dmg`, `NoBlast.dmg` and `appcast.xml`.
