$ErrorActionPreference = 'Stop'

$main = {
    $build   = if (!$env:APPVEYOR_BUILD_NUMBER)  { throw '[Build] Missing "APPVEYOR_BUILD_NUMBER" environment variable' }  else { $env:APPVEYOR_BUILD_NUMBER }
    $version = if (!$env:APPVEYOR_BUILD_VERSION) { throw '[Build] Missing "APPVEYOR_BUILD_VERSION" environment variable' } else { $env:APPVEYOR_BUILD_VERSION }
    $branch  = if (!$env:APPVEYOR_REPO_BRANCH )  { throw '[Build] Missing "APPVEYOR_REPO_BRANCH " environment variable' }  else { $env:APPVEYOR_REPO_BRANCH  }

    # Strip build number from the version, assuming the APPVEYOR_BUILD_VERSION is in .NET format
    # Note that Version.Build is actually 'patch'
    $parsedVersion = [Version] $version
    $version = "$($parsedVersion.Major).$($parsedVersion.Minor).$($parsedVersion.Build)"

    $semver = Get-SemverVersion $version $branch $build
    $version = $version + '.' + $build

    Write-Host "Setting semver version to `"$semver`""
    Write-Host "Setting assembly version to `"$version`""

    Update-AppveyorBuild -Version $semver
    Set-AppveyorBuildVariable -Name 'SemverVersion' -Value $semver
    Set-AppveyorBuildVariable -Name 'AssemblyVersion' -Value $version
}

function Get-SemverVersion() {
    [CmdletBinding()]
    param (
        [parameter()] [string] $Version,
        [parameter()] [string] $Branch,
        [parameter()] [string] $Build
    )

    $Branch = if ($Branch) { $Branch.ToLowerInvariant().Trim() } else { '' }
    if ($Branch -eq 'master') {
        $stage = $null
    } elseif ($Branch -eq 'test') {
        $stage = 'test.' + $build
    } elseif ($Branch -eq 'dev') {
        $stage = 'pre.' + $build
    } else {
        # Sanitize branch name by extracting the last, meaningful, part
        $parts = $Branch.Split("/")
        if ($parts.Count -eq 1) {
            $meaningful = $Branch
        } else {
            $meaningful = $parts[$parts.Count - 1]
        }
        $stage = 'dev.' + $meaningful + '.' + $Build
    }

    # Sanitize stage
    $stage = $stage -replace "[^A-Za-z0-9\-_.]+", "-"
    # Add version
    $semver = $Version
    # Add stage
    if ($stage -ne $null) { $semver = $semver + '-' + $stage }
    # Add build number as metadata
    $semver = $semver + '+build.' + $Build
    $semver
    return
}

& $main
