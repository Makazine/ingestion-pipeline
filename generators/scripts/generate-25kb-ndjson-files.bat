@echo off
setlocal enabledelayedexpansion

set FILES=5
set RECORDS=1000
set OUTPUT=C:\Users\moula\OneDrive\Documents\_Dev\data\batch\ndjson
set CHARS=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789

for /f "tokens=1-3 delims=-/" %%a in ("%date%") do (
    set DATEPREFIX=%%c-%%a-%%b
)

if not exist "%OUTPUT%" mkdir "%OUTPUT%"

echo Generating small NDJSON files...

for /l %%F in (1,1,%FILES%) do (
    set FILEPATH=%OUTPUT%\%DATEPREFIX%-file%%F.ndjson
    echo Creating !FILEPATH!...
    if exist "!FILEPATH!" del "!FILEPATH!"

    for /l %%R in (1,1,%RECORDS%) do (
        set ID=
        for /l %%i in (1,1,8) do (
            set /a IDX=!random! %% 62
            for /f %%c in ("!CHARS:~!IDX!,1!") do set ID=!ID!%%c
        )

        REM Small payload 20 chars
        set DATA=
        for /l %%i in (1,1,20) do (
            set /a IDX=!random! %% 62
            for /f %%c in ("!CHARS:~!IDX!,1!") do set DATA=!DATA!%%c
        )

        for /f %%t in ('powershell -command "Get-Date -Format o"') do set TS=%%t

        >>"!FILEPATH!" echo {"id":"!ID!","ts":"!TS!","data":"!DATA!"}
    )
)

echo Done!
exit /b
