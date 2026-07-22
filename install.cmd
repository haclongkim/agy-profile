@echo off
:: install.cmd - Install agy-profile on this machine (adds it to the user PATH)
:: Run:   install.cmd            -> install
::        install.cmd -Uninstall -> uninstall
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %ERRORLEVEL%
