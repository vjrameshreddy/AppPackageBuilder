# IExpress Package Builder — Plan & Architecture Record

> **Maintenance rule:** Update this document whenever a design decision changes,
> a feature is added/modified/removed, a significant bug is found, or a security
> fix is applied.  Cross-reference `RELEASE-NOTES.md` for the full change log.
>
> **Related files:**
> - [`README.md`](README.md) — project overview and quick start
> - [`Build-IExpressPackage-Usage.md`](Build-IExpressPackage-Usage.md) — full parameter reference, examples, troubleshooting
> - [`RELEASE-NOTES.md`](RELEASE-NOTES.md) — version history and security assessment

---

## Current version: 1.1.0 (2026-10-16)

---

## 1. Goal

One reusable, parameterized PowerShell script — `Build-IExpressPackage.ps1` — that turns any payload folder into a single IExpress `Setup.exe`.  The setup installs the app, creates shortcuts, registers an uninstaller, and (optionally) signs all executables and imports a code-signing certificate automatically on the target machine.

**Status: ✅ Fully implemented and verified.**

---

## 2. Origin — existing hard-coded project (analysed, now superseded)

The following files existed before this tooling and were the basis for analysis.  They are **never modified** by the new scripts.

| File | What it did |
|---|---|
| `prepare-zip.ps1` | Hard-coded zip of `Payload\*` → `Build\Stale_VEN.zip`; verified `stale_ven_gui.exe` in zip |
| `Build\install.ps1` | Self-elevating installer; hard-coded app name, folder, exe, version; one Desktop + one Start Menu shortcut |
| `Build\install.bat` | Wrapper: file checks, runs `Install.ps1` with logging, pauses on failure |
| `Output\Stale_VEN_Reports_Generation_Utility.SED` | Hand-crafted IExpress SED; absolute paths; three files packed |
| `Payload\*` | `stale_ven_gui.exe`, `stale_ven_cli.exe`, `run_stale_ven_cli.bat`, `stale_ven_docs_final.html` |

**Gaps closed by the new tooling:**
1. Start Menu got only one shortcut → now gets one per `.exe`, `.bat`, `.html` + Uninstall shortcut
2. Uninstaller reachable only from Add/Remove Programs → now also has a Start Menu shortcut
3. Everything hard-coded → fully parameterized
4. Manual build process → single script end-to-end
5. Temp zip not cleaned up on failure → strict `finally` cleanup throughout

---

## 3. Repository layout

```
AppPackageBuilder\
├── Build-IExpressPackage.ps1      ← main builder (parameterized, reusable)
├── Build-Package.bat              ← interactive launcher with 4-option menu
├── Build-IExpressPackage-Usage.md ← full parameter reference and examples
├── RELEASE-NOTES.md               ← version history and security log
├── README.md                      ← project overview and quick start
├── iexpress-package-builder-plan.md  ← this file
├── .gitignore                     ← excludes Package\ from source control
├── Payload\                       ← application files to package
└── Package\                       ← generated at build time (excluded from git)
    ├── Build\                     ← temp work folder (auto-deleted after build)
    └── Output\                    ← final deliverables
```

---

## 4. Parameters (implemented)

### Mandatory

| Parameter | Validation | Description |
|---|---|---|
| `-PayloadDir` | `ValidateScript { Test-Path $_ -PathType Container }` | Folder whose contents become the installed application |
| `-AppName` | `ValidateNotNullOrEmpty` | Human-readable app name; invalid file-system chars stripped to derive `$SafeName` |
| `-MainExe` | `ValidateNotNullOrEmpty` + no path separators (SEC-001) | File name of the primary exe inside `PayloadDir` |

### Optional — general

| Parameter | Default | Validation | Description |
|---|---|---|---|
| `-Version` | `1.0.0` | `ValidatePattern '^\d+(\.\d+){0,3}$'` | Version string for Add/Remove Programs |
| `-Publisher` | *(empty)* | — | Publisher name for registry and cert subject |
| `-OutputDir` | `<script dir>\Package\Output` | — | Destination for Setup EXE and sidecar files |
| `-WorkDir` | `<script dir>\Package\Build` | — | Temporary build folder; cleaned at run start |
| `-SetupName` | `<SafeName>_Setup.exe` | No path separators + `.exe` suffix (SEC-007) | Output EXE file name |
| `-InstallScope` | `Machine` | `ValidateSet 'Machine','User'` | Program Files / HKLM vs LOCALAPPDATA / HKCU |
| `-NoDesktopShortcut` | off | switch | Suppress Desktop shortcut for main exe |
| `-KeepWorkFiles` | off | switch | Do not delete `WorkDir` after successful build |

### Optional — signing

| Parameter | Default | Validation | Description |
|---|---|---|---|
| `-Sign` | off | switch | Enable code signing |
| `-SignAllExes` | off | switch | Sign every `.exe` in payload (default: `MainExe` only) |
| `-CertSubject` | `CN=<Publisher> Code Signing (Self-Signed)` | — | Cert subject to find or create |
| `-CertThumbprint` | *(none)* | — | Thumbprint of existing cert in `Cert:\CurrentUser\My` |
| `-CertValidityYears` | `10` | `ValidateRange(1, 30)` (SEC-005) | Validity years for new self-signed cert |
| `-TimestampServer` | *(none)* | Must start with `https://` (SEC-004) | RFC 3161 timestamp server URL |

---

## 5. Architecture — build pipeline

```
PayloadDir
    │
    ▼  [if -Sign] resolve/create cert → export .cer to WorkDir + OutputDir
    │
    ▼  copy PayloadDir → WorkDir\Staging\
       [if -Sign] sign exes in Staging\
    │
    ▼  Compress-Archive Staging\* → WorkDir\payload.zip
       verify zip contains MainExe
    │
    ▼  generate WorkDir\Uninstall.ps1  (embedded constants)
       generate WorkDir\Uninstall.bat
    │
    ▼  generate WorkDir\Install.ps1   (embedded constants)
    │
    ▼  generate WorkDir\Install.bat   (IExpress launcher wrapper)
    │
    ▼  generate WorkDir\<SafeName>.SED
       copy SED → OutputDir\<SafeName>.SED  (for troubleshooting)
    │
    ▼  delete OutputDir\<SetupName>.exe if exists  (IExpress can't overwrite)
       & iexpress.exe /N /Q WorkDir\<SafeName>.SED
       poll for OutputDir\<SetupName>.exe size stability (up to 3 min)
    │
    ▼  [if -Sign] sign OutputDir\<SetupName>.exe
       write OutputDir\Trust-Certificate.ps1
    │
    ▼  print BUILD COMPLETE summary
       [unless -KeepWorkFiles] delete WorkDir
```

---

## 6. Sub-tasks — status

### Sub-task 1 — Builder script skeleton, parameters and validation ✅

**Implemented:**
- Param block with full validation (see §4)
- `$SafeName` derived from `AppName` by stripping non-word chars and replacing spaces with `_`
- `iexpress.exe` located at `$env:SystemRoot\System32\iexpress.exe`; fails with DISM install hint if missing
- Payload non-empty check and `MainExe`-in-payload check
- `WorkDir` cleaned and recreated on every run; `OutputDir` created if absent
- `WorkDir`, `OutputDir` resolved to absolute paths and checked against each other and `PayloadDir` (SEC-008)
- `$ErrorActionPreference = 'Stop'` and `Set-StrictMode -Version Latest` throughout
- Single-quote escape for `AppName`, `Publisher`, `CertSubject` before embedding into generated scripts (SEC-003)

**Design decision — `$SafeName`:**
Derived once at builder level and embedded as a constant in all generated scripts.  This ensures the registry key, install folder, SED name, and shortcut names are all consistent and contain no characters that could cause problems in paths or registry keys.

---

### Sub-task 2 — Payload staging and zipping ✅

**Implemented:**
- Payload copied to `WorkDir\Staging\` (original `PayloadDir` never touched)
- `[if -Sign]` exes in `Staging\` signed before zipping
- `Compress-Archive -Path (Staging\*) -DestinationPath WorkDir\payload.zip`
- Zip verified with `System.IO.Compression.ZipFile::OpenRead()` — checks that `MainExe` is at zip root

**Design decision — staging copy:**
Signing modifies file content (adds Authenticode signature block).  Signing must happen on a copy so `PayloadDir` is never altered.  Signing must happen *before* zipping because the zip stores the signed binary; signing after zipping would require re-zipping.

---

### Sub-task 3 — Generated `Install.ps1` ✅

**Implemented:**
- All app constants (`AppName`, `SafeName`, `MainExe`, `Version`, `Publisher`, `InstallScope`, `NoDesktopShortcut`, `InstallCert`, `CertFileName`) embedded as single-quoted PS string literals — apostrophes escaped (SEC-003)
- Self-elevation via `Start-Process powershell.exe -Verb RunAs`
- Certificate import step (step 1, signed builds only): imports `.cer` into `LocalMachine\Root` and `LocalMachine\TrustedPublisher` silently (already elevated)
- Payload zip extracted to a GUID-named temp dir in `%TEMP%`
- Previous installation removed cleanly before copy (supports upgrade)
- Files copied to `%ProgramFiles%\<SafeName>` (Machine) or `%LOCALAPPDATA%\Programs\<SafeName>` (User)
- Start Menu shortcuts: one per `.exe`, `.bat`, `.html` in installed dir; main exe gets app name; names de-duplicated
- Desktop shortcut for main exe (skipped with `-NoDesktopShortcut`)
- Uninstaller copied from `$PSScriptRoot` to `%ProgramData%\<SafeName>\`
- Uninstall Start Menu shortcut targets `powershell.exe … Uninstall.ps1`
- Add/Remove Programs registry entry: all standard fields including `QuietUninstallString` (passes `/quiet` flag)
- Log written to `%TEMP%\<SafeName>_install.log`
- `finally` block removes GUID staging dir

**Design decision — `Uninstall.ps1` as a separate packed file:**
Early approach embedded the uninstaller as a here-string inside the installer template.  This caused PS string nesting and single/double-quote collision issues that were difficult to maintain.  Switched to: `Uninstall.ps1` and `Uninstall.bat` are separate files packed into the SED by IExpress; the installer copies them from `$PSScriptRoot` to `SupportDir` at install time.

---

### Sub-task 4 — Generated `Uninstall.ps1` + `Uninstall.bat` ✅

**Implemented:**
- All constants embedded (same set as `Install.ps1`)
- Self-elevation via `Start-Process -Verb RunAs`
- Interactive confirmation prompt (skipped with `/quiet`)
- Running-process check: lists processes from install dir; offers stop-and-continue prompt
- Removes: install dir, Start Menu folder, Desktop shortcut, registry key
- Deferred self-deletion: cleanup script written to `%TEMP%\<SafeName>_uninstall_cleanup_<PID>.ps1` (PID suffix prevents TOCTOU — SEC-006), launched as detached `powershell.exe -WindowStyle Hidden`; deletes `SupportDir` 3 seconds after the uninstaller exits
- Cert notice printed when `$InstallCert = $true` (cert not removed automatically — may be shared)
- `Uninstall.bat`: thin wrapper — `powershell.exe … Uninstall.ps1 %*` + pause (passes all args including `/quiet`)

---

### Sub-task 5 — Generated `Install.bat` + SED ✅

**Implemented:**
- `Install.bat`:
  - Log file named `<SafeName>_Install.log` in `%TEMP%`
  - `AppName` echo sanitised — shell metacharacters stripped (SEC-002)
  - Checks for `Install.ps1` and `payload.zip` before running
  - Redirects PowerShell output to `<SafeName>_Install_PS.log`
  - Pauses on failure; exits cleanly on success
- SED:
  - Written as ANSI/ASCII (`System.IO.File::WriteAllText` with `Encoding.ASCII`)
  - `[Version]`, `[Options]`, `[Strings]`, `[SourceFiles]`, `[SourceFiles0]` sections match the format IExpress requires
  - Files packed: `Install.bat`, `Install.ps1`, `Uninstall.ps1`, `Uninstall.bat`, `payload.zip` (+ `.cer` for signed builds)
  - `SourceFiles0=<WorkDir>\` with trailing backslash
  - `%FILEn%=` entries in `[SourceFiles0]` (no value, key only)
  - Copy of SED written to `OutputDir` for troubleshooting

**Design decision — `List<string>` + `WriteAllLines`:**
`@(...)` array literals under `Set-StrictMode -Version Latest` collapse due to `+` operator precedence: `@('a' + $b, 'c')` produces one element.  `[System.Collections.Generic.List[string]]::new()` with `.Add()` calls avoids the collapse.  `Set-Content` with a piped array also produced single-line output — replaced with `[System.IO.File]::WriteAllLines($path, $list, $encoding)`.

---

### Sub-task 6 — IExpress execution and polling ✅

**Implemented:**
- Existing output EXE deleted before invocation (IExpress silently produces a ~160 KB stub if the target already exists — cannot overwrite)
- Invoked via PowerShell call operator: `& $IExpressExe /N /Q $sedPath`
- Exit code ignored (IExpress always returns 1 even on success — well-known behaviour)
- Size-stability poll: checks every 3 seconds up to 180 seconds; breaks when file size is the same for two consecutive checks (IExpress writes a stub first, then fills the full content asynchronously after process exit)
- Build summary printed: path, size, signing status, cert thumbprint/expiry

**Design decision — `&` call operator vs `Start-Process`:**

| Method | Behaviour | Outcome |
|---|---|---|
| `Start-Process -Wait -PassThru` | Detaches GUI process from caller's window station | IExpress exits immediately with code 1, no output |
| `Start-Process -WindowStyle Normal -Wait` | Same detachment | Same failure |
| `UseShellExecute=true` + `WaitForExit()` | Detaches as GUI process | Returns immediately (GUI process) |
| `cmd /c "iexpress.exe ..."` | Doesn't block on GUI process | Returns before EXE is written |
| `& $IExpressExe ...` | Runs synchronously in caller's process context | **Works** — same as typing the command in the terminal |

The `&` operator is the only reliable method because IExpress is an old Win32 GUI tool that requires the calling process's interactive window station.

---

### Sub-task 7 — Code signing ✅

**Implemented:**
- Certificate resolution: searches `Cert:\CurrentUser\My` for valid, unexpired, code-signing EKU cert matching `$CertSubject`
- Certificate creation if none found: `New-SelfSignedCertificate`, 3072-bit RSA, SHA-256, `KeyExportPolicy NonExportable`, user-specified or default `NotAfter`
- Public `.cer` exported to `WorkDir` (for IExpress to pack) and `OutputDir` (for manual distribution)
- Payload signing: exes in `WorkDir\Staging\` signed with `Set-AuthenticodeSignature -HashAlgorithm SHA256`; status must be `Valid` or `UnknownError` (self-signed root not yet in trust store)
- Setup EXE signing: after IExpress; same verification
- `$InstallCert` flag (`$true`/`$false`) and `$CertFileName` embedded into generated `Install.ps1` and `Uninstall.ps1`
- `Trust-Certificate.ps1` written to `OutputDir`: admin-only, shows cert details, requires `[Y/N]` confirmation before importing

**Signing status notes:**
- `UnknownError` during build = cert valid but not yet in trust store on build machine — **expected and harmless**
- `Valid` = cert already trusted on the build machine (e.g. after running `Trust-Certificate.ps1` once)
- Any other status = build failure

---

### Sub-task 8 — Help, documentation and launcher ✅

**Implemented:**
- Comment-based `Get-Help` block with `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` (all 16), and 4 `.EXAMPLE` entries
- `Build-IExpressPackage-Usage.md`: full parameter table, step-by-step flow diagrams, console output screenshots, cert trust scenarios (3), troubleshooting table
- `README.md`: setup guide, repository layout (annotated), quick-start, key parameters, cert trust summary
- `Build-Package.bat`: interactive launcher with 4-option menu (unsigned, signed-main, signed-all, show config); all config at top in labelled `set` statements; temp `.ps1` file invocation to avoid `-Command` quoting issues (SEC-009)
- `RELEASE-NOTES.md`: full security assessment (SEC-001 to SEC-009), design decisions, change log format guide

---

## 7. Security decisions (summary)

Full detail in [`RELEASE-NOTES.md`](RELEASE-NOTES.md) §[1.1.0].

| ID | Area | Decision |
|---|---|---|
| SEC-001 | `MainExe` | Rejects path separators — file name only |
| SEC-002 | `Install.bat` echo | Shell metacharacters stripped from `AppName` before writing |
| SEC-003 | Generated PS constants | `AppName`, `Publisher`, `CertSubject` apostrophes escaped (`'` → `''`) |
| SEC-004 | Timestamp server | HTTPS enforced via `ValidateScript`; `http://` rejected |
| SEC-005 | Cert validity | `ValidateRange(1, 30)` — no expired or century-spanning certs |
| SEC-006 | Cleanup script | Filename includes `$PID` to prevent TOCTOU symlink attack |
| SEC-007 | `SetupName` | Rejects path separators — file name only |
| SEC-008 | WorkDir/OutputDir | Equality guards against `PayloadDir`; `WorkDir ≠ OutputDir` enforced |
| SEC-009 | `Build-Package.bat` | PS command written to `%RANDOM%`-named temp file, invoked via `-File` not `-Command` |

**Confirmed clean:**
- No hardcoded secrets, credentials, or API keys anywhere in the project
- Private key is non-exportable (`KeyExportPolicy NonExportable`)
- No sensitive data in any log output

---

## 8. Known limitations and open points

| Item | Status | Notes |
|---|---|---|
| `.bat` shortcut working directory | Accepted as-is | `run_stale_ven_cli.bat` hard-codes `OneDrive - IBM\Documents` — out of scope, left unchanged |
| Machine-wide install only fully tested | Accepted | `User` scope implemented but untested end-to-end |
| SmartScreen reputation | By design | Self-signed cert imported but SmartScreen may still warn until publisher reputation builds; use `-CertThumbprint` with a CA cert for production |
| IExpress progress UI | By design | `/Q` flag suppresses progress window; build machine must have an interactive session |
| IExpress exit code | By design | Always returns 1 even on success; exit code is ignored; success determined by output file presence and size stability |
| IExpress requires interactive session | By design | Must be run from the user's own terminal; headless automation contexts (CI/CD) are not supported without additional window station setup |

---

## 9. Design decisions log

Decisions are recorded here when they affect future maintenance choices.

| Date | Decision | Rationale |
|---|---|---|
| 2026-10-15 | Uninstaller as separate packed files, not here-string | Here-string nesting inside installer template caused unresolvable PS quoting collisions |
| 2026-10-15 | `List<string>.Add()` + `WriteAllLines` for all generated scripts | `@(...)` + `Set-Content` collapse under `Set-StrictMode -Version Latest` due to `+` precedence |
| 2026-10-15 | `& $IExpressExe` (call operator) for IExpress invocation | Only method that keeps IExpress on the caller's window station AND blocks until completion |
| 2026-10-15 | Pre-delete output EXE before IExpress run | IExpress silently produces a 160 KB stub rather than overwriting an existing file |
| 2026-10-15 | Size-stability poll (2× stable reads, 3 s interval, 3 min ceiling) | IExpress exits before the output file is fully flushed; existence check alone is insufficient |
| 2026-10-15 | Certificate not removed by uninstaller | Cert may be shared by multiple apps from same publisher; manual `certlm.msc` instructions printed instead |
| 2026-10-15 | 3072-bit RSA, SHA-256, non-exportable | Meets NIST SP 800-57 minimum for code signing; private key stays in cert store |
| 2026-10-16 | HTTPS enforced for `-TimestampServer` | RFC 3161 response integrity requires transport security; HTTP allows MITM forgery of timestamps |
| 2026-10-16 | `ValidateRange(1, 30)` on `-CertValidityYears` | Prevents accidentally-expired certs (0/negative) and practically-infinite certs (>30 yr) |
| 2026-10-16 | PID suffix on cleanup temp script | Fixed name creates predictable TOCTOU attack surface for local privilege escalation |
