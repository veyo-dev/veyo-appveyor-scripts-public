<#
.SYNOPSIS
    An AppVeyor build setup script for .NET Core Projects.
.DESCRIPTION
    The script sets assembly version based on AppVeyor build version.
.PARAMETER Version
    The build version. Provided for testing.
    Default: the APPVEYOR_BUILD_VERSION environment variable.
#>
[CmdletBinding()]
param ( [string] $Version   = $env:APPVEYOR_BUILD_VERSION )

$ErrorActionPreference = 'Stop'

if (!$Version)   { throw 'Missing APPVEYOR_BUILD_VERSION environment variable'}
if (!$Workspace) { throw 'Missing APPVEYOR_BUILD_FOLDER environment variable'}
if (!$Branch)    { throw 'Missing APPVEYOR_REPO_BRANCH environment variable'}

$main = {
    Write-Host "Setting assembly version to `"$Version`""

    if ($env:APPVEYOR) {
        Set-AppveyorBuildVariable -Name 'AssemblyVersion' -Value $Version
    }
}

& $main