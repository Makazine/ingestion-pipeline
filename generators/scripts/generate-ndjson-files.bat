@echo off
setlocal enabledelayedexpansion

REM generate-ndjson-files.bat
REM ===== Configurable =====
set FILES=5
set RECORDS=1000
set OUTPUT=C:\ndjson_test

for /f "tokens=1-3 delims=-/" %%a in ("%date%") do (
    set DATEPREFIX=%%c-%%a-%%b
)

REM Create output directory
if not exist "%OUTPUT%" mkdir "%OUTPUT%"

echo Generating NDJSON in %OUTPUT% with prefix %DATEPREFIX%- ...

REM Random string function
set CHARS=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789

:gen_files
for /l %%F in (1,1,%FILES%) do (
    set FILEPATH=%OUTPUT%\%DATEPREFIX%-file%%F.ndjson
    echo Writing !FILEPATH! ...

    if exist "!FILEPATH!" del "!FILEPATH!"

    for /l %%R in (1,1,%RECORDS%) do (
        REM Generate random 16-char ID
        set ID=
        for /l %%i in (1,1,16) do (
            set /a IDX=!random! %% 62
            for /f %%c in ("!CHARS:~!IDX!,1!") do set ID=!ID!%%c
        )

        REM Select random category
        set /a CATIDX=!random! %% 4
        if !CATIDX!==0 set CATEGORY=alpha
        if !CATIDX!==1 set CATEGORY=beta
        if !CATIDX!==2 set CATEGORY=gamma
        if !CATIDX!==3 set CATEGORY=delta

        REM Timestamp (local format)
        for /f %%t in ('powershell -command "Get-Date -Format o"') do set TIMESTAMP=%%t

        REM Generate payload (50 chars)
        set PAYLOAD=
        for /l %%p in (1,1,50) do (
            set /a IDX=!random! %% 62
            for /f %%c in ("!CHARS:~!IDX!,1!") do set PAYLOAD=!PAYLOAD!%%c
        )

        REM Write JSON record
        >>"!FILEPATH!" echo {"id":"!ID!","timestamp":"!TIMESTAMP!","category":"!CATEGORY!","value":!random!,"payload":"!PAYLOAD!"}
    )
)

echo Done!
exit /b
