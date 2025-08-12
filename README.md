# Repair Docker Scout CLI on Windows 10/11

A small, safe PowerShell helper that works around a Docker Desktop issue where the built-in updater fails to update Docker Scout CLI (example message: "Unable to install new update" / "An unexpected error occurred while updating").

This script installs the Docker Scout CLI plugin under your user profile and configures Docker Desktop to load it.

- Original issue: https://github.com/docker/for-win/issues/14807
- My comment (workaround): https://github.com/docker/for-win/issues/14807#issuecomment-3175147951
- Docker Scout CLI releases: https://github.com/docker/scout-cli/releases

## What it does

- Detects your CPU architecture (amd64 or arm64) and selects the correct v1.18.2 ZIP from the official release.
- Downloads to a unique temp folder (does not overwrite existing files).
- Installs `docker-scout.exe` to `%USERPROFILE%\.docker\scout` (creates the folder if missing; skips if already installed).
- Updates `%USERPROFILE%\.docker\config.json` to include:
  ```json
  "cliPluginsExtraDirs": ["C:\\Users\\<you>\\.docker\\scout"]
  ```
  - Creates a timestamped backup before writing.
  - If already configured, leaves it unchanged.

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 (preinstalled with Windows). PowerShell 7+ is optional but supported.
- Internet connectivity to download from GitHub releases.

## Quick run

Using Windows PowerShell 5.1 (cmd.exe or Windows Terminal):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr -UseBasicParsing 'https://raw.githubusercontent.com/<your_repo>/main/Repair-DockerScoutCLI.ps1')"
```

Using PowerShell 7+ (pwsh.exe):

```powershell
pwsh -NoProfile -Command "iex (irm 'https://raw.githubusercontent.com/<your_repo>/main/Repair-DockerScoutCLI.ps1')"
```

- Add `-Yes` to auto-confirm all prompts (non-interactive). Because `iex` executes the script immediately, the simplest way is to download to a temp file and run it with `-Yes`:

```powershell
$src = 'https://raw.githubusercontent.com/<your_repo>/main/Repair-DockerScoutCLI.ps1'
$tmp = Join-Path $env:TEMP 'Repair-DockerScoutCLI.ps1'
iwr -UseBasicParsing $src -OutFile $tmp
powershell -NoProfile -ExecutionPolicy Bypass -File $tmp -Yes
```

Note: When invoked via `iex`, the script runs immediately. It asks for confirmation before making changes unless `-Yes` is provided.

## Manual run (clone or download)

```powershell
# From the repo root
powershell -NoProfile -ExecutionPolicy Bypass -File .\Repair-DockerScoutCLI.ps1
```

Options:
- `-Yes` — auto-confirm all actions (useful for CI or non-interactive sessions)

## Safety and idempotency

- No admin rights required; everything is under `%USERPROFILE%`.
- Creates backups of `config.json` with filenames like `config.json.backup-by-Repair-DockerScoutCLI-YYYYMMDD_HHMMSS.json`.
- Skips steps that are already satisfied (existing `docker-scout.exe` or config already set).
- Clear logging and comments in the script so you can audit what it does.

## Verify it worked

1. Open Docker Desktop.
2. The faulty Scout CLI update notification should be gone.
3. You should now be able to upgrade Docker Desktop normally.

## Rollback

- To undo the config change, restore the backup created in `%USERPROFILE%\.docker` (copy the backup file over `config.json`).
- You may also remove `%USERPROFILE%\.docker\scout\docker-scout.exe` if you want to fully revert the plugin installation.

## Notes

- This script targets Docker Scout CLI v1.18.2 to match the version referenced in the issue. You can adapt the version in the script later if needed.
- The script supports both amd64 (x64) and arm64 Windows.

## License

MIT
