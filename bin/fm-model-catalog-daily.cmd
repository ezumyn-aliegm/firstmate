@echo off
REM Daily Task Scheduler entry for the live model catalog refresh.
setlocal
set "FM_WINDOWS=1"
set "FM_HOME=C:\work\firstmate-windows"
"C:\Program Files\Git\bin\bash.exe" -lc "export FM_WINDOWS=1 FM_HOME=/c/work/firstmate-windows; /c/work/firstmate-windows/bin/fm-model-catalog.sh"
exit /b %ERRORLEVEL%
