@echo off
:: agy-profile.cmd - Wrapper de goi agy-profile.ps1 tu CMD/PowerShell
:: Dat file nay cung thu muc voi agy-profile.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0agy-profile.ps1" %*
exit /b %ERRORLEVEL%
