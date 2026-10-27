<#
.SYNOPSIS
    Turns a payload folder into a signed, self-installing IExpress Setup.exe.

.DESCRIPTION
    Build-IExpressPackage.ps1 zips the payload, generates a parameterized
    installer, uninstaller and IExpress wrapper, builds a SED file and runs
    iexpress.exe to produce a single Setup.exe.

    With -Sign a self-signed code-signing certificate is created (or reused),
    the payload exes are signed before zipping, the Setup.exe is signed after
    IExpress finishes, and the public certificate is packed into the Setup.exe
    so it is imported automatically on the target machine during installation.

    Existing files in Build\, Output\ and Payload\ are never modified.
    All generated artefacts go to WorkDir (default: Package\Build) and
    OutputDir (default: Package\Output).

.PARAMETER PayloadDir
    Folder whose contents become the installed application.
    Must exist, be non-empty, and contain MainExe.

.PARAMETER AppName
    Human-readable application name.  Used for the Start Menu folder,
    Add/Remove Programs entry and (by default) the Setup EXE file name.
    Characters that are invalid in file or registry names are stripped.

.PARAMETER MainExe
    File name (not path) of the primary executable inside PayloadDir.
    Used for the Desktop shortcut and (with -Sign) the default signing target.

.PARAMETER Version
    Version string for the Add/Remove Programs registry entry.
    Default: 1.0.0

.PARAMETER Publisher
    Publisher name for the registry entry and (with -Sign) the default
    certificate subject.  Default: empty string.

.PARAMETER OutputDir
    Folder for the final Setup.exe, SED, .cer and trust helper.
    Created if absent.  Default: <script dir>\Package\Output

.PARAMETER WorkDir
    Temporary build folder.  Cleaned at the start of each run.
    Default: <script dir>\Package\Build

.PARAMETER SetupName
    File name of the produced Setup EXE.  Must end in .exe.
    Default: <SafeAppName>_Setup.exe

.PARAMETER InstallScope
    Machine  - installs to %ProgramFiles%, uses HKLM (default).
    User     - installs to %LOCALAPPDATA%\Programs, uses HKCU.

.PARAMETER NoDesktopShortcut
    Suppress the Desktop shortcut for the main exe.

.PARAMETER KeepWorkFiles
    Do not delete WorkDir after a successful build.

.PARAMETER Sign
    Enable code signing.  A self-signed certificate is created if none
    matching CertSubject or CertThumbprint exists in Cert:\CurrentUser\My.

.PARAMETER SignAllExes
    Sign every .exe in PayloadDir before zipping.
    Default: sign only MainExe.

.PARAMETER CertSubject
    Subject of the certificate to find or create.
    Default: CN=<Publisher> Code Signing (Self-Signed)

.PARAMETER CertThumbprint
    Thumbprint of an existing certificate in Cert:\CurrentUser\My.
    Overrides CertSubject lookup/creation.

.PARAMETER CertValidityYears
    Validity in years for a newly created certificate.  Default: 10.

.PARAMETER TimestampServer
    HTTP or HTTPS URL of an RFC 3161 timestamp server.  Optional.
    Note: PowerShell's Set-AuthenticodeSignature internally requires http://
    even when https:// is supplied; the https:// form will be passed as-is but
    the underlying server still negotiates TLS for the RFC 3161 response.

.EXAMPLE
    # Stale VEN - unsigned build
    .\Build-IExpressPackage.ps1 `
        -PayloadDir  .\Payload `
        -AppName     'Stale VEN Reports Generation Utility' `
        -MainExe     stale_ven_gui.exe `
        -Publisher   'Illumio Tools' `
        -Version     1.0.0

.EXAMPLE
    # Stale VEN - signed build (self-signed, 10-year cert, auto-trust on install)
    .\Build-IExpressPackage.ps1 `
        -PayloadDir  .\Payload `
        -AppName     'Stale VEN Reports Generation Utility' `
        -MainExe     stale_ven_gui.exe `
        -Publisher   'Illumio Tools' `
        -Version     1.0.0 `
        -Sign

.EXAMPLE
    # Signed build, sign all exes, custom cert subject, RFC 3161 timestamp
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
        -TimestampServer   'https://timestamp.digicert.com'

.EXAMPLE
    # Use an existing cert by thumbprint, custom output folder
    .\Build-IExpressPackage.ps1 `
        -PayloadDir     .\Payload `
        -AppName        'Stale VEN Reports Generation Utility' `
        -MainExe        stale_ven_gui.exe `
        -Publisher      'Illumio Tools' `
        -Version        1.0.0 `
        -Sign `
        -CertThumbprint '3A7F9B2C1D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A' `
        -OutputDir      D:\Releases\StaleVEN `
        -KeepWorkFiles
#>

[CmdletBinding()]
param(
    # --- Mandatory -------------------------------------------------------
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string] $PayloadDir,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $AppName,

    # File name only — no path separators allowed (prevents path traversal)
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({
        if ($_ -match '[/\\]') { throw "MainExe must be a file name, not a path. Remove any directory separators." }
        $true
    })]
    [string] $MainExe,

    # --- Optional general ------------------------------------------------
    # Version: semver-like pattern guards against injection into generated scripts
    [ValidatePattern('^\d+(\.\d+){0,3}$')]
    [string] $Version   = '1.0.0',
    [string] $Publisher = '',

    [string] $OutputDir = '',
    [string] $WorkDir   = '',

    # File name only — no path separators allowed
    [ValidateScript({
        if ($_ -and $_ -match '[/\\]') { throw "SetupName must be a file name, not a path. Remove any directory separators." }
        if ($_ -and $_ -notmatch '\.exe$') { throw "SetupName must end in .exe" }
        $true
    })]
    [string] $SetupName = '',

    [ValidateSet('Machine', 'User')]
    [string] $InstallScope = 'Machine',

    [switch] $NoDesktopShortcut,
    [switch] $KeepWorkFiles,

    # --- Signing ---------------------------------------------------------
    [switch] $Sign,
    [switch] $SignAllExes,
    [string] $CertSubject       = '',
    [string] $CertThumbprint    = '',
    # Validity bounded to 1–30 years; 0 or negative creates an already-expired cert
    [ValidateRange(1, 30)]
    [int]    $CertValidityYears = 10,
    # Timestamp server: accept http:// or https://.
    # NOTE: Set-AuthenticodeSignature only accepts http:// URLs regardless of what
    # is passed (PowerShell limitation on Windows); https:// triggers a PS error.
    # The underlying RFC 3161 exchange is still TLS-protected by the server itself.
    [ValidateScript({
        if ($_ -and $_ -notmatch '^https?://') { throw "TimestampServer must be an HTTP or HTTPS URL (got: '$_'). Example: https://timestamp.digicert.com" }
        $true
    })]
    [string] $TimestampServer   = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ============================================================
# Helper output functions
# ============================================================
function Write-Step { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "  [OK]  $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "  [WARN] $Msg" -ForegroundColor Yellow }
function Write-Build { param([string]$Msg) Write-Host $Msg -ForegroundColor White }

# ============================================================
# Sub-task 1 – Derive safe names and paths
# ============================================================

# Strip characters that are invalid in file names and registry key names.
$SafeName = ($AppName -replace '[^\w\s\-]', '') -replace '\s+', '_'
$SafeName = $SafeName.Trim('_')
if (-not $SafeName) {
    throw "AppName '$AppName' produces an empty safe name after sanitising."
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $OutputDir) { $OutputDir = Join-Path $ScriptDir 'Package\Output' }
if (-not $WorkDir)   { $WorkDir   = Join-Path $ScriptDir 'Package\Build'  }
if (-not $SetupName) { $SetupName = "${SafeName}_Setup.exe" }

# Resolve PayloadDir to absolute path
$PayloadDir = (Resolve-Path $PayloadDir).Path

# Resolve WorkDir/OutputDir to absolute paths for comparison
$WorkDir   = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkDir)
$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)

# Safety: WorkDir must not be the same as PayloadDir (would wipe the payload on clean)
$WorkDirResolved   = $WorkDir.TrimEnd('\','/')
$OutputDirResolved = $OutputDir.TrimEnd('\','/')
$PayloadDirResolved = $PayloadDir.TrimEnd('\','/')
if ($WorkDirResolved -eq $PayloadDirResolved) {
    throw "WorkDir cannot be the same as PayloadDir ('$PayloadDir'). Choose a different temporary folder."
}
if ($OutputDirResolved -eq $PayloadDirResolved) {
    throw "OutputDir cannot be the same as PayloadDir ('$PayloadDir'). Choose a different output folder."
}
if ($WorkDirResolved -eq $OutputDirResolved) {
    throw "WorkDir and OutputDir cannot be the same folder. They must be distinct."
}

# Escape single quotes in string values that are embedded into generated PS script constants.
# A bare apostrophe inside a single-quoted PS string terminates it early.
$AppNameEsc    = $AppName    -replace "'", "''"
$PublisherEsc  = $Publisher  -replace "'", "''"
$CertSubjTemp  = ''   # computed after default logic below

# Certificate subject default
if ($Sign -and -not $CertSubject -and -not $CertThumbprint) {
    $subjectPublisher = if ($Publisher) { $Publisher } else { $SafeName }
    $CertSubject = "CN=$subjectPublisher Code Signing (Self-Signed)"
}
$CertSubjEsc = $CertSubject -replace "'", "''"

# Cert file name derived from setup name (swap .exe -> .cer)
$CertFileName = [System.IO.Path]::ChangeExtension($SetupName, '.cer')

# Set-AuthenticodeSignature only accepts http:// URLs (PowerShell limitation).
# Normalise the user-supplied value so signing never fails due to https://.
$tsUrl = if ($TimestampServer) { $TimestampServer -replace '^https://', 'http://' } else { '' }

# IExpress SED name
$SedName = "${SafeName}.SED"

# ============================================================
# Validate iexpress.exe
# ============================================================
$IExpressExe = Join-Path $env:SystemRoot 'System32\iexpress.exe'
if (-not (Test-Path $IExpressExe -PathType Leaf)) {
    throw "iexpress.exe not found at '$IExpressExe'. " +
          "Install it via: DISM /Online /Add-Capability /CapabilityName:Tools.IExpress~~~~0.0.1.0"
}

# ============================================================
# Validate payload
# ============================================================
$payloadItems = Get-ChildItem -Path $PayloadDir -ErrorAction SilentlyContinue
if (-not $payloadItems) { throw "PayloadDir '$PayloadDir' is empty." }

$mainExeInPayload = Join-Path $PayloadDir $MainExe
if (-not (Test-Path $mainExeInPayload -PathType Leaf)) {
    $foundExes = @(Get-ChildItem -Path $PayloadDir -Filter '*.exe' -File -ErrorAction SilentlyContinue |
                   Select-Object -ExpandProperty Name)
    $foundText = if ($foundExes.Count -gt 0) { $foundExes -join ', ' } else { '(none)' }
    throw ("ERROR: Main executable '$MainExe' is missing from the payload folder '$PayloadDir'. " +
           "Executables found there: $foundText. " +
           "Check the -MainExe / -PayloadDir values (MAIN_EXE / PAYLOAD_DIR in Build-Package.bat).")
}

# ============================================================
# Create / clean WorkDir and OutputDir
# ============================================================
if (Test-Path $WorkDir) {
    Remove-Item $WorkDir -Recurse -Force
}
New-Item -ItemType Directory -Path $WorkDir   -Force | Out-Null
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$StagingDir = Join-Path $WorkDir 'Staging'
New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null

# ============================================================
# Banner
# ============================================================
Write-Build ''
Write-Build '========================================================'
Write-Build "  Build-IExpressPackage  -  $AppName"
Write-Build "  Version   : $Version"
Write-Build "  Publisher : $Publisher"
Write-Build "  Scope     : $InstallScope"
Write-Build "  Signing   : $(if ($Sign) { 'YES' } else { 'no' })"
Write-Build '========================================================'
Write-Build ''

try {

# ============================================================
# Sub-task 7 (part 1) – Certificate
# ============================================================
$cert            = $null
$installCertFlag = 'false'   # rendered into generated PS as $false / $true
$certFileInWorkDir = ''

if ($Sign) {
    Write-Step 'Resolving code-signing certificate...'

    if ($CertThumbprint) {
        $cert = Get-Item "Cert:\CurrentUser\My\$CertThumbprint" -ErrorAction SilentlyContinue
        if (-not $cert) {
            throw "Certificate with thumbprint '$CertThumbprint' not found in Cert:\CurrentUser\My."
        }
    } else {
        $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object {
            $_.Subject -eq $CertSubject -and
            $_.NotAfter -gt (Get-Date) -and
            ($_.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.3' })
        } | Sort-Object NotAfter -Descending | Select-Object -First 1

        if (-not $cert) {
            Write-Step "Creating new self-signed certificate: $CertSubject"
            $notAfter = (Get-Date).AddYears($CertValidityYears)
            $cert = New-SelfSignedCertificate `
                -Type              CodeSigningCert `
                -Subject           $CertSubject `
                -CertStoreLocation 'Cert:\CurrentUser\My' `
                -KeyLength         3072 `
                -HashAlgorithm     SHA256 `
                -KeyExportPolicy   NonExportable `
                -NotAfter          $notAfter
        }
    }

    Write-Ok "Certificate : $($cert.Subject)"
    Write-Ok "Thumbprint  : $($cert.Thumbprint)"
    Write-Ok "Expires     : $($cert.NotAfter.ToString('yyyy-MM-dd'))"

    # Export public .cer to WorkDir (for IExpress to pack) AND OutputDir
    $certFileInWorkDir   = Join-Path $WorkDir   $CertFileName
    $certFileInOutputDir = Join-Path $OutputDir $CertFileName
    Export-Certificate -Cert $cert -FilePath $certFileInWorkDir   -Type CERT -Force | Out-Null
    Export-Certificate -Cert $cert -FilePath $certFileInOutputDir -Type CERT -Force | Out-Null
    Write-Ok "Certificate exported: $certFileInOutputDir"

    $installCertFlag = 'true'
}

# ============================================================
# Sub-task 2 – Stage payload, optionally sign exes
# ============================================================
Write-Step 'Staging payload...'
Copy-Item -Path (Join-Path $PayloadDir '*') -Destination $StagingDir -Recurse -Force

if ($Sign) {
    if ($SignAllExes) {
        $exesToSign = @(Get-ChildItem -Path $StagingDir -Filter '*.exe' -Recurse)
    } else {
        $exesToSign = @(Get-Item (Join-Path $StagingDir $MainExe))
    }

    foreach ($exeFile in $exesToSign) {
        Write-Step "  Signing: $($exeFile.Name)"
        $sigParams = @{
            FilePath      = $exeFile.FullName
            Certificate   = $cert
            HashAlgorithm = 'SHA256'
        }
        if ($tsUrl) { $sigParams['TimestampServer'] = $tsUrl }

        $sig = Set-AuthenticodeSignature @sigParams
        if ($sig.Status -notin 'Valid', 'UnknownError') {
            throw "Signing failed for '$($exeFile.Name)': Status=$($sig.Status)"
        }
        Write-Ok "  $($exeFile.Name) -> $($sig.Status)"
    }
}

# ============================================================
# Sub-task 2 – Zip
# ============================================================
Write-Step 'Creating payload.zip...'
$payloadZip = Join-Path $WorkDir 'payload.zip'
Compress-Archive -Path (Join-Path $StagingDir '*') -DestinationPath $payloadZip -Force

# Verify zip contains MainExe at the root
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipArchive = [System.IO.Compression.ZipFile]::OpenRead($payloadZip)
$zipEntries = @($zipArchive.Entries | ForEach-Object { $_.Name })
$zipArchive.Dispose()
if ($MainExe -notin $zipEntries) {
    throw "payload.zip does not contain '$MainExe' at its root. Check PayloadDir contents."
}
Write-Ok "payload.zip verified (contains $MainExe)"

# ============================================================
# Derived constants written into generated scripts
# ============================================================
$noDesktopStr = if ($NoDesktopShortcut) { '$true' } else { '$false' }
$installCertStr = if ($installCertFlag -eq 'true') { '$true' } else { '$false' }

if ($InstallScope -eq 'Machine') {
    $regHive = 'HKLM'
} else {
    $regHive = 'HKCU'
}

# ============================================================
# Sub-task 4 – Write Uninstall.ps1 to WorkDir
# ============================================================
Write-Step 'Generating Uninstall.ps1...'

$u = [System.Collections.Generic.List[string]]::new()
$u.Add('$ErrorActionPreference = ' + "'Stop'")
$u.Add('')
$u.Add('# ---- Embedded constants ----')
$u.Add('$AppName       = ' + "'$AppNameEsc'")
$u.Add('$SafeName      = ' + "'$SafeName'")
$u.Add('$CertSubject   = ' + "'$CertSubjEsc'")
$u.Add('$InstallCert   = ' + $installCertStr)
$u.Add('$InstallScope  = ' + "'$InstallScope'")
$u.Add('')
$u.Add('# ---- Derived paths ----')
$u.Add('$InstallDir = if ($InstallScope -eq ' + "'Machine') {")
$u.Add('    Join-Path $env:ProgramFiles $SafeName')
$u.Add('} else {')
$u.Add('    Join-Path $env:LOCALAPPDATA "Programs\$SafeName"')
$u.Add('}')
$u.Add('$SupportDir   = Join-Path $env:ProgramData $SafeName')
$u.Add('$UninstallKey = ' + "'${regHive}:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$SafeName'")
$u.Add('$StartMenuBase = if ($InstallScope -eq ' + "'Machine') {")
$u.Add('    Join-Path $env:ProgramData ' + "'Microsoft\Windows\Start Menu\Programs'")
$u.Add('} else {')
$u.Add('    Join-Path $env:APPDATA ' + "'Microsoft\Windows\Start Menu\Programs'")
$u.Add('}')
$u.Add('$StartMenuDir = Join-Path $StartMenuBase $AppName')
$u.Add('$DesktopDir   = if ($InstallScope -eq ' + "'Machine') {")
$u.Add("    [Environment]::GetFolderPath('CommonDesktopDirectory')")
$u.Add('} else {')
$u.Add("    [Environment]::GetFolderPath('Desktop')")
$u.Add('}')
$u.Add('')
$u.Add('# ---- Self-elevate ----')
$u.Add('$id = [Security.Principal.WindowsIdentity]::GetCurrent()')
$u.Add('$pr = [Security.Principal.WindowsPrincipal]::new($id)')
$u.Add('if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {')
$u.Add('    $argsStr = ' + "'-NoProfile -ExecutionPolicy Bypass -File ""' + `$PSCommandPath + '""'")
$u.Add("    if (`$args -contains '/quiet') { `$argsStr += ' /quiet' }")
$u.Add('    try {')
$u.Add('        $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList $argsStr -Wait -PassThru')
$u.Add('        exit $proc.ExitCode')
$u.Add('    } catch {')
$u.Add("        Write-Error 'Administrator permission was not granted.'")
$u.Add('        exit 1')
$u.Add('    }')
$u.Add('}')
$u.Add('')
$u.Add('$quiet = ($args -contains ' + "'/quiet')")
$u.Add('')
$u.Add('try {')
$u.Add('    if (-not $quiet) {')
$u.Add('        Write-Host ""')
$u.Add("        Write-Host `"This will uninstall `$AppName.`" -ForegroundColor Yellow")
$u.Add("        `$ans = Read-Host 'Continue? [Y/N]'")
$u.Add("        if (`$ans -notmatch '^[Yy]') { Write-Host 'Uninstall cancelled.'; exit 0 }")
$u.Add('    }')
$u.Add('')
$u.Add('    Write-Host "Uninstalling $AppName..." -ForegroundColor Cyan')
$u.Add('')
$u.Add('    # ---- Stop running processes from install dir ----')
$u.Add('    $running = Get-Process | Where-Object {')
$u.Add('        $_.Path -and $_.Path.StartsWith($InstallDir, [System.StringComparison]::OrdinalIgnoreCase)')
$u.Add('    }')
$u.Add('    if ($running) {')
$u.Add('        Write-Warning "The following processes are running from the install directory:"')
$u.Add('        $running | ForEach-Object { Write-Warning "  $($_.Name) (PID $($_.Id))" }')
$u.Add('        if (-not $quiet) {')
$u.Add("            `$ans2 = Read-Host 'Stop them and continue? [Y/N]'")
$u.Add("            if (`$ans2 -notmatch '^[Yy]') { Write-Host 'Uninstall cancelled.'; exit 0 }")
$u.Add('        }')
$u.Add('        $running | Stop-Process -Force -ErrorAction SilentlyContinue')
$u.Add('        Start-Sleep -Seconds 2')
$u.Add('    }')
$u.Add('')
$u.Add('    # ---- Remove install dir ----')
$u.Add('    if (Test-Path -LiteralPath $InstallDir) {')
$u.Add('        Remove-Item -LiteralPath $InstallDir -Recurse -Force')
$u.Add('        Write-Host "  Removed: $InstallDir"')
$u.Add('    }')
$u.Add('')
$u.Add('    # ---- Remove Start Menu folder ----')
$u.Add('    if (Test-Path -LiteralPath $StartMenuDir) {')
$u.Add('        Remove-Item -LiteralPath $StartMenuDir -Recurse -Force')
$u.Add('        Write-Host "  Removed: $StartMenuDir"')
$u.Add('    }')
$u.Add('')
$u.Add('    # ---- Remove Desktop shortcut ----')
$u.Add('    $desktopLnk = Join-Path $DesktopDir "$AppName.lnk"')
$u.Add('    if (Test-Path -LiteralPath $desktopLnk) {')
$u.Add('        Remove-Item -LiteralPath $desktopLnk -Force')
$u.Add('        Write-Host "  Removed: $desktopLnk"')
$u.Add('    }')
$u.Add('')
$u.Add('    # ---- Remove registry entry ----')
$u.Add('    if (Test-Path -LiteralPath $UninstallKey) {')
$u.Add('        Remove-Item -LiteralPath $UninstallKey -Recurse -Force')
$u.Add('        Write-Host "  Removed registry key"')
$u.Add('    }')
$u.Add('')
$u.Add('    Write-Host ""')
$u.Add('    Write-Host "$AppName has been uninstalled." -ForegroundColor Green')
$u.Add('')
$u.Add('    # ---- Cert notice (signed builds only) ----')
$u.Add('    if ($InstallCert -and $CertSubject) {')
$u.Add('        Write-Host ""')
$u.Add('        Write-Warning (')
$u.Add('            "The code-signing certificate was NOT removed automatically.`n" +')
$u.Add('            "It may be shared with other software from the same publisher.`n" +')
$u.Add("            `"To remove it, open certlm.msc and delete '`$CertSubject'``n`" +")
$u.Add('            "from:  Trusted Root Certification Authorities`n" +')
$u.Add('            "  and: Trusted Publishers"')
$u.Add('        )')
$u.Add('    }')
$u.Add('}')
$u.Add('catch {')
$u.Add('    Write-Error "Uninstallation failed: $($_.Exception.Message)"')
$u.Add('    exit 1')
$u.Add('}')
$u.Add('finally {')
$u.Add('    # ---- Deferred self-deletion of SupportDir ----')
$u.Add('    # Use PID in the temp script name to avoid predictable-name TOCTOU attacks')
$u.Add("    `$tmpScript = Join-Path `$env:TEMP ('${SafeName}_uninstall_cleanup_' + `$PID + '.ps1')")
$u.Add('    if (Test-Path -LiteralPath $SupportDir) {')
$u.Add('        try {')
$u.Add("            `$cleanup = `"Start-Sleep 3; Remove-Item -LiteralPath '`$SupportDir' -Recurse -Force -ErrorAction SilentlyContinue`"")
$u.Add('            $cleanup | Set-Content -LiteralPath $tmpScript -Encoding UTF8')
$u.Add('            Start-Process powershell.exe `')
$u.Add('                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmpScript`"" `')
$u.Add('                -WindowStyle Hidden')
$u.Add('        } catch { <# best effort #> }')
$u.Add('    }')
$u.Add('}')
$uninstPsLines = $u

$uninstPsPath = Join-Path $WorkDir 'Uninstall.ps1'
[System.IO.File]::WriteAllLines($uninstPsPath, $uninstPsLines, [System.Text.Encoding]::UTF8)
Write-Ok 'Uninstall.ps1 written'

# ============================================================
# Sub-task 4 – Write Uninstall.bat to WorkDir
# ============================================================
$uninstBatPath = Join-Path $WorkDir 'Uninstall.bat'
$ub = [System.Collections.Generic.List[string]]::new()
$ub.Add('@echo off')
$ub.Add("title Uninstall $AppName")
$ub.Add('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1" %*')
$ub.Add('pause')
[System.IO.File]::WriteAllLines($uninstBatPath, $ub, [System.Text.Encoding]::ASCII)
Write-Ok 'Uninstall.bat written'

# ============================================================
# Sub-task 3 – Write Install.ps1 to WorkDir
# ============================================================
Write-Step 'Generating Install.ps1...'

$i = [System.Collections.Generic.List[string]]::new()
$i.Add('$ErrorActionPreference = ' + "'Stop'")
$i.Add('')
$i.Add('# ---- Embedded constants ----')
$i.Add('$AppName           = ' + "'$AppNameEsc'")
$i.Add('$SafeName          = ' + "'$SafeName'")
$i.Add('$MainExe           = ' + "'$MainExe'")
$i.Add('$Version           = ' + "'$Version'")
$i.Add('$Publisher         = ' + "'$PublisherEsc'")
$i.Add('$InstallScope      = ' + "'$InstallScope'")
$i.Add('$NoDesktopShortcut = ' + $noDesktopStr)
$i.Add('$InstallCert       = ' + $installCertStr)
$i.Add('$CertFileName      = ' + "'$CertFileName'")
$i.Add('')
$i.Add('# ---- Derived paths ----')
$i.Add('$InstallDir = if ($InstallScope -eq ' + "'Machine') {")
$i.Add('    Join-Path $env:ProgramFiles $SafeName')
$i.Add('} else {')
$i.Add('    Join-Path $env:LOCALAPPDATA "Programs\$SafeName"')
$i.Add('}')
$i.Add('$SupportDir   = Join-Path $env:ProgramData $SafeName')
$i.Add('$UninstallKey = if ($InstallScope -eq ' + "'Machine') {")
$i.Add("    `"${regHive}:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$SafeName`"")
$i.Add('} else {')
$i.Add("    `"${regHive}:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$SafeName`"")
$i.Add('}')
$i.Add('$StartMenuBase = if ($InstallScope -eq ' + "'Machine') {")
$i.Add('    Join-Path $env:ProgramData ' + "'Microsoft\Windows\Start Menu\Programs'")
$i.Add('} else {')
$i.Add('    Join-Path $env:APPDATA ' + "'Microsoft\Windows\Start Menu\Programs'")
$i.Add('}')
$i.Add('$StartMenuDir = Join-Path $StartMenuBase $AppName')
$i.Add('$DesktopDir   = if ($InstallScope -eq ' + "'Machine') {")
$i.Add("    [Environment]::GetFolderPath('CommonDesktopDirectory')")
$i.Add('} else {')
$i.Add("    [Environment]::GetFolderPath('Desktop')")
$i.Add('}')
$i.Add('$PayloadZip  = Join-Path $PSScriptRoot ' + "'payload.zip'")
$i.Add('$CerPath     = Join-Path $PSScriptRoot $CertFileName')
$i.Add('$LogFile     = Join-Path $env:TEMP "' + "${SafeName}_install.log" + '"')
$i.Add('$StageDir    = Join-Path $env:TEMP ("' + "${SafeName}-" + '" + [guid]::NewGuid().ToString(' + "'N'))")
$i.Add('')
$i.Add('# ---- Logging ----')
$i.Add('function Write-Log {')
$i.Add('    param([string]$Msg)')
$i.Add('    $ts = (Get-Date).ToString(' + "'yyyy-MM-dd HH:mm:ss')")
$i.Add('    "$ts  $Msg" | Add-Content -LiteralPath $LogFile -Encoding UTF8')
$i.Add('    Write-Host $Msg')
$i.Add('}')
$i.Add('')
$i.Add('# ---- Self-elevate ----')
$i.Add('$id = [Security.Principal.WindowsIdentity]::GetCurrent()')
$i.Add('$pr = [Security.Principal.WindowsPrincipal]::new($id)')
$i.Add('if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {')
$i.Add('    $argsStr = ' + "'-NoProfile -ExecutionPolicy Bypass -File ""' + `$PSCommandPath + '""'")
$i.Add('    try {')
$i.Add('        $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList $argsStr -Wait -PassThru')
$i.Add('        exit $proc.ExitCode')
$i.Add('    } catch {')
$i.Add("        Write-Error 'Administrator permission was not granted.'")
$i.Add('        exit 1')
$i.Add('    }')
$i.Add('}')
$i.Add('')
$i.Add('try {')
$i.Add('    Write-Log "Installing $AppName v$Version..."')
$i.Add('    Write-Log "Log: $LogFile"')
$i.Add('')
$i.Add('    # ---- Step 1: Import certificate (signed builds only) ----')
$i.Add('    if ($InstallCert -and (Test-Path -LiteralPath $CerPath)) {')
$i.Add("        Write-Log 'Importing code-signing certificate...'")
$i.Add("        Import-Certificate -FilePath `$CerPath -CertStoreLocation 'Cert:\LocalMachine\Root'             | Out-Null")
$i.Add("        Import-Certificate -FilePath `$CerPath -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher'  | Out-Null")
$i.Add("        Write-Log 'Certificate imported into LocalMachine\Root and LocalMachine\TrustedPublisher.'")
$i.Add('    }')
$i.Add('')
$i.Add('    # ---- Step 2: Verify payload ZIP ----')
$i.Add('    if (-not (Test-Path -LiteralPath $PayloadZip -PathType Leaf)) {')
$i.Add('        throw "payload.zip not found: $PayloadZip"')
$i.Add('    }')
$i.Add('')
$i.Add('    # ---- Step 3: Extract payload ----')
$i.Add('    New-Item -ItemType Directory -Path $StageDir -Force | Out-Null')
$i.Add('    Expand-Archive -LiteralPath $PayloadZip -DestinationPath $StageDir -Force')
$i.Add("    Write-Log 'Payload extracted.'")
$i.Add('')
$i.Add('    # ---- Step 4: Remove previous installation ----')
$i.Add('    if (Test-Path -LiteralPath $InstallDir) {')
$i.Add('        Write-Log "Removing previous installation at $InstallDir..."')
$i.Add('        Remove-Item -LiteralPath $InstallDir -Recurse -Force')
$i.Add('    }')
$i.Add('')
$i.Add('    # ---- Step 5: Copy files ----')
$i.Add('    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null')
$i.Add('    Copy-Item -Path (Join-Path $StageDir ' + "'*') -Destination `$InstallDir -Recurse -Force")
$i.Add('    Write-Log "Files installed to $InstallDir"')
$i.Add('')
$i.Add('    $mainExeInstalled = Join-Path $InstallDir $MainExe')
$i.Add('    if (-not (Test-Path -LiteralPath $mainExeInstalled -PathType Leaf)) {')
$i.Add('        throw "MainExe ' + "'`$MainExe'" + ' not found in install dir after copy."')
$i.Add('    }')
$i.Add('')
$i.Add('    # ---- Step 6: Create Start Menu shortcuts ----')
$i.Add('    New-Item -ItemType Directory -Path $StartMenuDir -Force | Out-Null')
$i.Add('    $shell = New-Object -ComObject WScript.Shell')
$i.Add('')
$i.Add('    # .html files get a shortcut only when they sit in the install root; those in subdirectories are skipped.')
$i.Add('    $installRoot = $InstallDir.TrimEnd([char]92, [char]47)')
$i.Add('    $shortcutTargets = Get-ChildItem -Path $InstallDir -Recurse -File |')
$i.Add("        Where-Object {")
$i.Add("            `$_.Extension -in '.exe', '.bat' -or")
$i.Add("            (`$_.Extension -eq '.html' -and `$_.DirectoryName.TrimEnd([char]92, [char]47) -eq `$installRoot)")
$i.Add("        }")
$i.Add('')
$i.Add('    $usedNames = @{}')
$i.Add('    foreach ($target in $shortcutTargets) {')
$i.Add('        if ($target.Name -eq $MainExe) {')
$i.Add('            $lnkName = $AppName')
$i.Add('        } else {')
$i.Add("            `$lnkName = `$target.BaseName -replace '[_\-]+', ' '")
$i.Add('            $lnkName = (Get-Culture).TextInfo.ToTitleCase($lnkName.ToLower())')
$i.Add('        }')
$i.Add('        $uniqueName = $lnkName')
$i.Add('        $idx = 1')
$i.Add('        while ($usedNames.ContainsKey($uniqueName)) {')
$i.Add('            $idx++')
$i.Add('            $uniqueName = "$lnkName ($idx)"')
$i.Add('        }')
$i.Add('        $usedNames[$uniqueName] = $true')
$i.Add('        $lnkPath = Join-Path $StartMenuDir "$uniqueName.lnk"')
$i.Add('        $lnk = $shell.CreateShortcut($lnkPath)')
$i.Add('        $lnk.TargetPath = $target.FullName')
$i.Add('        $lnk.WorkingDirectory = $InstallDir')
$i.Add('        $lnk.Description = $uniqueName')
$i.Add('        $lnk.Save()')
$i.Add('    }')
$i.Add('')
$i.Add('    # ---- Step 7: Desktop shortcut (main exe only) ----')
$i.Add('    if (-not $NoDesktopShortcut) {')
$i.Add('        $dtLnk = $shell.CreateShortcut((Join-Path $DesktopDir "$AppName.lnk"))')
$i.Add('        $dtLnk.TargetPath = $mainExeInstalled')
$i.Add('        $dtLnk.WorkingDirectory = $InstallDir')
$i.Add('        $dtLnk.Description = $AppName')
$i.Add('        $dtLnk.Save()')
$i.Add("        Write-Log 'Desktop shortcut created.'")
$i.Add('    }')
$i.Add('')
$i.Add('    # ---- Step 8: Copy uninstaller from package to SupportDir ----')
$i.Add('    New-Item -ItemType Directory -Path $SupportDir -Force | Out-Null')
$i.Add('    $uninstPs  = Join-Path $SupportDir ' + "'Uninstall.ps1'")
$i.Add('    $uninstBat = Join-Path $SupportDir ' + "'Uninstall.bat'")
$i.Add('    Copy-Item -LiteralPath (Join-Path $PSScriptRoot ' + "'Uninstall.ps1') -Destination `$uninstPs  -Force")
$i.Add('    Copy-Item -LiteralPath (Join-Path $PSScriptRoot ' + "'Uninstall.bat') -Destination `$uninstBat -Force")
$i.Add("    Write-Log 'Uninstaller written to SupportDir.'")
$i.Add('')
$i.Add('    # ---- Step 9: Uninstall shortcut in Start Menu ----')
$i.Add('    $uninstLnk = $shell.CreateShortcut((Join-Path $StartMenuDir "Uninstall $AppName.lnk"))')
$i.Add("    `$uninstLnk.TargetPath       = 'powershell.exe'")
$i.Add('    $uninstLnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$uninstPs`""')
$i.Add('    $uninstLnk.WorkingDirectory = $SupportDir')
$i.Add('    $uninstLnk.Description      = "Uninstall $AppName"')
$i.Add('    $uninstLnk.WindowStyle      = 1')
$i.Add('    $uninstLnk.Save()')
$i.Add("    Write-Log 'Uninstall shortcut created in Start Menu.'")
$i.Add('')
$i.Add('    # ---- Step 10: Register in Add/Remove Programs ----')
$i.Add('    New-Item -Path $UninstallKey -Force | Out-Null')
$i.Add('    $installDirSize = [math]::Round(')
$i.Add('        (Get-ChildItem -Path $InstallDir -Recurse | Measure-Object -Property Length -Sum).Sum / 1KB')
$i.Add('    )')
$i.Add('    $regValues = @{')
$i.Add('        DisplayName          = $AppName')
$i.Add('        DisplayVersion       = $Version')
$i.Add('        Publisher            = $Publisher')
$i.Add('        InstallLocation      = $InstallDir')
$i.Add('        DisplayIcon          = $mainExeInstalled')
$i.Add('        UninstallString      = """powershell.exe"" -NoProfile -ExecutionPolicy Bypass -File ""$uninstPs"""')
$i.Add('        QuietUninstallString = """powershell.exe"" -NoProfile -ExecutionPolicy Bypass -File ""$uninstPs"" /quiet"')
$i.Add('        EstimatedSize        = $installDirSize')
$i.Add('    }')
$i.Add('    foreach ($kv in $regValues.GetEnumerator()) {')
$i.Add('        $type = if ($kv.Value -is [int]) { ' + "'DWord' } else { 'String' }")
$i.Add('        New-ItemProperty -Path $UninstallKey -Name $kv.Key -Value $kv.Value -PropertyType $type -Force | Out-Null')
$i.Add('    }')
$i.Add('    New-ItemProperty -Path $UninstallKey -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null')
$i.Add('    New-ItemProperty -Path $UninstallKey -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null')
$i.Add("    Write-Log 'Registered in Add/Remove Programs.'")
$i.Add('')
$i.Add('    # ---- Done ----')
$i.Add("    Write-Log ''")
$i.Add("    Write-Log '========================================'")
$i.Add("    Write-Log ' Installation completed successfully!'")
$i.Add("    Write-Log '========================================'")
$i.Add('    Write-Log "Application : $AppName"')
$i.Add('    Write-Log "Location    : $InstallDir"')
$i.Add('    exit 0')
$i.Add('}')
$i.Add('catch {')
$i.Add('    Write-Log "ERROR: $($_.Exception.Message)"')
$i.Add('    exit 1')
$i.Add('}')
$i.Add('finally {')
$i.Add('    if (Test-Path -LiteralPath $StageDir) {')
$i.Add('        Remove-Item -LiteralPath $StageDir -Recurse -Force -ErrorAction SilentlyContinue')
$i.Add('    }')
$i.Add('}')
$installPsLines = $i

$installPsPath = Join-Path $WorkDir 'Install.ps1'
[System.IO.File]::WriteAllLines($installPsPath, $installPsLines, [System.Text.Encoding]::UTF8)
Write-Ok 'Install.ps1 written'

# ============================================================
# Sub-task 5 – Write Install.bat to WorkDir
# ============================================================
Write-Step 'Generating Install.bat...'

$logBaseName    = "${SafeName}_Install"
$installBatPath = Join-Path $WorkDir 'Install.bat'

# Build the bat lines as an array to avoid quoting issues
$ib = [System.Collections.Generic.List[string]]::new()
$ib.Add('@echo off')
$ib.Add('setlocal')
$ib.Add('')
$ib.Add('set "LOG=%TEMP%\' + $logBaseName + '.log"')
$ib.Add('')
$ib.Add('echo ======================================== > "%LOG%"')
$ib.Add('echo ' + ($AppName -replace '[&<>^|]', '') + ' Installation Log >> "%LOG%"')
$ib.Add('echo Started: %DATE% %TIME% >> "%LOG%"')
$ib.Add('echo Script directory: %~dp0 >> "%LOG%"')
$ib.Add('echo ======================================== >> "%LOG%"')
$ib.Add('')
$ib.Add('echo Installer started.')
$ib.Add('echo Log file: %LOG%')
$ib.Add('')
$ib.Add('if not exist "%~dp0Install.ps1" (')
$ib.Add('    echo ERROR: Install.ps1 not found in package. >> "%LOG%"')
$ib.Add('    echo ERROR: Install.ps1 was not found.')
$ib.Add('    pause')
$ib.Add('    exit /b 1')
$ib.Add(')')
$ib.Add('')
$ib.Add('if not exist "%~dp0payload.zip" (')
$ib.Add('    echo ERROR: payload.zip not found in package. >> "%LOG%"')
$ib.Add('    echo ERROR: payload.zip was not found.')
$ib.Add('    pause')
$ib.Add('    exit /b 1')
$ib.Add(')')
$ib.Add('')
$ib.Add('echo Launching PowerShell installer... >> "%LOG%"')
$ib.Add('')
$ib.Add('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"' +
    ' >> "%TEMP%\' + $logBaseName + '_PS.log" 2>&1')
$ib.Add('')
$ib.Add('set "RESULT=%ERRORLEVEL%"')
$ib.Add('')
$ib.Add('echo Installer exit code: %RESULT% >> "%LOG%"')
$ib.Add('echo Finished: %DATE% %TIME% >> "%LOG%"')
$ib.Add('')
$ib.Add('if not "%RESULT%"=="0" (')
$ib.Add('    echo Installation failed. Check:')
$ib.Add('    echo %LOG%')
$ib.Add('    echo %TEMP%\' + $logBaseName + '_PS.log')
$ib.Add('    pause')
$ib.Add('    exit /b %RESULT%')
$ib.Add(')')
$ib.Add('')
$ib.Add('echo Installation completed.')
$ib.Add('exit /b 0')

[System.IO.File]::WriteAllLines($installBatPath, $ib, [System.Text.Encoding]::ASCII)
Write-Ok 'Install.bat written'

# ============================================================
# Sub-task 5 – Generate SED
# ============================================================
Write-Step 'Generating IExpress SED...'

$setupExePath = Join-Path $OutputDir $SetupName
$finishMsg    = "$AppName installation completed."
$friendlyName = "$AppName Setup"

# Build file list entries dynamically
$sedFiles = [System.Collections.Generic.List[string]]::new()
$sedFiles.Add('Install.bat')
$sedFiles.Add('Install.ps1')
$sedFiles.Add('Uninstall.ps1')
$sedFiles.Add('Uninstall.bat')
$sedFiles.Add('payload.zip')
if ($Sign -and $certFileInWorkDir) { $sedFiles.Add($CertFileName) }

$fileEntriesStr  = ''
$sourceEntryList = ''
for ($i = 0; $i -lt $sedFiles.Count; $i++) {
    $fileEntriesStr  += "FILE${i}=`"$($sedFiles[$i])`"`r`n"
    $sourceEntryList += "%FILE${i}%=`r`n"
}

$sedContent = "[Version]`r`nClass=IEXPRESS`r`nSEDVersion=3`r`n`r`n" +
    "[Options]`r`nPackagePurpose=InstallApp`r`nShowInstallProgramWindow=1`r`n" +
    "HideExtractAnimation=0`r`nUseLongFileName=1`r`nInsideCompressed=0`r`n" +
    "CAB_FixedSize=0`r`nCAB_ResvCodeSigning=0`r`nRebootMode=N`r`n" +
    "InstallPrompt=%InstallPrompt%`r`nDisplayLicense=%DisplayLicense%`r`n" +
    "FinishMessage=%FinishMessage%`r`nTargetName=%TargetName%`r`n" +
    "FriendlyName=%FriendlyName%`r`nAppLaunched=%AppLaunched%`r`n" +
    "PostInstallCmd=%PostInstallCmd%`r`nAdminQuietInstCmd=%AdminQuietInstCmd%`r`n" +
    "UserQuietInstCmd=%UserQuietInstCmd%`r`nSourceFiles=SourceFiles`r`n`r`n" +
    "[Strings]`r`nInstallPrompt=`r`nDisplayLicense=`r`n" +
    "FinishMessage=$finishMsg`r`n" +
    "TargetName=$setupExePath`r`n" +
    "FriendlyName=$friendlyName`r`n" +
    "AppLaunched=cmd.exe /c Install.bat`r`n" +
    "PostInstallCmd=<None>`r`nAdminQuietInstCmd=`r`nUserQuietInstCmd=`r`n" +
    $fileEntriesStr +
    "[SourceFiles]`r`nSourceFiles0=$WorkDir\`r`n" +
    "[SourceFiles0]`r`n" +
    $sourceEntryList

$sedPath = Join-Path $WorkDir $SedName
[System.IO.File]::WriteAllText($sedPath, $sedContent, [System.Text.Encoding]::ASCII)
Copy-Item -LiteralPath $sedPath -Destination (Join-Path $OutputDir $SedName) -Force
Write-Ok "SED written: $sedPath"

# ============================================================
# Sub-task 6 – Run IExpress
# ============================================================

# IExpress cannot overwrite an existing output EXE — remove it first.
if (Test-Path $setupExePath -PathType Leaf) {
    Remove-Item $setupExePath -Force
}

Write-Step 'Running iexpress.exe...'
Write-Build "  $IExpressExe /N /Q `"$sedPath`""

# Invoke iexpress.exe using the call operator (&) so it runs synchronously in
# the caller's process context — the same as typing the command in the terminal.
# Start-Process and UseShellExecute both detach the GUI process, causing
# WaitForExit() to return immediately before the EXE is written to disk.
# IExpress exit code is unreliable (always 1 even on success); ignore it.
& $IExpressExe /N /Q $sedPath

# IExpress writes the output file asynchronously after its process exits and
# first creates a small stub before filling in the full content.
# Poll until the file exists AND its size has been stable for two consecutive
# 3-second checks (up to 3 minutes total).
$maxWait   = 180
$waited    = 0
$lastSize  = -1
$stableFor = 0
while ($waited -lt $maxWait) {
    Start-Sleep -Seconds 3
    $waited += 3
    if (Test-Path $setupExePath -PathType Leaf) {
        $currentSize = (Get-Item $setupExePath).Length
        if ($currentSize -gt 0 -and $currentSize -eq $lastSize) {
            $stableFor += 3
            if ($stableFor -ge 6) { break }   # stable for two consecutive checks
        } else {
            $stableFor = 0
        }
        $lastSize = $currentSize
    }
}

if (-not (Test-Path $setupExePath -PathType Leaf)) {
    throw "IExpress did not produce '$setupExePath'. " +
          "Inspect '$OutputDir\$SedName' to diagnose."
}

$setupSize = (Get-Item $setupExePath).Length
Write-Ok "Setup EXE created: $setupExePath  ($([math]::Round($setupSize/1MB,2)) MB)"

# ============================================================
# Sub-task 7 (part 2) – Sign Setup EXE + write trust helper
# ============================================================
if ($Sign) {
    Write-Step 'Signing Setup EXE...'
    $sigParams2 = @{
        FilePath      = $setupExePath
        Certificate   = $cert
        HashAlgorithm = 'SHA256'
    }
    if ($tsUrl) { $sigParams2['TimestampServer'] = $tsUrl }

    $sig2 = Set-AuthenticodeSignature @sigParams2
    if ($sig2.Status -notin 'Valid', 'UnknownError') {
        throw "Signing Setup EXE failed: Status=$($sig2.Status)"
    }
    Write-Ok "Setup EXE signed -> $($sig2.Status)"

    # Write Trust-Certificate.ps1
    $trustScriptPath = Join-Path $OutputDir 'Trust-Certificate.ps1'
    $t = [System.Collections.Generic.List[string]]::new()
    $t.Add('<#')
    $t.Add('.SYNOPSIS')
    $t.Add("    Imports the $AppName code-signing certificate into the local machine trust stores.")
    $t.Add('.DESCRIPTION')
    $t.Add("    Run as Administrator on machines that receive $AppName")
    $t.Add('    without going through Setup.exe.')
    $t.Add("    Setup.exe already imports the certificate automatically.")
    $t.Add('')
    $t.Add('    Adds the certificate to:')
    $t.Add('      - LocalMachine\Trusted Root Certification Authorities')
    $t.Add('      - LocalMachine\Trusted Publishers')
    $t.Add('#>')
    $t.Add('[CmdletBinding()]')
    $t.Add('param()')
    $t.Add('')
    $t.Add('$ErrorActionPreference = ' + "'Stop'")
    $t.Add('')
    $t.Add('$id = [Security.Principal.WindowsIdentity]::GetCurrent()')
    $t.Add('$pr = [Security.Principal.WindowsPrincipal]::new($id)')
    $t.Add('if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {')
    $t.Add("    throw 'This script must be run as Administrator.'")
    $t.Add('}')
    $t.Add('')
    $t.Add('$cerPath = Join-Path $PSScriptRoot ' + "'$CertFileName'")
    $t.Add('if (-not (Test-Path -LiteralPath $cerPath)) {')
    $t.Add('    throw "Certificate file not found: $cerPath"')
    $t.Add('}')
    $t.Add('')
    $t.Add('Write-Host ""')
    $t.Add("Write-Host 'This will import the following certificate into the local machine trust stores:'")
    $t.Add('Write-Host "  File    : $cerPath"')
    $t.Add("Write-Host '  Subject : $CertSubject'")
    $t.Add("Write-Host '  Stores  : LocalMachine\Root, LocalMachine\TrustedPublisher'")
    $t.Add('Write-Host ""')
    $t.Add('$ans = Read-Host ' + "'Continue? [Y/N]'")
    $t.Add("if (`$ans -notmatch '^[Yy]') { Write-Host 'Cancelled.'; exit 0 }")
    $t.Add('')
    $t.Add("Import-Certificate -FilePath `$cerPath -CertStoreLocation 'Cert:\LocalMachine\Root'             | Out-Null")
    $t.Add("Import-Certificate -FilePath `$cerPath -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher'  | Out-Null")
    $t.Add('')
    $t.Add('Write-Host ""')
    $t.Add("Write-Host 'Certificate imported successfully.' -ForegroundColor Green")
    $t.Add("Write-Host 'Files signed with this certificate will now show as trusted on this machine.'")
    $trustLines = $t
    [System.IO.File]::WriteAllLines($trustScriptPath, $trustLines, [System.Text.Encoding]::UTF8)
    Write-Ok "Trust-Certificate.ps1 written: $trustScriptPath"

    Write-Build ''
    Write-Warn 'This certificate is self-signed and intended for internal testing only.'
    Write-Warn 'SmartScreen may still warn on first run (unknown publisher reputation).'
    Write-Warn 'For production, use a certificate from a trusted CA via -CertThumbprint.'
    Write-Build ''
}

# ============================================================
# Sub-task 6 – Summary
# ============================================================
Write-Build ''
Write-Build '========================================================'
Write-Build ' BUILD COMPLETE'
Write-Build '========================================================'
Write-Build "  App       : $AppName v$Version"
Write-Build "  Setup EXE : $setupExePath"
Write-Build "  Size      : $([math]::Round($setupSize/1MB,2)) MB"
if ($Sign) {
    Write-Build "  Cert      : $(Join-Path $OutputDir $CertFileName)"
    Write-Build "  Trust     : $(Join-Path $OutputDir 'Trust-Certificate.ps1')"
    Write-Build "  Thumbprint: $($cert.Thumbprint)"
    Write-Build "  Expires   : $($cert.NotAfter.ToString('yyyy-MM-dd'))"
}
Write-Build '========================================================'
Write-Build ''

} # end try
finally {
    if (-not $KeepWorkFiles -and (Test-Path $WorkDir)) {
        Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Step 'WorkDir cleaned up.'
    } elseif ($KeepWorkFiles) {
        Write-Step "WorkDir retained (-KeepWorkFiles): $WorkDir"
    }
}
