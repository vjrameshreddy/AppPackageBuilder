# IExpress Package Builder – Plan

> **Usage guide:** [`Build-IExpressPackage-Usage.md`](Build-IExpressPackage-Usage.md) — full parameter reference, examples, signing notes and troubleshooting.

## Top-Level Overview

**Goal:** One reusable, parameterized PowerShell script, `Build-IExpressPackage.ps1`, that turns any payload folder into a single IExpress `Setup.exe`. The setup installs the app, creates shortcuts, and registers an uninstaller.

**Existing project (analysed):**
- [`prepare-zip.ps1`](prepare-zip.ps1) – hard-coded paths. Zips `Payload\*` to `Build\Stale_VEN.zip` and checks that `stale_ven_gui.exe` is in the zip.
- [`Build/install.ps1`](Build/install.ps1) – the installer.
  - Self-elevates, expands the zip to a temp folder and copies it to `%ProgramFiles%\Stale_VEN_Reports_Generation_Utility`.
  - Writes `Uninstall.ps1` and `Uninstall.bat` into `%ProgramData%`.
  - Creates ONE shortcut (GUI exe) on the common Desktop and in the Start Menu.
  - Registers `HKLM\...\Uninstall\<key>` with `NoModify` and `NoRepair`.
  - App name, folder, exe and version are all hard-coded.
- [`Build/install.bat`](Build/install.bat) – wrapper that checks files, runs `Install.ps1` with logging, and pauses on failure.
- [`Output/Stale_VEN_Reports_Generation_Utility.SED`](Output/Stale_VEN_Reports_Generation_Utility.SED) – hand-made IExpress SED. Packs `Install.bat`, `Install.ps1` and `Stale_VEN.zip`. `AppLaunched=cmd.exe /c Install.bat`. Uses absolute paths.
- Payload: `stale_ven_gui.exe`, `stale_ven_cli.exe`, `run_stale_ven_cli.bat`, `stale_ven_docs_final.html`.

**Gaps the new script closes:**
1. The Start Menu gets only one shortcut. It should get all exe, html and bat files plus an Uninstall shortcut.
2. The uninstaller is only reachable through Add/Remove Programs. It also needs a Start Menu shortcut.
3. Everything is hard-coded, so the tooling cannot be reused for another app.
4. Building is manual: zip, then hand-edit the SED, then run IExpress.
5. `install.bat` hard-codes names and logs. The temp zip is not cleaned up if the build fails.

**Decisions confirmed with user:**
- The Setup EXE has no menu. It always installs. Uninstall is only through the Start Menu shortcut and Add/Remove Programs.
- Start Menu folder, named after the app: a shortcut for every `.exe`, `.html` and `.bat` in the payload, plus an **Uninstall** shortcut.
- Desktop: only the main-exe shortcut.
- Deliverable: one end-to-end script. It zips the payload, generates the installer, uninstaller and wrapper, generates the SED, and runs `iexpress.exe`. Parameterized. Existing scripts and folders are left untouched.

**Approach:** The builder script holds the installer and uninstaller as here-string templates. It substitutes parameters into them, writes them to a fresh build folder, and then calls IExpress. The generated installer is self-contained and reads its settings from a small `package.json` or embedded constants. This avoids a second script that must be kept in sync.

**Proposed parameters:**
- `-PayloadDir` (mandatory)
- `-AppName`
- `-MainExe`
- `-Version` (default `1.0.0`)
- `-Publisher`
- `-OutputDir` (default `<script dir>\Package\Output`)
- `-WorkDir` (default `<script dir>\Package\Build`)
- `-SetupName` (default `<AppName>_Setup.exe`)
- `-InstallScope` (`Machine` default, i.e. Program Files and HKLM)
- Switches:
  - `-NoDesktopShortcut`
  - `-KeepWorkFiles`
  - `-Sign` and its related signing parameters (see sub-task 7)

## Sub-Tasks

### 1. Builder script skeleton, parameters and validation
- **Intent:** Create the reusable entry point with safe defaults. Nothing hard-coded to Stale VEN, except the example invocation.
- **Expected Outcomes:** `Build-IExpressPackage.ps1` runs with `-PayloadDir` and `-MainExe` and fails with clear messages when inputs are bad.
- **Todo List:**
  1. Add the param block with validation (`ValidateScript` on the paths, `ValidatePattern` on the names).
  2. Derive the safe folder or registry key name from `AppName` (strip invalid file-name characters).
  3. Locate `iexpress.exe` in `$env:SystemRoot\System32`; fail if missing.
  4. Verify the payload is non-empty and contains `MainExe`.
  5. Create a clean `WorkDir` and `OutputDir` separate from the existing `Build` and `Output` folders.
- **Relevant Context:** The checks in [`prepare-zip.ps1`](prepare-zip.ps1) (lines 10-19, 41-52) are generalized here.
- **Status:** `[ ] pending`

### 2. Payload zipping
- **Intent:** Package the payload as a single zip that the installer extracts.
- **Expected Outcomes:** `<WorkDir>\payload.zip` with files at the zip root, including subfolders. The zip is verified to contain `MainExe`.
- **Todo List:**
  1. `Compress-Archive` of `PayloadDir\*`.
  2. Open the archive with `System.IO.Compression.ZipFile` and check `MainExe`.
  3. Fail the whole build on error. The existing script swallows errors, so avoid that.
- **Relevant Context:** [`prepare-zip.ps1`](prepare-zip.ps1).
- **Status:** `[ ] pending`

### 3. Generated installer (`Install.ps1`)
- **Intent:** Parameterized install with full shortcut set, automatic certificate trust (when signed), and uninstall registration.
- **Expected Outcomes:** After setup, the files are in `%ProgramFiles%\<AppFolder>`. The Start Menu folder `<AppName>` holds a shortcut per `.exe`, `.html` and `.bat` (recursive over the installed payload), plus **Uninstall <AppName>**. The Desktop has only the main-exe shortcut. The app appears in Installed Apps. When the build used `-Sign`, the certificate is silently imported into `LocalMachine\Root` and `LocalMachine\TrustedPublisher` at the start of the install (already elevated — no extra UAC prompt).
- **Todo List:**
  1. Keep the elevation, zip extraction and staging-with-cleanup logic from [`Build/install.ps1`](Build/install.ps1).
  2. **Certificate import step (only when `-Sign` was used at build time):** At the top of the install sequence, import the bundled `.cer` file (packed alongside the installer by sub-task 5) into `Cert:\LocalMachine\Root` and `Cert:\LocalMachine\TrustedPublisher` using `Import-Certificate`. The builder embeds a `$InstallCert = $true/$false` constant in the generated script so no extra parameter is needed at runtime.
  3. Remove any previous installation before copying, so reinstall or upgrade is clean.
  4. Enumerate `.exe`, `.html` and `.bat` in the installed folder. Shortcut names come from the file base name, tidied and made unique. The main exe gets the app name.
     - `.exe` and `.bat`: target the file.
     - `.html`: target the file, so the default browser opens it.
     - Working directory: the install dir for exe. For `.bat`, decide in the validation step (the bat in [`Payload/run_stale_ven_cli.bat`](Payload/run_stale_ven_cli.bat) uses a relative `INPUT_FILE`).
  5. Desktop shortcut for the main exe only (skipped with `-NoDesktopShortcut`).
  6. Write the uninstaller (sub-task 4) and create the Start Menu **Uninstall** shortcut. Target: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Uninstall.ps1`, window style normal.
  7. Write the Add/Remove Programs registry entry: DisplayName, DisplayVersion, Publisher, InstallLocation, DisplayIcon, UninstallString, EstimatedSize, NoModify and NoRepair.
  8. Log to a file in `%TEMP%`. Return exit code 0 on success, non-zero on failure.
- **Relevant Context:** Shortcut and registry blocks in [`Build/install.ps1`](Build/install.ps1) lines 189-241.
- **Status:** `[ ] pending`

### 4. Generated uninstaller (`Uninstall.ps1` and `Uninstall.bat`)
- **Intent:** Complete removal. This fixes the existing uninstaller, which leaves its support files behind and only removes two known shortcuts.
- **Expected Outcomes:** Running the Start Menu **Uninstall** shortcut, or Add/Remove Programs, removes the install dir, the whole Start Menu folder (all shortcuts), the Desktop shortcut, the registry key and the support folder. The certificate is **not** removed automatically (it may be shared with other software from the same publisher); a notice is printed instead.
- **Todo List:**
  1. Self-elevate.
  2. Confirm with a prompt unless `/quiet` is passed. Add/Remove Programs can pass `/quiet` through `QuietUninstallString`.
  3. Remove the shortcuts, install dir and registry key.
  4. Delete the support folder through a deferred step, because a script cannot delete itself while running (for example, copy itself to `%TEMP%` and run from there, or use a `cmd /c ping ... & rmdir` trailer).
  5. Handle the case where an app process is running from the install dir (warn, or stop it).
  6. Print a notice: *"The code-signing certificate was not removed. To remove it, open certlm.msc and delete the '<Subject>' certificate from Trusted Root Certification Authorities and Trusted Publishers."* (only when `$InstallCert = $true`).
- **Relevant Context:** The embedded uninstaller in [`Build/install.ps1`](Build/install.ps1) lines 122-179.
- **Status:** `[ ] pending`

### 5. Wrapper (`Install.bat`) and SED generation
- **Intent:** Generate everything IExpress needs, with no hand-edited paths.
- **Expected Outcomes:** A generated SED with `AppLaunched=cmd.exe /c Install.bat`. Source files are `Install.bat`, `Install.ps1`, `payload.zip`, and — when `-Sign` was used — the exported `.cer` file (four files total). `TargetName` in `OutputDir`. `FriendlyName` and `FinishMessage` built from `AppName`.
- **Todo List:**
  1. Generate `Install.bat` from the template in [`Build/install.bat`](Build/install.bat). Remove the hard-coded "Stale VEN" log names and use the safe app name. Keep the pause on error.
  2. Write the SED in the format of [`Output/*.SED`](Output/Stale_VEN_Reports_Generation_Utility.SED) (`PackagePurpose=InstallApp`, `SourceFiles`, `[Strings]`, `FILEn`). Use `WorkDir` as the source. When `-Sign` was used, include the `.cer` file as an additional `FILEn` entry so IExpress packs it into the Setup EXE.
  3. Keep the `.SED` in `OutputDir` for troubleshooting.
- **Relevant Context:** Existing SED and bat files.
- **Status:** `[ ] pending`

### 6. Run IExpress and verify
- **Intent:** Produce the final Setup EXE and confirm the build.
- **Expected Outcomes:** `<OutputDir>\<SetupName>` exists, is non-zero, and its size and path are printed. The script returns a non-zero exit code on failure. Temp files are cleaned unless `-KeepWorkFiles` is set.
- **Todo List:**
  1. Run `iexpress.exe /N /Q <sed>` with `Start-Process -Wait`.
  2. Poll for or verify the output EXE, because IExpress returns early and its exit code is unreliable.
  3. Print a summary and clean up.
- **Relevant Context:** None in the repo. IExpress CLI behaviour needs checking while implementing.
- **Status:** `[ ] pending`

### 7. Code signing (self-signed, automatic trust on install)
- **Intent:** Sign the main exe, optionally the other payload exes, and the final Setup EXE. Pack the certificate into the Setup EXE and import it automatically on the target machine during installation, so the installed files are trusted from first run. Also produce a `Trust-Certificate.ps1` for machines that receive the app without going through Setup.
- **Expected Outcomes:** With `-Sign`:
  - The main exe (and optionally all payload exes) are signed before zipping.
  - The Setup EXE is signed after IExpress finishes.
  - A `.cer` (public key only) is exported to `OutputDir` and packed into the Setup EXE.
  - During installation, the `.cer` is silently imported into `LocalMachine\Root` and `LocalMachine\TrustedPublisher` (already elevated — no extra UAC prompt). The installed files show `Status = Valid` in PowerShell and in Explorer.
  - A `Trust-Certificate.ps1` is written to `OutputDir` for manual use on machines that do not go through Setup.
  - Without `-Sign` the build behaves as in sub-tasks 1-6.
- **Todo List:**
  1. Add parameters:
     - `-Sign` (switch)
     - `-SignAllExes` (switch, default signs only `MainExe`)
     - `-CertSubject` (default `CN=<Publisher> Code Signing (Self-Signed)`)
     - `-CertThumbprint` (use an existing certificate instead of creating one)
     - `-CertValidityYears` (default 10)
     - `-TimestampServer` (optional, HTTPS only)
  2. Certificate helper:
     - Look in `Cert:\CurrentUser\My` for a valid, unexpired code-signing certificate that matches the subject or thumbprint.
     - Otherwise create one with `New-SelfSignedCertificate -Type CodeSigningCert -CertStoreLocation Cert:\CurrentUser\My`. Use a key of at least 3072 bits, RSA with SHA256, and a non-exportable key.
     - Export the public part only, as `<SetupName>.cer`, to `WorkDir` (so it can be packed by IExpress) **and** to `OutputDir` (for manual distribution). Use `Export-Certificate`.
  3. Sign step before zipping: copy the payload to `WorkDir\Staging\` so the original `PayloadDir` is never modified. Run `Set-AuthenticodeSignature -HashAlgorithm SHA256` on the target exes in `Staging\`. Zip from `Staging\`. Fail the build if any signature status is not `Valid` or `UnknownError`.
  4. Sign step after IExpress: sign the Setup EXE the same way. Verify with `Get-AuthenticodeSignature`.
  5. Embed the cert flag in the generated `Install.ps1`: the builder writes `$InstallCert = $true` (or `$false`) into the script so the installer knows at runtime whether to import the certificate. The `.cer` file name is also embedded as a constant.
  6. Trust helper: write `Trust-Certificate.ps1` to `OutputDir`. It imports the `.cer` into `LocalMachine\Root` and `LocalMachine\TrustedPublisher`, requires admin, and prompts for confirmation before proceeding. It is **never run automatically** on the build machine.
  7. Print the signing summary, thumbprint and expiry. Warn that the certificate is self-signed and for internal testing only.
- **Relevant Context:** Integrates into sub-task 2 (sign before zip), sub-task 3 (cert import in installer), sub-task 5 (pack `.cer` in SED), and sub-task 6 (sign after IExpress). The existing flow in [`prepare-zip.ps1`](prepare-zip.ps1) has no signing.
- **Status:** `[ ] pending`

### 8. Test run and usage notes
- **Intent:** Prove it works for Stale VEN and for a second sample payload, without touching the existing files.
- **Expected Outcomes:** A usage example is in the script's comment-based help. A Stale VEN invocation gives a working Setup EXE.
- **Todo List:**
  1. ~~Add comment-based help with the Stale VEN example~~ — **done in pre-implementation:** full usage guide written to [`Build-IExpressPackage-Usage.md`](Build-IExpressPackage-Usage.md). Distil that into `Get-Help`-compatible `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` and `.EXAMPLE` blocks inside the script during implementation.
  2. Run the build and check the zip, the SED and the Setup EXE.
  3. If an elevated test is possible, install, then check the shortcuts, registry entry and uninstall. Otherwise give the user a manual checklist.
  4. Confirm that [`prepare-zip.ps1`](prepare-zip.ps1), `Build\` and `Output\` are unchanged.
- **Status:** `[ ] pending`

## Open Points for Validation
- Working directory for `.bat` shortcuts (install dir, or the user's Documents folder). The Stale VEN batch file reads its input CSV relatively and writes to `%userprofile%`.
- The Stale VEN batch file hard-codes `OneDrive - IBM\Documents`. It is out of scope and left unchanged.
- Machine-wide install (Program Files, HKLM, common Desktop and Start Menu) as in the current installer, kept as the default.
- Setup EXE needs admin rights and shows a UAC prompt (current behaviour).
- Security notes for implementation: the script does not change execution policy persistently (`-ExecutionPolicy Bypass` is process-scoped, as now). The payload is trusted local input.
- Signing is self-signed and for internal testing only. Even with the cert imported, Windows Defender SmartScreen may still warn on first run for an unknown publisher reputation. Production use needs a certificate from a trusted CA (which `-CertThumbprint` supports) combined with EV signing or sufficient SmartScreen reputation.
- The private key stays in the local certificate store and is non-exportable. No passwords or keys are written to the repo, the SED or the logs.
- Signing a zipped exe changes its hash, so signing must run before zipping. The final Setup EXE is signed after IExpress finishes.
- The certificate is **not** removed by the uninstaller. It may be shared with other software from the same publisher. A notice with instructions to remove it via `certlm.msc` is printed instead.
- The `.cer` is exported to both `WorkDir` (for IExpress to pack) and `OutputDir` (for manual distribution). Only the public key is exported — the private key is non-exportable and stays in `Cert:\CurrentUser\My`.
