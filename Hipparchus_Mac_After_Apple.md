# After Apple: signing and notarising Hipparchus

What to do once the Apple Developer Program enrolment is approved, so that
someone can download the disk image from GitHub and open it by double-clicking.

Enrolment was submitted **2 August 2026**. Approval usually takes a day or two;
Apple emails when it is done.

---

## Why this is needed at all

Whether a downloader sees a warning turns on two things, and only the second is
about this repository.

The first is the `com.apple.quarantine` attribute, and it is set by whatever
**received** the file. A USB stick, AirDrop or a sync folder sets nothing, and
the app opens with no fuss whatever it is signed with — which is why the earlier
ad-hoc builds could be handed to friends and appeared to be fine. A browser
download, from GitHub or anywhere else, does set it.

The second is what Gatekeeper then makes of the file. An ad-hoc signature it
cannot verify, so it refuses. A Developer ID signature *plus* an Apple
notarisation ticket it accepts, and the app opens on a double-click.

There is no way around this. A self-signed certificate does not help — Gatekeeper
does not trust it, and the result is identical to unsigned. A free Apple ID
cannot issue a Developer ID certificate at all.

The alternatives, if the program ever lapses:

| Route | What the downloader does |
|---|---|
| Developer ID + notarisation | Double-clicks. Nothing else. |
| Ad-hoc, as before | Right-click → **Open**, once. Or one `xattr` command. |
| A Homebrew tap | `brew install --cask --no-quarantine …` |
| Build from source | Nothing — a locally built app is never quarantined. |

---

## Step 1 — Create the Developer ID certificate

Apple must have approved the enrolment first. Then, in Xcode:

**Xcode → Settings → Accounts → (your Apple ID) → Manage Certificates → `+` →
Developer ID Application**

The certificate and its private key land in the login keychain. Confirm from a
terminal:

```bash
security find-identity -v -p codesigning
```

You want a line reading `Developer ID Application: … (TEAMID)`. Before enrolment
this command printed `0 valid identities found`.

**Keep the private key.** Export it once from Keychain Access — select both the
certificate and its key, right-click → Export → `.p12` — and put it somewhere
safe. Apple will re-issue a certificate, but not the key that goes with it, and
without the key the certificate is useless.

## Step 2 — Note the Team ID

At <https://developer.apple.com/account> under Membership. Ten characters,
letters and digits. It is also the value in brackets after the certificate name
in step 1.

## Step 3 — Make an app-specific password

Notarisation authenticates as you, and Apple will not take your ordinary
password for it.

At <https://appleid.apple.com> → Sign-In and Security → App-Specific Passwords →
generate one, and label it something like `hipparchus-notary`. It is shown once.

## Step 4 — Store the credentials, once

Run this yourself. It prompts for the app-specific password from step 3 and
stores everything in the keychain, so no password ever reaches a script, a
repository or a terminal history.

```bash
xcrun notarytool store-credentials hipparchus-notary \
    --apple-id YOUR_APPLE_ID_EMAIL \
    --team-id YOUR_TEAM_ID
```

The profile name `hipparchus-notary` is what `Scripts/make-dmg.sh` looks for. If
you use a different one, pass it as `NOTARY_PROFILE=…`.

Check it took:

```bash
xcrun notarytool history --keychain-profile hipparchus-notary
```

## Step 5 — Build

Nothing to write. The script already does all of it:

```bash
bash Scripts/make-dmg.sh
```

With the certificate and the credentials in place it will:

1. Build in release and stage the app.
2. Sign the app deep, with the hardened runtime and a secure timestamp —
   notarisation rejects anything less.
3. Create the disk image, and sign the image too, so it is the image Gatekeeper
   trusts rather than only its contents.
4. Submit for notarisation and wait. Apple decides when; a few minutes is
   normal.
5. Staple the ticket into the image, so it opens on a Mac that is offline or
   behind a firewall blocking Apple's check.
6. Print `spctl`'s verdict.

The last line should read **"Signed with a Developer ID and notarised."** If it
says signed but not notarised, the submission failed and the error is above.

## Step 6 — Check it as a stranger would

```bash
spctl -a -vvv -t open --context context:primary-signature dist/Hipparchus-*.dmg
xcrun stapler validate dist/Hipparchus-*.dmg
```

`spctl` should say `accepted` with `source=Notarized Developer ID`.

For a real end-to-end test, put the image somewhere it will be *downloaded* — the
GitHub release is the honest test — fetch it in a browser on another Mac, and
double-click. Copying it over the network does not exercise quarantine and will
pass whatever you do.

## Step 7 — Replace the release asset

The asset on the release is an un-notarised build until this is done.

`<TAG>` is whatever release is current when you get here — a placeholder rather
than a number, because it was written as `v0.2.6` and the version has since moved
to 0.3.0. Check with `gh release list --repo tsevis/HipparchusMac`.

```bash
gh release delete-asset <TAG> <OLD_FILENAME>.dmg --repo tsevis/HipparchusMac --yes
gh release upload <TAG> dist/<NEW_FILENAME>.dmg --repo tsevis/HipparchusMac
```

**Then edit the release notes.** They name the file by its commit sha in the
Download line, so replacing the asset without editing them leaves an instruction
pointing at a file that no longer exists. This has happened once already.

Also worth rewriting once notarisation works: the "Before you open it" section
of both the release notes and the README's Download section currently explains
the right-click workaround. That advice becomes wrong, and telling people to
work around a warning they will not see reads as an app that cannot be trusted.

---

## If something fails

**`notarytool submit` rejects the build.** Ask for the log — it names the offending
binary:

```bash
xcrun notarytool log <SUBMISSION_ID> --keychain-profile hipparchus-notary
```

The usual causes are a missing hardened runtime, a missing secure timestamp, or a
nested binary signed with a different identity. The script passes
`--options runtime --timestamp` and signs `--deep`, so all three should be
covered; the vendored GEOS library is the thing most likely to argue.

**Gatekeeper still refuses after notarisation.** Almost always the ticket was not
stapled, or the *app* inside was stapled and not the image. Check with
`xcrun stapler validate`.

**The certificate expires.** Developer ID certificates last five years, but the
notarisation ticket does not expire and already-notarised builds keep working.
Renewal only affects new builds.

**Enrolment lapses.** Nothing already notarised stops working. New builds fall
back to ad-hoc, and `Scripts/make-dmg.sh` says so rather than failing.

---

## What not to do

- Do not put the `.p12`, the app-specific password or the Team ID in the
  repository. The script reads them from the keychain for exactly this reason.
- Do not commit `dist/`. It is gitignored.
- Do not ask an assistant to type any of these credentials. Steps 3 and 4 are
  yours; everything after step 5 is automatable.
