# Installs the standalone Ox CLI on Windows. Compatible with Windows PowerShell 5.1 and PowerShell 7.
# Preferences stay inside functions because `irm ... | iex` runs this script in the caller's session.

function Get-OxDownload([string]$Url, [string]$Path) {
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec 300 -Headers @{ 'User-Agent' = 'ox-cli-installer' }
}

function Install-Ox {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'install.ps1 supports Windows; use install.sh on macOS and Linux' }
  $architecture = $env:PROCESSOR_ARCHITEW6432
  if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }
  switch ($architecture) {
    'AMD64' { $platform = 'windows-x64' }
    'ARM64' { $platform = 'windows-arm64' }
    default { throw "Unsupported CPU architecture: $architecture" }
  }

  $installDir = $env:OX_INSTALL_DIR
  if (-not $installDir) { $installDir = Join-Path $env:LOCALAPPDATA 'Programs\Ox\bin' }
  if (-not [IO.Path]::IsPathRooted($installDir)) { throw 'OX_INSTALL_DIR must be an absolute path' }
  $installDir = $installDir.TrimEnd('\', '/')
  $target = Join-Path $installDir 'ox.exe'
  $existing = Get-Command ox -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($existing -and $existing.Source -ne $target) {
    throw "ox already resolves to $($existing.Source). Remove that installation or set OX_INSTALL_DIR to its directory, then retry."
  }
  if (Test-Path -LiteralPath $target -PathType Container) { throw "$target is a directory" }

  New-Item -ItemType Directory -Force -Path $installDir | Out-Null
  $staging = Join-Path $installDir (".ox-install." + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $staging | Out-Null
  try {
    $version = $env:OX_CLI_VERSION
    if (-not $version) {
      $versions = @()
      for ($page = 1; ; $page++) {
        $releasesPath = Join-Path $staging 'releases.json'
        Get-OxDownload "https://api.github.com/repos/ziyzhu/openox/releases?per_page=100&page=$page" $releasesPath
        # Windows PowerShell 5.1 emits a JSON array as one object; assign before wrapping.
        $releases = Get-Content -LiteralPath $releasesPath -Raw | ConvertFrom-Json
        $releases = @($releases)
        $versions += $releases | ForEach-Object { if ($_.tag_name -match '^ox-cli-v(\d+\.\d+\.\d+)$') { [version]$Matches[1] } }
        if ($releases.Count -ne 100) { break }
      }
      $latest = $versions | Sort-Object -Descending | Select-Object -First 1
      if (-not $latest) { throw 'No standalone Ox CLI release is available yet' }
      $version = $latest.ToString()
    }
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'OX_CLI_VERSION must be a version such as 0.1.0' }

    $archive = "ox-cli-$platform.zip"
    $release = "https://github.com/ziyzhu/openox/releases/download/ox-cli-v$version"
    Write-Host "Installing Ox CLI $version for $platform..."
    Get-OxDownload "$release/$archive" (Join-Path $staging $archive)
    Get-OxDownload "$release/SHA256SUMS" (Join-Path $staging 'SHA256SUMS')
    $checksums = @(Get-Content -LiteralPath (Join-Path $staging 'SHA256SUMS') | Where-Object { ($_ -split '\s+')[1] -eq $archive })
    if ($checksums.Count -ne 1) { throw 'Release checksums are missing or ambiguous' }
    $expected = ($checksums[0] -split '\s+')[0]
    if ($expected -notmatch '^[0-9a-fA-F]{64}$') { throw 'Invalid release checksum' }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $staging $archive)).Hash
    if ($actual -ne $expected) { throw 'Download checksum verification failed' }

    Expand-Archive -LiteralPath (Join-Path $staging $archive) -DestinationPath (Join-Path $staging 'extract')
    $downloaded = Join-Path $staging 'extract\ox.exe'
    if (-not (Test-Path -LiteralPath $downloaded -PathType Leaf)) { throw 'The release does not contain an Ox executable' }
    $installedVersion = (& $downloaded --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'The downloaded executable could not run on this machine' }
    if ($installedVersion -ne $version) { throw "Downloaded version $installedVersion does not match $version" }
    Move-Item -LiteralPath $downloaded -Destination $target -Force
    Write-Host "Installed $target"
  } finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  }

  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $entries = @($userPath -split ';' | Where-Object { $_ })
  if ($entries -notcontains $installDir -and $env:OX_NO_MODIFY_PATH -ne '1') {
    [Environment]::SetEnvironmentVariable('Path', (@($entries) + $installDir) -join ';', 'User')
    $env:Path = "$env:Path;$installDir"
    Write-Host "Added $installDir to your user PATH. Run: ox --help"
  } elseif ($entries -notcontains $installDir) {
    Write-Host "Add $installDir to your PATH, then run: ox --help"
  } else {
    Write-Host 'Run: ox --help'
  }
}

Install-Ox
