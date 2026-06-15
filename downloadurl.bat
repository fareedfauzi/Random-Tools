@echo off
setlocal enabledelayedexpansion

for /f "usebackq delims=" %%U in ("urls.txt") do (
    set "URL=%%U"

    for %%A in ("!URL:/=\!") do set "FILENAME=%%~nxA"

    echo Downloading !FILENAME! ...

    curl -L --fail -o "!FILENAME!" "!URL!"

    if exist "!FILENAME!" (
        set "MD5="
        set "LINE=0"

        for /f "usebackq tokens=* delims=" %%H in (`certutil -hashfile "!FILENAME!" MD5`) do (
            set /a LINE+=1
            if !LINE! EQU 2 set "MD5=%%H"
        )

        if defined MD5 (
            ren "!FILENAME!" "!MD5!_!FILENAME!_"
            echo Saved as !MD5!_!FILENAME!_
        ) else (
            echo Failed to calculate MD5 for !FILENAME!
        )
    ) else (
        echo Failed to download: !URL!
    )
)

echo Downloads completed.
pause
