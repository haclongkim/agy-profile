@echo off
:: agy-profile.cmd - Wrapper to invoke agy-profile.ps1 from CMD/PowerShell
:: Keep this file in the same folder as agy-profile.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0agy-profile.ps1" %*
exit /b %ERRORLEVEL%
