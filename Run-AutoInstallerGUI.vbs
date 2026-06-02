Option Explicit

Dim shell, fso, scriptPath, folderPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptPath = WScript.ScriptFullName
folderPath = fso.GetParentFolderName(scriptPath)

command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & _
          Chr(34) & fso.BuildPath(folderPath, "AutoInstallerGUI.ps1") & Chr(34)

shell.Run command, 0, False
