# RELEASE-NOTES.md — AppPackageBuilder

> **Maintenance rule:** Update this file whenever a script change is made.
> Every entry must include a date, version bump, changed files, and — for any
> security-related change — an entry in the Security section of that release.
> If a security fix is made outside a feature release, increment the patch
> version and add a Security-only entry.

---

## [1.1.0] — 2026-10-16

### Security fixes

| ID | Severity | File | Vulnerability | Fix |
|---|---|---|---|---|
| SEC-001 | **High** | `Build-IExpressPackage.ps1` | **Path traversal — `-MainExe`**: accepted values containing `..\ ` or `/`, allowing resolution of an executable outside `PayloadDir`. | Added `ValidateScript` that rejects any `/` or `\` in the parameter value. |
| SEC-002 | **High** | Generated `Install.bat` | **Command injection — `AppName` in bat echo**: an app name containing `&`, `>`, `<`, `^`, or `|` would execute commands or redirect output when written into the bat file's `echo` statement. | Shell metacharacters stripped from the `AppName` value before it is written into the `echo` line. |
| SEC-003 | **Medium** | Generated `Install.ps1` / `Uninstall.ps1` | **Single-quote injection in generated PS constants**: an apostrophe in `AppName`, `Publisher`, or `CertSubject` terminated the single-quoted PS string early, producing a broken or injectable generated script. | Values are escaped (`'` → `''`) before embedding: `$AppNameEsc`, `$PublisherEsc`, `$CertSubjEsc`. |
| SEC-004 | **Medium** | `Build-IExpressPackage.ps1` | **Insecure timestamp server URL accepted**: `http://` URLs were accepted for the RFC 3161 timestamp server, allowing a network attacker to forge the timestamp response. | `ValidateScript` now rejects any value not starting with `https://`. All default examples updated to `https://timestamp.digicert.com`. |
| SEC-005 | **Medium** | `Build-IExpressPackage.ps1` | **Unbounded `-CertValidityYears`**: a value of `0` or negative produced an already-expired certificate; very large values (e.g. `1000`) created certificates valid until year 3026. | `[ValidateRange(1, 30)]` enforced on the parameter. |
| SEC-006 | **Medium** | Generated `Uninstall.ps1` | **Predictable temp script name (TOCTOU)**: the deferred cleanup script was written to `%TEMP%\<SafeName>_uninstall_cleanup.ps1` — a fixed, guessable path that a lower-privileged local user could pre-create as a symlink or replace between the write and the execute. | The filename now includes `$PID` (e.g. `<SafeName>_uninstall_cleanup_12345.ps1`), making it process-unique and non-guessable. |
| SEC-007 | **Low** | `Build-IExpressPackage.ps1` | **Path traversal — `-SetupName`**: accepted values such as `..\..\evil.exe`, allowing the output EXE to be written outside `OutputDir`. | `ValidateScript` rejects any `/` or `\` in the value. The `.exe` suffix check is now also in `ValidateScript` (replacing the weaker `ValidatePattern`). |
| SEC-008 | **Low** | `Build-IExpressPackage.ps1` | **No guard against `WorkDir == PayloadDir`**: if the user passed `-WorkDir .\Payload`, the script would silently delete the payload folder at the start of each build. Same risk for `OutputDir == PayloadDir` and `WorkDir == OutputDir`. | Paths are resolved to absolute form; equality checks added before any destructive operation. Clear error messages thrown on conflict. |
| SEC-009 | **Low** | `Build-Package.bat` | **Command injection via `-Command "%PS_CMD%"`**: the assembled PowerShell command was passed as a `-Command` string, which the shell evaluates. An app name or path containing apostrophes, ampersands, or parentheses could break or inject code. | The command is now written to a `%TEMP%\BuildPackage_run_%RANDOM%.ps1` file and invoked via `-File`, which does not re-evaluate the content as a shell expression. The temp file is deleted after use. |

### Confirmed clean (no action required)

| Item | Status |
|---|---|
| Hardcoded secrets / credentials / API keys | ✅ None found |
| Private key export | ✅ `KeyExportPolicy NonExportable` — private key never leaves the cert store |
| Sensitive data in logs | ✅ Only cert subject and thumbprint logged; no private key material |
| Input validation on paths | ✅ `PayloadDir` validated via `ValidateScript { Test-Path $_ -PathType Container }` |
| Registry write scope | ✅ Keys written only under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\<SafeName>` |
| Temp file cleanup | ✅ `StageDir` (GUID-named) cleaned in `finally` block of generated installer |

### Other changes in this release

- **`Build-IExpressPackage.ps1`** — `Version` parameter now validated with `ValidatePattern '^\d+(\.\d+){0,3}$'` to prevent injection of arbitrary strings into generated script constants.
- **`Build-Package.bat`** — default `TIMESTAMP_SERVER` updated from `http://` to `https://`.
- **`README.md`**, **`Build-IExpressPackage-Usage.md`** — all timestamp server examples updated to `https://`.

---

## [1.0.0] — 2026-10-15

### Initial release

| Component | Description |
|---|---|
| `Build-IExpressPackage.ps1` | Parameterized builder: payload staging, signing, zip, installer/uninstaller generation, SED generation, IExpress execution. |
| `Build-Package.bat` | Interactive launcher with 4-option menu (unsigned, signed-main, signed-all, show config). |
| `README.md` | Project overview, setup guide, quick-start commands. |
| `Build-IExpressPackage-Usage.md` | Full parameter reference, console output examples, cert trust scenarios, troubleshooting. |
| `iexpress-package-builder-plan.md` | Architecture decisions and sub-task record. |

### Key design decisions

| Decision | Rationale |
|---|---|
| IExpress invoked via `& $IExpressExe` call operator | `Start-Process -Wait` and `UseShellExecute=true` both detach the GUI process, causing premature return. The call operator runs synchronously in the caller's window station. |
| Output file polled for size stability | IExpress writes the output asynchronously after process exit; polling for two consecutive equal-size reads (3-second interval) ensures the file is fully written before proceeding. |
| Existing output EXE deleted before IExpress run | IExpress silently produces a ~160 KB stub when the output path already exists; deleting first ensures a clean write. |
| Uninstaller as separate packed files | Embedding the uninstaller as a here-string inside the installer template caused PS nesting/quoting issues. `Uninstall.ps1` and `Uninstall.bat` are packed into the SED separately and copied to `SupportDir` during install. |
| `[System.Collections.Generic.List[string]]` for generated scripts | `@(...)` array literals under `Set-StrictMode -Version Latest` collapse with `+` operator; `List<string>.Add()` + `[System.IO.File]::WriteAllLines()` avoids the collapse bug. |
| Self-signed cert: 3072-bit RSA, SHA-256, non-exportable | Meets current NIST SP 800-57 minimum for code signing; private key stays in `Cert:\CurrentUser\My` and is never written to disk. |
| Certificate not removed by uninstaller | The cert may be shared across multiple apps from the same publisher. A console notice with `certlm.msc` instructions is printed instead. |

---

## Change log format

Each release entry follows this template:

```markdown
## [X.Y.Z] — YYYY-MM-DD

### Security fixes       ← required if any CVE/SEC entry applies
### Bug fixes            ← functional regressions
### Improvements         ← non-breaking enhancements
### Breaking changes     ← param renames, behaviour changes
### Confirmed clean      ← items re-scanned and found clean
```

Severity levels for security entries:

| Level | Criteria |
|---|---|
| **Critical** | Remote code execution, credential exfiltration, privilege escalation without user interaction |
| **High** | Local code execution via crafted input, path traversal to sensitive locations |
| **Medium** | Logic flaws exploitable by a local user, integrity failures (e.g. unencrypted transport for crypto ops) |
| **Low** | Defence-in-depth issues, race conditions requiring specific preconditions |
| **Info** | Confirmed clean after review — no fix required |
