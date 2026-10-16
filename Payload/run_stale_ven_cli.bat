@echo off
:: =============================================================================
:: VEN Cleanup - Batch Runner
:: =============================================================================
:: Drop your PCE workload export CSV into the same folder as this file,
:: update the INPUT_FILE variable below, then double-click or run from cmd.
:: =============================================================================

:: ── CONFIGURATION ────────────────────────────────────────────────────────────

:: Path to the PCE workload export CSV (relative or absolute)
set INPUT_FILE=workload_export.csv

:: Heartbeat threshold in days (default: 60)
set DAYS=60

:: Base output directory — a dated sub-folder will be created inside this
set BASE_DIR=%userprofile%\OneDrive - IBM\Documents\Stale_VEN_Cleanup_Gen_Reports

:: Date the PCE export was fetched — YYYY-MM-DD format, e.g. 2026-07-21
:: Leave blank to use today's date (default behaviour).
:: Set this when re-running the script against an older export so that elapsed
:: days and output filenames reflect the actual export date, not the run date.
set REPORT_DATE=

:: ─────────────────────────────────────────────────────────────────────────────

:: Security: DAYS and REPORT_DATE are expanded into command lines below, so accept
:: only digits / YYYY-MM-DD (allow-list) and refuse anything else before it is used.
echo %DAYS%| findstr /R /X "[0-9][0-9]*" >nul
if errorlevel 1 (
    echo ERROR: DAYS must be a whole number, e.g. 60.
    pause
    exit /b 1
)
if not "%REPORT_DATE%"=="" (
    echo %REPORT_DATE%| findstr /R /X "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]" >nul
    if errorlevel 1 (
        echo ERROR: REPORT_DATE must be blank or in YYYY-MM-DD format, e.g. 2026-07-21.
        pause
        exit /b 1
    )
)

:: Build the dated sub-folder name (DD-Month-YYYY) from REPORT_DATE if set,
:: or from today's date if not.  PowerShell reads REPORT_DATE from the environment
:: ($env:REPORT_DATE) instead of having it pasted into the command text, and uses the
:: invariant culture so the month name always matches the tool's file names.
set RUN_DATE=
if not "%REPORT_DATE%"=="" (
    for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "try { [datetime]::ParseExact($env:REPORT_DATE,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture).ToString('dd-MMMM-yyyy',[Globalization.CultureInfo]::InvariantCulture) } catch { }"`) do set RUN_DATE=%%i
    if not defined RUN_DATE (
        echo ERROR: REPORT_DATE is not a valid calendar date: %REPORT_DATE%
        pause
        exit /b 1
    )
) else (
    for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "(Get-Date).ToString('dd-MMMM-yyyy',[Globalization.CultureInfo]::InvariantCulture)"`) do set RUN_DATE=%%i
)
set OUT_DIR=%BASE_DIR%\%RUN_DATE%

echo.
echo ============================================================
echo  Stale VEN Report Genaration Automation
echo ============================================================
echo  Input file  : %INPUT_FILE%
echo  Threshold   : %DAYS% days since last heartbeat
echo  Report date : %REPORT_DATE% (blank = today)
echo  Base dir    : %BASE_DIR%
echo  Output dir  : %OUT_DIR%
echo ============================================================
echo.

:: Check input file exists
if not exist "%INPUT_FILE%" (
    echo ERROR: Input file not found: %INPUT_FILE%
    echo        Update the INPUT_FILE variable at the top of this batch file.
    pause
    exit /b 1
)

:: Basic guardrail: reject previously generated batch/master CSVs instead of the
:: original PCE workload export. Those files only contain href,hostname,TMP and
:: will fail stale-heartbeat processing.
:: The path is read from $env:INPUT_FILE (-LiteralPath) rather than pasted into the command.
powershell -NoProfile -Command "$headers = (Get-Content -LiteralPath $env:INPUT_FILE -TotalCount 1); if ($headers -match '^(?:""|)?href(?:""|)?\s*,\s*(?:""|)?hostname(?:""|)?\s*,\s*(?:""|)?TMP(?:""|)?$') { exit 2 } else { exit 0 }"
if errorlevel 2 (
    echo ERROR: INPUT_FILE points to a generated stale VEN output CSV, not the original PCE workload export.
    echo        Detected header: href, hostname, TMP
    echo        Please select the original workload export CSV from PCE that includes the last heartbeat column.
    pause
    exit /b 1
)

:: Create the dated output directory if it doesn't exist
if not exist "%OUT_DIR%" (
    mkdir "%OUT_DIR%"
    echo Created output directory: %OUT_DIR%
    echo.
)

:: Write the launcher banner to the log file so the complete console output
:: (banner + tool summary) ends up in one place.
:: The Python script appends its own output to the same file via _Tee.
set LOG_FILE=%OUT_DIR%\run_log_%RUN_DATE%.txt
(
    echo ============================================================
    echo  Stale VEN Report Genaration Automation
    echo ============================================================
    echo  Input file  : %INPUT_FILE%
    echo  Threshold   : %DAYS% days since last heartbeat
    echo  Report date : %REPORT_DATE% (blank = today)
    echo  Base dir    : %BASE_DIR%
    echo  Output dir  : %OUT_DIR%
    echo ============================================================
    echo.
) > "%LOG_FILE%"

:: Build the optional --report-date argument
set REPORT_DATE_ARG=
if not "%REPORT_DATE%"=="" set REPORT_DATE_ARG=--report-date %REPORT_DATE%

:: Run stale_ven_cli.exe if present, otherwise fall back to Python script
if exist "%~dp0stale_ven_cli.exe" (
    echo Running standalone executable...
    echo Running standalone executable...>> "%LOG_FILE%"
    "%~dp0stale_ven_cli.exe" "%INPUT_FILE%" --days %DAYS% --out-dir "%OUT_DIR%" %REPORT_DATE_ARG%
) else (
    echo Executable not found, falling back to Python script...
    echo Executable not found, falling back to Python script...>> "%LOG_FILE%"
    python --version >nul 2>&1
    if errorlevel 1 (
        echo ERROR: stale_ven_cli.exe not found and Python is not on PATH.
        echo        Place stale_ven_cli.exe next to this file,
        echo        or install Python from https://www.python.org
        pause
        exit /b 1
    )
    python "%~dp0src\stale_ven_cli.py" "%INPUT_FILE%" --days %DAYS% --out-dir "%OUT_DIR%" %REPORT_DATE_ARG%
)

if errorlevel 1 (
    echo.
    echo ERROR: Script exited with an error. See message above.
    pause
    exit /b 1
)

echo.
echo ============================================================
echo  Done! Output files are in: %OUT_DIR%
echo ============================================================
echo.
pause
