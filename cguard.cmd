@echo off
:: cguard launcher - lets you type "cguard ..." from any terminal
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cguard.ps1" %*
endlocal
exit /b %ERRORLEVEL%
