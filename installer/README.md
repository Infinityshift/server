# LSB Windows Installer

`LSB-Installer.ps1` is the installer and the control panel in one program.
The **Build Windows server package** workflow turns it into `LSB-Installer.exe`
and attaches it to each release next to `lsb-windows.zip`.

## Using it
1. Download `LSB-Installer.exe` from the latest release and run it.
2. Choose a folder (default `C:\LSB`) and press **Install**.
   It installs the Visual C++ runtime if needed (Windows asks for permission),
   downloads the server, creates a private MariaDB database on port 3307 and fills it.
3. Next time, use **LSB Control Panel** on your desktop.

## What gets kept by "Update server"
- The database (it lives in `database\`, outside the server folder)
- `server\settings\` (everything except `settings\default\`)
- `server\modules\init.txt`, your own module folders (`infinityshift`), and any
  module folder that isn't in the new version
- `server\sql\backups\`, `server\log\`, `login.key` / `login.cert`

The previous version is moved to `old\` – delete it once everything works.

## Testing the script without building the .exe
Right-click `LSB-Installer.ps1` → **Run with PowerShell**. If Windows blocks it, run this once in PowerShell:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.
When run this way, **Stop** closes the server programs directly instead of sending them Ctrl+C;
the .exe version shuts them down cleanly.

## Building the .exe yourself (optional)
```powershell
Install-Module ps2exe -Scope CurrentUser
Invoke-ps2exe .\LSB-Installer.ps1 .\LSB-Installer.exe -noConsole -STA
```
