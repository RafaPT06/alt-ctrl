# Account Manager Control Center

Small Windows desktop control panel for the Account Manager remote API. It uses only Python's standard library (Tkinter + urllib), so no pip packages are required.

## Run

Open PowerShell in this folder and set the PC token privately for the current terminal:

```powershell
$env:ACCOUNT_MANAGER_PC_TOKEN="your-private-pc-token"
python account_manager.py
```

Optional overrides:

```powershell
$env:ACCOUNT_MANAGER_API_BASE="https://meowz.up.railway.app"
$env:ACCOUNT_MANAGER_ALT_USER_ID="9039839654"
```

Do not commit your PC token to this repository.

## Current behavior

- polls the remote state endpoint once per second
- displays ALT online/offline state and telemetry
- displays mode, target, effects, health, server, host presence and queued-command count
- queues commands through the authenticated PC command endpoint
- shows server-provided ALT logs when available
- provides quick buttons for common commands

The backend can accept and queue commands already. Actual remote execution still requires the ALT-side authenticated sync/transport to be connected. Until that exists, the dashboard can show the backend state and queue commands, but the phone ALT will not consume them automatically.
