@echo off
setlocal
set "QIMEN_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "QIMEN_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%QIMEN_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop.ps1" %*
set "QIMEN_EXIT=%ERRORLEVEL%"
if not "%QIMEN_EXIT%"=="0" pause
endlocal & exit /b %QIMEN_EXIT%
