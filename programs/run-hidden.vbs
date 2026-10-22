' run-hidden.vbs - start hourly.ps1 with no console window (used by Task Scheduler).
' WScript.Shell.Run with window style 0 keeps the process in the user session but
' never creates a visible window, so the hourly job does not steal focus.
Option Explicit

Dim fso, shell, dir, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

dir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ _
    & dir & "\hourly.ps1"" -NoPause"

shell.Run cmd, 0, True
