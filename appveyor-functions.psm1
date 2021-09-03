<#
    .SYNOPSIS
    Common PowerShell cmdlets for AppVeyor builds.

    .COMPONENT
    AppVeyor
#>
param()

<#
    .SYNOPSIS
        Tags the current commit and pushes the tag to the "origin" remote.

    .PARAMETER Tag
        The Git tag name.
        Default: %build_tag%
#>
function Tag-GitBuild {
    [CmdletBinding()]
    param (
        [parameter()] [string] $Tag = $env:build_tag,
        [parameter()] [string] $Roles = $env:build_roles,
        [parameter()] [string] $GitUser = 'AppVeyor Build Agent',
        [parameter()] [string] $GitEmail = $env:build_notify_email
    )

    if ($env:build_tag_disabled -or $Tag -like 'disabled') {
        Log-Message '[Git] Tagging disabled, skipping'
        return
    }

    if (!$Tag) { throw '[Git] Tag is not set (missing "build_tag" environment variable)' }

    if ($Roles) { $Tag = $Tag + "-" + $Roles.ToLower() }

    # Check the tag already exists
    $output = $(git tag -l $Tag 2>&1)
    if ($output -eq $Tag -or $? -eq $false) {
        Log-Warning "[Git] Tag '$Tag' already exists, skipping"
        return
    }

    Call-NativeCommand "git config --replace-all --global user.name `"$GitUser`""
    Call-NativeCommand "git config --replace-all --global user.email `"$GitEmail`""

    Log-Message "[Git] Tagging Git commit with '$Tag' tag"
    Call-NativeCommand "git tag -a -f -m `"Automated build tagged: $Tag.`" $Tag" -NotifyStandardErrorOkay -IgnoreExitCode

    Log-Message "[Git] Pushing '$Tag' to origin"
    Call-NativeCommand "git push origin $Tag" -NotifyStandardErrorOkay -IgnoreExitCode
}

<#
    .SYNOPSIS
        Transitions JIRA issues matching the query using the default transaction actions for each branch.

    .PARAMETER Address
        The JIRA address.
        Default: https://2pointb.atlassian.net

    .PARAMETER Login
        The login of the JIRA user account performing the transition.
        Default: %jira_login%

    .PARAMETER Password
        The password of the JIRA user account performing the transition.
        Default: %jira_password%

    .PARAMETER ProjectQuery
        The query used to fetch JIRA issues by project i.e. `project = AD` or `project in (AD, YODA)`
        Default: `project = AD`
    .PARAMETER TestBranchName
        The name of the test branch being used for transitions
        Default: test

    .PARAMETER IntegrationBranchName
        The name of the integration branch being used for transitions
        Default: master
#>
function Transition-Branch-JiraIssues {
    [CmdletBinding()]
    param (
        [parameter()] [string] $Address = $env:jira_url,
        [parameter()] [string] $Login = $env:jira_login,
        [parameter()] [string] $Password = $env:jira_password,
        [parameter()] [bool]   $AddComment = $true,
        [parameter()] [string] $ProjectQuery = 'project = YODA',
        [parameter()] [string] $TestBranchName = 'test',
        [parameter()] [string] $IntegrationBranchName = 'master'
    )


    switch ($env:APPVEYOR_REPO_BRANCH) {
        $TestBranchName {
            Log-Message -Message "[JIRA] Transitioning issues for the test branch"
            Transition-JiraIssues -Query "$ProjectQuery AND status in (`"Ready for QA`")"     -Transition "In QA"
        }

        $IntegrationBranchName {
            Log-Message -Message "[JIRA] Transitioning issues for the integration branch"
            Transition-JiraIssues -Query "$ProjectQuery AND status in (`"Ready for Integration`")" -Transition "Integrated"
        }

        default {
            Log-Message -Message "[JIRA] Skipping JIRA Transitions due to being on branch '$env:APPVEYOR_REPO_BRANCH'"
        }
    }
}

<#
    .SYNOPSIS
        Transitions JIRA issues matching the query using the specified transition action.

    .PARAMETER Query
        The JQL query to use for searching JIRA issues to transition.
        Default: %jira_query%

    .PARAMETER Transition
        The transition action name.
        Default: %jira_transition%

    .PARAMETER Address
        The JIRA address.
        Default: https://2pointb.atlassian.net

    .PARAMETER Login
        The login of the JIRA user account performing the transition.
        Default: %jira_login%

    .PARAMETER Password
        The password of the JIRA user account performing the transition.
        Default: %jira_password%

    .PARAMETER AddComment
        Leave a common in matching JIRA issues mentioning that the issue was
        included into certain build or deployment.
        Default: true
#>
function Transition-JiraIssues {
    [CmdletBinding()]
    param (
        [parameter()] [string] $Query = $env:jira_query,
        [parameter()] [string] $Transition = $env:jira_transition,
        [parameter()] [string] $Address = $env:jira_url,
        [parameter()] [string] $Login = $env:jira_login,
        [parameter()] [string] $Password = $env:jira_password,
        [parameter()] [bool]   $AddComment = $true
    )

    if ($env:jira_transition_disabled -or $Transition -like 'disabled') {
        Log-Message '[JIRA] Issues transitioning disabled, skipping'
        return
    }

    if (!$Query) { throw "[JIRA] JQL Query is not specified" }
    if (!$Transition) { throw "[JIRA] Transition is not specified" }
    if (!$Address) { throw "[JIRA] Address is not specified" }
    if (!$Login) { throw "[JIRA] Login is not specified" }
    if (!$Password) { throw "[JIRA] Password is not specified" }

    Prepare-Jira -ErrorAction Continue

    Log-Message "[JIRA] Logging in to $Address"
    Set-JiraConfigServer $Address

    $securePassword = $Password | ConvertTo-SecureString -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($Login, $securePassword)
    New-JiraSession -Credential $credential > $null

    Log-Message "[JIRA] JQL: $Query"
    $issues = Get-JiraIssue -Query $Query

    if ($issues.Count -eq 0) {
        Log-Message "[JIRA] No issues to transition"
        return
    }

    $comment = Create-JiraComment

    foreach ($issue in $issues) {
        # Search for allowed JIRA transition
        $existingTransition = $issue.Transition | ? { $_.Name -like $Transition } | Select -First 1
        if (!$existingTransition) {
            Log-Warning "[JIRA] Issue $($issue.Key) cannot be transitioned with action '$Transition': no transition found"
            continue
        }

        Invoke-JiraIssueTransition -Issue $issue -Transition $existingTransition.ID -ErrorAction Continue
        if ($AddComment) {
            Add-JiraIssueComment -Issue $issue -Comment $comment -ErrorAction Continue > $null
        }

        Log-Message "[JIRA] Issue $($issue.Key) transitioned from '$($issue.Status)' with action '$Transition'"
    }
}

<#
    .SYNOPSIS
        Installs and loads JiraPS module.
#>
function Prepare-Jira {
    [CmdletBinding()] param()

    if ((Get-Module JiraPS) -ne $null) {
        Import-Module JiraPS
        return
    }

    Log-Message "[JIRA] Installing JiraPS module"

    # Check if NuGet package provider installed
    if ((Get-PackageProvider NuGet) -eq $null) {
        Install-PackageProvider NuGet -Force > $null
        Import-PackageProvider NuGet -Force > $null
    }

    # Allow installing from PSGallery:
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    Install-Module JiraPS -Scope CurrentUser -Force
    Import-Module JiraPS
}

<#
    .SYNOPSIS
        Creates a JIRA issue comment text mentioning that the issue was build
        as part of AppVeyor project or deployed to the specific environment (Platform).

    .PARAMETER Tag
        The Git tag name. Default: %build_tag%

    .PARAMETER Branch
        The Git branch name. Default: %build_environment%

    .PARAMETER Environment
        The environment name, optional. Default: %build_environment%

    .PARAMETER TeamUrl
        The AppVeyor team URL. Default: 'https://ci.appveyor.com/project/veyo-dev'

    .PARAMETER ProjectName
        The AppVeyor project name. Default: %APPVEYOR_PROJECT_NAME%

    .PARAMETER ProjectSlug
        The AppVeyor project slug used to build a project link.
        Default: %APPVEYOR_PROJECT_SLUG%

#>
function Create-JiraComment($Tag = $env:build_tag,
    $Branch = $env:APPVEYOR_REPO_BRANCH,
    $Environment = $env:build_environment,
    $TeamUrl = 'https://ci.appveyor.com/project/veyo-dev',
    $ProjectName = $env:APPVEYOR_PROJECT_NAME,
    $ProjectSlug = $env:APPVEYOR_PROJECT_SLUG,
    $ProjectVersion = $env:APPVEYOR_BUILD_VERSION) {
    $projectUrl = $TeamUrl
    if ($ProjectSlug) { $projectUrl = "$projectUrl/$ProjectSlug" }
    if ($ProjectVersion) { $projectUrl = "$projectUrl/build/$ProjectVersion" }
    if (!$ProjectName) { $ProjectName = "Unknown AppVeyor" }
    if (!$Tag) { $Tag = 'unknown-build' }
    if (!$Branch) { $Branch = 'unknown-branch' }

    if ($Environment) {
        $message = "The issue was deployed to the $Environment environment (built by $ProjectName project)"
    } else {
        $message = "The issue was built by the $ProjectName project"
    }

    return @"
$($message):
* Build: [$Tag|$projectUrl]
* Branch: $Branch
"@
}

<#
    .SYNOPSIS
        Traps STDERR instead of throwing a native error and writes output as warning.

    .DESCRIPTION
        A workaround for https://github.com/PowerShell/PowerShell/issues/3996 when running in
        AppVeyor.

        The issue results in nasty red error messages and `NativeCommandError` exceptions if
        a native command writes anything to STDERR regardless of the status code.

    .PARAMETER Command
        A native command string including arguments.
#>
function Call-NativeCommand {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true, ValueFromPipeline = $true)] [string] $Command,
        [parameter()] [switch] $NotifyStandardErrorOkay = $false,
        [parameter()] [switch] $IgnoreExitCode = $false
    )

    Write-Output "Executing `"$Command`""
    if ($NotifyStandardErrorOkay) {
        Notify-StandardError-Okay
    }

    $output = cmd /c $Command 2>&1
    Write-Output $output

    if (!$IgnoreExitCode) {
        Check-LastExitCode
    }
}

# https://rkeithhill.wordpress.com/2009/08/03/effective-powershell-item-16-dealing-with-errors/
function Check-LastExitCode {
    param (
        [int[]] $SuccessCodes = @(0),
        [scriptblock] $CleanupScript = $null,
        [int] $ExitCode = $LastExitCode
    )

    if ($SuccessCodes -notcontains $ExitCode) {
        if ($CleanupScript) {
            Log-Message "Executing cleanup script: $CleanupScript"
            &$CleanupScript
        }
        $message = @"
EXE RETURNED EXITCODE $LastExitCode
CALLSTACK:$(Get-PSCallStack | Out-String)
"@
        throw $message
    }
}

<#
    .SYNOPSIS
    Writes an informational message using Write-Output and Add-AppveyorMessage.

    .PARAMETER Message
    The message to write.
#>
function Log-Message {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string] $Message
    )

    Write-Output $Message
    Add-AppveyorMessage $Message
}

<#
    .SYNOPSIS
    Writes a warning message using Write-Warning and Add-AppveyorMessage.

    .PARAMETER Message
    The message to write.
#>
function Log-Warning {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string] $Message
    )

    Write-Warning $Message
    Add-AppveyorMessage -Message $Message -Category Warning
}

function In-AppVeyor {
    [CmdletBinding()] param ()
    return $env:APPVEYOR -like 'true'
}

function Notify-StandardError-Okay {
    [CmdletBinding()] param ()
    Write-Host '[Note] The native command writes to STDERR that remote PowerShell treats as an error: red error messages right below should be ignored unless the command exit code is non-zero'
}

# TODO: export as local aliases when In-AppVeyor is $false
<#
function Add-AppveyorMessage
{
    [CmdletBinding()]
    param ([string] $Message, [string] $Category = "Information")
    Write-Output "### Add-AppveyorMessage ($Category): $Message"
}

function Set-AppveyorBuildVariable
{
    [CmdletBinding()]
    param ([string] $Name, [string] $Value)
    Write-Output "### Set-AppveyorBuildVariable: $Name=`"$Value`""
}

function Update-AppveyorBuild
{
    [CmdletBinding()]
    param ([string] $Version)
    Write-Output "### Update-AppveyorBuild: Version=`"$Version`""
}

# Export AppVeyor command stubs for local testing
if (In-AppVeyor -eq $false)
{
    Export-ModuleMember -Function @('Set-AppveyorBuildVariable', 'Add-AppveyorMessage', 'Update-AppveyorBuild')
}
#>

$exportedCommands = @(
    'Tag-GitBuild',
    'Transition-Branch-JiraIssues',
    'Transition-JiraIssues',
    'Call-NativeCommand',
    'Check-LastExitCode',
    'Log-Message',
    'Log-Warning',
    'In-AppVeyor',
    'Notify-StandardError-Okay'
)

Export-ModuleMember -Function $exportedCommands
