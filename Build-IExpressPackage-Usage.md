# Build-IExpressPackage.ps1 — Usage Guide

> **Script location:** `Build-IExpressPackage.ps1` (repo root, next to `Payload\`, `Build\` and `Output\`)
> **Requires:** Windows 10/11, PowerShell 5.1+, `iexpress.exe` (built into Windows at `%SystemRoot%\System32\iexpress.exe`)

---

## Quick-start — Stale VEN build

```powershell
.\Build-IExpressPackage.ps1 `
    -PayloadDir  .\Payload `
    -AppName     'Stale VEN Reports Generation Utility' `
    -MainExe     stale_ven_gui.exe `
    -Publisher   Illumio Tools `
    -Version     1.0.0
```

Output: `Package\Output\Stale_VEN_Reports_Generation_Utility_Setup.exe`

---

## Quick-start — Stale VEN build with signing

```powershell
.\Build-IExpressPackage.ps1 `
    -PayloadDir  .\Payload `
    -AppName     'Stale VEN Reports Generation Utility' `
    -MainExe     stale_ven_gui.exe `
    -Publisher   Illumio Tools `
    -Version     1.0.0 `
    -Sign
```

This creates a self-signed code-signing certificate (10-year validity), signs
`stale_ven_gui.exe` and the final `Setup.exe`, packs the certificate into the
Setup EXE, and imports it automatically on the target machine when Setup runs.

---

## All parameters

### Mandatory

| Parameter | Type | Description |
|---|---|---|
| `-PayloadDir` | `string` (path) | Folder whose contents become the installed application. Must exist and be non-empty. Must contain `MainExe`. |
| `-AppName` | `string` | Human-readable application name. Used for the Start Menu folder, Add/Remove Programs entry and the default `SetupName`. Characters that are invalid in file or registry names are stripped automatically. |
| `-MainExe` | `string` | File name (not path) of the primary executable inside `PayloadDir`. Used for the Desktop shortcut and (with `-Sign`) the default signing target. |

### Optional — general

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Version` | `string` | `1.0.0` | Version string written to the Add/Remove Programs registry entry (`DisplayVersion`). |
| `-Publisher` | `string` | *(empty)* | Publisher name written to the registry entry. Also used as the default certificate subject when `-Sign` is set. |
| `-OutputDir` | `string` (path) | `<script dir>\Package\Output` | Folder where the final `Setup.exe`, the `.SED`, the `.cer` and the trust helper are written. Created if absent. **Never** points at the existing `Output\` folder. |
| `-WorkDir` | `string` (path) | `<script dir>\Package\Build` | Temporary build folder. Cleaned at the start of each run. Created if absent. **Never** points at the existing `Build\` folder. |
| `-SetupName` | `string` | `<SafeAppName>_Setup.exe` | File name of the produced Setup EXE. Must end in `.exe`. |
| `-InstallScope` | `Machine` \| `User` | `Machine` | `Machine` installs to `%ProgramFiles%` and uses `HKLM`. `User` installs to `%LOCALAPPDATA%\Programs` and uses `HKCU`. (Machine is the current behaviour.) |

### Optional — switches

| Switch | Description |
|---|---|
| `-NoDesktopShortcut` | Suppress the Desktop shortcut for the main exe. Start Menu shortcuts are unaffected. |
| `-KeepWorkFiles` | Do not delete `WorkDir` after a successful build. Useful for inspecting the generated `Install.ps1`, `Uninstall.ps1`, `Install.bat` and `.SED`. |

### Optional — signing (only active when `-Sign` is present)

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Sign` | switch | off | Enable code signing. All signing parameters below are ignored unless this switch is present. |
| `-SignAllExes` | switch | off | Sign every `.exe` in `PayloadDir` before zipping. Default signs only `MainExe`. |
| `-CertSubject` | `string` | `CN=<Publisher> Code Signing (Self-Signed)` | Subject of the code-signing certificate to find or create. |
| `-CertThumbprint` | `string` | *(none)* | Thumbprint of an existing certificate in `Cert:\CurrentUser\My`. When provided, the script uses that certificate instead of finding or creating one by subject. |
| `-CertValidityYears` | `int` | `10` | Validity period in years for a newly created self-signed certificate. Ignored when an existing certificate is found or `-CertThumbprint` is supplied. |
| `-TimestampServer` | `string` | *(none)* | HTTPS URL of an RFC 3161 timestamp server (e.g. `http://timestamp.digicert.com`). If omitted, no timestamp is added to the signature. |

---

## What happens when you run the script

```
1. Validate parameters and locate iexpress.exe
2. Create clean WorkDir and OutputDir
3. [if -Sign] Find or create the code-signing certificate
                Export .cer → WorkDir\  and  OutputDir\
4. Stage payload to WorkDir\Staging\
   [if -Sign] Sign MainExe (and all .exe if -SignAllExes) in Staging\
5. Compress-Archive Staging\* → WorkDir\payload.zip
   Verify payload.zip contains MainExe
6. Generate WorkDir\Install.ps1   (installer template with embedded constants)
7. Generate WorkDir\Uninstall.ps1 + Uninstall.bat
8. Generate WorkDir\Install.bat   (IExpress wrapper)
9. Generate WorkDir\<AppName>.SED
   [if -Sign] adds .cer as a packed file in the SED
10. Run: iexpress.exe /N /Q WorkDir\<AppName>.SED
    Poll until OutputDir\<SetupName> appears
11. [if -Sign] Sign OutputDir\<SetupName>
               Verify signature status
               Write OutputDir\Trust-Certificate.ps1
12. Print build summary (path, size, signing status)
13. [unless -KeepWorkFiles] Delete WorkDir
```

---

## What the generated Setup.exe does when run on the target machine

```
1. IExpress self-extracts to a temp folder
2. cmd.exe /c Install.bat  →  powershell.exe … Install.ps1
3. [if signed build] Import .cer into LocalMachine\Root
                                    and LocalMachine\TrustedPublisher  (silent, already elevated)
4. Expand payload.zip into staging temp folder
5. Remove previous installation if present (clean upgrade)
6. Copy files to %ProgramFiles%\<AppFolder>
7. Create Start Menu folder "<AppName>" with shortcuts:
     • One shortcut per .exe, .bat and .html in the install dir
     • Uninstall <AppName>
8. Create Desktop shortcut for MainExe  (unless -NoDesktopShortcut was set at build time)
9. Write %ProgramData%\<SafeAppName>\Uninstall.ps1
                                      Uninstall.bat
10. Register HKLM\…\Uninstall\<SafeAppName> with:
      DisplayName, DisplayVersion, Publisher, InstallLocation,
      DisplayIcon, UninstallString, QuietUninstallString,
      EstimatedSize, NoModify=1, NoRepair=1
11. Log → %TEMP%\<SafeAppName>_install.log
12. Clean up temp extraction folder
```

---

## What the uninstaller does

Triggered from:
- **Start Menu** → `<AppName>` → **Uninstall Stale VEN Reports Generation Utility**
- **Settings** → **Installed Apps** → app entry → **Uninstall**
- `Add/Remove Programs` — double-click the entry

```
1. Self-elevate (UAC prompt)
2. Prompt for confirmation  (skipped if /quiet is passed)
3. Stop any running process from the install dir  (with warning)
4. Remove %ProgramFiles%\<AppFolder>\
5. Remove Start Menu folder and all shortcuts
6. Remove Desktop shortcut
7. Remove HKLM\…\Uninstall\<SafeAppName>
8. Copy Uninstall.ps1 to %TEMP% and schedule deferred deletion of %ProgramData%\<SafeAppName>\
9. [if signed build] Print notice:
     "The code-signing certificate was NOT removed automatically.
      To remove it, open certlm.msc and delete '<CertSubject>'
      from Trusted Root Certification Authorities and Trusted Publishers."
```

---

## Output files in `OutputDir`

| File | Always? | Description |
|---|---|---|
| `<SetupName>.exe` | ✅ | The distributable Setup EXE. |
| `<AppName>.SED` | ✅ | IExpress SED file kept for troubleshooting. |
| `<SetupName>.cer` | With `-Sign` | Public certificate for manual import on machines that do not use Setup. |
| `Trust-Certificate.ps1` | With `-Sign` | Helper that imports the `.cer` into `LocalMachine\Root` and `LocalMachine\TrustedPublisher`. Run as admin on the target machine. **Never run automatically.** |

---

## Signing — key facts

| Fact | Detail |
|---|---|
| What gets signed | `MainExe` in the zip (default) or all payload `.exe` files (`-SignAllExes`). Always: the final `Setup.exe`. |
| When signing happens | Payload exes: **before** zipping (sign → zip). Setup EXE: **after** IExpress finishes (IExpress → sign). |
| Original `PayloadDir` | **Never modified.** Signing operates on a copy in `WorkDir\Staging\`. |
| Certificate created | Only if no valid, unexpired cert matching the subject/thumbprint exists in `Cert:\CurrentUser\My`. |
| Private key | Non-exportable, stays in `Cert:\CurrentUser\My`. Never written to disk. |
| Status after signing | `Valid` (chain trusted) or `UnknownError` (self-signed root not yet imported). Both are acceptable during build. Any other status fails the build. |
| SmartScreen | Even with the cert imported, SmartScreen may warn on first run if the publisher has no reputation. For production, use a certificate from a trusted CA with `-CertThumbprint`. |
| Cert not removed on uninstall | The cert may be shared with other apps from the same publisher. A manual removal notice is printed instead. |

---

## Examples

### Minimal — no signing, no desktop shortcut

```powershell
.\Build-IExpressPackage.ps1 `
    -PayloadDir        C:\MyApp\dist `
    -AppName           'My Application' `
    -MainExe           myapp.exe `
    -Version           2.3.1 `
    -Publisher         'Acme Corp' `
    -NoDesktopShortcut
```

### Custom output location, keep work files for inspection

```powershell
.\Build-IExpressPackage.ps1 `
    -PayloadDir  .\Payload `
    -AppName     'Stale VEN Reports Generation Utility' `
    -MainExe     stale_ven_gui.exe `
    -Publisher   Illumio Tools `
    -Version     1.0.0 `
    -OutputDir   D:\Releases\StaleVEN `
    -WorkDir     D:\Releases\StaleVEN_Build `
    -KeepWorkFiles
```

### Full signed build, sign all exes, custom cert subject, timestamp

```powershell
.\Build-IExpressPackage.ps1 `
    -PayloadDir       .\Payload `
    -AppName          'Stale VEN Reports Generation Utility' `
    -MainExe          stale_ven_gui.exe `
    -Publisher        Illumio Tools `
    -Version          1.0.0 `
    -Sign `
    -SignAllExes `
    -CertSubject      'CN=Illumio Tools Code Signing (Self-Signed)' `
    -CertValidityYears 10 `
    -TimestampServer  http://timestamp.digicert.com
```

### Use an existing certificate by thumbprint

```powershell
.\Build-IExpressPackage.ps1 `
    -PayloadDir      .\Payload `
    -AppName         'Stale VEN Reports Generation Utility' `
    -MainExe         stale_ven_gui.exe `
    -Publisher       Illumio Tools `
    -Version         1.0.0 `
    -Sign `
    -CertThumbprint  '3A7F9B2C1D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A'
```

---

## Trusting the certificate on a target machine

This only applies to signed builds (`-Sign`).  The relevant output files are:

| File | Purpose |
|---|---|
| `<SetupName>.cer` | The public certificate (no private key). Distribute alongside Setup or separately. |
| `Trust-Certificate.ps1` | Admin script that imports the `.cer` into the local machine trust stores. |

### Scenario 1 — Installing via Setup.exe (normal case)

Run `Setup.exe` as usual.  The certificate is silently imported into
`LocalMachine\Root` and `LocalMachine\TrustedPublisher` at the very start of
the installation, before any files are copied.  No extra step is needed.

After Setup completes, `Get-AuthenticodeSignature stale_ven_gui.exe` will
return `Status: Valid` on that machine.

### Scenario 2 — Trusting the cert on the build machine (optional)

During the build you will see:

```
[OK]  stale_ven_gui.exe -> UnknownError
```

`UnknownError` is expected and harmless — it means the certificate is
structurally valid but the build machine has not imported it into its own
trust store yet (the cert was just created).  The signed files are correct;
they just show as untrusted locally until the cert is imported.

To make signatures show as `Valid` on the build machine too, run once from
an elevated PowerShell in `Package\Output\`:

```powershell
# From an elevated PowerShell:
cd C:\01-iExpress_source\AppPackageBuilder\Package\Output
.\Trust-Certificate.ps1
```

The script will show what it is about to import and ask for confirmation:

```
This will import the following certificate into the local machine trust stores:
  File    : C:\...\Stale_VEN_Reports_Generation_Utility_Setup.cer
  Subject : CN=Illumio Tools Code Signing (Self-Signed)
  Stores  : LocalMachine\Root, LocalMachine\TrustedPublisher

Continue? [Y/N]: Y
Certificate imported successfully.
Files signed with this certificate will now show as trusted on this machine.
```

After this, `Get-AuthenticodeSignature stale_ven_gui.exe` on this machine will
return `Status: Valid` instead of `UnknownError`.

### Scenario 3 — Manual trust on a target machine (no Setup)

For machines that receive the app files without going through Setup.exe (for
example, a developer copying the installed folder manually), copy both files
to the same folder on the target machine and run from an elevated PowerShell:

```powershell
# Both files must be in the same folder:
#   Stale_VEN_Reports_Generation_Utility_Setup.cer
#   Trust-Certificate.ps1

# From an elevated PowerShell on the target machine:
cd "C:\path\where\you\put\the\files"
.\Trust-Certificate.ps1
```

### Alternative — certlm.msc (manual, no script)

1. Open `certlm.msc` (Local Machine certificate store).
2. Expand **Trusted Root Certification Authorities** → **Certificates**.
3. Right-click → **All Tasks** → **Import** → select the `.cer` file.
4. Repeat under **Trusted Publishers**.

### Removing the certificate

The uninstaller does **not** remove the certificate — it may be shared with
other apps signed by the same publisher.  To remove it manually:

1. Open `certlm.msc`.
2. Find `CN=Illumio Tools Code Signing (Self-Signed)` under both:
   - **Trusted Root Certification Authorities** → **Certificates**
   - **Trusted Publishers** → **Certificates**
3. Delete both entries.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `iexpress.exe not found` | Missing from `%SystemRoot%\System32`. Can happen on N editions. | Run `DISM /Online /Add-Capability /CapabilityName:Tools.IExpress~~~~0.0.1.0` or copy from another Windows install. |
| `MainExe not found in PayloadDir` | Wrong file name or wrong folder. | Check `-MainExe` matches the exact file name inside `-PayloadDir`. |
| `Setup.exe not created after IExpress` | IExpress silently failed. Use `-KeepWorkFiles` and open the `.SED` in IExpress GUI to see the error. | Inspect the generated `.SED` in `OutputDir`. |
| Signature status `NotSigned` after signing | `Set-AuthenticodeSignature` failed (often a permission or policy issue). | Check that the signing certificate is in `Cert:\CurrentUser\My` and that the process is not blocked by AppLocker or WDAC. |
| SmartScreen still warns after install | Self-signed cert imported but publisher has no SmartScreen reputation. | Expected behaviour for self-signed certs. Use a commercial CA cert for production. |
| Uninstall leaves files behind | A process is still running from the install dir. | Close the application before uninstalling, or run with `/quiet` which skips the confirmation but still warns about running processes. |

---

## Files this script does NOT touch

The following existing files are **never modified** by `Build-IExpressPackage.ps1`:

- `prepare-zip.ps1`
- `Build\install.ps1`
- `Build\install.bat`
- `Build\Stale_VEN.zip`
- `Output\Stale_VEN_Reports_Generation_Utility.SED`
- `Output\Stale_VEN_Reports_Generation_Utility_Setup.exe`
- `Payload\*`

All generated artefacts go to `Package\Build\` (WorkDir) and `Package\Output\` (OutputDir) by default.
