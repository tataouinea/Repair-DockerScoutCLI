<#
    Repair-DockerScoutCLI.ps1

    Purpose
    -------
    Safe, guided workaround to fix Docker Desktop's Scout CLI update issue on Windows 10/11
    by manually installing the Docker Scout CLI plugin and configuring Docker to load it.

    What this script does
    ---------------------
    1) Detects your CPU architecture (amd64 or arm64) and selects the proper Docker Scout ZIP
       from the latest official GitHub release.
    2) If an older docker-scout.exe is already installed, offers to upgrade it; otherwise installs fresh.
    3) Downloads the ZIP to a unique temp folder (won't overwrite existing files).
    4) Extracts and installs docker-scout.exe to: %USERPROFILE%\.docker\scout
       - Creates the folder if missing.
       - If docker-scout.exe already exists there, skips re-install.
    5) Safely updates %USERPROFILE%\.docker\config.json to include:
         "cliPluginsExtraDirs": ["<your_user_profile>\\.docker\\scout"]
       - Creates a timestamped backup before writing.
       - If already configured, leaves it unchanged.

    Safety & trust
    --------------
    - No admin rights required; changes are confined to your user profile.
    - Always asks for confirmation before making changes (use -Yes to auto-confirm).
    - Creates backups where appropriate and skips steps already satisfied.
    - Uses only official GitHub release URLs for Docker Scout CLI (latest release).

    References
    ----------
    - Original Docker for Windows issue thread:
      https://github.com/docker/for-win/issues/14807
    - My comment with the manual workaround:
      https://github.com/docker/for-win/issues/14807#issuecomment-3175147951
    - Docker Scout CLI releases:
      https://github.com/docker/scout-cli/releases

    Requirements
    ------------
    - Windows 10/11 with Windows PowerShell 5.1 (preinstalled on Windows). PowerShell 7 is NOT required.

    Usage (example via iex once this script is published in a repo)
    --------------------------------------------------------------
    powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr -UseBasicParsing 'https://raw.githubusercontent.com/tataouinea/Repair-DockerScoutCLI/main/Repair-DockerScoutCLI.ps1')"
#>
[CmdletBinding()]
param(
    # Auto-confirm all prompts (non-interactive). Default: prompts before changes
    [switch]$Yes
)

# Fail fast on errors
$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO ] $Message" -ForegroundColor Cyan
}
function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN ] $Message" -ForegroundColor Yellow
}
function Write-Ok {
    param([string]$Message)
    Write-Host "[ OK  ] $Message" -ForegroundColor Green
}
function Write-Err {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}
function Confirm-Action {
    param(
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Yes) { return $true }
    $choices = @(
        (New-Object System.Management.Automation.Host.ChoiceDescription '&Yes', 'Proceed with this action.'),
        (New-Object System.Management.Automation.Host.ChoiceDescription '&No', 'Skip this action.')
    )
    $result = $Host.UI.PromptForChoice('Confirmation', $Message, $choices, 1)
    return ($result -eq 0)
}

function Get-OsArchLabel {
    # Returns 'amd64' or 'arm64'
    try {
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
        switch ($arch) {
            'x64' { return 'amd64' }
            'arm64' { return 'arm64' }
            default {
                # Fallback to env var
                if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { return 'arm64' } else { return 'amd64' }
            }
        }
    }
    catch {
        if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { return 'arm64' } else { return 'amd64' }
    }
}

function Get-InstalledDockerScoutVersion {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath
    )
    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) { return $null }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ExePath
        $psi.Arguments = 'version'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        $combined = "$out`n$err"
        # Look for vX.Y.Z
        $m = [regex]::Match($combined, 'v(?<v>\d+\.\d+\.\d+)')
        if ($m.Success) { return $m.Groups['v'].Value }
        return $null
    }
    catch {
        return $null
    }
}

function Get-LatestDockerScoutVersion {
    <#
        Resolves the latest Docker Scout CLI version by following the GitHub
        releases "latest" redirect and extracting the vX.Y.Z tag.

        Returns: version string like "1.18.3" (without the leading 'v').
    #>
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {}

    $latestUrl = 'https://github.com/docker/scout-cli/releases/latest'
    $finalUri = $null

    # Prefer .NET HttpClient for consistent redirect handling
    try {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $true
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('Repair-DockerScoutCLI/1.0 (+https://github.com/tataouinea/Repair-DockerScoutCLI)')

        # Use HEAD to avoid downloading page content; fall back to GET if needed
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Head, $latestUrl)
        try {
            $res = $client.SendAsync($req).GetAwaiter().GetResult()
        } catch {
            # Fallback to GET if HEAD not supported
            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $latestUrl)
            $res = $client.SendAsync($req).GetAwaiter().GetResult()
        }
        $finalUri = $res.RequestMessage.RequestUri.AbsoluteUri
        $client.Dispose()
    }
    catch {
        # Fallback: PowerShell Invoke-WebRequest
        try {
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                $resp = Invoke-WebRequest -Uri $latestUrl -MaximumRedirection 10
            } else {
                $resp = Invoke-WebRequest -UseBasicParsing -Uri $latestUrl -MaximumRedirection 10
            }
            # After following redirects, ResponseUri should point to the final tag URL
            $finalUri = $resp.BaseResponse.ResponseUri.AbsoluteUri
        }
        catch {
            throw "Could not resolve latest release URL: $($_.Exception.Message)"
        }
    }

    if (-not $finalUri) { throw 'Could not determine final release URL for latest version.' }
    $m = [regex]::Match($finalUri, '/tag/v(?<v>\d+\.\d+\.\d+)\b')
    if (-not $m.Success) { throw "Could not parse version from URL: $finalUri" }
    return $m.Groups['v'].Value
}

try {
    Write-Info "Checking PowerShell version and environment..."
    $psv = $PSVersionTable.PSVersion
    if ($psv.Major -lt 5 -or ($psv.Major -eq 5 -and $psv.Minor -lt 1)) {
        throw "This script requires Windows PowerShell 5.1 or later. Current: $psv"
    }

    # Detect Windows reliably on both Windows PowerShell 5.1 and PowerShell 7+
    $IsOnWindows = $false
    try {
        $IsOnWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
    }
    catch {
        $IsOnWindows = ($env:OS -eq 'Windows_NT')
    }
    if (-not $IsOnWindows) {
        throw "This script is intended for Windows only."
    }

    Write-Ok "PowerShell $psv detected on Windows."

    # Resolve latest version via GitHub redirect (e.g., .../releases/tag/v1.18.3)
    $version = Get-LatestDockerScoutVersion
    $arch = Get-OsArchLabel
    $baseUrl = "https://github.com/docker/scout-cli/releases/download/v$version"
    $zipName = if ($arch -eq 'arm64') { "docker-scout_${version}_windows_arm64.zip" } else { "docker-scout_${version}_windows_amd64.zip" }
    $downloadUrl = "$baseUrl/$zipName"

    Write-Info "Target Docker Scout CLI v$version for $arch"
    Write-Info "Release URL: $downloadUrl"

    $destDir = Join-Path $home ".docker\scout"
    $configPath = Join-Path $home ".docker\config.json"

    Write-Info "Planned install directory: $destDir"
    Write-Info "Docker config path: $configPath"

    if (-not (Confirm-Action "Proceed with installing/verifying Docker Scout CLI and updating Docker config?")) {
        Write-Warn "User cancelled at initial confirmation. No changes were made."
        return
    }

    # Ensure destination directory exists
    if (-not (Test-Path -LiteralPath $destDir -PathType Container)) {
        if (Confirm-Action "Create directory '$destDir'?") {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            Write-Ok "Created: $destDir"
        }
        else {
            throw "Cannot proceed without destination directory '$destDir'. User declined creation."
        }
    }
    else {
        Write-Ok "Directory exists: $destDir"
    }

    $targetExe = Join-Path $destDir 'docker-scout.exe'
    $installedVersion = Get-InstalledDockerScoutVersion -ExePath $targetExe
    $needInstall = $true
    if ($installedVersion) {
        if ($installedVersion -eq $version) {
            Write-Ok "docker-scout.exe already at latest v$installedVersion. Skipping download/install."
            $needInstall = $false
        }
        else {
            Write-Info "Installed version detected: v$installedVersion; latest available: v$version"
            if (-not (Confirm-Action "Upgrade docker-scout.exe from v$installedVersion to v$version in '$destDir'?")) {
                Write-Warn "User chose not to upgrade. Skipping download/install."
                $needInstall = $false
            }
        }
    }
    else {
        Write-Info "docker-scout.exe not found in destination. Preparing download and install..."
        if (-not (Confirm-Action "Download and install Docker Scout CLI v$version ($arch) to '$destDir'?")) {
            Write-Warn "User chose not to download/install. Skipping to config update."
            $needInstall = $false
        }
    }

    if ($needInstall) {
            # Create unique temp working area
            $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $tempRoot = Join-Path $env:TEMP "RepairDockerScoutCLI_${stamp}_$([Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
            $zipPath = Join-Path $tempRoot $zipName
            $extractDir = Join-Path $tempRoot 'extracted'

            Write-Info "Downloading to: $zipPath"
            try {
                # Enforce TLS 1.2 for GitHub
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            }
            catch { }

            if ($PSVersionTable.PSVersion.Major -ge 6) {
                Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath
            }
            else {
                Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $zipPath
            }
            $size = (Get-Item $zipPath).Length
            Write-Ok "Downloaded archive ($([Math]::Round($size/1MB,2)) MB)."

            New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
            Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
            Write-Ok "Extracted archive."

            $exe = Get-ChildItem -Path $extractDir -Recurse -Filter 'docker-scout*.exe' | Select-Object -First 1
            if (-not $exe) { throw "Could not locate docker-scout executable within the archive." }

            if (-not (Test-Path -LiteralPath $destDir -PathType Container)) {
                throw "Destination directory '$destDir' does not exist."
            }

            Copy-Item -LiteralPath $exe.FullName -Destination $targetExe -Force -ErrorAction Stop
            Write-Ok "Installed: $targetExe"

            # Attempt cleanup of temp area
            try {
                Remove-Item -Recurse -Force -LiteralPath $tempRoot
                Write-Info "Cleaned up temporary files."
            }
            catch {
                Write-Warn "Could not remove temp directory '$tempRoot'. You may delete it manually."
            }
    }

    # Update Docker config.json with cliPluginsExtraDirs
    Write-Info "Verifying Docker config for cliPluginsExtraDirs..."
    $ensureDir = $destDir  # directory to add into cliPluginsExtraDirs

    $configParent = Split-Path -Parent $configPath
    if (-not (Test-Path -LiteralPath $configParent -PathType Container)) {
        if (Confirm-Action "Create directory '$configParent' for Docker config?") {
            New-Item -ItemType Directory -Path $configParent -Force | Out-Null
            Write-Ok "Created: $configParent"
        }
        else {
            throw "Cannot proceed without Docker config directory."
        }
    }

    $configObj = $null
    $hadConfig = $false
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $hadConfig = $true
        try {
            $raw = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop
            $configObj = $raw | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-Warn "Existing config.json could not be parsed as JSON."
            if (-not (Confirm-Action "Backup and replace config.json with a minimal valid JSON?")) {
                throw "Aborting to avoid overwriting an unparseable config.json without consent."
            }
            $backupName = "config.json.backup-by-Repair-DockerScoutCLI-$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
            $backupPath = Join-Path $configParent $backupName
            Copy-Item -LiteralPath $configPath -Destination $backupPath -ErrorAction Stop
            Write-Ok "Backup created: $backupPath"
            $configObj = [ordered]@{}
        }
    }
    else {
        Write-Warn "Docker config.json does not exist."
        if (-not (Confirm-Action "Create a new minimal config.json at '$configPath'?")) {
            throw "Cannot continue without a config.json to update."
        }
        $configObj = [ordered]@{}
    }

    # Ensure cliPluginsExtraDirs is an array and contains $ensureDir
    if (-not ($configObj.PSObject.Properties.Name -contains 'cliPluginsExtraDirs')) {
        if ($configObj -is [hashtable]) {
            $configObj['cliPluginsExtraDirs'] = @()
        }
        else {
            $null = Add-Member -InputObject $configObj -NotePropertyName 'cliPluginsExtraDirs' -NotePropertyValue @() -Force
        }
    }

    # If it's a string, convert to array
    if ($configObj.cliPluginsExtraDirs -is [string]) {
        $configObj.cliPluginsExtraDirs = @($configObj.cliPluginsExtraDirs)
    }

    # Normalize existing entries and check presence (case-insensitive)
    $current = @()
    foreach ($p in @($configObj.cliPluginsExtraDirs)) {
        if ($null -ne $p -and "$p".Trim() -ne '') { $current += "$p" }
    }

    $alreadyPresent = $false
    foreach ($p in $current) {
        if ([string]::Equals($p, $ensureDir, [System.StringComparison]::OrdinalIgnoreCase)) {
            $alreadyPresent = $true; break
        }
    }

    if ($alreadyPresent) {
        Write-Ok "cliPluginsExtraDirs already contains: $ensureDir"
    }
    else {
        if (Confirm-Action "Add '$ensureDir' to cliPluginsExtraDirs in config.json?") {
            $configObj.cliPluginsExtraDirs = @($current + $ensureDir)

            # Backup before writing (even if we created the file in this run, keep consistent safety)
            if (Test-Path -LiteralPath $configPath -PathType Leaf) {
                $backupName = "config.json.backup-by-Repair-DockerScoutCLI-$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
                $backupPath = Join-Path $configParent $backupName
                Copy-Item -LiteralPath $configPath -Destination $backupPath -ErrorAction Stop
                Write-Ok "Backup created: $backupPath"
            }

            $json = $configObj | ConvertTo-Json -Depth 8
            # Reformat with indentation for readability in Windows PowerShell 5.1
            $json = ($json | Out-String)
            Set-Content -LiteralPath $configPath -Value $json -Encoding UTF8
            Write-Ok "Updated: $configPath"
        }
        else {
            Write-Warn "Skipped updating cliPluginsExtraDirs."
        }
    }

    Write-Info "All steps completed."
    Write-Host "Next steps:" -ForegroundColor Magenta
    Write-Host "  1) Open Docker Desktop." -ForegroundColor Magenta
    Write-Host "  2) Confirm the faulty Scout CLI update notification is gone." -ForegroundColor Magenta
    Write-Host "  3) You should now be able to upgrade Docker normally." -ForegroundColor Magenta

    Write-Ok "Done."

}
catch {
    Write-Err $_.Exception.Message
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Err ("At: " + $_.InvocationInfo.PositionMessage)
    }
    exit 1
}
