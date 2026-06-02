@echo off
set "LAUNCHER=%~dp0Run-AutoInstallerGUI.vbs"
start "" wscript.exe "%LAUNCHER%"
exit /b
