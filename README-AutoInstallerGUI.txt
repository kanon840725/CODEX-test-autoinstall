Folder Auto Installer for Windows 10
====================================

Files:
- Run-AutoInstallerGUI.cmd: double-click this to start the GUI without keeping a command window open.
- Run-AutoInstallerGUI.vbs: hidden launcher used by the CMD file.
- AutoInstallerGUI.ps1: the main program.

How to use:
1. Double-click Run-AutoInstallerGUI.cmd.
2. Click "Restart as admin" if the window says it is not running as administrator.
3. Click "Select folder..." to choose the installer folder in a GUI window, or click "New temp" to create a temporary folder.
4. Put your installer files in that folder, then click "Scan".
5. Click "Start installing".

Log output:
- The main area only shows the log.
- Selecting and scanning a folder is logged immediately.
- Scan results show the total installer count plus EXE, MSI, and MSU counts.
- During installation, the log shows INSTALLING, then SUCCESS or FAILED for each application.
- After each installer finishes, the next installer starts automatically.
- After all installers finish, the log shows a summary list of successful and failed applications.

Supported installer files:
- .msi: installed with Windows Installer silent defaults.
- .msu: installed with Windows Update Standalone Installer quiet mode.
- .exe: best-effort silent install. EXE installers use different silent switches, so the tool tries common defaults and records failures in the log.

Notes:
- Some EXE installers do not support silent install, or use custom switches.
- Leave "Fallback to normal installer window" unchecked if you want fully unattended behavior.
- Failed or skipped installer files are moved into a "Fail" folder inside the chosen installer folder.
- A log file named InstRec-MMdd.txt is written into the chosen installer folder after scanning.
