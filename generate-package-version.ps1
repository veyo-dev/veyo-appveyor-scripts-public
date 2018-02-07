<#
.SYNOPSIS
    An AppVeyor build setup script for NuGet-based projects.
.DESCRIPTION
    The script generates a NuGet package version and ensures that the package with the given version does not exist
    in the AppVeyor feed.
.PARAMETER DisableVersionValidation
    Disables the validation of NuGet packages presence in the AppVeyor feed.
    Can be overridden with the DISABLE_VERSION_VALIDATION=true environment variable.
    Default: false.
.PARAMETER PackageId
    The NuGet package identifier. Provided for testing.
    Can be overridden with the PACKAGE_ID environment variable.
    Default: the script will automatically detect NuGet package projects in the workspace.
.PARAMETER Version
    The NuGet package version. Provided for testing.
    Default: the APPVEYOR_BUILD_VERSION environment variable.
.PARAMETER Workspace
    The sources workspace path. Provided for testing.
    Default: the APPVEYOR_BUILD_FOLDER environment variable.
.PARAMETER Branch
    The SCM branch name. Provided for testing.
    Default: the APPVEYOR_REPO_BRANCH environment variable.
.PARAMETER NuGetFeed
    The NuGet feed to use for package versions validation.
    Default: 'AppVeyorAccountFeed'.

    The feed should be registered in the local NuGet sources of the build server before invoking the script.
    The following feeds are enabled by AppVeyor by default:
        1. nuget.org (https://api.nuget.org/v3/index.json)
        2. AppVeyorAccountFeed
        3. AppVeyorProjectFeed
        4. Microsoft Visual Studio Offline Packages (local)
.LINK
    Get-PackageIds
.LINK
    Get-SemverVersion
#>
[CmdletBinding()]
param ( [bool] $DisableVersionValidation = $false,
        [string] $PackageId = $env:PACKAGE_ID,
        [string] $Version   = $env:APPVEYOR_BUILD_VERSION,
        [string] $Workspace = $env:APPVEYOR_BUILD_FOLDER,
        [string] $Branch    = $env:APPVEYOR_REPO_BRANCH,
        [string] $NuGetFeed = 'AppVeyorAccountFeed' )

$ErrorActionPreference = 'Stop'

if (!$Version)   { throw 'Missing APPVEYOR_BUILD_VERSION environment variable'}
if (!$Workspace) { throw 'Missing APPVEYOR_BUILD_FOLDER environment variable'}
if (!$Branch)    { throw 'Missing APPVEYOR_REPO_BRANCH environment variable'}
if ($env:DISABLE_VERSION_VALIDATION -and $env:DISABLE_VERSION_VALIDATION -like 'true') { $DisableVersionValidation = $true }

$main = {
    # Step 1: generate and set versions
    $semver = Get-SemverVersion -version $Version -branch $Branch

    Write-Host "Setting semver-2.0.0 version to `"$semver`""
    Write-Host "Setting assembly version to `"$Version`""

    if ($env:APPVEYOR) {
        Update-AppveyorBuild -Version $semver
        Set-AppveyorBuildVariable -Name 'SemverVersion' -Value $semver
        Set-AppveyorBuildVariable -Name 'AssemblyVersion' -Value $Version
    }

    # Step 2: ensure that packages with the same versions are not present in the AppVeyor NuGet feed
    if (!$DisableVersionValidation) {
        Write-Host "Testing that package versions are not present in the `"$NuGetFeed`" feed"

        # Search for NuGet package ids in the source tree by parsing .csproj files
        $packageIds = if ($PackageId) { @( $PackageId ) } else { Get-PackageIds $Workspace }
        $packageVersion = (Get-SemverVersion -version $Version -branch $Branch -excludeBuildMetadata)

        Confirm-PackagesDoesNotExist -packageIds $packageIds -version $packageVersion -source $NuGetFeed
    }
}

<#
.SYNOPSIS
    Given a list of package identifiers and a package version, validate that there are no packages with the same
    identifier and version exist in the NuGet feed.
.PARAMETER packageIds
    An array of package identifiers.
.PARAMETER version
    The packages version.
.PARAMETER source
    The NuGet feed source.
.OUTPUTS
    An error will be thrown in case of there are any packages with the same version exist in the NuGet feed.
#>
function Confirm-PackagesDoesNotExist() {
    [CmdletBinding()]
    param ( [string[]] $packageIds,
            [string] $version,
            [string] $source )

    $validationFailed = $false

    foreach ($packageId in $packageIds) {
        if (Test-PackageExists -packageId $packageId -version $version -source $source) {
            $validationFailed = $true
            Write-Error -ErrorAction Continue @"
The package "$packageId.$packageVersion" exists in the "$source" feed.
Please make sure you incremented the package version in appveyor.yml.
"@
        }
    }

    if ($validationFailed) { throw 'Failed to validate packages, see the errors above' }
}

<#
.SYNOPSIS
    Given the package identifier, its version, and the NuGet feed check if the package exists in the feed.
.PARAMETER packageId
    The package identifier.
.PARAMETER version
    The package version without build metadata.
.PARAMETER source
    The NuGet feed source.
.OUTPUTS
    true if the package with the specified version exists; otherwise, false
.LINK
    Get-PackageId
#>
function Test-PackageExists() {
    [CmdletBinding()]
    param ( [string] $packageId,
            [string] $version,
            [string] $source )

    Write-Host "Testing existence of `"$packageId.$version`" in the `"$source`" feed"

    # Notes on the naive nuget.exe usage:
    # 1) I am not using NuGet API directly here because we do not have access to the NuGet feed credentials
    #    and I do not want to parametrize all appveyor.ymls for NuGet projects with the feed credentials.
    # 2) NuGet CLI does not support searching by specific package id and version, so I had to list all versions and
    #    grep from the output. Please vote for https://github.com/NuGet/Home/issues/5138
    # 3) Getting all package versions including pre-release ones is kinda okay since we are working with the NuGet
    #    repository almost locally.
    $output = nuget list $packageId -Source $source -AllVersions -Prerelease
    if ($LastExitCode -ne 0) {
        throw "nuget.exe failed with $LastExitCode exit code. See the error message above"
    }

    $matching = $output | Select-String "^$packageId\s+$version\s*`$"
    Write-Verbose '#START `nuget.exe` output:'
    $output | Write-Verbose
    Write-Verbose '#END `nuget.exe` output'

    if ($matching) { $true } else { $false }
}

<#
.SYNOPSIS
    Given the workspace path get package identifiers of all NuGet-based C# projects within the workspace.
.DESCRIPTION
    Searches for all 'packable' C# projects in the workspace directory and finds their `PackageId`.
.PARAMETER workspace
    Directory path where to search for C# projects.
    Default: current folder.
.OUTPUTS
    An array of found package identifiers.
.LINK
    Get-PackageId
#>
function Get-PackageIds() {
    [CmdletBinding()]
    param ([string] $workspace = '')

    if (!$workspace) { $workspace = (Get-Item -Path ".\").FullName }

    Write-Verbose "Searching for *.csproj files in `"$workspace`""
    $projects = Get-Childitem -Path $workspace -Include '*.csproj' -File -Recurse -ErrorAction SilentlyContinue

    return $projects | ForEach-Object { Get-PackageId $_ } | Where-Object { $_ -ne $null }
}

<#
.SYNOPSIS
    Given a project file find a NuGet `PackageId` value.
.DESCRIPTION
    A simple implementation that finds the `PackageId` property in the .csproj and follows one level deep to evaluate
    its value if needed.
    We do not want to go crazy here with a properties evaluation or with loading MSBuild SDK to parse .csproj files.
.PARAMETER project (FileInfo)
    The project file.
.OUTPUTS
    1) The found `PacakgeId` package identifier
    2) The project file base name if `PacakgeId` is not found.
    3) null if the project is not a NuGet one.
       The project is considered a NuGet package if it does not define `IsPackable=False` explicitly.
#>
function Get-PackageId() {
    [CmdletBinding()]
    param ($project)
    [xml] $contents = Get-Content $project

    # IsPackable is defined and set to 'false': return null
    $isPackable = Get-ProjectProperty $contents IsPackable
    if ($isPackable -like 'false') {
        Write-Verbose "`"$project`": project is marked as not packable, skipping"
        return $null
    }

    $packageId = Get-ProjectProperty $contents PackageId

    # PackageId is not defined: return .csproj base file name
    if (!$packageId) { return $project.BaseName }

    # Grep possible property reference from PackageId, e.g. `$(Title)`
    $propertyName = $packageId | Select-String -Pattern '^\$\((.+)\)$' | ForEach-Object { $_.Matches.Groups[1].Value }

    # PackageId is a literal value: return it
    if (!$propertyName) {
        Write-Verbose "`"$project`": found PackageId=`"$packageId`""
        return $packageId
    }

    # PackageId is a reference to another property: try evaluating the property value
    # We do not want to go crazy here, just go a single level deep
    Write-Verbose "`"$project`": getting `"$propertyName`" property value"
    $propertyValue = Get-ProjectProperty $contents $propertyName

    # Property has a value and it is not a reference to another property
    if ($propertyValue -and $propertyValue -notlike '$(*)') {
        Write-Verbose "`"$project`": found PackageId=`"$propertyValue`""
        return $propertyValue
    }

    Write-Verbose "`"$project`": could not find PackageId, using `"$($project.BaseName))`" as PackageId"
    return $project.BaseName
}

<#
.SYNOPSIS
    Given a version and branch generate a semver-2.0.0 version for a NuGet project.
.PARAMETER branch
    The branch name.
.PARAMETER version
    The package version in the 'MAJOR.MINOR.PATCH.BUILD' format.
.PARAMETER excludeBuildMetadata
    Do not append build metadata to the version.
    Used by NuGet search-related functions since the build metadata is ignored per NuGet specs.
    Default: false
.EXAMPLE
    Building a stable version of the package from the 'master' branch:

    Get-SemverVersion -branch 'master' -version 2.0.0.10
    OUTPUT: '2.0.0+build.10'

    Note that the build number is appended to the build metadata.
.EXAMPLE
    Building a pre-release version of the package from the 'dev' branch:

    Get-SemverVersion -branch 'dev' -version 3.0.0.11
    OUTPUT: '3.0.0-pre.11+build.11'

    Note that the build number is appended to both, the build metadata and as a pre-release tag.
.EXAMPLE
    Building a package from the feature branch named 'feature/YYY-123-An-Amazing-Feature':

    Get-SemverVersion -branch 'feature/YYY-123-An-Amazing-Feature' -version 4.0.1.12
    OUTPUT: '4.0.1-dev.yyy-123-an-amazing-feature.12+build.12'

    Note that the part of the branch name is appended as a pre-release tag as well as the build number.
    This approach allows pushing a continuous stream of builds from feature branches without a need to increment
    versions manually each time.
#>
function Get-SemverVersion() {
    [CmdletBinding()]
    param ( [string] $branch,
            [string] $version,
            [switch] $excludeBuildMetadata = $false )
    if (!$version) { throw '"$version" is not specified' }
    if (!$branch) { throw '"$branch" is not specified' }

    $parsedVersion = [Version] $version
    $version = "$($parsedVersion.Major).$($parsedVersion.Minor).$($parsedVersion.Build)"
    $build = if ($parsedVersion.Revision -ge 0) { $parsedVersion.Revision } else { 0 }

    # Generate a version stage
    $branch = $branch.ToLowerInvariant().Trim()
    if ($branch -eq 'master') {
        $stage = $null
    } elseif ($branch -eq 'test') {
        $stage = 'test.' + $build
    } elseif ($branch -eq 'dev') {
        $stage = 'pre.' + $build
    } else {
        # Sanitize the branch name by extracting the last, meaningful part
        $parts = $branch.Split("/")
        $meaningful = if ($parts.Count -eq 1) { $branch } else { $parts[$parts.Count - 1] }
        $stage = 'dev.' + $meaningful + '.' + $build
    }

    # Sanitize stage
    $stage = $stage -replace "[^A-Za-z0-9\-_.]+", "-"
    $semver = $version
    if ($stage) { $semver = $semver + '-' + $stage }
    if (!$excludeBuildMetadata) { $semver = $semver + '+build.' + $build }

    Write-Verbose "Generated `"$semver`" semver-2.0.0 from version=`"$version`", stage=`"$stage`", build=`"$build`""
    return $semver
}

<# Gets the first XML property value from a MSBuild project #>
function Get-ProjectProperty($xml, $property) {
    $xml | Select-Xml -XPath "/Project/PropertyGroup/$property" `
         | Select-Object -First 1 -ExpandProperty Node `
         | Select-Object -ExpandProperty InnerText
}

& $main
