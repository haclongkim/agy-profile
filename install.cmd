@echo off
:: install.cmd - Install agy-profile on this machine (adds it to the user PATH)
:: Run:   install.cmd                              -> install, asks which shells to set up
::        install.cmd -Shells cmd,powershell,bash  -> install, non-interactive
::        install.cmd -Uninstall                   -> uninstall
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %ERRORLEVEL%
