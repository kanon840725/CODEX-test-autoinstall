# CODEX-test-autoinstall
This is my first vibe coding presentation, aiming to make and share some self-using apps. 

How to use:
1. Double-click Run-AutoInstallerGUI.cmd.
2. Click "Restart as admin" if the window says it is not running as administrator.
3. Click "Select folder..." to choose the installer folder in a GUI window, or click "New temp" to create a temporary folder.
4. Put your installer files in that folder, then click "Scan".
5. Click "Start installing".


Supported installer files:
- .msi: installed with Windows Installer silent defaults.
- .msu: installed with Windows Update Standalone Installer quiet mode.
- .exe: best-effort silent install. EXE installers use different silent switches, so the tool tries common defaults and records failures in the log.
