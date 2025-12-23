@echo off
setlocal enabledelayedexpansion

REM -------------------------------
REM CONFIGURATION
REM -------------------------------
set FILES=5
set RECORDS=1000
set OUTPUT=C:\ndjson_small
set CHARS=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789

REM -------------------------------
REM GET DATE IN yyyy-mm-dd WITHOUT POWERSHELL
REM -------------------------------

REM Extract digits from %DATE% into a clean numeric string
set RAWDATE=
for /f "delims=0123456789" %%A in ("%date%") do (
    REM Not used, but required for parsing
)
for /f "tokens=1-3 delims=/- " %%a in ("%date%") do (
    set D1=%%a
    set D2=%%b
    set D3=%%c
)

REM Detect format (MM-DD-YYYY, DD-MM-YYYY, YYYY-MM-DD)
REM Check which token has 4 digits → that's the year
if "!D1!"=="!D1:~0,4!" if "!D1:~4!"=="" (
    REM Format is YYYY-MM-DD or YYYY/DD/MM
    set YEAR=!D1!
    set MONTH=!D2!
    set DAY=!D3!
) else if "!D3!"=="!D3:~0,4!" if "!D3:~4!"=="" (
    REM Format is DD-MM-YYYY or MM/DD/YYYY
    set YEAR=!D3!
    
    REM Determine if first token is month or day:
    if !D1! LEQ 12 (
        set MONTH=!D1!
        set DAY=!D2!
    ) else (
        set DAY=!D1!
        set MONTH=!D2!
    )
) else (
    echo Could not determine date format from %date%
    exit /b 1
)

REM Zero-pad month/day if needed
if 1%!MONTH! LSS 110 set MONTH=0!MONTH!
if 1%!DAY! LSS 110 set DAY=0!DAY!

set DATEPREFIX=!YEAR!-!MONTH!-!DAY!

REM -------------------------------
REM CREATE OUTPUT FOLDER
REM -------------------------------
if not exist "%OUTPUT%" mkdir "%OUTPUT%"

echo Using date prefix: !DATEPREFIX!-
echo Generating %FILES% NDJSON files...
echo.

REM -------------------------------
REM FILE GENERATION
REM -------------------------------
for /l %%F in (1,1,%FILES%) do (
    set FILEPATH=%OUTPUT%\!DATEPREFIX!-file%%F.ndjson
    echo Creating !FILEPATH!...
    if exist "!FILEPATH!" del "!FILEPATH!"

    for /l %%R in (1,1,%RECORDS%) do (

        REM Generate Random ID (8 chars)
        set ID=
        for /l %%i in (1,1,8) do (
            set /a IDX=!random! %% 62
            for /f %%c in ("!CHARS:~!IDX!,1!") do set ID=!ID!%%c
        )

        REM Generate small payload (20 chars)
        set DATA=
        for /l %%i in (1,1,20) do (
            set /a IDX=!random! %% 62
            for /f %%c in ("!CHARS:~!IDX!,1!") do set DATA=!DATA!%%c
        )

        REM Generate timestamp (simple since no PowerShell)
        set TS=!DATEPREFIX!T12:00:00Z

        REM Write JSON record
        >>"!FILEPATH!" echo {"id":"!ID!","ts":"!TS!","data":"!DATA!"}
    )
)

echo.
echo Done!
exit /b
