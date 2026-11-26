# Test install of the Store package from this folder (needs Developer Mode).
# Settings > System > For developers > Developer Mode: On. Then right-click this file > Run with PowerShell.
Add-AppxPackage -Register (Join-Path $PSScriptRoot 'AppxManifest.xml')
Write-Host 'Sawaruna (Store test) installed. Open it from the Start menu.'
Read-Host 'Press Enter to close'
