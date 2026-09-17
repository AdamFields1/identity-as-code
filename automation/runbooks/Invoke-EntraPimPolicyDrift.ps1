<#
.SYNOPSIS
    Compares the PIM role settings (role management policies) of every
    Microsoft Entra directory role, and optionally of named PIM for Groups
    groups, with a baseline, mails a digest when they differ, and, when
    DryRun is false, patches the drifted rules back to the baseline.

.DESCRIPTION
    Runs as an Azure Automation runbook on a user-assigned managed identity.
    It checks three activation rules in every policy:

      Expiration_EndUser_Assignment   unifiedRoleManagementPolicyExpirationRule
                                      activation maximum duration (baseline PT4H)
      Enablement_EndUser_Assignment   unifiedRoleManagementPolicyEnablementRule
                                      on activation require MultiFactorAuthentication
                                      and Justification (baseline)
      Approval_EndUser_Assignment     unifiedRoleManagementPolicyApprovalRule
                                      require approval, and by whom (per baseline)

    The rule ids and the admin center settings they map to are the ones in
    "Rules in PIM - Mapping guide" on learn.microsoft.com; PIM for Groups
    policies carry the same rule ids.

    Directory roles. One Graph v1.0 call lists every policy assignment with
    its policy and rules:

      GET policies/roleManagementPolicyAssignments
          ?$filter=scopeId eq '/' and scopeType eq 'DirectoryRole'
          &$expand=policy($expand=rules)

    The list is deduplicated by (roleDefinitionId, scopeId) before it is
    compared. Only the tenant scope '/' is read, on purpose. "Configure
    Microsoft Entra role settings in PIM" (Microsoft Learn) says role
    settings are defined per role and that "All assignments for the same
    role follow the same role settings". That page does not mention
    administrative units. The step from there to "an assignment scoped to an
    administrative unit follows the tenant-scope policy" is an inference: the
    Graph v1.0 reference for unifiedRoleManagementPolicyAssignment documents
    scopeId as either '/' (the tenant) or a group id, so there is no
    administrative-unit policy to read. Role names come from
    roleManagement/directory/roleDefinitions, matched on id and templateId.
    An empty list stops the run with an error rather than passing as a
    clean run: every tenant has one policy per directory role, so zero
    assignments means a broken filter, a wrong scope type, or an API change.

    Groups. Each name in IncludeGroupNames is resolved to one group id, and
    the same list call is made with scopeId eq '<group id>' and
    scopeType eq 'Group'; the member and owner policies are checked with the
    same rules. If the identity is refused (HTTP 403) while resolving or
    reading groups, the group checks are skipped with a warning and the
    directory role checks carry on. A listed group that returns no member or
    owner policy is recorded as a failure (and therefore mailed), because it
    would otherwise go unchecked every day. The how-to article for PIM rules still
    says the groups API is beta only; the v1.0 API reference documents the
    Group scope for both the list and the rule update, and that is what this
    runbook calls.

    Baseline. The baseline is one JSON object with a mode, defaults, and
    overrides keyed by role display name (roles) and by group display name
    (groups):

      {
        "mode": "minimum",
        "defaults": {
          "maximumActivationDuration": "PT4H",
          "activationRequirements": ["MultiFactorAuthentication", "Justification"],
          "requireApproval": false,
          "approverGroupName": "",
          "authenticationContextSatisfiesMfa": false
        },
        "roles":  { "Global Administrator": { "requireApproval": true, "approverGroupName": "PIM Approvers Tier 0" } },
        "groups": {}
      }

    The run takes the baseline from the first of these that applies:
      1. BaselineJson, when it is not blank. This is for workstation runs
         and tests, and the Automation variable is then not read. Leave it
         empty in a job schedule: the Automation service may parse
         JSON-looking parameter text before it binds it (see
         Get-AutomationStringVariable in automation/lib/Runbook.Common.ps1),
         so a job in Azure Automation that receives BaselineJson logs a
         warning.
      2. The Automation string variable named by BaselineVariableName
         (default PimPolicy_EntraBaseline), when BaselineJson is blank. A
         string variable comes back exactly as it was stored. A missing,
         empty, non-string, or unreadable variable stops the run before any
         request, because falling back to the built-in baseline would
         silently drop every override (an excluded role would then be
         patched). Store {} to use the built-in baseline.
      3. The built-in baseline (the defaults above, no overrides), when both
         are blank.
    Text that looks like a converted PowerShell object ("@{...}" or
    System.Collections.Hashtable) is refused from either source, and every
    baseline error names the source.

    An override may set any default key plus "exclude": true, which takes the
    role or group out of the check. Unknown keys are an error, so a typo
    cannot silently leave a role on the defaults. The built-in baseline has
    no overrides. An override naming a role that does not exist is recorded
    as a failure (and therefore mailed); an override naming a group that is
    not in IncludeGroupNames stops the run before anything is read.

    Mode "minimum" (the default) treats the baseline as a floor: a rule that
    is stricter than the baseline (a shorter activation, an extra requirement
    such as Ticketing, approval where the baseline does not ask for it, extra
    approval stages) is compliant, and a patch only ever tightens:
      - An expiration patch for a rule that does not require activation to
        expire turns expiry on. It keeps a stored maximum duration that is
        at least PT1H and shorter than the baseline, and otherwise writes
        the baseline duration, so it never lengthens a stored value.
      - An enablement patch writes every live requirement plus the missing
        baseline ones. It never removes a live value.
      - An approval patch for a rule that already requires approval replaces
        only the first stage's primary approvers. It keeps the live approval
        mode, the later stages, and the first stage's timeout and escalation
        settings.
      - An approval patch for a rule that does not require approval yet turns
        approval on with one stage (SingleStage) whose approver is the
        baseline group. Approval was off, so the stored stages it replaces
        granted nothing.
    Mode "exact" makes any difference drift, so enforcement can loosen a
    rule; choose it only in a reviewed baseline change. In exact mode an
    expiration patch always writes the baseline duration, an enablement
    patch removes the extra requirements, and an approval patch writes one
    stage with the baseline group, which removes any extra stages and
    resets that stage's timeout and escalation settings. In both modes a
    rule that requires approval must have exactly the baseline approver
    group in its first stage; in exact mode it must also have only that one
    stage. The baseline does not model approval on extension, so no patch
    changes the live isApprovalRequiredForExtension.

    Authentication context. A role's PIM settings can require a Conditional
    Access authentication context on activation: the
    AuthenticationContext_EndUser_Assignment rule is enabled and its
    claimValue names the context. By default that does not count as
    MultiFactorAuthentication. A baseline that asks for MFA reports the
    missing value as drift, and the patch adds MultiFactorAuthentication
    next to the context. The reason is that the context's requirements live
    in a Conditional Access policy this runbook does not read. "Configure
    Microsoft Entra role settings in PIM" (Microsoft Learn) says that
    Conditional Access administrators can change or remove those
    requirements, and that the MFA fallback does not apply when that policy
    is off, in report-only mode, or excludes the user. Without this default,
    a portal change from MFA to a context could waive the MFA floor
    unnoticed.

    Set "authenticationContextSatisfiesMfa": true in defaults, or in a role
    or group override, to accept an enabled context as that role's step-up.
    The runbook then counts a baseline MFA requirement as met by the context
    and never adds MFA next to it. The substitution is never silent: the
    rule row says "MFA delegated to authentication context <claimValue>",
    the run logs that at Warn level, and a digest sent for any other reason
    lists it. With the key on, an enabled context rule with an empty
    claimValue is recorded as an error (and mailed), and the enablement rule
    of that policy is not patched. Review the Conditional Access policies
    behind accepted contexts as carefully as this baseline.

    Microsoft Learn does not say whether Graph accepts MFA and an
    authentication context on the same policy, and the azuread Terraform
    provider treats the two settings as conflicting for PIM for Groups
    policies. With the key off, a patch that adds MFA next to a context may
    therefore be refused. It is then recorded as Failed and mailed on every
    run until the baseline sets the key for that role or the context
    requirement is removed. That noise is intended: accepting a Conditional
    Access policy in place of MFA is a baseline decision, not a portal one.
    With either setting, a live MultiFactorAuthentication next to an enabled
    context is never removed.

    Safety model.
      - DryRun is $true by default. A dry run reads everything, computes the
        same plan, logs every patch and the digest as "Would ...", and writes
        and sends nothing.
      - Only drifted rules are patched, one PATCH per rule, with the rule's
        own @odata.type, as the Graph documentation requires. The body is
        the whole rule, so sending it twice leaves the same rule, and the
        runbook lets the library repeat a rule PATCH after a server error or
        a lost response (-RetryNonIdempotent). The digest mail is never
        repeated that way.
      - Circuit breaker, aborting: before the first write, in dry runs too,
        the number of planned rule updates is compared with
        MaxRuleUpdatesPerRun. More than that stops the run with an error and
        nothing is changed. A large number is a symptom (a new baseline, a
        bulk change in the tenant, a broken filter), and the right response is
        a person reading the report. A first enforcement run against a
        tenant on Microsoft's defaults will trip it; raise the cap for that
        one run after reading the dry-run report.
      - A PATCH refused with HTTP 403 (or any other error) is recorded as
        Failed, logged at Error level, and the run moves on to the next rule.
      - The digest is sent only when there is drift or a failure. A clean run
        sends nothing.
      - A baseline that requires approval must name an approver group, so a
        patch never turns on approval with no approvers (which makes active
        Privileged Role Administrators and Global Administrators the default
        approvers, and can lock a tenant out when none are active). Each
        approver group must also have at least one user member, directly or
        through nested groups. An empty approver group stops the run before
        any policy is read, because approval routed to it could never be
        granted. Disabled member accounts are not detected, because that
        needs User.Read.All, which this runbook is not granted. Keep
        emergency access accounts outside PIM.
      - ReportPath is checked before anything is read: the folder is
        created and the file is opened for writing once. If the report still
        cannot be written at the end, the run records a Failed ExportReport
        item, mails it with the digest, and still returns its summary. When
        the breaker has tripped, the breaker error is still the error the
        run ends with.
      - The access token is never logged; the library scrubs token-shaped
        text from every log line and error.

    Design rules shared by every runbook in this repository are in
    automation/README.md. The plumbing (logging, identity, transport, lookups,
    circuit breaker, summary) comes from automation/lib/Runbook.Common.ps1,
    which the block between the two INLINE_LIBRARY markers below dot-sources
    on a workstation and which stacks/azure-automation inlines at deploy time
    (library = "Runbook.Common.ps1").

    Graph application permissions (granted to the managed identity):
      RoleManagementPolicy.ReadWrite.Directory     read and patch directory role policies
                                                   (RoleManagementPolicy.Read.Directory is enough for a dry run)
      RoleManagement.Read.Directory                list role definitions for display names
      Group.Read.All                               resolve IncludeGroupNames and approver group names,
                                                   and read approver group members
      RoleManagementPolicy.ReadWrite.AzureADGroup  read and patch PIM for Groups policies, only with
                                                   IncludeGroupNames (RoleManagementPolicy.Read.AzureADGroup
                                                   for a dry run)
      Mail.Send                                    the digest, restricted to SenderMailbox by an Exchange
                                                   application access policy (automation/README.md)

    RoleManagementPolicy.ReadWrite.Directory is a tier 0 permission. It can
    change the PIM settings of every directory role, including removing MFA
    or approval from Global Administrator activation. Whoever controls an
    identity that holds it can therefore make Global Administrator easy to
    activate for any eligible account. The identity holding it is tier 0,
    and the permission belongs only to the PIM tier identity (the managed
    identity that runs the PIM runbooks), never to an identity shared with
    lower-tier automation. RoleManagementPolicy.ReadWrite.AzureADGroup is the
    same for PIM groups that grant Global Administrator. Treat everything
    that can steer this runbook as tier 0 too: the Automation account, its
    runbooks, schedules, and job parameters, and the baseline variable.
    Anyone who can write that variable can set exclude or exact mode and
    have this runbook remove MFA or approval for them.

    Azure RBAC roles: none. The runbook makes no Azure Resource Manager or
    Storage calls, so the Automation identity needs no role assignment for
    it. It reads the baseline variable with the sandbox's internal
    Get-AutomationVariable cmdlet, which needs no role assignment either.

    Recommended schedule: daily. The corp cell runs it every day at 05:15
    UTC (schedule daily-0515-utc), a quarter of an hour after the Azure PIM
    policy governance run. Role settings change rarely, and a daily run
    bounds the time a portal change goes unnoticed to one day. Ship the cell
    with dry_run = true. A dry run sends no mail, so read the first dry
    run's job output (the "Would patch" lines and the summary), add
    overrides for the roles that legitimately differ, then turn enforcement
    on in a reviewed change.

    Tenant cell. Lists are plain strings separated by semicolons, for
    example recipients = "iam@corp.example.com;secops@corp.example.com" and
    includegroupnames = "PIM Tier 0 Operators;PIM Tier 1 Operators". The
    baseline is not a job parameter: publish it as the Automation string
    variable PimPolicy_EntraBaseline (the stack's desired_state_files map
    publishes a repository JSON file as a string variable) and leave
    baselinevariablename at its default.

.PARAMETER BaselineVariableName
    Name of the Automation string variable that holds the baseline JSON (see
    DESCRIPTION). Default PimPolicy_EntraBaseline. Read only when
    BaselineJson is blank. A missing, empty, or unreadable variable stops
    the run before any request. On a workstation, where Automation variables
    do not exist, pass -BaselineJson, or -BaselineVariableName '' for the
    built-in baseline.

.PARAMETER BaselineJson
    The baseline as one JSON object string, for workstation runs and tests
    (see DESCRIPTION): mode, defaults, and per-role and per-group overrides.
    When it is not blank it wins and the Automation variable is not read.
    Default empty. Leave it empty in a job schedule and use the variable
    instead.

.PARAMETER IncludeGroupNames
    Optional display names of PIM for Groups groups whose member and owner
    policies are also checked, as one string separated by semicolons, for
    example 'PIM Tier 0 Operators;PIM Tier 1 Operators'. Commas also
    separate, so a name that contains a comma or a semicolon cannot be
    listed from a schedule. A JSON array such as ["PIM Tier 0 Operators"] is
    accepted on a local run, where the text reaches the runbook unchanged.
    Each name must match exactly one group.

.PARAMETER ApproverGroupName
    Display name of the group used as approver where the baseline requires
    approval and neither the override nor the defaults name an approver
    group. Needed only when approval is required somewhere.

.PARAMETER Recipients
    Mail addresses that receive the digest, as one string separated by
    semicolons, for example 'iam@corp.example.com;secops@corp.example.com'.
    Commas also separate. A JSON array is accepted on a local run only.
    Without it the digest is not sent and a warning is logged.

.PARAMETER SenderMailbox
    Shared mailbox the digest is sent from, as a user principal name. The
    managed identity needs Mail.Send restricted to this mailbox.

.PARAMETER MaxRuleUpdatesPerRun
    Circuit breaker. More planned rule updates than this stops the run before
    any write, in dry runs too. Default 40.

.PARAMETER ReportPath
    Optional path for a CSV with one row per checked rule (scope, target,
    policy, rule, status, outcome, live value, baseline value). On an
    Automation worker use a path under $env:TEMP. Checked before anything is
    read: a missing drive, a folder, or a locked file stops the run.

.PARAMETER DryRun
    Default $true. Everything is read and compared, every patch and the
    digest are logged as "Would ...", and nothing is written or sent. Pass
    -DryRun:$false (dry_run = false in the tenant cell) to enforce.

.PARAMETER Environment
    National cloud: Global (default) or USGov. Selects the Graph endpoint and
    the token audience.

.PARAMETER ClientId
    Client ID of the user-assigned managed identity. Passed to the Automation
    identity endpoint so the right identity is used when the account has
    more than one.

.PARAMETER AccessToken
    Local runs only: a Microsoft Graph access token obtained by the caller.
    Never logged. When set, the identity endpoint and Az.Accounts are not
    used.

.PARAMETER RunId
    Correlation ID stamped on every log line, on the digest, and on the
    summary. Defaults to a new GUID.

.EXAMPLE
    # Dry run from a workstation with a CLI token and the built-in baseline;
    # nothing is written or sent.
    $token = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
    .\Invoke-EntraPimPolicyDrift.ps1 -AccessToken $token -BaselineVariableName '' -ReportPath .\out\pim-policy-drift.csv

.EXAMPLE
    # Dry run with the baseline file the Automation variable is published
    # from, two PIM for Groups groups, and a digest address.
    $baseline = Get-Content -Raw -Path .\baseline.json
    .\Invoke-EntraPimPolicyDrift.ps1 -AccessToken $token -BaselineJson $baseline -ApproverGroupName 'PIM Approvers Tier 0' -IncludeGroupNames 'PIM Tier 0 Operators;PIM Tier 1 Operators' -Recipients iam@corp.example.com -SenderMailbox iam-noreply@corp.example.com

.EXAMPLE
    # Live run from Azure Automation: parameters come from the job schedule,
    # and the baseline from the PimPolicy_EntraBaseline string variable.
    .\Invoke-EntraPimPolicyDrift.ps1 -Recipients 'iam@corp.example.com;secops@corp.example.com' -SenderMailbox iam-noreply@corp.example.com -DryRun:$false -ClientId <identity client id>

.NOTES
    Windows PowerShell 5.1 and PowerShell 7 compatible; no modules required.
    There is no #Requires line: "Azure Automation runbook types" (Microsoft
    Learn, PowerShell 5.1 limitations) says the statement is not supported
    in the Azure sandbox or on Hybrid Runbook Workers and might cause the
    job to fail.
    Endpoints (Microsoft Graph v1.0, verified on learn.microsoft.com):
      GET   /policies/roleManagementPolicyAssignments?$filter=...&$expand=policy($expand=rules)
      PATCH /policies/roleManagementPolicies/{policyId}/rules/{ruleId}   (2xx; 200 with the rule or 204)
      GET   /roleManagement/directory/roleDefinitions
      GET   /groups?$filter=displayName eq '...'                           (library)
      GET   /groups/{id}/transitiveMembers/microsoft.graph.user?$select=id (library)
      POST  /users/{sender}/sendMail                                       (library)
#>

[CmdletBinding()]
param(
    [string]$BaselineVariableName = 'PimPolicy_EntraBaseline',

    [string]$BaselineJson = '',

    [string]$IncludeGroupNames = '',

    [string]$ApproverGroupName = '',

    [string]$Recipients = '',

    [ValidatePattern('^$|^[^@\s]+@[^@\s]+$')]
    [string]$SenderMailbox = '',

    [ValidateRange(0, 1000)]
    [int]$MaxRuleUpdatesPerRun = 40,

    [string]$ReportPath = '',

    [bool]$DryRun = $true,

    [ValidateSet('Global', 'USGov')]
    [string]$Environment = 'Global',

    [string]$ClientId = '',

    [string]$AccessToken = '',

    [string]$RunId = ([Guid]::NewGuid().ToString())
)

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'

# ---------------------------------------------------------------------------
# Shared library. Replaced with automation/lib/Runbook.Common.ps1 at deploy
# time by modules/azure/automation-runbooks; on a workstation and in the
# tests the line between the markers loads the same file from disk. Do not
# edit the marker lines; Terraform splits on them.
# ---------------------------------------------------------------------------

# INLINE_LIBRARY_BEGIN
. (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\Runbook.Common.ps1')
# INLINE_LIBRARY_END

# ---------------------------------------------------------------------------
# Constants. Rule ids and values from "Rules in PIM - Mapping guide" and
# "Update unifiedRoleManagementPolicyRule" (Microsoft Graph v1.0).
# ---------------------------------------------------------------------------

$script:PimRuleIds = @{
    Expiration            = 'Expiration_EndUser_Assignment'
    Enablement            = 'Enablement_EndUser_Assignment'
    Approval              = 'Approval_EndUser_Assignment'
    AuthenticationContext = 'AuthenticationContext_EndUser_Assignment'
}
$script:PimActivationRequirements = @('MultiFactorAuthentication', 'Justification', 'Ticketing')
$script:PimBaselineKeys = @('description', 'mode', 'defaults', 'roles', 'groups')
$script:PimMinimumActivation = [TimeSpan]::FromHours(1)
$script:PimMaximumActivation = [TimeSpan]::FromHours(24)
$script:PimBuiltInBaselineSource = 'the built-in baseline'

# ---------------------------------------------------------------------------
# Small helpers. Pure.
# ---------------------------------------------------------------------------

function Get-PimProperty {
    <#
    .SYNOPSIS
        Value of a property of a parsed JSON object or a dictionary, or $null
        when it is absent.
    .DESCRIPTION
        An array value is written to the pipeline item by item; wrap the call
        in @() when a list is expected.
    .PARAMETER Object
        PSCustomObject, dictionary, or $null.
    .PARAMETER Name
        Property name.
    .EXAMPLE
        Get-PimProperty -Object $rule -Name 'maximumDuration'
    #>
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-PimJsonObject {
    <#
    .SYNOPSIS
        True when a value is a parsed JSON object (a PSCustomObject), and not
        a string, number, array, or dictionary that PowerShell has wrapped.
    .DESCRIPTION
        The [PSCustomObject] accelerator stands for PSObject, so
        "-is [PSCustomObject]" is also true for any wrapped value. This checks
        the base object's real type instead.
    .PARAMETER Value
        The value to test.
    .EXAMPLE
        Test-PimJsonObject -Value (ConvertFrom-Json -InputObject '{"a":1}')
        True
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $false }
    $base = $Value
    if ($Value -is [System.Management.Automation.PSObject]) { $base = $Value.PSObject.BaseObject }
    return ($base -is [System.Management.Automation.PSCustomObject])
}

function Get-PimJsonMember {
    <#
    .SYNOPSIS
        A member of a parsed JSON object, returned as is (an array stays one
        array), or $null when the member is absent.
    .PARAMETER Object
        A parsed JSON object.
    .PARAMETER Name
        Member name, matched case-insensitively.
    .EXAMPLE
        $roles = Get-PimJsonMember -Object $parsed -Name 'roles'
    #>
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-PimJsonObject -Value $Object)) { return $null }
    $member = $Object.PSObject.Properties[$Name]
    if ($null -eq $member) { return $null }
    return , $member.Value
}

function ConvertFrom-PimDuration {
    <#
    .SYNOPSIS
        TimeSpan of an ISO 8601 duration such as PT4H, or $null when the value
        is empty or not a duration.
    .PARAMETER Value
        The duration text.
    .EXAMPLE
        ConvertFrom-PimDuration -Value 'PT1H45M'
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ($text.Length -eq 0) { return $null }
    try { return [System.Xml.XmlConvert]::ToTimeSpan($text) }
    catch { return $null }
}

function ConvertTo-PimDurationText {
    <#
    .SYNOPSIS
        ISO 8601 text in hours and minutes for an activation duration.
    .DESCRIPTION
        Always PT<h>H<m>M with zero parts left out, so 24 hours is PT24H
        rather than P1D, the form the admin center writes.
    .PARAMETER Duration
        The duration.
    .EXAMPLE
        ConvertTo-PimDurationText -Duration ([TimeSpan]::FromMinutes(105))
        PT1H45M
    #>
    param([Parameter(Mandatory = $true)][TimeSpan]$Duration)

    $hours = [int][Math]::Floor($Duration.TotalHours)
    $minutes = $Duration.Minutes
    $text = 'PT'
    if ($hours -gt 0) { $text += ('{0}H' -f $hours) }
    if ($minutes -gt 0 -or $hours -eq 0) { $text += ('{0}M' -f $minutes) }
    return $text
}

function ConvertTo-PimRequirementName {
    <#
    .SYNOPSIS
        Canonical spelling of an activation requirement, or the trimmed input
        when it is not one of the known values.
    .PARAMETER Value
        For example 'multifactorauthentication'.
    .EXAMPLE
        ConvertTo-PimRequirementName -Value 'justification'
        Justification
    #>
    param([AllowNull()][object]$Value)

    $text = ''
    if ($null -ne $Value) { $text = ([string]$Value).Trim() }
    foreach ($known in $script:PimActivationRequirements) {
        if ($known.Equals($text, [StringComparison]::OrdinalIgnoreCase)) { return $known }
    }
    return $text
}

function Select-PimUniqueName {
    <#
    .SYNOPSIS
        Names with case-insensitive duplicates removed, first spelling kept.
    .PARAMETER Names
        The names.
    .EXAMPLE
        @(Select-PimUniqueName -Names @('A', 'a', 'B')).Count
        2
    #>
    param([AllowEmptyCollection()][AllowNull()][string[]]$Names = @())

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($Names)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($seen.Add($name)) { $name }
    }
}

# ---------------------------------------------------------------------------
# Baseline. Parsed and validated before anything is read from the tenant.
# ---------------------------------------------------------------------------

function Merge-PimSettings {
    <#
    .SYNOPSIS
        Applies one baseline object (defaults or an override) on top of a
        settings table and validates every value.
    .DESCRIPTION
        Returns a new hashtable: MaximumActivationDuration (TimeSpan),
        ActivationRequirements (string[]), RequireApproval (bool),
        ApproverGroupName (string), AuthenticationContextSatisfiesMfa (bool),
        Exclude (bool). An empty approverGroupName keeps the inherited one.
        Unknown keys throw. Every message starts with Source and Label.
    .PARAMETER Base
        The inherited settings.
    .PARAMETER Override
        The parsed JSON object, or $null.
    .PARAMETER Label
        Where the object sits in the baseline, for error messages.
    .PARAMETER AllowExclude
        Whether "exclude" is a valid key here (overrides only).
    .PARAMETER Source
        Where the baseline came from, for error messages: BaselineJson or
        Automation variable "<name>".
    .EXAMPLE
        Merge-PimSettings -Base $defaults -Override $parsed.roles.'Global Administrator' -Label 'roles."Global Administrator"' -AllowExclude $true -Source 'BaselineJson'
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Base,
        [AllowNull()][object]$Override,
        [Parameter(Mandatory = $true)][string]$Label,
        [bool]$AllowExclude = $false,
        [ValidateNotNullOrEmpty()][string]$Source = 'BaselineJson'
    )

    $at = '{0} {1}' -f $Source, $Label
    $result = @{
        MaximumActivationDuration         = $Base.MaximumActivationDuration
        ActivationRequirements            = [string[]]@($Base.ActivationRequirements)
        RequireApproval                   = [bool]$Base.RequireApproval
        ApproverGroupName                 = [string]$Base.ApproverGroupName
        AuthenticationContextSatisfiesMfa = [bool]$Base.AuthenticationContextSatisfiesMfa
        Exclude                           = $false
    }
    if ($null -eq $Override) { return $result }
    if (-not (Test-PimJsonObject -Value $Override)) { throw ('{0} must be a JSON object.' -f $at) }

    foreach ($property in $Override.PSObject.Properties) {
        $value = $property.Value
        switch ($property.Name) {
            'maximumActivationDuration' {
                $duration = ConvertFrom-PimDuration -Value $value
                if ($null -eq $duration -or -not ($value -is [string])) {
                    throw ('{0}.maximumActivationDuration "{1}" is not an ISO 8601 duration such as PT4H.' -f $at, $value)
                }
                if ($duration -lt $script:PimMinimumActivation -or $duration -gt $script:PimMaximumActivation -or $duration.Seconds -ne 0 -or $duration.Milliseconds -ne 0) {
                    throw ('{0}.maximumActivationDuration "{1}" must be whole minutes between PT1H and PT24H, the range the admin center allows.' -f $at, $value)
                }
                $result.MaximumActivationDuration = $duration
            }
            'activationRequirements' {
                if ($null -eq $value -or $value -is [string] -or (Test-PimJsonObject -Value $value) -or -not ($value -is [System.Collections.IEnumerable])) {
                    throw ('{0}.activationRequirements must be a JSON array, for example ["MultiFactorAuthentication","Justification"].' -f $at)
                }
                $list = New-Object System.Collections.Generic.List[string]
                foreach ($element in $value) {
                    if (-not ($element -is [string])) { throw ('{0}.activationRequirements must hold strings only.' -f $at) }
                    $name = ConvertTo-PimRequirementName -Value $element
                    if ($script:PimActivationRequirements -notcontains $name) {
                        throw ('{0}.activationRequirements has "{1}"; allowed values are {2}.' -f $at, $element, ($script:PimActivationRequirements -join ', '))
                    }
                    if (-not $list.Contains($name)) { $list.Add($name) }
                }
                $result.ActivationRequirements = [string[]]$list.ToArray()
            }
            'requireApproval' {
                if (-not ($value -is [bool])) { throw ('{0}.requireApproval must be true or false.' -f $at) }
                $result.RequireApproval = [bool]$value
            }
            'approverGroupName' {
                if ($null -ne $value -and -not ($value -is [string])) { throw ('{0}.approverGroupName must be a string.' -f $at) }
                if (-not [string]::IsNullOrWhiteSpace([string]$value)) { $result.ApproverGroupName = ([string]$value).Trim() }
            }
            'authenticationContextSatisfiesMfa' {
                if (-not ($value -is [bool])) { throw ('{0}.authenticationContextSatisfiesMfa must be true or false.' -f $at) }
                $result.AuthenticationContextSatisfiesMfa = [bool]$value
            }
            'exclude' {
                if (-not $AllowExclude) { throw ('{0} cannot use "exclude"; it is only valid in a role or group override.' -f $at) }
                if (-not ($value -is [bool])) { throw ('{0}.exclude must be true or false.' -f $at) }
                $result.Exclude = [bool]$value
            }
            default {
                throw ('{0} has an unknown key "{1}". Allowed: maximumActivationDuration, activationRequirements, requireApproval, approverGroupName, authenticationContextSatisfiesMfa{2}.' -f $at, $property.Name, $(if ($AllowExclude) { ', exclude' } else { '' }))
            }
        }
    }

    if ($result.RequireApproval -and -not $result.Exclude -and [string]::IsNullOrWhiteSpace($result.ApproverGroupName)) {
        throw ('{0} requires approval but no approver group is named. Set approverGroupName there or in defaults, or pass -ApproverGroupName.' -f $at)
    }
    return $result
}

function Resolve-PimBaselineText {
    <#
    .SYNOPSIS
        The baseline JSON text and where it came from.
    .DESCRIPTION
        Precedence:
          1. BaselineJson when it is not blank (workstation runs and tests).
             The variable is not read. When Get-AutomationVariable exists
             (the Automation sandbox or a Hybrid Runbook Worker), a Warn line
             says that job parameters are not a safe carrier for JSON.
          2. Otherwise the Automation string variable named by
             BaselineVariableName, when that is not blank, read with
             Get-AutomationStringVariable. A missing, empty, non-string, or
             unreadable variable throws: falling back to the built-in
             baseline would silently drop every override.
          3. Otherwise the built-in baseline (empty text).
        Returns Text and Source. Source is BaselineJson,
        Automation variable "<name>", or the built-in baseline. The variable
        value is never logged.
    .PARAMETER BaselineJson
        The BaselineJson parameter.
    .PARAMETER BaselineVariableName
        The BaselineVariableName parameter.
    .EXAMPLE
        $baselineInput = Resolve-PimBaselineText -BaselineJson '' -BaselineVariableName 'PimPolicy_EntraBaseline'
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$BaselineJson = '',
        [AllowNull()][AllowEmptyString()][string]$BaselineVariableName = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($BaselineJson)) {
        if ($null -ne (Get-Command -Name 'Get-AutomationVariable' -ErrorAction SilentlyContinue)) {
            $variableText = 'the Automation string variable named by BaselineVariableName'
            if (-not [string]::IsNullOrWhiteSpace($BaselineVariableName)) { $variableText = 'the Automation string variable "{0}"' -f $BaselineVariableName }
            Write-RunLog -Level Warn -Message ('BaselineJson was passed to a job in Azure Automation, so {0} was not read. The service may change JSON text in a job parameter before it is bound; publish the baseline as {0} and leave BaselineJson empty in the schedule.' -f $variableText)
        }
        return [PSCustomObject]@{ Text = $BaselineJson; Source = 'BaselineJson' }
    }

    if (-not [string]::IsNullOrWhiteSpace($BaselineVariableName)) {
        $value = ''
        try { $value = Get-AutomationStringVariable -Name $BaselineVariableName }
        catch {
            throw ('Could not read the baseline from Automation variable "{0}": {1} On a workstation pass -BaselineJson with the baseline text, or -BaselineVariableName '''' for the built-in baseline.' -f $BaselineVariableName, (Protect-RunbookText -Text $_.Exception.Message -MaxLength 400))
        }
        return [PSCustomObject]@{ Text = $value; Source = ('Automation variable "{0}"' -f $BaselineVariableName) }
    }

    return [PSCustomObject]@{ Text = ''; Source = $script:PimBuiltInBaselineSource }
}

function ConvertTo-PimBaseline {
    <#
    .SYNOPSIS
        Parses and validates the baseline JSON into mode, defaults, and
        overrides.
    .DESCRIPTION
        An empty value, or {}, is the built-in baseline: PT4H,
        MultiFactorAuthentication and Justification, no approval, an
        authentication context not counted as MFA, mode minimum. Returns
        Mode, Source, Defaults (hashtable), Roles and Groups (hashtables
        keyed by lower-case name, each entry Name and Settings). Text that
        looks like a converted PowerShell object is refused. Every problem
        throws with the source and the location in the baseline.
    .PARAMETER Json
        The baseline text.
    .PARAMETER ApproverGroupName
        Fallback approver group for entries that require approval without
        naming one.
    .PARAMETER Source
        Where the text came from, for messages: BaselineJson (the default),
        Automation variable "<name>", or the built-in baseline.
    .EXAMPLE
        $baseline = ConvertTo-PimBaseline -Json $BaselineJson -ApproverGroupName 'PIM Approvers'
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Json,
        [AllowNull()][AllowEmptyString()][string]$ApproverGroupName = '',
        [ValidateNotNullOrEmpty()][string]$Source = 'BaselineJson'
    )

    $text = ''
    if ($null -ne $Json) { $text = $Json.Trim() }
    if ($text.StartsWith('"') -and $text.EndsWith('"') -and $text.Length -ge 2) {
        # A JSON string literal around the object, as a stored value may be wrapped.
        try { $text = ([string](ConvertFrom-RunbookJsonText -Json $text)).Trim() }
        catch { throw ('{0} looks like a quoted JSON string but does not parse.' -f $Source) }
    }
    if ($text.Length -eq 0) { $text = '{}' }
    if ($text.StartsWith('@{') -or $text -eq 'System.Collections.Hashtable') {
        throw ('{0} arrived as a converted object, not as JSON text. Store the baseline as JSON text in the Automation string variable named by BaselineVariableName, and leave BaselineJson empty in a job schedule.' -f $Source)
    }
    if (-not $text.StartsWith('{')) { throw ('{0} must be a JSON object, for example {{"defaults":{{...}},"roles":{{}}}}.' -f $Source) }

    $parsed = $null
    try { $parsed = ConvertFrom-RunbookJsonText -Json $text }
    catch { throw ('{0} does not parse as JSON: {1}' -f $Source, (Protect-RunbookText -Text $_.Exception.Message -MaxLength 200)) }
    if (-not (Test-PimJsonObject -Value $parsed)) { throw ('{0} must be a JSON object.' -f $Source) }

    foreach ($property in $parsed.PSObject.Properties) {
        if ($script:PimBaselineKeys -notcontains $property.Name) {
            throw ('{0} has an unknown top-level key "{1}". Allowed: {2}.' -f $Source, $property.Name, ($script:PimBaselineKeys -join ', '))
        }
    }

    $mode = 'minimum'
    $modeValue = Get-PimJsonMember -Object $parsed -Name 'mode'
    if ($null -ne $modeValue) {
        if (-not ($modeValue -is [string])) { throw ('{0} mode must be a string: "minimum" or "exact".' -f $Source) }
        $mode = $modeValue.Trim().ToLowerInvariant()
        if (@('minimum', 'exact') -notcontains $mode) { throw ('{0} mode "{1}" is not valid. Use "minimum" or "exact".' -f $Source, $modeValue) }
    }

    $fallbackApprover = ''
    if (-not [string]::IsNullOrWhiteSpace($ApproverGroupName)) { $fallbackApprover = $ApproverGroupName.Trim() }
    $builtIn = @{
        MaximumActivationDuration         = [TimeSpan]::FromHours(4)
        ActivationRequirements            = [string[]]@('MultiFactorAuthentication', 'Justification')
        RequireApproval                   = $false
        ApproverGroupName                 = $fallbackApprover
        AuthenticationContextSatisfiesMfa = $false
        Exclude                           = $false
    }
    $defaults = Merge-PimSettings -Base $builtIn -Override (Get-PimJsonMember -Object $parsed -Name 'defaults') -Label 'defaults' -AllowExclude $false -Source $Source

    $tables = @{}
    foreach ($section in @('roles', 'groups')) {
        $table = @{}
        $sectionValue = Get-PimJsonMember -Object $parsed -Name $section
        if ($null -ne $sectionValue) {
            if (-not (Test-PimJsonObject -Value $sectionValue)) { throw ('{0} {1} must be a JSON object keyed by display name.' -f $Source, $section) }
            foreach ($entry in $sectionValue.PSObject.Properties) {
                $name = $entry.Name.Trim()
                if ($name.Length -eq 0) { throw ('{0} {1} has an empty name.' -f $Source, $section) }
                $key = $name.ToLowerInvariant()
                if ($table.ContainsKey($key)) { throw ('{0} {1} names "{2}" more than once.' -f $Source, $section, $name) }
                $label = '{0}."{1}"' -f $section, $name
                $settings = Merge-PimSettings -Base $defaults -Override $entry.Value -Label $label -AllowExclude $true -Source $Source
                $table[$key] = [PSCustomObject]@{ Name = $name; Settings = $settings }
            }
        }
        $tables[$section] = $table
    }

    return [PSCustomObject]@{
        Mode     = $mode
        Source   = $Source
        Defaults = $defaults
        Roles    = $tables['roles']
        Groups   = $tables['groups']
    }
}

function Get-PimEffectiveSettings {
    <#
    .SYNOPSIS
        The settings that apply to one role or group: its override, or the
        defaults.
    .PARAMETER Baseline
        From ConvertTo-PimBaseline.
    .PARAMETER Kind
        Role or Group.
    .PARAMETER Name
        Role or group display name.
    .EXAMPLE
        Get-PimEffectiveSettings -Baseline $baseline -Kind Role -Name 'Global Administrator'
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Baseline,
        [Parameter(Mandatory = $true)][ValidateSet('Role', 'Group')][string]$Kind,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name
    )

    $table = $Baseline.Roles
    if ($Kind -eq 'Group') { $table = $Baseline.Groups }
    $key = $Name.Trim().ToLowerInvariant()
    if ($table.ContainsKey($key)) { return $table[$key].Settings }
    return $Baseline.Defaults
}

function Get-PimApproverGroupNames {
    <#
    .SYNOPSIS
        Every approver group name the baseline needs, once each.
    .DESCRIPTION
        Writes the names to the pipeline; wrap in @(). Excluded overrides and
        entries that do not require approval need no approver.
    .PARAMETER Baseline
        From ConvertTo-PimBaseline.
    .EXAMPLE
        foreach ($name in @(Get-PimApproverGroupNames -Baseline $baseline)) { Resolve-GroupIdByName -DisplayName $name }
    #>
    param([Parameter(Mandatory = $true)][object]$Baseline)

    $candidates = New-Object System.Collections.ArrayList
    [void]$candidates.Add($Baseline.Defaults)
    foreach ($entry in @($Baseline.Roles.Values | Sort-Object -Property Name)) { [void]$candidates.Add($entry.Settings) }
    foreach ($entry in @($Baseline.Groups.Values | Sort-Object -Property Name)) { [void]$candidates.Add($entry.Settings) }

    $names = New-Object System.Collections.ArrayList
    foreach ($settings in $candidates) {
        if (-not $settings.RequireApproval -or $settings.Exclude) { continue }
        [void]$names.Add([string]$settings.ApproverGroupName)
    }
    Select-PimUniqueName -Names ([string[]]$names.ToArray())
}

# ---------------------------------------------------------------------------
# Policy reads.
# ---------------------------------------------------------------------------

function New-PimAssignmentsUri {
    <#
    .SYNOPSIS
        Relative Graph URI that lists policy assignments for one scope with
        each policy and its rules expanded.
    .PARAMETER ScopeId
        '/' for directory roles, or a group id.
    .PARAMETER ScopeType
        DirectoryRole or Group.
    .EXAMPLE
        New-PimAssignmentsUri -ScopeId '/' -ScopeType DirectoryRole
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ScopeId,
        [Parameter(Mandatory = $true)][ValidateSet('DirectoryRole', 'Group')][string]$ScopeType
    )

    # The filter value is escaped (spaces, quotes, the '/' scope); the expand
    # is sent in the literal form the API reference shows.
    $filter = 'scopeId eq {0} and scopeType eq {1}' -f (ConvertTo-ODataLiteral -Value $ScopeId), (ConvertTo-ODataLiteral -Value $ScopeType)
    return ('policies/roleManagementPolicyAssignments?$filter={0}&$expand=policy($expand=rules)' -f [Uri]::EscapeDataString($filter))
}

function Select-UniquePimAssignment {
    <#
    .SYNOPSIS
        Policy assignments with duplicates of (roleDefinitionId, scopeId)
        removed, first one kept, order kept.
    .DESCRIPTION
        Writes the kept assignments to the pipeline; wrap in @().
    .PARAMETER Assignments
        Parsed unifiedRoleManagementPolicyAssignment objects.
    .EXAMPLE
        $unique = @(Select-UniquePimAssignment -Assignments $raw)
    #>
    param([AllowEmptyCollection()][AllowNull()][object[]]$Assignments = @())

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($assignment in @($Assignments)) {
        if ($null -eq $assignment) { continue }
        $key = '{0}|{1}' -f [string](Get-PimProperty -Object $assignment -Name 'roleDefinitionId'), [string](Get-PimProperty -Object $assignment -Name 'scopeId')
        if ($seen.Add($key)) { $assignment }
    }
}

function Get-PimRoleNameMap {
    <#
    .SYNOPSIS
        Table from role definition id and template id to display name.
    .DESCRIPTION
        Policy assignments name built-in roles by template id, which equals
        the id for built-in roles; custom roles by id. Both are keys.
    .PARAMETER RoleDefinitions
        Parsed unifiedRoleDefinition objects.
    .EXAMPLE
        $names = Get-PimRoleNameMap -RoleDefinitions $definitions
    #>
    param([AllowEmptyCollection()][AllowNull()][object[]]$RoleDefinitions = @())

    $map = @{}
    foreach ($definition in @($RoleDefinitions)) {
        if ($null -eq $definition) { continue }
        $name = [string](Get-PimProperty -Object $definition -Name 'displayName')
        foreach ($key in @([string](Get-PimProperty -Object $definition -Name 'id'), [string](Get-PimProperty -Object $definition -Name 'templateId'))) {
            if (-not [string]::IsNullOrWhiteSpace($key) -and -not $map.ContainsKey($key)) { $map[$key] = $name }
        }
    }
    return $map
}

function Get-PimRuleById {
    <#
    .SYNOPSIS
        The rule with this id from a policy's rules, or $null.
    .PARAMETER Rules
        The policy's rules.
    .PARAMETER RuleId
        For example Expiration_EndUser_Assignment.
    .EXAMPLE
        Get-PimRuleById -Rules $policy.rules -RuleId 'Approval_EndUser_Assignment'
    #>
    param(
        [AllowEmptyCollection()][AllowNull()][object[]]$Rules = @(),
        [Parameter(Mandatory = $true)][string]$RuleId
    )

    foreach ($rule in @($Rules)) {
        if ($null -eq $rule) { continue }
        if ($RuleId.Equals([string](Get-PimProperty -Object $rule -Name 'id'), [StringComparison]::OrdinalIgnoreCase)) { return $rule }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Request bodies. Shapes from "Update unifiedRoleManagementPolicyRule" and
# "Update rules in PIM" (Microsoft Graph v1.0): @odata.type of the rule, its
# id, the changed values, and the target.
# ---------------------------------------------------------------------------

function New-PimRuleTarget {
    <#
    .SYNOPSIS
        The target object of an activation (EndUser, Assignment) rule.
    .EXAMPLE
        New-PimRuleTarget
    #>
    return [ordered]@{
        '@odata.type'       = 'microsoft.graph.unifiedRoleManagementPolicyRuleTarget'
        caller              = 'EndUser'
        operations          = @('All')
        level               = 'Assignment'
        inheritableSettings = @()
        enforcedSettings    = @()
    }
}

function New-PimExpirationRuleBody {
    <#
    .SYNOPSIS
        PATCH body for Expiration_EndUser_Assignment.
    .PARAMETER Duration
        Activation maximum duration.
    .EXAMPLE
        New-PimExpirationRuleBody -Duration ([TimeSpan]::FromHours(4))
    #>
    param([Parameter(Mandatory = $true)][TimeSpan]$Duration)

    return [ordered]@{
        '@odata.type'        = '#microsoft.graph.unifiedRoleManagementPolicyExpirationRule'
        id                   = $script:PimRuleIds.Expiration
        isExpirationRequired = $true
        maximumDuration      = (ConvertTo-PimDurationText -Duration $Duration)
        target               = (New-PimRuleTarget)
    }
}

function New-PimEnablementRuleBody {
    <#
    .SYNOPSIS
        PATCH body for Enablement_EndUser_Assignment.
    .PARAMETER EnabledRules
        The full list to set, for example MultiFactorAuthentication and Justification.
    .EXAMPLE
        New-PimEnablementRuleBody -EnabledRules @('MultiFactorAuthentication', 'Justification')
    #>
    param([AllowEmptyCollection()][string[]]$EnabledRules = @())

    return [ordered]@{
        '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyEnablementRule'
        id            = $script:PimRuleIds.Enablement
        enabledRules  = [string[]]@($EnabledRules)
        target        = (New-PimRuleTarget)
    }
}

function New-PimApprovalRuleBody {
    <#
    .SYNOPSIS
        PATCH body for Approval_EndUser_Assignment.
    .DESCRIPTION
        Required, fresh (the default): one stage (SingleStage) whose primary
        approver is the members of ApproverGroupId, as in the Graph how-to
        example. Required with KeepLiveStages and at least one live stage:
        the live setting with only the first stage's primaryApprovers
        replaced, so the approval mode, later stages, and the first stage's
        timeout and escalation settings stay as they are. Not required:
        isApprovalRequired false with the live approval mode, stages, and
        approvers kept, so the approver list survives if approval is turned
        on again. In every case the live isApprovalRequiredForExtension is
        kept, because the baseline does not model it.
    .PARAMETER Required
        Whether approval is required.
    .PARAMETER ApproverGroupId
        Approver group object id; needed when Required.
    .PARAMETER LiveSetting
        The live approvalSettings, or $null.
    .PARAMETER KeepLiveStages
        With Required: change only the first stage's primary approvers
        (minimum mode, approval already required).
    .EXAMPLE
        New-PimApprovalRuleBody -Required $true -ApproverGroupId $groupId -LiveSetting $rule.setting -KeepLiveStages $true
    #>
    param(
        [Parameter(Mandatory = $true)][bool]$Required,
        [AllowEmptyString()][string]$ApproverGroupId = '',
        [AllowNull()][object]$LiveSetting = $null,
        [bool]$KeepLiveStages = $false
    )

    $stages = @()
    foreach ($liveStage in @(Get-PimProperty -Object $LiveSetting -Name 'approvalStages')) {
        if ($null -ne $liveStage) { $stages += $liveStage }
    }
    $liveMode = ([string](Get-PimProperty -Object $LiveSetting -Name 'approvalMode')).Trim()
    $forExtension = $false
    $extensionValue = Get-PimProperty -Object $LiveSetting -Name 'isApprovalRequiredForExtension'
    if ($null -ne $extensionValue) { $forExtension = [bool]$extensionValue }

    if ($Required) {
        if ([string]::IsNullOrWhiteSpace($ApproverGroupId)) { throw 'An approval rule that requires approval needs an approver group id.' }
        $approver = [ordered]@{ '@odata.type' = '#microsoft.graph.groupMembers'; groupId = $ApproverGroupId }
        if ($KeepLiveStages -and $stages.Count -gt 0) {
            $mode = $liveMode
            if ($mode.Length -eq 0 -or $mode -eq 'NoApproval') {
                $mode = 'SingleStage'
                $stages = @($stages[0])
            }
            $first = [ordered]@{}
            if ($stages[0] -is [System.Collections.IDictionary]) {
                foreach ($key in $stages[0].Keys) { $first[[string]$key] = $stages[0][$key] }
            }
            else {
                foreach ($property in $stages[0].PSObject.Properties) { $first[$property.Name] = $property.Value }
            }
            $first['primaryApprovers'] = @($approver)
            $newStages = @($first)
            for ($index = 1; $index -lt $stages.Count; $index++) { $newStages += $stages[$index] }
        }
        else {
            $mode = 'SingleStage'
            $newStages = @([ordered]@{
                    approvalStageTimeOutInDays      = 1
                    isApproverJustificationRequired = $true
                    escalationTimeInMinutes         = 0
                    primaryApprovers                = @($approver)
                    isEscalationEnabled             = $false
                    escalationApprovers             = @()
                })
        }
        $setting = [ordered]@{
            '@odata.type'                    = 'microsoft.graph.approvalSettings'
            isApprovalRequired               = $true
            isApprovalRequiredForExtension   = $forExtension
            isRequestorJustificationRequired = $true
            approvalMode                     = $mode
            approvalStages                   = $newStages
        }
    }
    else {
        if ($stages.Count -eq 0) {
            $stages = @([ordered]@{
                    approvalStageTimeOutInDays      = 1
                    isApproverJustificationRequired = $true
                    escalationTimeInMinutes         = 0
                    primaryApprovers                = @()
                    isEscalationEnabled             = $false
                    escalationApprovers             = @()
                })
        }
        $mode = $liveMode
        if ($mode.Length -eq 0) { $mode = 'SingleStage' }
        $justification = $true
        $justificationValue = Get-PimProperty -Object $LiveSetting -Name 'isRequestorJustificationRequired'
        if ($null -ne $justificationValue) { $justification = [bool]$justificationValue }
        $setting = [ordered]@{
            '@odata.type'                    = 'microsoft.graph.approvalSettings'
            isApprovalRequired               = $false
            isApprovalRequiredForExtension   = $forExtension
            isRequestorJustificationRequired = $justification
            approvalMode                     = $mode
            approvalStages                   = $stages
        }
    }

    return [ordered]@{
        '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyApprovalRule'
        id            = $script:PimRuleIds.Approval
        target        = (New-PimRuleTarget)
        setting       = $setting
    }
}

# ---------------------------------------------------------------------------
# Comparison. Pure: live rule objects and baseline values in, one result out.
# Status is Compliant, Drift (Body holds the PATCH), or Error.
# ---------------------------------------------------------------------------

function New-PimRuleResult {
    <#
    .SYNOPSIS
        One rule comparison result.
    .PARAMETER RuleId
        Rule id.
    .PARAMETER Status
        Compliant, Drift, or Error.
    .PARAMETER Live
        Live value, as text.
    .PARAMETER Desired
        Baseline value, as text.
    .PARAMETER Detail
        Why.
    .PARAMETER Body
        PATCH body for Drift.
    .PARAMETER Notice
        Something a person should know even when the rule is compliant, such
        as MFA delegated to an authentication context. The run logs it at
        Warn level. It is also part of Detail.
    .EXAMPLE
        New-PimRuleResult -RuleId 'Expiration_EndUser_Assignment' -Status Compliant -Live 'PT4H' -Desired 'PT4H'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RuleId,
        [Parameter(Mandatory = $true)][ValidateSet('Compliant', 'Drift', 'Error')][string]$Status,
        [AllowEmptyString()][string]$Live = '',
        [AllowEmptyString()][string]$Desired = '',
        [AllowEmptyString()][string]$Detail = '',
        [AllowNull()][object]$Body = $null,
        [AllowEmptyString()][string]$Notice = ''
    )

    return [PSCustomObject]@{
        RuleId  = $RuleId
        Status  = $Status
        Live    = $Live
        Desired = $Desired
        Detail  = $Detail
        Body    = $Body
        Notice  = $Notice
    }
}

function Compare-PimExpirationRule {
    <#
    .SYNOPSIS
        Compares Expiration_EndUser_Assignment with the baseline duration.
    .DESCRIPTION
        Compliant when expiration is required and the maximum duration is at
        most the baseline (minimum) or equal to it (exact). Durations compare
        as time, so PT240M equals PT4H.

        The patch turns expiration on and writes the baseline duration. In
        minimum mode, when expiration is not required but the rule stores a
        whole-minute duration of at least PT1H that is shorter than the
        baseline, the patch keeps that stored duration instead, so a patch
        never lengthens a stored value.
    .PARAMETER Rule
        The live rule, or $null.
    .PARAMETER DesiredDuration
        Baseline activation maximum duration.
    .PARAMETER Mode
        minimum or exact.
    .EXAMPLE
        Compare-PimExpirationRule -Rule $rule -DesiredDuration ([TimeSpan]::FromHours(4)) -Mode minimum
    #>
    param(
        [AllowNull()][object]$Rule,
        [Parameter(Mandatory = $true)][TimeSpan]$DesiredDuration,
        [ValidateSet('minimum', 'exact')][string]$Mode = 'minimum'
    )

    $ruleId = $script:PimRuleIds.Expiration
    $desiredText = ConvertTo-PimDurationText -Duration $DesiredDuration
    if ($null -eq $Rule) {
        return (New-PimRuleResult -RuleId $ruleId -Status Error -Live '(rule not in policy)' -Desired $desiredText -Detail 'the policy returned no expiration rule for activation')
    }

    $required = $false
    $requiredValue = Get-PimProperty -Object $Rule -Name 'isExpirationRequired'
    if ($null -ne $requiredValue) { $required = [bool]$requiredValue }
    $rawDuration = Get-PimProperty -Object $Rule -Name 'maximumDuration'
    $liveDuration = ConvertFrom-PimDuration -Value $rawDuration

    $liveText = '(none)'
    if ($null -ne $liveDuration) { $liveText = ConvertTo-PimDurationText -Duration $liveDuration }
    elseif ($null -ne $rawDuration -and ([string]$rawDuration).Length -gt 0) { $liveText = [string]$rawDuration }
    if (-not $required) { $liveText += ', expiration not required' }

    $detail = ''
    $compliant = $false
    if (-not $required) { $detail = 'activation is not required to expire' }
    elseif ($null -eq $liveDuration) { $detail = 'the live maximum duration cannot be read' }
    elseif ($liveDuration -gt $DesiredDuration) { $detail = 'activation can last longer than the baseline allows' }
    elseif ($liveDuration -lt $DesiredDuration -and $Mode -eq 'exact') { $detail = 'activation is shorter than the baseline (exact mode)' }
    else {
        $compliant = $true
        if ($liveDuration -lt $DesiredDuration) { $detail = 'shorter than the baseline; stricter is compliant in minimum mode' }
    }

    if ($compliant) { return (New-PimRuleResult -RuleId $ruleId -Status Compliant -Live $liveText -Desired $desiredText -Detail $detail) }

    $patchDuration = $DesiredDuration
    $keepStored = (-not $required) -and ($Mode -eq 'minimum') -and ($null -ne $liveDuration) -and
        ($liveDuration -ge $script:PimMinimumActivation) -and ($liveDuration -lt $DesiredDuration) -and
        ($liveDuration.Seconds -eq 0) -and ($liveDuration.Milliseconds -eq 0)
    if ($keepStored) {
        $patchDuration = $liveDuration
        $detail += ('; the patch turns expiration on and keeps the shorter stored {0}' -f (ConvertTo-PimDurationText -Duration $liveDuration))
    }
    return (New-PimRuleResult -RuleId $ruleId -Status Drift -Live $liveText -Desired $desiredText -Detail $detail -Body (New-PimExpirationRuleBody -Duration $patchDuration))
}

function Compare-PimEnablementRule {
    <#
    .SYNOPSIS
        Compares Enablement_EndUser_Assignment with the baseline activation
        requirements.
    .DESCRIPTION
        Compliant when every baseline requirement is enabled (minimum), or
        when the enabled set is exactly the baseline (exact). Values compare
        case-insensitively.

        An enabled authentication context rule does not count as
        MultiFactorAuthentication unless AuthenticationContextSatisfiesMfa
        is set. Without it, a baseline MFA the rule lacks is missing, the
        patch adds it next to the context, and Detail names the context and
        the baseline key.

        With AuthenticationContextSatisfiesMfa and an enabled context, a
        baseline MFA counts as met and is never added. When the context
        stands in for a baseline MFA that the rule lacks, Detail and Notice
        say "MFA delegated to authentication context <claimValue>". An
        enabled context rule with an empty claimValue is then an Error, and
        nothing is patched.

        With either setting, a live MFA next to an enabled context is never
        an extra and is never removed. The patch changes only what the
        comparison flagged. It adds the missing requirements, removes the
        extras in exact mode, and keeps every other live value. In minimum
        mode it therefore only adds.
    .PARAMETER Rule
        The live enablement rule, or $null.
    .PARAMETER AuthenticationContextRule
        The live AuthenticationContext_EndUser_Assignment rule, or $null.
    .PARAMETER DesiredRules
        Baseline activation requirements.
    .PARAMETER Mode
        minimum or exact.
    .PARAMETER AuthenticationContextSatisfiesMfa
        Baseline key authenticationContextSatisfiesMfa for this role or
        group. Default $false.
    .EXAMPLE
        Compare-PimEnablementRule -Rule $rule -AuthenticationContextRule $contextRule -DesiredRules @('MultiFactorAuthentication', 'Justification') -AuthenticationContextSatisfiesMfa $true
    #>
    param(
        [AllowNull()][object]$Rule,
        [AllowNull()][object]$AuthenticationContextRule = $null,
        [AllowEmptyCollection()][string[]]$DesiredRules = @(),
        [ValidateSet('minimum', 'exact')][string]$Mode = 'minimum',
        [bool]$AuthenticationContextSatisfiesMfa = $false
    )

    $ruleId = $script:PimRuleIds.Enablement
    $mfa = 'MultiFactorAuthentication'
    $contextEnabled = $false
    $contextValue = Get-PimProperty -Object $AuthenticationContextRule -Name 'isEnabled'
    if ($null -ne $contextValue) { $contextEnabled = [bool]$contextValue }
    $claimValue = ''
    $claimRaw = Get-PimProperty -Object $AuthenticationContextRule -Name 'claimValue'
    if ($null -ne $claimRaw) { $claimValue = ([string]$claimRaw).Trim() }
    # The context stands in for MFA only when the baseline says so.
    $contextCounts = $contextEnabled -and $AuthenticationContextSatisfiesMfa

    $baselineWantsMfa = $false
    $desired = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($DesiredRules)) {
        $name = ConvertTo-PimRequirementName -Value $value
        if ($name.Length -eq 0 -or $desired.Contains($name)) { continue }
        if ($name -eq $mfa) {
            $baselineWantsMfa = $true
            if ($contextCounts) { continue }
        }
        $desired.Add($name)
    }
    $desiredText = '(none)'
    if ($desired.Count -gt 0) { $desiredText = $desired.ToArray() -join ', ' }
    if ($contextCounts -and $baselineWantsMfa) { $desiredText += ' (MFA met by authentication context)' }

    if ($null -eq $Rule) {
        return (New-PimRuleResult -RuleId $ruleId -Status Error -Live '(rule not in policy)' -Desired $desiredText -Detail 'the policy returned no enablement rule for activation')
    }

    $live = New-Object System.Collections.Generic.List[string]
    foreach ($value in @(Get-PimProperty -Object $Rule -Name 'enabledRules')) {
        if ($null -eq $value) { continue }
        $name = ConvertTo-PimRequirementName -Value $value
        if ($name.Length -gt 0 -and -not $live.Contains($name)) { $live.Add($name) }
    }
    $liveText = '(none)'
    if ($live.Count -gt 0) { $liveText = $live.ToArray() -join ', ' }
    $contextText = ''
    if ($contextEnabled -and $claimValue.Length -gt 0) {
        $contextText = 'authentication context {0}' -f $claimValue
        $liveText += (' (authentication context {0} enabled)' -f $claimValue)
    }
    elseif ($contextEnabled) {
        $contextText = 'an authentication context with an empty claimValue'
        $liveText += ' (authentication context enabled, claimValue empty)'
    }

    if ($contextCounts -and $claimValue.Length -eq 0) {
        return (New-PimRuleResult -RuleId $ruleId -Status Error -Live $liveText -Desired $desiredText -Detail 'the authentication context rule is enabled but names no authentication context (claimValue is empty), so nothing is known to stand in for MultiFactorAuthentication; fix the role setting in the admin center')
    }

    $missing = @($desired | Where-Object { -not $live.Contains($_) })
    # A live MFA next to an enabled context is neither required nor an extra.
    $extra = @($live | Where-Object { -not $desired.Contains($_) -and -not ($contextEnabled -and $_ -eq $mfa) })
    $notice = ''
    if ($contextCounts -and $baselineWantsMfa -and -not $live.Contains($mfa)) {
        $notice = 'MFA delegated to authentication context {0}' -f $claimValue
    }

    $compliant = ($missing.Count -eq 0) -and ($Mode -eq 'minimum' -or $extra.Count -eq 0)
    if ($compliant) {
        $parts = @()
        if ($notice.Length -gt 0) { $parts += $notice }
        if ($extra.Count -gt 0) { $parts += ('also requires {0}; stricter is compliant in minimum mode' -f ($extra -join ', ')) }
        return (New-PimRuleResult -RuleId $ruleId -Status Compliant -Live $liveText -Desired $desiredText -Detail ($parts -join '; ') -Notice $notice)
    }

    $parts = @()
    if ($missing.Count -gt 0) { $parts += ('missing {0}' -f ($missing -join ', ')) }
    if ($Mode -eq 'exact' -and $extra.Count -gt 0) { $parts += ('not in the baseline: {0} (exact mode)' -f ($extra -join ', ')) }
    if ($notice.Length -gt 0) { $parts += $notice }
    if ($contextEnabled -and -not $contextCounts -and $missing -contains $mfa) {
        $parts += ('{0} is enabled but counts as MFA only when the baseline sets authenticationContextSatisfiesMfa; Graph may refuse MFA next to a context' -f $contextText)
    }

    # Change only what was flagged: remove the extras in exact mode, add what
    # is missing, and keep every other live value (a live MFA included), so a
    # minimum-mode patch never drops a requirement.
    $combined = New-Object System.Collections.Generic.List[string]
    foreach ($name in $live) {
        if ($Mode -eq 'exact' -and $extra -contains $name) { continue }
        $combined.Add($name)
    }
    foreach ($name in $missing) { if (-not $combined.Contains($name)) { $combined.Add($name) } }
    $target = New-Object System.Collections.Generic.List[string]
    foreach ($known in $script:PimActivationRequirements) { if ($combined.Contains($known)) { $target.Add($known) } }
    foreach ($other in $combined) { if (-not $target.Contains($other)) { $target.Add($other) } }
    return (New-PimRuleResult -RuleId $ruleId -Status Drift -Live $liveText -Desired $desiredText -Detail ($parts -join '; ') -Body (New-PimEnablementRuleBody -EnabledRules $target.ToArray()) -Notice $notice)
}

function Get-PimApproverIds {
    <#
    .SYNOPSIS
        Sorted approver keys of one approval stage: group:<id>, user:<id>, or
        other:<type> for any other subject set.
    .PARAMETER Stage
        A live unifiedApprovalStage, or $null.
    .EXAMPLE
        Get-PimApproverIds -Stage $setting.approvalStages[0]
    #>
    param([AllowNull()][object]$Stage)

    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($approver in @(Get-PimProperty -Object $Stage -Name 'primaryApprovers')) {
        if ($null -eq $approver) { continue }
        $type = [string](Get-PimProperty -Object $approver -Name '@odata.type')
        if ($type -match 'groupMembers$') { $key = 'group:' + ([string](Get-PimProperty -Object $approver -Name 'groupId')).ToLowerInvariant() }
        elseif ($type -match 'singleUser$') { $key = 'user:' + ([string](Get-PimProperty -Object $approver -Name 'userId')).ToLowerInvariant() }
        else { $key = 'other:' + $type.TrimStart('#') }
        if (-not $keys.Contains($key)) { $keys.Add($key) }
    }
    $keys.Sort([StringComparer]::Ordinal)
    return , ([string[]]$keys.ToArray())
}

function Compare-PimApprovalRule {
    <#
    .SYNOPSIS
        Compares Approval_EndUser_Assignment with the baseline.
    .DESCRIPTION
        Baseline requires approval: compliant when approval is required and
        the first stage's primary approvers are exactly the baseline group
        (and, in exact mode, there is only one stage). Baseline does not
        require approval: always compliant in minimum mode (approval is
        stricter); in exact mode compliant only when approval is off.
        In minimum mode, a rule that already requires approval is patched by
        replacing only its first stage's primary approvers; everything else
        in the live setting is kept (see New-PimApprovalRuleBody).
    .PARAMETER Rule
        The live approval rule, or $null.
    .PARAMETER RequireApproval
        Baseline value.
    .PARAMETER ApproverGroupId
        Baseline approver group id; needed when RequireApproval.
    .PARAMETER ApproverGroupName
        Its display name, for the report.
    .PARAMETER Mode
        minimum or exact.
    .EXAMPLE
        Compare-PimApprovalRule -Rule $rule -RequireApproval $true -ApproverGroupId $id -ApproverGroupName 'PIM Approvers'
    #>
    param(
        [AllowNull()][object]$Rule,
        [Parameter(Mandatory = $true)][bool]$RequireApproval,
        [AllowEmptyString()][string]$ApproverGroupId = '',
        [AllowEmptyString()][string]$ApproverGroupName = '',
        [ValidateSet('minimum', 'exact')][string]$Mode = 'minimum'
    )

    $ruleId = $script:PimRuleIds.Approval
    if ($RequireApproval -and [string]::IsNullOrWhiteSpace($ApproverGroupId)) {
        throw 'Compare-PimApprovalRule: the baseline requires approval but no approver group id was resolved.'
    }
    $desiredText = 'not required'
    if ($RequireApproval) { $desiredText = 'required; approvers: group "{0}" ({1})' -f $ApproverGroupName, $ApproverGroupId }

    if ($null -eq $Rule) {
        return (New-PimRuleResult -RuleId $ruleId -Status Error -Live '(rule not in policy)' -Desired $desiredText -Detail 'the policy returned no approval rule for activation')
    }

    $setting = Get-PimProperty -Object $Rule -Name 'setting'
    $liveRequired = $false
    $requiredValue = Get-PimProperty -Object $setting -Name 'isApprovalRequired'
    if ($null -ne $requiredValue) { $liveRequired = [bool]$requiredValue }
    $stages = @()
    foreach ($stage in @(Get-PimProperty -Object $setting -Name 'approvalStages')) { if ($null -ne $stage) { $stages += $stage } }
    $firstApprovers = [string[]]@()
    if ($stages.Count -gt 0) { $firstApprovers = Get-PimApproverIds -Stage $stages[0] }

    $approverText = '(none)'
    if ($firstApprovers.Count -gt 0) { $approverText = $firstApprovers -join ', ' }
    if ($liveRequired) { $liveText = 'required; {0} stage(s); first stage approvers: {1}' -f $stages.Count, $approverText }
    else { $liveText = 'not required' }

    if ($RequireApproval) {
        $expected = 'group:' + $ApproverGroupId.ToLowerInvariant()
        $approversMatch = ($firstApprovers.Count -eq 1 -and $firstApprovers[0] -eq $expected)
        $detail = ''
        if (-not $liveRequired) { $detail = 'approval is not required' }
        elseif (-not $approversMatch) { $detail = 'the first stage approvers are not exactly the baseline approver group' }
        elseif ($Mode -eq 'exact' -and $stages.Count -ne 1) { $detail = 'more than one approval stage (exact mode)' }
        else {
            $extraStages = ''
            if ($stages.Count -gt 1) { $extraStages = 'extra approval stages; stricter is compliant in minimum mode' }
            return (New-PimRuleResult -RuleId $ruleId -Status Compliant -Live $liveText -Desired $desiredText -Detail $extraStages)
        }
        $keepLive = ($Mode -eq 'minimum' -and $liveRequired)
        $body = New-PimApprovalRuleBody -Required $true -ApproverGroupId $ApproverGroupId -LiveSetting $setting -KeepLiveStages $keepLive
        return (New-PimRuleResult -RuleId $ruleId -Status Drift -Live $liveText -Desired $desiredText -Detail $detail -Body $body)
    }

    if (-not $liveRequired) { return (New-PimRuleResult -RuleId $ruleId -Status Compliant -Live $liveText -Desired $desiredText) }
    if ($Mode -eq 'minimum') {
        return (New-PimRuleResult -RuleId $ruleId -Status Compliant -Live $liveText -Desired $desiredText -Detail 'approval is required; stricter is compliant in minimum mode')
    }
    return (New-PimRuleResult -RuleId $ruleId -Status Drift -Live $liveText -Desired $desiredText -Detail 'approval is required but the baseline does not require it (exact mode)' -Body (New-PimApprovalRuleBody -Required $false -LiveSetting $setting))
}

function Get-PimPolicyDrift {
    <#
    .SYNOPSIS
        Report rows for one policy assignment: one per checked rule.
    .DESCRIPTION
        Writes one row per rule (Expiration, Enablement, Approval) with
        ScopeType, Target, RoleDefinitionId, ScopeId, PolicyId, RuleId,
        Status, Outcome, Live, Desired, Detail, Notice, and Body (the PATCH
        body for Drift). An excluded role or group gives one Excluded row; an
        assignment without an expanded policy gives Error rows. Wrap in @().
    .PARAMETER Assignment
        A parsed policy assignment with policy and rules expanded.
    .PARAMETER ScopeType
        DirectoryRole or Group.
    .PARAMETER TargetName
        Role name, or "group name (member|owner)".
    .PARAMETER Settings
        From Get-PimEffectiveSettings.
    .PARAMETER ApproverGroupId
        Resolved approver group id when the settings require approval.
    .PARAMETER Mode
        minimum or exact.
    .EXAMPLE
        $rows = @(Get-PimPolicyDrift -Assignment $a -ScopeType DirectoryRole -TargetName 'Global Administrator' -Settings $settings -Mode minimum)
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Assignment,
        [Parameter(Mandatory = $true)][ValidateSet('DirectoryRole', 'Group')][string]$ScopeType,
        [Parameter(Mandatory = $true)][string]$TargetName,
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [AllowEmptyString()][string]$ApproverGroupId = '',
        [ValidateSet('minimum', 'exact')][string]$Mode = 'minimum'
    )

    $policy = Get-PimProperty -Object $Assignment -Name 'policy'
    $policyId = [string](Get-PimProperty -Object $Assignment -Name 'policyId')
    if ([string]::IsNullOrWhiteSpace($policyId)) { $policyId = [string](Get-PimProperty -Object $policy -Name 'id') }
    $base = [ordered]@{
        ScopeType        = $ScopeType
        Target           = $TargetName
        RoleDefinitionId = [string](Get-PimProperty -Object $Assignment -Name 'roleDefinitionId')
        ScopeId          = [string](Get-PimProperty -Object $Assignment -Name 'scopeId')
        PolicyId         = $policyId
    }

    $results = @()
    if ($Settings.Exclude) {
        $results += New-PimRuleResult -RuleId '*' -Status Compliant -Live '' -Desired '' -Detail 'excluded by the baseline'
    }
    elseif ($null -eq $policy -or [string]::IsNullOrWhiteSpace($policyId)) {
        foreach ($id in @($script:PimRuleIds.Expiration, $script:PimRuleIds.Enablement, $script:PimRuleIds.Approval)) {
            $results += New-PimRuleResult -RuleId $id -Status Error -Live '(policy not expanded)' -Detail 'the assignment came back without its policy and rules'
        }
    }
    else {
        $rules = @(Get-PimProperty -Object $policy -Name 'rules')
        $results += Compare-PimExpirationRule -Rule (Get-PimRuleById -Rules $rules -RuleId $script:PimRuleIds.Expiration) -DesiredDuration $Settings.MaximumActivationDuration -Mode $Mode
        $results += Compare-PimEnablementRule -Rule (Get-PimRuleById -Rules $rules -RuleId $script:PimRuleIds.Enablement) -AuthenticationContextRule (Get-PimRuleById -Rules $rules -RuleId $script:PimRuleIds.AuthenticationContext) -DesiredRules $Settings.ActivationRequirements -Mode $Mode -AuthenticationContextSatisfiesMfa ([bool]$Settings.AuthenticationContextSatisfiesMfa)
        $results += Compare-PimApprovalRule -Rule (Get-PimRuleById -Rules $rules -RuleId $script:PimRuleIds.Approval) -RequireApproval ([bool]$Settings.RequireApproval) -ApproverGroupId $ApproverGroupId -ApproverGroupName ([string]$Settings.ApproverGroupName) -Mode $Mode
    }

    foreach ($result in $results) {
        $status = $result.Status
        $outcome = ''
        if ($Settings.Exclude) { $status = 'Excluded'; $outcome = 'Excluded' }
        elseif ($status -eq 'Compliant') { $outcome = 'Compliant' }
        elseif ($status -eq 'Error') { $outcome = 'Error' }
        $row = [ordered]@{}
        foreach ($key in $base.Keys) { $row[$key] = $base[$key] }
        $row.RuleId = $result.RuleId
        $row.Status = $status
        $row.Outcome = $outcome
        $row.Live = $result.Live
        $row.Desired = $result.Desired
        $row.Detail = $result.Detail
        $row.Notice = [string]$result.Notice
        $row.Body = $result.Body
        [PSCustomObject]$row
    }
}

# ---------------------------------------------------------------------------
# Output: digest and report.
# ---------------------------------------------------------------------------

function New-PimDriftDigestHtml {
    <#
    .SYNOPSIS
        HTML body of the drift digest.
    .PARAMETER Rows
        Report rows with Status Drift or Error.
    .PARAMETER Failures
        Failed summary items.
    .PARAMETER Notes
        Extra lines, such as skipped group checks.
    .PARAMETER DryRun
        Whether this run was a dry run.
    .PARAMETER Mode
        Baseline mode, for the text.
    .PARAMETER RunId
        Correlation id.
    .EXAMPLE
        New-PimDriftDigestHtml -Rows $driftRows -Failures $failures -DryRun $true -Mode minimum -RunId $runId
    #>
    param(
        [AllowEmptyCollection()][object[]]$Rows = @(),
        [AllowEmptyCollection()][object[]]$Failures = @(),
        [AllowEmptyCollection()][string[]]$Notes = @(),
        [bool]$DryRun = $true,
        [string]$Mode = 'minimum',
        [AllowEmptyString()][string]$RunId = ''
    )

    $driftCount = @($Rows | Where-Object { $_.Status -eq 'Drift' }).Count
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px">')
    [void]$sb.Append(('<p>{0} PIM activation rule(s) differ from the baseline ({1} mode), and the run recorded {2} failure(s).</p>' -f $driftCount, (ConvertTo-HtmlSafe -Value $Mode), @($Failures).Count))
    if ($DryRun) {
        [void]$sb.Append('<p>This run was a report only (DryRun). Either a role setting was changed outside the baseline (revert it, or change the baseline if the new value is intended), or enforcement is not turned on for this Automation account.</p>')
    }
    else {
        [void]$sb.Append('<p>Rules marked Done were patched back to the baseline by the runbook; the Entra audit log records each change under the runbook identity. Rules marked Failed were not changed.</p>')
    }

    if (@($Rows).Count -gt 0) {
        [void]$sb.Append('<table border="1" cellpadding="4" cellspacing="0" style="border-collapse:collapse">')
        [void]$sb.Append('<tr><th>Scope</th><th>Target</th><th>Rule</th><th>Live</th><th>Baseline</th><th>Outcome</th><th>Detail</th></tr>')
        foreach ($row in @($Rows | Sort-Object -Property ScopeType, Target, RuleId)) {
            [void]$sb.Append('<tr>')
            foreach ($value in @($row.ScopeType, $row.Target, $row.RuleId, $row.Live, $row.Desired, $row.Outcome, $row.Detail)) {
                [void]$sb.Append(('<td>{0}</td>' -f (ConvertTo-HtmlSafe -Value ([string]$value))))
            }
            [void]$sb.Append('</tr>')
        }
        [void]$sb.Append('</table>')
    }

    if (@($Failures).Count -gt 0) {
        [void]$sb.Append('<p>Failures:</p><table border="1" cellpadding="4" cellspacing="0" style="border-collapse:collapse"><tr><th>Action</th><th>Target</th><th>Detail</th></tr>')
        foreach ($failure in @($Failures)) {
            [void]$sb.Append(('<tr><td>{0}</td><td>{1}</td><td>{2}</td></tr>' -f (ConvertTo-HtmlSafe -Value $failure.Action), (ConvertTo-HtmlSafe -Value $failure.Target), (ConvertTo-HtmlSafe -Value $failure.Detail)))
        }
        [void]$sb.Append('</table>')
    }

    if (@($Notes).Count -gt 0) {
        [void]$sb.Append('<ul>')
        foreach ($note in @($Notes)) { [void]$sb.Append(('<li>{0}</li>' -f (ConvertTo-HtmlSafe -Value $note))) }
        [void]$sb.Append('</ul>')
    }

    [void]$sb.Append(('<p style="color:#666">Sent by the PIM policy drift runbook (run {0}). This mailbox is not monitored.</p>' -f (ConvertTo-HtmlSafe -Value $RunId)))
    [void]$sb.Append('</body></html>')
    return $sb.ToString()
}

function Export-PimDriftReport {
    <#
    .SYNOPSIS
        Writes the report rows to a CSV file (no request bodies).
    .PARAMETER Rows
        Report rows.
    .PARAMETER Path
        CSV path; the folder is created when missing.
    .EXAMPLE
        Export-PimDriftReport -Rows $rows -Path "$env:TEMP\pim-policy-drift.csv"
    #>
    param(
        [AllowEmptyCollection()][object[]]$Rows = @(),
        [Parameter(Mandatory = $true)][string]$Path
    )

    $columns = @('ScopeType', 'Target', 'RoleDefinitionId', 'ScopeId', 'PolicyId', 'RuleId', 'Status', 'Outcome', 'Live', 'Desired', 'Detail')
    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $records = @($Rows | Where-Object { $null -ne $_ } | Select-Object -Property $columns)
    if ($records.Count -eq 0) {
        Set-Content -LiteralPath $Path -Value ((@($columns | ForEach-Object { '"' + $_ + '"' })) -join ',') -Encoding UTF8
        return
    }
    $records | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Resolve-PimReportPath {
    <#
    .SYNOPSIS
        Checks ReportPath before the run reads anything and returns it as a
        full file system path.
    .DESCRIPTION
        Resolves the path against the current location, refuses a folder or
        a path outside the file system, creates the parent folder, and opens
        the file for writing once, so a missing drive, a bad name, or a
        locked file stops the run before any request. A file that the check
        itself created is removed again. Every problem throws with the
        reason.
    .PARAMETER Path
        The ReportPath value.
    .EXAMPLE
        $reportFile = Resolve-PimReportPath -Path '.\out\pim-policy-drift.csv'
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $provider = $null
    $drive = $null
    $full = ''
    try { $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path.Trim(), [ref]$provider, [ref]$drive) }
    catch { throw ('ReportPath "{0}" cannot be used: {1}' -f $Path, (Protect-RunbookText -Text $_.Exception.Message -MaxLength 300)) }
    if ($null -eq $provider -or $provider.Name -ne 'FileSystem') { throw ('ReportPath "{0}" is not a file system path.' -f $Path) }
    if (Test-Path -LiteralPath $full -PathType Container) { throw ('ReportPath "{0}" is a folder. Give a file path, for example {1}.' -f $Path, (Join-Path -Path $full -ChildPath 'pim-policy-drift.csv')) }

    try {
        $directory = Split-Path -Path $full -Parent
        if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null }
        $existed = Test-Path -LiteralPath $full -PathType Leaf
        $stream = [System.IO.File]::Open($full, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.Dispose()
        if (-not $existed) { Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue }
    }
    catch { throw ('ReportPath "{0}" cannot be written: {1}' -f $Path, (Protect-RunbookText -Text $_.Exception.Message -MaxLength 300)) }
    return $full
}

function Save-PimDriftReport {
    <#
    .SYNOPSIS
        Writes the report, recording a failure instead of throwing.
    .DESCRIPTION
        Calls Export-PimDriftReport. An error is logged at Error level and
        recorded as a Failed ExportReport item, so the run still sends its
        digest and returns its summary, and a tripped breaker is still the
        error the run ends with. Returns $true when the file was written.
    .PARAMETER Summary
        The run summary.
    .PARAMETER Rows
        Report rows.
    .PARAMETER Path
        Full CSV path from Resolve-PimReportPath.
    .EXAMPLE
        $written = Save-PimDriftReport -Summary $summary -Rows $allRows -Path $reportFile
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Summary,
        [AllowEmptyCollection()][object[]]$Rows = @(),
        [Parameter(Mandatory = $true)][string]$Path
    )

    try {
        Export-PimDriftReport -Rows $Rows -Path $Path
        Write-RunLog -Level Info -Message ('Wrote report to {0}.' -f $Path)
        return $true
    }
    catch {
        $text = 'Could not write the report to {0}: {1}' -f $Path, (Protect-RunbookText -Text $_.Exception.Message -MaxLength 300)
        Write-RunLog -Level Error -Message $text
        Add-RunSummaryItem -Summary $Summary -Action 'ExportReport' -Target $Path -Outcome Failed -Detail $text
        return $false
    }
}

function Get-PimAccessHint {
    <#
    .SYNOPSIS
        An error message with a permission hint added for HTTP 403.
    .PARAMETER ErrorRecord
        The caught error.
    .PARAMETER Permission
        The Graph application permission the call needs.
    .EXAMPLE
        throw (Get-PimAccessHint -ErrorRecord $_ -Permission 'RoleManagementPolicy.Read.Directory')
    #>
    param(
        [Parameter(Mandatory = $true)][object]$ErrorRecord,
        [Parameter(Mandatory = $true)][string]$Permission
    )

    $message = ''
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $message = $ErrorRecord.Exception.Message }
    elseif ($ErrorRecord -is [Exception]) { $message = $ErrorRecord.Message }
    else { $message = [string]$ErrorRecord }
    if ((Get-CloudErrorStatus -ErrorRecord $ErrorRecord) -eq 403) {
        $message += (' The managed identity needs the Microsoft Graph application permission {0}.' -f $Permission)
    }
    return $message
}

# ---------------------------------------------------------------------------
# Run.
# ---------------------------------------------------------------------------

function Invoke-EntraPimPolicyDriftRun {
    <#
    .SYNOPSIS
        One drift run: parse and check the inputs, read, compare, check the
        breaker, patch, write the report, mail, and return the summary.
    .DESCRIPTION
        Takes the runbook parameters, with the same defaults. AccessToken may
        also be a hashtable in tests. Returns exactly one summary object.
    .PARAMETER BaselineVariableName
        See the runbook help.
    .PARAMETER BaselineJson
        See the runbook help.
    .PARAMETER IncludeGroupNames
        See the runbook help.
    .PARAMETER ApproverGroupName
        See the runbook help.
    .PARAMETER Recipients
        See the runbook help.
    .PARAMETER SenderMailbox
        See the runbook help.
    .PARAMETER MaxRuleUpdatesPerRun
        See the runbook help.
    .PARAMETER ReportPath
        See the runbook help.
    .PARAMETER DryRun
        See the runbook help.
    .PARAMETER Environment
        See the runbook help.
    .PARAMETER ClientId
        See the runbook help.
    .PARAMETER AccessToken
        See the runbook help.
    .PARAMETER RunId
        See the runbook help.
    .EXAMPLE
        Invoke-EntraPimPolicyDriftRun -AccessToken $token -BaselineVariableName '' -ReportPath .\out\pim.csv
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$BaselineVariableName = 'PimPolicy_EntraBaseline',
        [AllowNull()][AllowEmptyString()][string]$BaselineJson = '',
        [AllowEmptyString()][string]$IncludeGroupNames = '',
        [AllowEmptyString()][string]$ApproverGroupName = '',
        [AllowEmptyString()][string]$Recipients = '',
        [AllowEmptyString()][string]$SenderMailbox = '',
        [ValidateRange(0, 1000)][int]$MaxRuleUpdatesPerRun = 40,
        [AllowEmptyString()][string]$ReportPath = '',
        [bool]$DryRun = $true,
        [ValidateSet('Global', 'USGov')][string]$Environment = 'Global',
        [AllowEmptyString()][string]$ClientId = '',
        [AllowNull()][object]$AccessToken = $null,
        [AllowEmptyString()][string]$RunId = ''
    )

    Initialize-RunContext -RunbookName 'Invoke-EntraPimPolicyDrift' -RunId $RunId -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken -DryRun $DryRun
    $summary = New-RunSummary

    # Inputs. Every problem here is a configuration error: the run stops
    # before it sends any request.
    $baselineInput = Resolve-PimBaselineText -BaselineJson $BaselineJson -BaselineVariableName $BaselineVariableName
    $baseline = ConvertTo-PimBaseline -Json $baselineInput.Text -ApproverGroupName $ApproverGroupName -Source $baselineInput.Source
    $groupNames = @(Select-PimUniqueName -Names ([string[]]@(ConvertTo-StringList -Value $IncludeGroupNames -Label 'IncludeGroupNames')))
    $recipientList = @(ConvertTo-StringList -Value $Recipients -Label 'Recipients')
    foreach ($address in $recipientList) {
        if ($address -notmatch '^[^@\s]+@[^@\s]+$') { throw ('Recipients has a value that is not a mail address: "{0}".' -f $address) }
    }
    if (-not [string]::IsNullOrWhiteSpace($SenderMailbox) -and $SenderMailbox -notmatch '^[^@\s]+@[^@\s]+$') {
        throw ('SenderMailbox "{0}" is not a mail address.' -f $SenderMailbox)
    }
    foreach ($entry in $baseline.Groups.Values) {
        if (-not (@($groupNames | Where-Object { $_.Equals($entry.Name, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)) {
            throw ('{0} groups."{1}" names a group that is not in IncludeGroupNames. Add it there or remove the override.' -f $baseline.Source, $entry.Name)
        }
    }
    $reportFile = ''
    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) { $reportFile = Resolve-PimReportPath -Path $ReportPath }
    $defaults = $baseline.Defaults
    Write-RunLog -Level Info -Message ('Baseline from {0}: mode={1} maximumActivationDuration={2} activationRequirements={3} requireApproval={4} authenticationContextSatisfiesMfa={5} roleOverrides={6} groupOverrides={7}. Groups to check: {8}. Cap: {9} rule update(s).' -f $baseline.Source, $baseline.Mode, (ConvertTo-PimDurationText -Duration $defaults.MaximumActivationDuration), ($defaults.ActivationRequirements -join '+'), $defaults.RequireApproval, $defaults.AuthenticationContextSatisfiesMfa, $baseline.Roles.Count, $baseline.Groups.Count, $groupNames.Count, $MaxRuleUpdatesPerRun)

    # Approver groups, resolved once and up front: a missing or empty
    # approver group is a configuration error, not a per-role failure.
    # Approval routed to a group with no users can never be granted.
    $approverIds = @{}
    foreach ($name in @(Get-PimApproverGroupNames -Baseline $baseline)) {
        $approverId = ''
        try { $approverId = Resolve-GroupIdByName -DisplayName $name }
        catch { throw ('Approver group "{0}" could not be resolved: {1}' -f $name, (Get-PimAccessHint -ErrorRecord $_ -Permission 'Group.Read.All')) }
        $approverUsers = @()
        try { $approverUsers = @(Get-TransitiveGroupMemberIds -GroupId $approverId -MemberType User) }
        catch { throw ('Could not read the members of approver group "{0}" ({1}): {2}' -f $name, $approverId, (Get-PimAccessHint -ErrorRecord $_ -Permission 'Group.Read.All')) }
        if ($approverUsers.Count -eq 0) {
            throw ('Approver group "{0}" ({1}) has no user members, directly or through nested groups. Approval routed to it could never be granted, so the run stopped before reading any policy. Add approvers to the group or change the baseline.' -f $name, $approverId)
        }
        $approverIds[$name.ToLowerInvariant()] = $approverId
        Write-RunLog -Level Info -Message ('Approver group "{0}" is {1} with {2} user member(s).' -f $name, $approverId, $approverUsers.Count)
    }

    # Role names.
    $definitions = @()
    try { $definitions = @(Invoke-CloudRequest -Api Graph -Uri 'roleManagement/directory/roleDefinitions' -AllPages) }
    catch { throw ('Could not list directory role definitions: {0}' -f (Get-PimAccessHint -ErrorRecord $_ -Permission 'RoleManagement.Read.Directory')) }
    $roleNames = Get-PimRoleNameMap -RoleDefinitions $definitions
    $knownRoleNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($definition in $definitions) { [void]$knownRoleNames.Add([string](Get-PimProperty -Object $definition -Name 'displayName')) }
    $unmatchedOverrides = 0
    foreach ($entry in @($baseline.Roles.Values | Sort-Object -Property Name)) {
        if ($knownRoleNames.Contains($entry.Name)) { continue }
        $unmatchedOverrides++
        $text = '{0} roles."{1}" matches no directory role in this tenant; the override was not applied. Fix the name in the baseline.' -f $baseline.Source, $entry.Name
        Write-RunLog -Level Warn -Message $text
        Add-RunSummaryItem -Summary $summary -Action 'MatchOverride' -Target $entry.Name -Outcome Failed -Detail $text
    }

    # Directory role policies at the tenant scope.
    $rawDirectory = @()
    try { $rawDirectory = @(Invoke-CloudRequest -Api Graph -Uri (New-PimAssignmentsUri -ScopeId '/' -ScopeType DirectoryRole) -AllPages) }
    catch { throw ('Could not list directory role policy assignments: {0}' -f (Get-PimAccessHint -ErrorRecord $_ -Permission 'RoleManagementPolicy.Read.Directory')) }
    $directory = @(Select-UniquePimAssignment -Assignments $rawDirectory)
    $duplicates = $rawDirectory.Count - $directory.Count
    if ($directory.Count -eq 0) {
        throw ('The directory role policy list returned no assignments (filter: scopeId eq ''/'' and scopeType eq ''DirectoryRole''). Every tenant has one policy per directory role, so this is a broken filter, a wrong scope type, or an API change. Nothing was checked or changed.')
    }
    Write-RunLog -Level Info -Message ('Read {0} role policy assignment(s) ({1} duplicate(s) dropped) and {2} role definition(s).' -f $directory.Count, $duplicates, $definitions.Count)

    $rows = New-Object System.Collections.ArrayList
    foreach ($assignment in $directory) {
        $roleId = [string](Get-PimProperty -Object $assignment -Name 'roleDefinitionId')
        $roleName = $roleId
        if ($roleNames.ContainsKey($roleId)) { $roleName = [string]$roleNames[$roleId] }
        $settings = Get-PimEffectiveSettings -Baseline $baseline -Kind Role -Name $roleName
        $approverId = ''
        if ($settings.RequireApproval -and -not $settings.Exclude) { $approverId = [string]$approverIds[$settings.ApproverGroupName.ToLowerInvariant()] }
        foreach ($row in @(Get-PimPolicyDrift -Assignment $assignment -ScopeType DirectoryRole -TargetName $roleName -Settings $settings -ApproverGroupId $approverId -Mode $baseline.Mode)) {
            [void]$rows.Add($row)
        }
    }
    $rolePolicies = $directory.Count

    # PIM for Groups policies. A 403 anywhere here skips the group checks
    # with a warning; the directory results above stand.
    $groupPolicies = 0
    $groupsSkipped = $false
    $notes = New-Object System.Collections.ArrayList
    foreach ($groupName in $groupNames) {
        if ($groupsSkipped) { break }
        $rawGroup = @()
        $readFailed = $false
        try {
            $groupId = Resolve-GroupIdByName -DisplayName $groupName
            $rawGroup = @(Invoke-CloudRequest -Api Graph -Uri (New-PimAssignmentsUri -ScopeId $groupId -ScopeType Group) -AllPages)
        }
        catch {
            $readFailed = $true
            $message = Protect-RunbookText -Text $_.Exception.Message -MaxLength 400
            if ((Get-CloudErrorStatus -ErrorRecord $_) -eq 403) {
                $groupsSkipped = $true
                $text = 'PIM for Groups checks skipped: the identity was refused while reading group "{0}" ({1}). It needs Group.Read.All and RoleManagementPolicy.Read.AzureADGroup (ReadWrite to enforce). Directory role checks are unaffected.' -f $groupName, $message
                Write-RunLog -Level Warn -Message $text
                [void]$notes.Add($text)
                Add-RunSummaryItem -Summary $summary -Action 'CheckGroupPolicies' -Target ($groupNames -join '; ') -Outcome Skipped -Detail $text
            }
            else {
                $text = 'Could not read the PIM policies of group "{0}": {1}' -f $groupName, $message
                Write-RunLog -Level Error -Message $text
                Add-RunSummaryItem -Summary $summary -Action 'ReadGroupPolicies' -Target $groupName -Outcome Failed -Detail $text
            }
        }
        if ($readFailed) { continue }

        $groupAssignments = @(Select-UniquePimAssignment -Assignments @($rawGroup | Where-Object { @('member', 'owner') -contains ([string](Get-PimProperty -Object $_ -Name 'roleDefinitionId')).ToLowerInvariant() }))
        if ($groupAssignments.Count -eq 0) {
            $text = 'Group "{0}" returned no member or owner PIM policy, so it was not checked. Confirm the group is managed by PIM for Groups, or remove it from IncludeGroupNames.' -f $groupName
            Write-RunLog -Level Error -Message $text
            Add-RunSummaryItem -Summary $summary -Action 'ReadGroupPolicies' -Target $groupName -Outcome Failed -Detail $text
            continue
        }
        $settings = Get-PimEffectiveSettings -Baseline $baseline -Kind Group -Name $groupName
        $approverId = ''
        if ($settings.RequireApproval -and -not $settings.Exclude) { $approverId = [string]$approverIds[$settings.ApproverGroupName.ToLowerInvariant()] }
        foreach ($assignment in $groupAssignments) {
            $groupPolicies++
            $label = '{0} ({1})' -f $groupName, ([string](Get-PimProperty -Object $assignment -Name 'roleDefinitionId')).ToLowerInvariant()
            foreach ($row in @(Get-PimPolicyDrift -Assignment $assignment -ScopeType Group -TargetName $label -Settings $settings -ApproverGroupId $approverId -Mode $baseline.Mode)) {
                [void]$rows.Add($row)
            }
        }
    }

    # Findings.
    $allRows = @($rows.ToArray())
    $updates = @($allRows | Where-Object { $_.Status -eq 'Drift' })
    $errorRows = @($allRows | Where-Object { $_.Status -eq 'Error' })
    $compliantRows = @($allRows | Where-Object { $_.Status -eq 'Compliant' })
    $excludedRows = @($allRows | Where-Object { $_.Status -eq 'Excluded' })
    foreach ($row in $errorRows) {
        $text = '{0} "{1}" {2}: {3}' -f $row.ScopeType, $row.Target, $row.RuleId, $row.Detail
        Write-RunLog -Level Error -Message ('Cannot check {0}.' -f $text)
        Add-RunSummaryItem -Summary $summary -Action 'ReadRule' -Target ('{0}/{1}' -f $row.PolicyId, $row.RuleId) -Outcome Failed -Detail $text
    }
    foreach ($row in $excludedRows) {
        Add-RunSummaryItem -Summary $summary -Action 'CheckPolicy' -Target $row.Target -Outcome Skipped -Detail 'excluded by the baseline'
    }
    foreach ($row in $updates) {
        Write-RunLog -Level Info -Message ('Drift: {0} "{1}" {2}: live {3}; baseline {4}; {5}.' -f $row.ScopeType, $row.Target, $row.RuleId, $row.Live, $row.Desired, $row.Detail)
    }
    # A baseline requirement met by something this runbook does not check
    # (a Conditional Access policy) is compliant, but never silently.
    $noticeRows = @($allRows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Notice) })
    foreach ($row in $noticeRows) {
        $text = '{0} "{1}" {2}: {3}. This runbook does not check the Conditional Access policy behind that context; confirm it is on, not report-only, and excludes no eligible user.' -f $row.ScopeType, $row.Target, $row.RuleId, $row.Notice
        Write-RunLog -Level Warn -Message $text
        [void]$notes.Add($text)
    }
    Write-RunLog -Level Info -Message ('Checked {0} rule(s) in {1} role and {2} group policy(ies): {3} compliant, {4} drifted, {5} unreadable, {6} policy(ies) excluded.' -f ($compliantRows.Count + $updates.Count + $errorRows.Count), $rolePolicies, $groupPolicies, $compliantRows.Count, $updates.Count, $errorRows.Count, $excludedRows.Count)

    # Breaker first, in dry runs too, so a dry run shows that the live run
    # would refuse.
    try {
        Test-CircuitBreaker -Planned $updates.Count -Cap $MaxRuleUpdatesPerRun -Label 'PIM policy rule updates'
    }
    catch {
        $breakerError = $_
        Write-RunLog -Level Error -Message $breakerError.Exception.Message
        foreach ($row in $updates) { $row.Outcome = 'NotApplied' }
        # The report is best effort here; the breaker error is what the run
        # ends with, whatever happens to the file.
        if ($reportFile) { [void](Save-PimDriftReport -Summary $summary -Rows $allRows -Path $reportFile) }
        throw $breakerError
    }

    # Writes. One PATCH per drifted rule; a failure is recorded and the run
    # moves on.
    $forbidden = New-Object System.Collections.ArrayList
    foreach ($row in $updates) {
        $patchUri = 'policies/roleManagementPolicies/{0}/rules/{1}' -f [Uri]::EscapeDataString([string]$row.PolicyId), [Uri]::EscapeDataString([string]$row.RuleId)
        $patchBody = $row.Body
        $patchState = @{ Status = 0 }
        $actionText = 'patch {0} on {1} "{2}" (live {3}; baseline {4})' -f $row.RuleId, $row.ScopeType, $row.Target, $row.Live, $row.Desired
        $outcome = Invoke-RunbookAction -Summary $summary -Action 'PatchRule' -Target ('{0}/{1}' -f $row.PolicyId, $row.RuleId) -Description $actionText -PassThru -ScriptBlock {
            # The body is the whole rule, so sending it twice leaves the same
            # rule; a server error or a lost response may be retried.
            try { Invoke-CloudRequest -Api Graph -Method PATCH -Uri $patchUri -Body $patchBody -RetryNonIdempotent | Out-Null }
            catch {
                $patchState.Status = Get-CloudErrorStatus -ErrorRecord $_
                throw
            }
        }
        $row.Outcome = [string]$outcome
        if ($outcome -eq 'Failed' -and $patchState.Status -eq 403) {
            $permission = 'RoleManagementPolicy.ReadWrite.Directory'
            if ($row.ScopeType -eq 'Group') { $permission = 'RoleManagementPolicy.ReadWrite.AzureADGroup' }
            Write-RunLog -Level Warn -Message ('HTTP 403 patching {0} on "{1}": the managed identity needs {2}.' -f $row.RuleId, $row.Target, $permission)
            if (-not $forbidden.Contains($permission)) { [void]$forbidden.Add($permission) }
        }
    }
    foreach ($permission in $forbidden) {
        [void]$notes.Add(('Rule updates were refused with HTTP 403. The managed identity needs the Microsoft Graph application permission {0}.' -f $permission))
    }

    # Report, before the digest, so a file that cannot be written is a
    # failure the digest carries; it never stops the run after the writes.
    $reportWritten = $false
    if ($reportFile) { $reportWritten = Save-PimDriftReport -Summary $summary -Rows $allRows -Path $reportFile }

    # Digest, only when there is something to act on.
    $digestRows = @($allRows | Where-Object { $_.Status -eq 'Drift' -or $_.Status -eq 'Error' })
    $failures = @($summary.Failures.ToArray())
    $digestSent = $false
    if ($digestRows.Count -eq 0 -and $failures.Count -eq 0) {
        Write-RunLog -Level Info -Message 'No drift and no failures; no digest.'
    }
    elseif ($recipientList.Count -eq 0 -or [string]::IsNullOrWhiteSpace($SenderMailbox)) {
        Write-RunLog -Level Warn -Message ('{0} drifted or unreadable rule(s) and {1} failure(s), but no digest was sent: set Recipients and SenderMailbox.' -f $digestRows.Count, $failures.Count)
    }
    else {
        $digestHtml = New-PimDriftDigestHtml -Rows $digestRows -Failures $failures -Notes ([string[]]$notes.ToArray()) -DryRun $DryRun -Mode $baseline.Mode -RunId ([string](Get-RunContext).RunId)
        $digestSubject = 'PIM policy drift: {0} rule(s) differ, {1} failure(s)' -f $updates.Count, $failures.Count
        $mailOutcome = Invoke-RunbookAction -Summary $summary -Action 'SendDigest' -Target ($recipientList -join ';') -Description ('send the drift digest to {0}' -f ($recipientList -join ';')) -PassThru -ScriptBlock {
            Send-RunbookMail -SenderMailbox $SenderMailbox -To $recipientList -Subject $digestSubject -HtmlBody $digestHtml
        }
        $digestSent = ($mailOutcome -eq 'Done')
    }

    $extra = [ordered]@{
        BaselineMode         = $baseline.Mode
        BaselineSource       = $baseline.Source
        MaxRuleUpdatesPerRun = $MaxRuleUpdatesPerRun
        RolePoliciesChecked  = $rolePolicies
        DuplicatesDropped    = $duplicates
        GroupPoliciesChecked = $groupPolicies
        GroupsSkipped        = $groupsSkipped
        RulesChecked         = ($compliantRows.Count + $updates.Count + $errorRows.Count)
        RulesCompliant       = $compliantRows.Count
        RulesDrifted         = $updates.Count
        RulesUnreadable      = $errorRows.Count
        RulesMfaDelegated    = $noticeRows.Count
        PoliciesExcluded     = $excludedRows.Count
        UnmatchedOverrides   = $unmatchedOverrides
        RuleUpdatesDone      = @($updates | Where-Object { $_.Outcome -eq 'Done' }).Count
        RuleUpdatesFailed    = @($updates | Where-Object { $_.Outcome -eq 'Failed' }).Count
        DigestSent           = $digestSent
        ReportPath           = $reportFile
        ReportWritten        = $reportWritten
    }
    return (Complete-RunSummary -Summary $summary -Extra $extra)
}

# ---------------------------------------------------------------------------
# Entry point. Skipped when the file is dot-sourced (the tests load the
# functions that way); Azure Automation and a direct invocation run it.
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-EntraPimPolicyDriftRun -BaselineVariableName $BaselineVariableName -BaselineJson $BaselineJson -IncludeGroupNames $IncludeGroupNames -ApproverGroupName $ApproverGroupName `
        -Recipients $Recipients -SenderMailbox $SenderMailbox -MaxRuleUpdatesPerRun $MaxRuleUpdatesPerRun -ReportPath $ReportPath `
        -DryRun ([bool]$DryRun) -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken -RunId $RunId
}
