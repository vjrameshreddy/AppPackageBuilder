@echo off
setlocal EnableDelayedExpansion

:: ============================================================
:: Build-Package.bat
:: Launcher for Build-IExpressPackage.ps1
::
:: Edit the USER CONFIGURATION section below, then double-click
:: this file (or run it in a terminal) to build your package.
:: ============================================================


:: ============================================================
::  USER CONFIGURATION
::  Edit the values below to match your application.
::  All settings in this section are the only ones you need to
::  change for a different app.
:: ============================================================

:: --- Required ---
:: Folder whose contents become the installed application.
:: Use a relative path (from this .bat file) or an absolute path.
set "PAYLOAD_DIR=.\Payload"

:: Human-readable application name.
:: Used for the Start Menu folder, Add/Remove Programs and the Setup EXE name.
set "APP_NAME=Stale VEN Reports Generation Utility"

:: File name (not path) of the primary executable inside PAYLOAD_DIR.
:: Used for the Desktop shortcut and (with signing) the default signing target.
set "MAIN_EXE=stale_ven_gui.exe"

:: --- Optional ---
set "VERSION=1.0.1"
set "PUBLISHER=Illumio Tools"

:: Output folder for the final Setup EXE, .cer and trust helper.
:: Leave blank to use the default: <script dir>\Package\Output
set "OUTPUT_DIR="

:: Temporary build folder. Leave blank for default: <script dir>\Package\Build
set "WORK_DIR="

:: Set to 1 to suppress the Desktop shortcut.  0 = create Desktop shortcut.
set "NO_DESKTOP_SHORTCUT=0"

:: Set to 1 to keep the WorkDir after a successful build (for inspection).
set "KEEP_WORK_FILES=0"

:: --- Signing ---
:: Certificate subject for the self-signed cert that is created if none exists.
:: Leave blank to use the default: CN=<PUBLISHER> Code Signing (Self-Signed)
set "CERT_SUBJECT=CN=Illumio Tools Code Signing (Self-Signed)"

:: Validity in years for a newly created self-signed certificate.
set "CERT_VALIDITY_YEARS=10"

:: Thumbprint of an existing certificate in Cert:\CurrentUser\My.
:: When set, overrides CERT_SUBJECT lookup/creation.
:: Leave blank to auto-find or auto-create by subject.
set "CERT_THUMBPRINT="

:: RFC 3161 timestamp server URL.  Leave blank to skip timestamping.
set "TIMESTAMP_SERVER=https://timestamp.digicert.com"

:: ============================================================
::  END OF USER CONFIGURATION — do not edit below this line
:: ============================================================


:: Locate the script next to this .bat file
set "SCRIPT=%~dp0Build-IExpressPackage.ps1"

if not exist "%SCRIPT%" (
    echo.
    echo  ERROR: Build-IExpressPackage.ps1 not found at:
    echo    %SCRIPT%
    echo  Make sure this .bat file is in the same folder as the script.
    echo.
    pause
    exit /b 1
)


:: ============================================================
::  MENU
:: ============================================================
:MENU
cls
echo.
echo  ============================================================
echo   Build-Package  --  %APP_NAME%  v%VERSION%
echo   Publisher : %PUBLISHER%
echo  ============================================================
echo.
echo   [1]  Unsigned build
echo        Output: %APP_NAME% Setup EXE, no signing
echo.
echo   [2]  Signed build  (sign MainExe only)
echo        Creates / reuses self-signed cert, signs %MAIN_EXE%
echo        and Setup EXE; cert auto-trusted on install
echo.
echo   [3]  Signed build  (sign ALL exes in payload)
echo        Same as [2] but signs every .exe in %PAYLOAD_DIR%
echo.
echo   [4]  Show current configuration
echo.
echo   [Q]  Quit
echo.
set /p "CHOICE=  Enter choice [1/2/3/4/Q]: "

if /i "%CHOICE%"=="1" goto BUILD_UNSIGNED
if /i "%CHOICE%"=="2" goto BUILD_SIGNED
if /i "%CHOICE%"=="3" goto BUILD_SIGNED_ALL
if /i "%CHOICE%"=="4" goto SHOW_CONFIG
if /i "%CHOICE%"=="Q" goto DONE
if /i "%CHOICE%"=="q" goto DONE

echo   Invalid choice.  Press any key to try again.
pause >nul
goto MENU


:: ============================================================
::  SHOW CONFIG
:: ============================================================
:SHOW_CONFIG
cls
echo.
echo  ============================================================
echo   Current configuration
echo  ============================================================
echo   PAYLOAD_DIR          : %PAYLOAD_DIR%
echo   APP_NAME             : %APP_NAME%
echo   MAIN_EXE             : %MAIN_EXE%
echo   VERSION              : %VERSION%
echo   PUBLISHER            : %PUBLISHER%
echo   OUTPUT_DIR           : %OUTPUT_DIR%
if "%OUTPUT_DIR%"=="" echo                          (default: Package\Output)
echo   WORK_DIR             : %WORK_DIR%
if "%WORK_DIR%"==""    echo                          (default: Package\Build)
echo   NO_DESKTOP_SHORTCUT  : %NO_DESKTOP_SHORTCUT%
echo   KEEP_WORK_FILES      : %KEEP_WORK_FILES%
echo   CERT_SUBJECT         : %CERT_SUBJECT%
echo   CERT_VALIDITY_YEARS  : %CERT_VALIDITY_YEARS%
echo   CERT_THUMBPRINT      : %CERT_THUMBPRINT%
if "%CERT_THUMBPRINT%"=="" echo                          (auto-find or create)
echo   TIMESTAMP_SERVER     : %TIMESTAMP_SERVER%
echo  ============================================================
echo.
pause
goto MENU


:: ============================================================
::  BUILD HELPERS  — assemble optional flags
:: ============================================================
:ASSEMBLE_OPTIONAL_FLAGS
set "OPT_FLAGS="
if not "%OUTPUT_DIR%"==""          set "OPT_FLAGS=%OPT_FLAGS% -OutputDir '%OUTPUT_DIR%'"
if not "%WORK_DIR%"==""            set "OPT_FLAGS=%OPT_FLAGS% -WorkDir '%WORK_DIR%'"
if "%NO_DESKTOP_SHORTCUT%"=="1"    set "OPT_FLAGS=%OPT_FLAGS% -NoDesktopShortcut"
if "%KEEP_WORK_FILES%"=="1"        set "OPT_FLAGS=%OPT_FLAGS% -KeepWorkFiles"
exit /b 0


:: ============================================================
::  BUILD — UNSIGNED
:: ============================================================
:BUILD_UNSIGNED
call :ASSEMBLE_OPTIONAL_FLAGS
set "PS_CMD=& '%SCRIPT%'"
set "PS_CMD=%PS_CMD% -PayloadDir '%PAYLOAD_DIR%'"
set "PS_CMD=%PS_CMD% -AppName '%APP_NAME%'"
set "PS_CMD=%PS_CMD% -MainExe '%MAIN_EXE%'"
set "PS_CMD=%PS_CMD% -Version '%VERSION%'"
set "PS_CMD=%PS_CMD% -Publisher '%PUBLISHER%'"
set "PS_CMD=%PS_CMD%%OPT_FLAGS%"
goto RUN_BUILD


:: ============================================================
::  BUILD — SIGNED (MainExe only)
:: ============================================================
:BUILD_SIGNED
call :ASSEMBLE_OPTIONAL_FLAGS
set "PS_CMD=& '%SCRIPT%'"
set "PS_CMD=%PS_CMD% -PayloadDir '%PAYLOAD_DIR%'"
set "PS_CMD=%PS_CMD% -AppName '%APP_NAME%'"
set "PS_CMD=%PS_CMD% -MainExe '%MAIN_EXE%'"
set "PS_CMD=%PS_CMD% -Version '%VERSION%'"
set "PS_CMD=%PS_CMD% -Publisher '%PUBLISHER%'"
set "PS_CMD=%PS_CMD% -Sign"
if not "%CERT_SUBJECT%"==""        set "PS_CMD=%PS_CMD% -CertSubject '%CERT_SUBJECT%'"
if not "%CERT_THUMBPRINT%"==""     set "PS_CMD=%PS_CMD% -CertThumbprint '%CERT_THUMBPRINT%'"
if not "%CERT_VALIDITY_YEARS%"=="" set "PS_CMD=%PS_CMD% -CertValidityYears %CERT_VALIDITY_YEARS%"
if not "%TIMESTAMP_SERVER%"==""    set "PS_CMD=%PS_CMD% -TimestampServer '%TIMESTAMP_SERVER%'"
set "PS_CMD=%PS_CMD%%OPT_FLAGS%"
goto RUN_BUILD


:: ============================================================
::  BUILD — SIGNED (all exes)
:: ============================================================
:BUILD_SIGNED_ALL
call :ASSEMBLE_OPTIONAL_FLAGS
set "PS_CMD=& '%SCRIPT%'"
set "PS_CMD=%PS_CMD% -PayloadDir '%PAYLOAD_DIR%'"
set "PS_CMD=%PS_CMD% -AppName '%APP_NAME%'"
set "PS_CMD=%PS_CMD% -MainExe '%MAIN_EXE%'"
set "PS_CMD=%PS_CMD% -Version '%VERSION%'"
set "PS_CMD=%PS_CMD% -Publisher '%PUBLISHER%'"
set "PS_CMD=%PS_CMD% -Sign -SignAllExes"
if not "%CERT_SUBJECT%"==""        set "PS_CMD=%PS_CMD% -CertSubject '%CERT_SUBJECT%'"
if not "%CERT_THUMBPRINT%"==""     set "PS_CMD=%PS_CMD% -CertThumbprint '%CERT_THUMBPRINT%'"
if not "%CERT_VALIDITY_YEARS%"=="" set "PS_CMD=%PS_CMD% -CertValidityYears %CERT_VALIDITY_YEARS%"
if not "%TIMESTAMP_SERVER%"==""    set "PS_CMD=%PS_CMD% -TimestampServer '%TIMESTAMP_SERVER%'"
set "PS_CMD=%PS_CMD%%OPT_FLAGS%"
goto RUN_BUILD


:: ============================================================
::  EXECUTE
:: ============================================================
:RUN_BUILD
echo.
echo  Launching PowerShell...
echo.

:: Write the command to a temp .ps1 file and invoke via -File.
:: cmd cannot safely echo a string containing & > < ' ^ into a file.
:: Instead we pass the command and the temp file path as PS variables
:: via the environment, which is immune to all shell metacharacters.
set "TMP_PS=%TEMP%\BuildPackage_run_%RANDOM%.ps1"
set "BP_CMD=%PS_CMD%"
set "BP_FILE=%TMP_PS%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$env:BP_CMD | Set-Content -LiteralPath $env:BP_FILE -Encoding UTF8"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TMP_PS%"
set "EXIT_CODE=%ERRORLEVEL%"
del "%TMP_PS%" 2>nul
set "BP_CMD="
set "BP_FILE="

echo.
if "%EXIT_CODE%"=="0" (
    echo  Build completed successfully.
) else (
    echo  Build failed with exit code %EXIT_CODE%.
    echo  Check the output above for details.
)
echo.
pause
goto MENU


:DONE
endlocal
