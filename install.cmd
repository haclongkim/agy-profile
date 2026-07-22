@echo off
:: install.cmd - Cai dat agy-profile vao may (them vao PATH cua user)
:: Chay:  install.cmd            -> cai dat
::        install.cmd -Uninstall -> go cai dat
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %ERRORLEVEL%
