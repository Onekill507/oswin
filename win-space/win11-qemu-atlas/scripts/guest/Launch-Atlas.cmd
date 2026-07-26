@echo off
:: Double-click from the desktop inside noVNC to open AME Wizard with the
:: Atlas Playbook already sitting next to it.
title AtlasOS - AME Wizard launcher
color 0B

set "PAYLOAD=C:\Atlas\payload"
set "WIZ=%PAYLOAD%\AMEWizard"

echo(
echo  ==========================================================
echo    AtlasOS staging - AME Wizard launcher
echo  ==========================================================
echo(

if not exist "%WIZ%" (
    echo  [!] AME Wizard was not staged. Re-run the bootstrap:
    echo      powershell -ExecutionPolicy Bypass -File C:\Atlas\scripts\guest-bootstrap.ps1
    echo(
    pause & exit /b 1
)

echo  Playbooks found in %PAYLOAD%:
dir /b "%PAYLOAD%\*.apbx" 2>nul || echo    (none - download one from github.com/Atlas-OS/Atlas/releases)
echo(
echo  Readiness checklist:
type "C:\Atlas\logs\checklist.txt" 2>nul
echo(
echo  Before you continue, confirm inside Windows Security:
echo    - Real-time protection ....... OFF
echo    - Tamper protection .......... OFF
echo  AME Wizard refuses to run otherwise.
echo(
echo  Then drag the .apbx file onto the AME Wizard window.
echo(
pause

for %%F in ("%WIZ%\*.exe") do (
    echo  Starting %%~nxF ...
    start "" "%%~fF"
    goto :done
)

echo  [!] No .exe inside %WIZ%
pause
:done
