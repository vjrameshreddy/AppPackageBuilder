# AppPackageBuilder

Turns any payload folder into a single, self-installing **IExpress Setup.exe** — with optional self-signed code signing and automatic certificate trust on install.

---

## Repository layout

```
AppPackageBuilder\
├── Build-IExpressPackage.ps1      # Main builder script
├── Build-Package.bat              # Interactive launcher (edit config, pick build type)
├── Build-IExpressPackage-Usage.md # Full parameter reference and examples
├── Payload\                       # Application files to package
│   ├── stale_ven_gui.exe
│   ├── stale_ven_cli.exe
│   ├── run_stale_ven_cli.bat
│   └── stale_ven_docs_final.html
└── Package\                       # Created at build time — not in source control
    ├── Build\                     # Temporary work files (auto-deleted after build)
    └── Output\                    # Final deliverables
        ├── <AppName>_Setup.exe
        ├── <AppName>_Setup.cer    # (signed builds only)
        └── Trust-Certificate.ps1  # (signed builds only)
```

---

## Requirements

| Requirement | Notes |
|---|---|
| Windows 10 / 11 | x64 |
| PowerShell 5.1+ | Included in Windows 10/11 |
| `iexpress.exe` | Built into Windows at `%SystemRoot%\System32\iexpress.exe`. If missing: `DISM /Online /Add-Capability /CapabilityName:Tools.IExpress~~~~0.0.1.0` |
| Administrator rights | Required by IExpress and by the installer it produces |

---

## Quick start — interactive (recommended)

1. Open [`Build-Package.bat`](Build-Package.bat) in a text editor.
2. Edit the **USER CONFIGURATION** section at the top with your app's values.
3. Double-click `Build-Package.bat` (or run it in a terminal).
4. Pick a build type from the menu:

```
  [1]  Unsigned build
  [2]  Signed build  (sign MainExe only)
  [3]  Signed build  (sign ALL exes in payload)
  [4]  Show current configuration
  [Q]  Quit
```

The Setup EXE appears in `Package\Output\` when the build completes.

---

## Quick start — command line

**Unsigned build:**
```powershell
.\Build-IExpressPackage.ps1 `
    -PayloadDir  .\Payload `
    -AppName     'Stale VEN Reports Generation Utility' `
    -MainExe     stale_ven_gui.exe `
    -Publisher   'Illumio Tools' `
    -Version     1.0.0
```

**Signed build** (self-signed cert, auto-trusted on install):
```powershell
.\Build-IExpressPackage.ps1 `
    -PayloadDir        .\Payload `
    -AppName           'Stale VEN Reports Generation Utility' `
    -MainExe           stale_ven_gui.exe `
    -Publisher         'Illumio Tools' `
    -Version           1.0.0 `
    -Sign `
    -SignAllExes `
    -CertSubject       'CN=Illumio Tools Code Signing (Self-Signed)' `
    -CertValidityYears 10 `
    -TimestampServer   'http://timestamp.digicert.com'
```

---

## What the build produces

| File | Always? | Description |
|---|---|---|
| `Package\Output\<AppName>_Setup.exe` | ✅ | Distributable self-installing EXE |
| `Package\Output\<AppName>.SED` | ✅ | IExpress SED kept for troubleshooting |
| `Package\Output\<AppName>_Setup.cer` | Signed builds | Public certificate for manual import |
| `Package\Output\Trust-Certificate.ps1` | Signed builds | Admin helper to import the cert on machines that don't use Setup |

---

## What Setup.exe does on the target machine

1. Self-extracts to a temp folder and runs `Install.bat` → `Install.ps1`
2. *(Signed builds)* Silently imports the bundled `.cer` into `LocalMachine\Root` and `LocalMachine\TrustedPublisher`
3. Expands the payload zip and copies files to `%ProgramFiles%\<AppFolder>`
4. Creates a **Start Menu** folder named after the app with:
   - One shortcut per `.exe`, `.bat` and `.html` in the install directory
   - An **Uninstall** shortcut
5. Creates a **Desktop** shortcut for the main exe (suppressible with `-NoDesktopShortcut`)
6. Registers the app in **Settings → Installed Apps** / **Add/Remove Programs**

---

## Uninstalling

- **Start Menu** → app folder → **Uninstall \<AppName\>**
- **Settings** → **Installed Apps** → app entry → **Uninstall**

The uninstaller removes the install directory, all shortcuts, and the registry entry. The code-signing certificate is **not** removed automatically — see [Trusting the certificate](#trusting-the-certificate).

---

## Code signing

With `-Sign`, the script:

1. Finds or creates a self-signed code-signing certificate in `Cert:\CurrentUser\My` (3072-bit RSA, SHA-256, non-exportable private key)
2. Signs the payload exe(s) **before** zipping
3. Signs the final `Setup.exe` **after** IExpress finishes
4. Packs the public `.cer` into `Setup.exe` so the installer can import it automatically

> **Note:** During the build, signing status shows as `UnknownError`. This is expected — the certificate is valid but not yet trusted on the build machine. It becomes `Valid` after the certificate is imported.

> **SmartScreen:** Even with the cert imported, Windows SmartScreen may warn on first run until the publisher accumulates reputation. For production use, supply a certificate from a trusted CA via `-CertThumbprint`.

---

## Trusting the certificate

| Scenario | What to do |
|---|---|
| **Installed via Setup.exe** | Nothing — cert is imported automatically during installation |
| **Make signatures show `Valid` on the build machine** | Run `.\Trust-Certificate.ps1` once from an elevated PowerShell in `Package\Output\` |
| **Target machine without Setup** | Copy `<AppName>_Setup.cer` + `Trust-Certificate.ps1` to the target, run the script as admin |

```powershell
# From an elevated PowerShell:
cd C:\01-iExpress_source\AppPackageBuilder\Package\Output
.\Trust-Certificate.ps1
```

To **remove** the certificate: open `certlm.msc`, find the subject under both **Trusted Root Certification Authorities** and **Trusted Publishers**, and delete both entries.

---

## Key parameters

| Parameter | Default | Description |
|---|---|---|
| `-PayloadDir` | *(required)* | Folder whose contents become the installed app |
| `-AppName` | *(required)* | Human-readable name (Start Menu, Add/Remove Programs) |
| `-MainExe` | *(required)* | Primary executable file name inside `PayloadDir` |
| `-Version` | `1.0.0` | Version string for Add/Remove Programs |
| `-Publisher` | *(empty)* | Publisher name for registry and cert subject |
| `-OutputDir` | `Package\Output` | Destination for the final Setup EXE and sidecar files |
| `-WorkDir` | `Package\Build` | Temporary build folder (cleaned each run) |
| `-NoDesktopShortcut` | off | Suppress the Desktop shortcut |
| `-KeepWorkFiles` | off | Keep `WorkDir` after build for inspection |
| `-Sign` | off | Enable code signing |
| `-SignAllExes` | off | Sign every `.exe` in payload (default: `MainExe` only) |
| `-CertSubject` | `CN=<Publisher> Code Signing (Self-Signed)` | Certificate subject to find or create |
| `-CertThumbprint` | *(none)* | Use an existing cert by thumbprint |
| `-CertValidityYears` | `10` | Validity for a newly created self-signed cert |
| `-TimestampServer` | *(none)* | RFC 3161 timestamp server URL |

See [`Build-IExpressPackage-Usage.md`](Build-IExpressPackage-Usage.md) for the full reference, all examples, and troubleshooting.

---

## Files this script never modifies

`Build-IExpressPackage.ps1` is strictly additive — it never touches the source payload or any existing build artefacts:

- `Payload\*` — original files are never signed or altered; signing operates on a copy in `WorkDir\Staging\`
- Any pre-existing `Build\`, `Output\` folders at the repo root
