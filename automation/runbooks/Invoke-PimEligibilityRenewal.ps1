<#
.SYNOPSIS
    Renews PIM eligibilities that are about to expire, for group principals
    only, across Entra directory roles, PIM for Groups, and Azure resource
    roles, and reports the individual eligibilities that a person has to
    decide about.

.DESCRIPTION
    Runs daily as an Azure Automation runbook on a user-assigned managed
    identity. It reads every eligibility schedule on three planes:

      Directory  roleManagement/directory/roleEligibilitySchedules
      Groups     identityGovernance/privilegedAccess/group/eligibilitySchedules,
                 for every role-assignable group plus the groups named in
                 GroupScopeNames (the API needs a groupId filter, so the
                 runbook has to know which groups to ask about)
      Azure      <scope>/providers/Microsoft.Authorization/roleEligibilitySchedules
                 at every management group or subscription named in
                 AzureScopeNames, including child management groups,
                 subscriptions, resource groups, and resources below them.
                 Opt-in: read only when IncludeAzureResources is $true.

    and decides, for each schedule, one of:

      NotDue    ends more than RenewWithinDays from now          nothing
      Extend    group principal, ends within the window          adminExtend / AdminExtend
      Renew     group principal, ended within the last           adminRenew / AdminRenew
                RenewWithinDays days
      Review    user, service principal, or any non-group        reported, never renewed
                principal that is due
      Excluded  group principal that PrincipalGroupNamePattern   reported, never renewed
                leaves out
      Skip      not provisioned, inherited, permanent, the       nothing; reported when due
                policy cannot be read, the policy maximum
                would not move the end date, the group name
                cannot be read while PrincipalGroupNamePattern
                is narrower than "*", or a directory schedule
                has no scope

    The rule this runbook exists to enforce. It never renews an eligibility
    whose principal is a user or a service principal. Standing eligibility
    for a person is an access decision about that person, and an automated
    renewal would turn "eligible until someone decides" into "eligible
    forever". Group-based eligibility is different: the access decision is
    group membership, which has its own owners and reviews, and the
    eligibility of the group to a role is plumbing that should not lapse
    because a date passed. So groups are renewed, and every individual
    eligibility that is due is listed in the log, the report, the summary,
    and the digest, for a person to extend in the portal or let expire.

    Requested duration. ExtendDays from now, clamped to the maximum of the
    role's admin eligibility expiration rule (Expiration_Admin_Eligibility)
    when that rule requires expiration. The rule is read for every role that
    has a renewal to make: Graph policies/roleManagementPolicyAssignments for
    directory roles (scopeType DirectoryRole) and for PIM for Groups
    (scopeType Group, roleDefinitionId member or owner), and ARM
    roleManagementPolicyAssignments (effectiveRules) at the eligibility's own
    scope for Azure roles. The runbook never requests longer than the policy
    allows. When the rule cannot be read the eligibility is skipped, not
    renewed blind. A schedule with no end date is permanent and is skipped;
    there is nothing to renew. ISO 8601 durations in years and months are
    read as 365 and 28 days, so a clamp is never longer than the policy.

    Safety model.
      - DryRun is $true by default. A dry run reads everything, decides
        everything, logs "Would extend ..." for each renewal, writes the
        report, and sends nothing and changes nothing.
      - Individual eligibility is never written, whatever the pattern says.
      - Circuit breaker. Before the first write, in dry runs too, the number
        of planned renewals is compared with MaxRenewalsPerRun. Above the cap
        the run stops and nothing is written. A renewal extends privileged
        access by up to a year, and a count that large means a cohort was
        created on one day, or the pattern matches more than intended; a
        person looks, then raises the cap for one run.
      - Each renewal is independent. A failure (for example HTTP 400 because
        a request for that eligibility is already pending, or a policy that
        requires a ticket number) is logged at Error, recorded on the
        summary, and the run carries on with the next one.
      - A request is never repeated once PIM may have acted on it. The
        Graph renewal POSTs use the library's rule: a POST is repeated only
        after HTTP 429 (throttled, so not applied), and after a 5xx or a
        lost response it fails at once with a note that it may already
        have been applied. Such a renewal is recorded as Failed with that
        note, counted in UncertainRenewals, and named in FollowUp and the
        digest. An ARM PUT carries a request name the runbook chose, so
        when a PUT still fails after a server error, a lost response, or a
        repeated attempt, the runbook reads the request back by that name
        and uses the status PIM recorded; a request PIM never created is a
        plain failure. The next day's run renews whatever did not happen.
      - A request that PIM accepts but has not applied yet (PendingApproval,
        PendingProvisioning, and similar) is reported as Pending, not as
        renewed: it is left out of Renewed and of the FollowUp line.
      - An Azure eligibility with an ABAC condition is renewed with the same
        condition and conditionVersion, so a renewal never widens access.
      - A directory eligibility is renewed at its own directoryScopeId or
        appScopeId. A schedule with neither is skipped; the scope is never
        guessed.
      - Fail closed on names. A group whose display name cannot be read is
        renewed only when PrincipalGroupNamePattern is "*"; otherwise it is
        skipped and reported, because an exclusion cannot be checked
        against a name nobody knows. A pattern value that holds no usable
        pattern (an empty JSON array, only separators, or a bare "!") stops
        the run before anything is read.
      - A plane, group, or scope that cannot be read is logged at Error,
        recorded on the summary, and listed first in the digest under
        "Could not be read", with the count in the subject, so a run that
        scanned nothing never looks clean.
      - Only Direct schedules are renewed; inherited and group-derived ones
        are renewed where they are assigned.
      - The justification on every request names the runbook and the run id,
        so the PIM audit history and the Entra audit log point back at the
        job and its summary.

    Infrastructure as code. PIM does not edit a schedule in place when it is
    extended or renewed: the request creates a new schedule (and new
    instance and request identifiers) and retires the old one. A Terraform
    estate that manages these eligibilities should, after any live run that
    renewed something:
      1. run terragrunt apply -refresh-only in the affected cells, so state
         catches up with the new identifiers and nothing changes in the
         tenant;
      2. run scripts/Export-PimEligibilityImports.ps1 with -AzureCellPath and
         -EntraCellPath to regenerate import blocks for anything whose
         identifier Terraform can no longer find.
    Where Terraform itself declares an expiration for a principal and role,
    let Terraform own the date: exclude that group here with the pattern
    (for example "*;!PIM TF *"), or the runbook and the next apply will keep
    moving the date in opposite directions. In a pattern only "*" and "?"
    are wildcards; every other character, square brackets included, is
    literal, so "!PIM TF [legacy] *" excludes "PIM TF [legacy] Readers".
    The summary carries a FollowUp line whenever a live renewal succeeded,
    or failed in a way that may still have applied it.

    Graph application permissions (modules/entra/graph-app-role-grant):
      RoleEligibilitySchedule.ReadWrite.Directory      read and renew directory role eligibility
                                                       (RoleEligibilitySchedule.Read.Directory for a dry run)
      RoleManagementPolicy.Read.Directory              directory role policy rules
      PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup
                                                       read and renew PIM for Groups eligibility
                                                       (PrivilegedEligibilitySchedule.Read.AzureADGroup for a dry run)
      RoleManagementPolicy.Read.AzureADGroup           PIM for Groups policy rules
      Group.Read.All                                   find role-assignable groups, resolve GroupScopeNames,
                                                       and read group principal names
      Mail.Send                                        the digest, restricted to SenderMailbox by an
                                                       Exchange application access policy

    Azure RBAC for the identity, only when IncludeAzureResources is $true,
    at each scope in AzureScopeNames:
      Reader                               eligibility schedules, policy assignments,
                                           management group descendants, and reading
                                           a renewal request back; all a dry run needs
      PIM Policy and Eligibility Operator  custom role from tenants/azure/corp/azure-rbac-roles:
                                           roleEligibilityScheduleRequests/write for
                                           AdminExtend and AdminRenew; live runs only
    The corp cell's pim tier holds Reader and the narrower custom role
    PIM Policy Operator at its root management group today, both for
    Invoke-AzurePimPolicyGovernance, and IncludeAzureResources is false
    there. Nothing in that cell holds PIM Policy and Eligibility Operator:
    it is added to the tier's arm_role_assignments only when this runbook's
    Azure plane is turned on, which is the change that makes the tier
    Owner-equivalent over the scopes it names.
    Never User Access Administrator or Owner. The stack and the
    workload-role-assignment module refuse either without a condition, and
    one identity runs every runbook in the account, so an unconditioned
    role that can assign roles would void the delegation condition the
    subscription guard depends on (docs/adr/0014). Role Based Access
    Control Administrator is no substitute: it holds no PIM action.

    These write permissions are tier 0. The permission that extends an
    eligibility is the permission that creates one. Submitting eligibility
    schedule requests at a scope (roleEligibilityScheduleRequests/write)
    lets the identity make any principal eligible for any role at that
    scope, Owner included, and the same custom role can also rewrite the
    PIM policies there. RoleEligibilitySchedule.ReadWrite.Directory does
    the same for every directory role, Global Administrator included, and
    PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup for membership or
    ownership of every PIM group. The rules this runbook keeps (groups
    only, existing eligibilities only, each at its own scope, never longer
    than the policy allows) are code controls in this file, not platform
    controls: anyone who can change the published runbook, create another
    runbook in the account, or otherwise get a token for the identity holds
    those permissions without the rules. Treat as tier 0 the identity,
    write access to the Automation account, the merge path for
    automation/, and the Terraform cells that grant these permissions.
    Grant the ReadWrite permissions and the custom role only where a live
    run is intended; a dry run needs only the Read permissions and Reader.

    Schedule. The corp cell runs this daily at 03:30 UTC (schedule
    daily-0330-utc in tenants/azure/corp/azure-automation), after the
    runbook backup and before the Azure and Entra PIM policy runs, so they
    see the same night's renewals. PIM mails expiry notices 14 days and
    1 day before an assignment ends, and self-service Extend appears in the
    portal inside those same 14 days, so the default window lines up with
    what people see, and a daily run gets fourteen chances at each renewal.
    Renewal of an expired eligibility only works while PIM still lists it
    (expired assignments stay visible for up to 30 days), so keep
    RenewWithinDays well under 30.

    Stack cell entry: the pim-eligibility-renewal entry of the runbooks map
    in tenants/azure/corp/azure-automation/terragrunt.hcl, trimmed. The
    stack adds clientid, environment, sendermailbox, and dryrun. Every list
    is one string in the semicolon form (never jsonencode), and the Azure
    plane is off here, as the shipped cell has it:

      pim-eligibility-renewal = {
        name         = "Invoke-PimEligibilityRenewal"
        file         = "Invoke-PimEligibilityRenewal.ps1"
        library      = "Runbook.Common.ps1"
        schedule_key = "daily-0330-utc"
        identity_key = "pim"
        parameters = {
          renewwithindays           = "14"
          extenddays                = "365"
          includedirectoryroles     = "true"
          includegroups             = "true"
          includeazureresources     = "false"
          azurescopenames           = join(";", ["mg:mg-example-root"])
          principalgroupnamepattern = join(";", ["*", "!Break Glass Owners", "!Platform Operators"])
          maxrenewalsperrun         = "20"
          recipients                = join(";", ["iam@corp.example.com"])
        }
      }

    Setting includeazureresources to "true" is not a one-line change: it
    also means adding Reader and the custom role PIM Policy and Eligibility
    Operator to the pim tier's arm_role_assignments at the scopes in
    azurescopenames, which makes that tier Owner-equivalent over them
    (see the permissions above). It belongs in its own reviewed change,
    with that consequence in the change description.

    Design rules shared by every runbook in this repository are in
    automation/README.md. The logging, identity, transport, lookup, and
    summary helpers come from automation/lib/Runbook.Common.ps1, inlined
    between the INLINE_LIBRARY marker lines at deploy time.

.PARAMETER RenewWithinDays
    Window in days. An eligibility is due when it ends within this many days
    from now, or ended no more than this many days ago (then it is renewed
    rather than extended). Default 14, range 1 to 90.

.PARAMETER ExtendDays
    Requested length of the renewed eligibility, in days from now. Clamped
    to the policy maximum when the policy requires expiration. Default 365.

.PARAMETER PrincipalGroupNamePattern
    Which group principals may be renewed, by display name, as one string
    of patterns separated by semicolons, for example "*;!PIM TF *" (commas
    separate too, so no pattern can contain a semicolon or a comma; write
    "?" in that place). A pattern that starts with "!" excludes. A group is
    renewed when it matches at least one include pattern (or there are
    none) and no exclude pattern. Matching is case-insensitive and covers
    the whole name; "*" matches any run of characters and "?" one
    character, and everything else, square brackets and backticks
    included, is literal. A group whose name cannot be read is renewed only
    when the value is "*". Default "*": any group. An empty or blank value
    also means "*". A value with no usable pattern in it (";", "[]", or a
    bare "!") is refused. Users and service principals are never renewed,
    whatever this says.
    A job schedule must pass the semicolon form: the Automation service may
    parse a JSON-looking value before it binds (ConvertTo-StringList in the
    library). A value whose first character is "[" is read as a JSON array,
    which only a local run can pass unchanged, so from a schedule make sure
    the value does not start with a bracket: list another entry first, or
    write the leading bracket as "?" ("?legacy] *").

.PARAMETER IncludeDirectoryRoles
    Read and renew Entra directory role eligibility. Default $true.

.PARAMETER IncludeGroups
    Read and renew PIM for Groups eligibility (membership and ownership).
    Default $true.

.PARAMETER IncludeAzureResources
    Read and renew Azure resource role eligibility at AzureScopeNames.
    Default $false: the Azure plane is opt-in, because it needs its own
    role assignments at every scope (see the description) and a list of
    scopes. Set it to $true together with AzureScopeNames. With it $true
    and no AzureScopeNames the Azure plane is skipped with a warning; with
    it $false, AzureScopeNames is ignored with a warning.

.PARAMETER AzureScopeNames
    Management groups and subscriptions to scan, as one string separated by
    semicolons, for example "mg:mg-example-root;sub:Identity Production".
    A plain entry is tried as a management group (id, then display name)
    and then as a subscription (display name, or id when it is a GUID).
    Prefix "mg:" or "sub:" to say which. Child management groups and
    subscriptions of a management group are scanned too. Commas separate
    as well, so name a scope whose display name holds a comma or a
    semicolon by its id. Used only when IncludeAzureResources is $true.
    A local run may also pass a JSON array.

.PARAMETER GroupScopeNames
    PIM for Groups groups to scan in addition to every role-assignable group,
    by exact display name, as one string separated by semicolons (commas
    separate too). Needed only for groups onboarded to PIM that are not
    role-assignable. Optional. A local run may also pass a JSON array.

.PARAMETER MaxRenewalsPerRun
    Circuit breaker. More planned renewals than this stops the run before
    anything is written. Default 20.

.PARAMETER Recipients
    Addresses that receive the digest (reads that failed, renewals and
    their outcomes, eligibilities that need a decision, and skipped due
    eligibilities), as one string separated by semicolons, for example
    "iam@corp.example.com;pim-owners@corp.example.com". A run with nothing
    in any of those sends no mail. Empty sends no mail. Requires
    SenderMailbox. A local run may also pass a JSON array.

.PARAMETER SenderMailbox
    Shared mailbox the digest is sent from, as a user principal name.

.PARAMETER ReportPath
    Optional CSV path for every schedule read, with its decision, requested
    end date, and outcome. For local runs; leave empty in Automation.

.PARAMETER DryRun
    Default $true. Everything is read and decided; renewals and the digest
    are logged as "Would ..." and nothing is written or sent. The circuit
    breaker is still evaluated. Pass -DryRun:$false to act.

.PARAMETER Environment
    National cloud: Global (default) or USGov.

.PARAMETER ClientId
    Client id of the user-assigned managed identity. Empty uses the
    account's default identity.

.PARAMETER AccessToken
    Local runs only. One token string for every API, or a JSON object with
    Graph and Arm keys when the Azure plane is included. Never logged.

.PARAMETER RunId
    Correlation id stamped on every log line, on the summary, and in the
    justification of every PIM request. A new GUID by default.

.EXAMPLE
    # Local dry run, directory roles and groups only (the Azure plane is off
    # by default), one Graph token.
    $token = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
    .\Invoke-PimEligibilityRenewal.ps1 -AccessToken $token -ReportPath .\out\pim-renewals.csv

.EXAMPLE
    # Local dry run on all three planes: Graph and ARM tokens in one JSON string.
    $graph = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
    $arm = az account get-access-token --resource-type arm --query accessToken -o tsv
    $tokens = @{ Graph = $graph; Arm = $arm } | ConvertTo-Json -Compress
    .\Invoke-PimEligibilityRenewal.ps1 -IncludeAzureResources $true -AzureScopeNames 'mg:mg-example-root;sub:Identity Production' -PrincipalGroupNamePattern 'PIM *;!PIM TF *' -AccessToken $tokens -ReportPath .\out\pim-renewals.csv

.EXAMPLE
    # What the corp cell's job schedule passes, with dry_run turned off: every
    # value is a string, and lists are semicolon lists.
    .\Invoke-PimEligibilityRenewal.ps1 -IncludeAzureResources $true -AzureScopeNames 'mg:mg-example-root' -PrincipalGroupNamePattern '*;!Break Glass Owners;!Platform Operators' -Recipients 'iam@corp.example.com' -SenderMailbox iam-noreply@corp.example.com -DryRun:$false -ClientId <identity client id>

.NOTES
    Windows PowerShell 5.1 and PowerShell 7 compatible; no modules required.
    Graph v1.0 and ARM api-version 2020-10-01 (Microsoft.Authorization PIM
    endpoints) and 2020-05-01 (management group descendants).
    Do not pass -DryRun:$false from a workstation; the live path is the
    Automation job, on the managed identity, with the cell's parameters.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(1, 90)]
    [int]$RenewWithinDays = 14,

    [ValidateRange(1, 3650)]
    [int]$ExtendDays = 365,

    [string]$PrincipalGroupNamePattern = '*',

    [bool]$IncludeDirectoryRoles = $true,

    [bool]$IncludeGroups = $true,

    [bool]$IncludeAzureResources = $false,

    [string]$AzureScopeNames = '',

    [string]$GroupScopeNames = '',

    [ValidateRange(0, 10000)]
    [int]$MaxRenewalsPerRun = 20,

    [string]$Recipients = '',

    [string]$SenderMailbox = '',

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

# INLINE_LIBRARY_BEGIN
. (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\Runbook.Common.ps1')
# INLINE_LIBRARY_END

# ---------------------------------------------------------------------------
# Settings. API versions verified on learn.microsoft.com: Microsoft.Authorization
# roleEligibilitySchedules, roleEligibilityScheduleRequests, and
# roleManagementPolicyAssignments at 2020-10-01; management group descendants
# at 2020-05-01.
# ---------------------------------------------------------------------------

$script:PimRunbookName = 'Invoke-PimEligibilityRenewal'
$script:PimArmApiVersion = '2020-10-01'
$script:PimDescendantsApiVersion = '2020-05-01'
$script:PimRuleCache = @{}

# ---------------------------------------------------------------------------
# Small pure helpers: values, dates, durations, names. No I/O.
# ---------------------------------------------------------------------------

function Get-PimProperty {
    <#
    .SYNOPSIS
        The value of a property on a parsed JSON object, or $null when the
        object or the property is missing.
    .PARAMETER Object
        A PSCustomObject from ConvertFrom-Json, or $null.
    .PARAMETER Name
        Property name.
    .EXAMPLE
        Get-PimProperty -Object $schedule -Name 'scheduleInfo'
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

function ConvertTo-PimUtcDateTime {
    <#
    .SYNOPSIS
        A UTC DateTime from a Graph or ARM timestamp, or $null.
    .DESCRIPTION
        Accepts a string (Windows PowerShell 5.1 leaves JSON dates as text),
        a DateTime (PowerShell 7 ConvertFrom-Json converts ISO 8601 text), or
        a DateTimeOffset. An unspecified kind is taken as UTC.
    .PARAMETER Value
        The raw value.
    .EXAMPLE
        ConvertTo-PimUtcDateTime -Value '2026-09-30T00:00:00Z'
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        return $Value.ToUniversalTime()
    }
    $text = ([string]$Value).Trim()
    if ($text.Length -eq 0) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $parsed.UtcDateTime }
    return $null
}

function Format-PimUtc {
    <#
    .SYNOPSIS
        A UTC timestamp in the form Graph and ARM accept: 2026-09-16T06:00:00Z.
    .PARAMETER Value
        The time. An unspecified kind is taken as UTC.
    .EXAMPLE
        Format-PimUtc -Value ([DateTime]::UtcNow)
    #>
    param([Parameter(Mandatory = $true)][DateTime]$Value)

    $utc = $Value
    if ($utc.Kind -eq [DateTimeKind]::Unspecified) { $utc = [DateTime]::SpecifyKind($utc, [DateTimeKind]::Utc) }
    return $utc.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-IsoDuration {
    <#
    .SYNOPSIS
        A TimeSpan from an ISO 8601 duration such as P365D or PT8H, or $null.
    .DESCRIPTION
        PIM policies express maximumDuration this way. Years count as 365
        days and months as 28, so a value used as an upper bound is never
        read as longer than it is. Anything that does not parse returns
        $null, and the caller treats that as an unreadable policy.
    .PARAMETER Value
        The duration text.
    .EXAMPLE
        (ConvertFrom-IsoDuration -Value 'P180D').TotalDays
        180
    #>
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $text = $Value.Trim().ToUpperInvariant()
    if ($text -eq 'P' -or $text.EndsWith('T')) { return $null }
    $match = [regex]::Match($text, '^P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$')
    if (-not $match.Success) { return $null }

    $seconds = [double]0
    if ($match.Groups[1].Success) { $seconds += 365 * 86400 * [double]$match.Groups[1].Value }
    if ($match.Groups[2].Success) { $seconds += 28 * 86400 * [double]$match.Groups[2].Value }
    if ($match.Groups[3].Success) { $seconds += 7 * 86400 * [double]$match.Groups[3].Value }
    if ($match.Groups[4].Success) { $seconds += 86400 * [double]$match.Groups[4].Value }
    if ($match.Groups[5].Success) { $seconds += 3600 * [double]$match.Groups[5].Value }
    if ($match.Groups[6].Success) { $seconds += 60 * [double]$match.Groups[6].Value }
    if ($match.Groups[7].Success) { $seconds += [double]$match.Groups[7].Value }
    return [TimeSpan]::FromSeconds($seconds)
}

function Get-PimScheduleWindow {
    <#
    .SYNOPSIS
        Start, end, and expiration type of a Graph requestSchedule.
    .DESCRIPTION
        Returns Start, End, HasEnd, and ExpirationType. noExpiration, or no
        end date and no usable duration, means HasEnd is $false. An
        afterDuration schedule ends at start plus the duration.
    .PARAMETER ScheduleInfo
        The scheduleInfo object of a directory or group schedule.
    .EXAMPLE
        (Get-PimScheduleWindow -ScheduleInfo $schedule.scheduleInfo).End
    #>
    param([AllowNull()][object]$ScheduleInfo)

    $start = ConvertTo-PimUtcDateTime -Value (Get-PimProperty -Object $ScheduleInfo -Name 'startDateTime')
    $expiration = Get-PimProperty -Object $ScheduleInfo -Name 'expiration'
    $type = [string](Get-PimProperty -Object $expiration -Name 'type')
    $end = $null
    if ($type -ne 'noExpiration') {
        $end = ConvertTo-PimUtcDateTime -Value (Get-PimProperty -Object $expiration -Name 'endDateTime')
        if ($null -eq $end -and $null -ne $start) {
            $duration = ConvertFrom-IsoDuration -Value ([string](Get-PimProperty -Object $expiration -Name 'duration'))
            if ($null -ne $duration) { $end = $start.Add($duration) }
        }
    }
    return [PSCustomObject]@{
        Start          = $start
        End            = $end
        HasEnd         = ($null -ne $end)
        ExpirationType = $type
    }
}

function Get-PimPrincipalType {
    <#
    .SYNOPSIS
        Group, User, ServicePrincipal, ForeignGroup, Device, Other, or Unknown.
    .DESCRIPTION
        Reads a declared type (ARM principalType) first, then the @odata.type
        of an expanded Graph principal. Anything that cannot be read is
        Unknown, and only Group is ever renewed.
    .PARAMETER Principal
        An expanded Graph directoryObject, or $null.
    .PARAMETER DeclaredType
        A type string such as the ARM principalType.
    .EXAMPLE
        Get-PimPrincipalType -Principal ([PSCustomObject]@{ '@odata.type' = '#microsoft.graph.group' })
        Group
    #>
    param(
        [AllowNull()][object]$Principal,
        [AllowNull()][AllowEmptyString()][string]$DeclaredType = ''
    )

    $raw = ''
    if (-not [string]::IsNullOrWhiteSpace($DeclaredType)) { $raw = $DeclaredType }
    elseif ($null -ne $Principal) { $raw = [string](Get-PimProperty -Object $Principal -Name '@odata.type') }
    $text = $raw.Trim().TrimStart('#')
    if ($text.StartsWith('microsoft.graph.', [StringComparison]::OrdinalIgnoreCase)) { $text = $text.Substring(16) }

    $result = 'Other'
    switch ($text.ToLowerInvariant()) {
        '' { $result = 'Unknown' }
        'group' { $result = 'Group' }
        'user' { $result = 'User' }
        'serviceprincipal' { $result = 'ServicePrincipal' }
        'foreigngroup' { $result = 'ForeignGroup' }
        'device' { $result = 'Device' }
    }
    return $result
}

function Split-PimGroupNamePattern {
    <#
    .SYNOPSIS
        Splits parsed PrincipalGroupNamePattern entries into includes and
        excludes, and says whether they let every name through.
    .DESCRIPTION
        Returns Includes, Excludes, and MatchesAll. Entries that start with
        "!" are excludes. With no include, "*" is the include. MatchesAll is
        $true only when there is no exclude and an include is made of "*"
        alone, which is the only case where a group with no readable name
        may be renewed. An entry that is "!" with nothing after it throws:
        it was meant to exclude something, and ignoring it would renew what
        it was meant to keep out.
    .PARAMETER Patterns
        The parsed entries.
    .EXAMPLE
        (Split-PimGroupNamePattern -Patterns @('*', '!PIM TF *')).MatchesAll
        False
    #>
    param([AllowNull()][AllowEmptyCollection()][string[]]$Patterns)

    $includes = New-Object System.Collections.ArrayList
    $excludes = New-Object System.Collections.ArrayList
    foreach ($pattern in @($Patterns)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        $trimmed = $pattern.Trim()
        if ($trimmed.StartsWith('!')) {
            $negated = $trimmed.Substring(1).Trim()
            if ($negated.Length -eq 0) { throw ('PrincipalGroupNamePattern entry "{0}" excludes nothing; put a name pattern after the "!".' -f $trimmed) }
            [void]$excludes.Add($negated)
        }
        else { [void]$includes.Add($trimmed) }
    }
    if ($includes.Count -eq 0) { [void]$includes.Add('*') }

    $matchesAll = $false
    if ($excludes.Count -eq 0) {
        foreach ($include in $includes) { if ($include.Trim('*').Length -eq 0) { $matchesAll = $true } }
    }
    return [PSCustomObject]@{
        Includes   = [string[]]$includes.ToArray()
        Excludes   = [string[]]$excludes.ToArray()
        MatchesAll = $matchesAll
    }
}

function Test-PimNamePatternMatch {
    <#
    .SYNOPSIS
        True when a whole name matches one pattern in which only "*" and "?"
        are wildcards.
    .DESCRIPTION
        Case-insensitive and culture-invariant. Every other character is
        literal, so square brackets in a group name need no escaping (the
        -like operator would read them as a character class and never match
        the literal name).
    .PARAMETER Name
        The display name.
    .PARAMETER Pattern
        One pattern, without a leading "!".
    .EXAMPLE
        Test-PimNamePatternMatch -Name 'PIM TF [legacy] Readers' -Pattern 'PIM TF [legacy] *'
        True
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('^')
    foreach ($character in $Pattern.ToCharArray()) {
        if ($character -eq [char]'*') { [void]$builder.Append('.*') }
        elseif ($character -eq [char]'?') { [void]$builder.Append('.') }
        else { [void]$builder.Append([regex]::Escape([string]$character)) }
    }
    [void]$builder.Append('$')
    $text = ''
    if ($null -ne $Name) { $text = $Name }
    $options = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant, Singleline'
    return [regex]::IsMatch($text, $builder.ToString(), $options)
}

function Test-PimPrincipalNameAllowed {
    <#
    .SYNOPSIS
        True when a group display name passes the include and exclude patterns.
    .DESCRIPTION
        Case-insensitive, whole-name patterns in which only "*" and "?" are
        wildcards (Test-PimNamePatternMatch). Entries that start with "!"
        exclude. With no include pattern everything is included. An exclude
        match always wins. A blank name passes only when the patterns let
        every name through (Split-PimGroupNamePattern MatchesAll), because
        no exclusion can be checked against it.
    .PARAMETER Name
        The group display name.
    .PARAMETER Patterns
        The parsed PrincipalGroupNamePattern entries.
    .EXAMPLE
        Test-PimPrincipalNameAllowed -Name 'PIM TF Readers' -Patterns @('PIM *', '!PIM TF *')
        False
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Name,
        [AllowNull()][AllowEmptyCollection()][string[]]$Patterns
    )

    $split = Split-PimGroupNamePattern -Patterns $Patterns
    if ([string]::IsNullOrWhiteSpace($Name)) { return [bool]$split.MatchesAll }
    foreach ($exclude in $split.Excludes) { if (Test-PimNamePatternMatch -Name $Name -Pattern $exclude) { return $false } }
    foreach ($include in $split.Includes) { if (Test-PimNamePatternMatch -Name $Name -Pattern $include) { return $true } }
    return $false
}

function ConvertTo-PimGroupNamePatternList {
    <#
    .SYNOPSIS
        Parses and checks the PrincipalGroupNamePattern parameter.
    .DESCRIPTION
        A blank value means "*". Otherwise the value is read with
        ConvertTo-StringList (JSON array, or a semicolon or comma list) and
        must yield at least one entry, and no entry may be a bare "!". An
        explicit empty JSON array or a value made only of separators throws
        instead of quietly becoming "*", because the operator wrote
        something and it was not "every group". Writes the entries to the
        pipeline; wrap in @().
    .PARAMETER Value
        The raw parameter value.
    .EXAMPLE
        $patterns = @(ConvertTo-PimGroupNamePatternList -Value 'PIM *;!PIM TF *')
    #>
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '*' }
    $entries = @(ConvertTo-StringList -Value $Value -Label 'PrincipalGroupNamePattern')
    if ($entries.Count -eq 0) {
        throw ('PrincipalGroupNamePattern "{0}" holds no pattern. Use "*" for every group, or name the groups to include and exclude.' -f $Value.Trim())
    }
    Split-PimGroupNamePattern -Patterns $entries | Out-Null
    foreach ($entry in $entries) { $entry }
}

function Split-PimAzureScopeName {
    <#
    .SYNOPSIS
        Splits an AzureScopeNames entry into its kind and value.
    .DESCRIPTION
        "mg:<name>" is a management group, "sub:<name>" a subscription, and
        anything else is Auto (management group first, then subscription).
        IsGuid tells whether the value can be a subscription id.
    .PARAMETER Name
        One entry.
    .EXAMPLE
        Split-PimAzureScopeName -Name 'sub:Identity Production'
    #>
    param([Parameter(Mandatory = $true)][string]$Name)

    $text = $Name.Trim()
    $kind = 'Auto'
    if ($text -match '^(mg|managementgroup):(.*)$') { $kind = 'ManagementGroup'; $text = $Matches[2].Trim() }
    elseif ($text -match '^(sub|subscription):(.*)$') { $kind = 'Subscription'; $text = $Matches[2].Trim() }
    if ($text.Length -eq 0) { throw ('AzureScopeNames entry "{0}" has no name after the prefix.' -f $Name) }
    return [PSCustomObject]@{
        Kind   = $kind
        Value  = $text
        IsGuid = ($text -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
    }
}

function Test-PimScopeWithin {
    <#
    .SYNOPSIS
        True when an eligibility scope belongs to a scan target.
    .DESCRIPTION
        A management group target owns only its own scope; its children are
        separate targets. A subscription target owns itself and everything
        below it (resource groups and resources). Listing at a scope also
        returns schedules above it, which this filter drops.
    .PARAMETER Scope
        The schedule's properties.scope.
    .PARAMETER TargetScope
        The scan target scope.
    .PARAMETER TargetKind
        ManagementGroup or Subscription.
    .EXAMPLE
        Test-PimScopeWithin -Scope '/subscriptions/1/resourceGroups/rg' -TargetScope '/subscriptions/1' -TargetKind Subscription
        True
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Scope,
        [Parameter(Mandatory = $true)][string]$TargetScope,
        [Parameter(Mandatory = $true)][ValidateSet('ManagementGroup', 'Subscription')][string]$TargetKind
    )

    if ([string]::IsNullOrWhiteSpace($Scope)) { return $false }
    $s = $Scope.Trim().TrimEnd('/')
    $t = $TargetScope.Trim().TrimEnd('/')
    if ($s.Equals($t, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($TargetKind -eq 'Subscription') { return $s.StartsWith($t + '/', [StringComparison]::OrdinalIgnoreCase) }
    return $false
}

function Get-PimArmRoleGuid {
    <#
    .SYNOPSIS
        The role definition GUID at the end of an ARM roleDefinitionId, lower case.
    .PARAMETER RoleDefinitionId
        For example /subscriptions/<id>/providers/Microsoft.Authorization/roleDefinitions/<guid>.
    .EXAMPLE
        Get-PimArmRoleGuid -RoleDefinitionId '/providers/Microsoft.Authorization/roleDefinitions/ABC'
        abc
    #>
    param([AllowNull()][AllowEmptyString()][string]$RoleDefinitionId)

    if ([string]::IsNullOrWhiteSpace($RoleDefinitionId)) { return '' }
    $parts = $RoleDefinitionId.Trim().TrimEnd('/').Split('/')
    return $parts[$parts.Length - 1].ToLowerInvariant()
}

function Get-PimEligibilityExpirationRule {
    <#
    .SYNOPSIS
        The admin eligibility expiration rule from a list of PIM policy rules.
    .DESCRIPTION
        Finds the rule with id Expiration_Admin_Eligibility in Graph
        policy.rules or ARM effectiveRules and returns IsExpirationRequired,
        MaximumDuration (TimeSpan, or $null when unreadable), and
        MaximumDurationText. Returns $null when the rule is not there.
    .PARAMETER Rules
        The rules array.
    .EXAMPLE
        Get-PimEligibilityExpirationRule -Rules $assignment.policy.rules
    #>
    param([AllowNull()][AllowEmptyCollection()][object[]]$Rules)

    foreach ($rule in @($Rules)) {
        if ($null -eq $rule) { continue }
        if ([string](Get-PimProperty -Object $rule -Name 'id') -ne 'Expiration_Admin_Eligibility') { continue }
        $requiredValue = Get-PimProperty -Object $rule -Name 'isExpirationRequired'
        $required = $false
        if ($requiredValue -is [bool]) { $required = $requiredValue }
        elseif ($null -ne $requiredValue) { $required = ([string]$requiredValue -eq 'true') }
        $maximumText = [string](Get-PimProperty -Object $rule -Name 'maximumDuration')
        return [PSCustomObject]@{
            IsExpirationRequired = $required
            MaximumDuration      = (ConvertFrom-IsoDuration -Value $maximumText)
            MaximumDurationText  = $maximumText
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Schedules to candidates. One shape for all three planes.
# ---------------------------------------------------------------------------

function New-PimCandidate {
    <#
    .SYNOPSIS
        The common shape every plane's schedule is converted to.
    .DESCRIPTION
        Internal constructor, so the three converters cannot drift apart.
    .PARAMETER Values
        Hashtable of the fields to set; missing ones default to empty.
    .EXAMPLE
        New-PimCandidate -Values @{ Plane = 'Directory'; ScheduleId = 'x' }
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Values)

    $fields = [ordered]@{
        Plane            = ''
        ScheduleId       = ''
        PrincipalId      = ''
        PrincipalType    = 'Unknown'
        PrincipalName    = ''
        RoleId           = ''
        RoleName         = ''
        Scope            = ''
        ScopeName        = ''
        DirectoryScopeId = ''
        AppScopeId       = ''
        GroupId          = ''
        AccessId         = ''
        Condition        = ''
        ConditionVersion = ''
        MemberType       = ''
        Status           = ''
        Start            = $null
        End              = $null
        HasEnd           = $false
        ExpirationType   = ''
    }
    foreach ($key in @($Values.Keys)) { $fields[[string]$key] = $Values[$key] }
    return (New-Object -TypeName PSObject -Property $fields)
}

function ConvertFrom-PimDirectorySchedule {
    <#
    .SYNOPSIS
        A candidate from a Graph unifiedRoleEligibilitySchedule read with
        $expand=principal,roleDefinition.
    .PARAMETER Schedule
        The schedule object.
    .EXAMPLE
        ConvertFrom-PimDirectorySchedule -Schedule $schedule
    #>
    param([Parameter(Mandatory = $true)][object]$Schedule)

    $principal = Get-PimProperty -Object $Schedule -Name 'principal'
    $roleDefinition = Get-PimProperty -Object $Schedule -Name 'roleDefinition'
    $window = Get-PimScheduleWindow -ScheduleInfo (Get-PimProperty -Object $Schedule -Name 'scheduleInfo')
    $directoryScopeId = [string](Get-PimProperty -Object $Schedule -Name 'directoryScopeId')
    $appScopeId = [string](Get-PimProperty -Object $Schedule -Name 'appScopeId')
    $scope = $directoryScopeId
    if ([string]::IsNullOrEmpty($scope) -and -not [string]::IsNullOrEmpty($appScopeId)) { $scope = 'app:' + $appScopeId }
    $roleId = [string](Get-PimProperty -Object $Schedule -Name 'roleDefinitionId')
    $roleName = [string](Get-PimProperty -Object $roleDefinition -Name 'displayName')
    if ([string]::IsNullOrEmpty($roleName)) { $roleName = $roleId }

    return (New-PimCandidate -Values @{
            Plane            = 'Directory'
            ScheduleId       = [string](Get-PimProperty -Object $Schedule -Name 'id')
            PrincipalId      = [string](Get-PimProperty -Object $Schedule -Name 'principalId')
            PrincipalType    = (Get-PimPrincipalType -Principal $principal)
            PrincipalName    = [string](Get-PimProperty -Object $principal -Name 'displayName')
            RoleId           = $roleId
            RoleName         = $roleName
            Scope            = $scope
            ScopeName        = $scope
            DirectoryScopeId = $directoryScopeId
            AppScopeId       = $appScopeId
            MemberType       = [string](Get-PimProperty -Object $Schedule -Name 'memberType')
            Status           = [string](Get-PimProperty -Object $Schedule -Name 'status')
            Start            = $window.Start
            End              = $window.End
            HasEnd           = $window.HasEnd
            ExpirationType   = $window.ExpirationType
        })
}

function ConvertFrom-PimGroupSchedule {
    <#
    .SYNOPSIS
        A candidate from a Graph privilegedAccessGroupEligibilitySchedule read
        with $expand=principal.
    .PARAMETER Schedule
        The schedule object.
    .PARAMETER GroupName
        Display name of the PIM group (the scope), for messages.
    .EXAMPLE
        ConvertFrom-PimGroupSchedule -Schedule $schedule -GroupName 'PIM Tier0 Admins'
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Schedule,
        [AllowEmptyString()][string]$GroupName = ''
    )

    $principal = Get-PimProperty -Object $Schedule -Name 'principal'
    $window = Get-PimScheduleWindow -ScheduleInfo (Get-PimProperty -Object $Schedule -Name 'scheduleInfo')
    $groupId = [string](Get-PimProperty -Object $Schedule -Name 'groupId')
    $accessId = ([string](Get-PimProperty -Object $Schedule -Name 'accessId')).ToLowerInvariant()
    $scopeName = $GroupName
    if ([string]::IsNullOrEmpty($scopeName)) { $scopeName = $groupId }

    return (New-PimCandidate -Values @{
            Plane          = 'Group'
            ScheduleId     = [string](Get-PimProperty -Object $Schedule -Name 'id')
            PrincipalId    = [string](Get-PimProperty -Object $Schedule -Name 'principalId')
            PrincipalType  = (Get-PimPrincipalType -Principal $principal)
            PrincipalName  = [string](Get-PimProperty -Object $principal -Name 'displayName')
            RoleId         = $accessId
            RoleName       = $accessId
            Scope          = $groupId
            ScopeName      = $scopeName
            GroupId        = $groupId
            AccessId       = $accessId
            MemberType     = [string](Get-PimProperty -Object $Schedule -Name 'memberType')
            Status         = [string](Get-PimProperty -Object $Schedule -Name 'status')
            Start          = $window.Start
            End            = $window.End
            HasEnd         = $window.HasEnd
            ExpirationType = $window.ExpirationType
        })
}

function ConvertFrom-PimAzureSchedule {
    <#
    .SYNOPSIS
        A candidate from an ARM Microsoft.Authorization roleEligibilitySchedule.
    .DESCRIPTION
        Names come from properties.expandedProperties. The ABAC condition is
        kept so a renewal carries it forward unchanged.
    .PARAMETER Schedule
        The schedule object.
    .EXAMPLE
        ConvertFrom-PimAzureSchedule -Schedule $schedule
    #>
    param([Parameter(Mandatory = $true)][object]$Schedule)

    $p = Get-PimProperty -Object $Schedule -Name 'properties'
    $expanded = Get-PimProperty -Object $p -Name 'expandedProperties'
    $principal = Get-PimProperty -Object $expanded -Name 'principal'
    $roleDefinition = Get-PimProperty -Object $expanded -Name 'roleDefinition'
    $scopeInfo = Get-PimProperty -Object $expanded -Name 'scope'

    $declaredType = [string](Get-PimProperty -Object $p -Name 'principalType')
    if ([string]::IsNullOrWhiteSpace($declaredType)) { $declaredType = [string](Get-PimProperty -Object $principal -Name 'type') }
    $roleId = [string](Get-PimProperty -Object $p -Name 'roleDefinitionId')
    $roleName = [string](Get-PimProperty -Object $roleDefinition -Name 'displayName')
    if ([string]::IsNullOrEmpty($roleName)) { $roleName = Get-PimArmRoleGuid -RoleDefinitionId $roleId }
    $scope = [string](Get-PimProperty -Object $p -Name 'scope')
    $scopeName = [string](Get-PimProperty -Object $scopeInfo -Name 'displayName')
    if ([string]::IsNullOrEmpty($scopeName)) { $scopeName = $scope }
    $start = ConvertTo-PimUtcDateTime -Value (Get-PimProperty -Object $p -Name 'startDateTime')
    $end = ConvertTo-PimUtcDateTime -Value (Get-PimProperty -Object $p -Name 'endDateTime')
    $expirationType = 'AfterDateTime'
    if ($null -eq $end) { $expirationType = 'NoExpiration' }

    return (New-PimCandidate -Values @{
            Plane            = 'Azure'
            ScheduleId       = [string](Get-PimProperty -Object $Schedule -Name 'id')
            PrincipalId      = [string](Get-PimProperty -Object $p -Name 'principalId')
            PrincipalType    = (Get-PimPrincipalType -DeclaredType $declaredType)
            PrincipalName    = [string](Get-PimProperty -Object $principal -Name 'displayName')
            RoleId           = $roleId
            RoleName         = $roleName
            Scope            = $scope
            ScopeName        = $scopeName
            Condition        = [string](Get-PimProperty -Object $p -Name 'condition')
            ConditionVersion = [string](Get-PimProperty -Object $p -Name 'conditionVersion')
            MemberType       = [string](Get-PimProperty -Object $p -Name 'memberType')
            Status           = [string](Get-PimProperty -Object $p -Name 'status')
            Start            = $start
            End              = $end
            HasEnd           = ($null -ne $end)
            ExpirationType   = $expirationType
        })
}

function Format-PimCandidateLabel {
    <#
    .SYNOPSIS
        One line naming a candidate's principal, role, and scope, for logs.
    .PARAMETER Candidate
        A candidate object.
    .EXAMPLE
        Format-PimCandidateLabel -Candidate $candidate
    #>
    param([Parameter(Mandatory = $true)][object]$Candidate)

    $name = [string]$Candidate.PrincipalName
    if ([string]::IsNullOrEmpty($name)) { $name = [string]$Candidate.PrincipalId }
    $what = ''
    switch ($Candidate.Plane) {
        'Directory' { $what = 'directory role "{0}" at "{1}"' -f $Candidate.RoleName, $Candidate.Scope }
        'Group' { $what = '{0} of group "{1}"' -f $Candidate.AccessId, $Candidate.ScopeName }
        default { $what = 'Azure role "{0}" at {1}' -f $Candidate.RoleName, $Candidate.Scope }
    }
    return ('{0} "{1}" ({2}), {3}' -f ([string]$Candidate.PrincipalType).ToLowerInvariant(), $name, $Candidate.PrincipalId, $what)
}

# ---------------------------------------------------------------------------
# The decision. Pure: the clock, the window, the patterns, and the policy
# rule are all parameters.
# ---------------------------------------------------------------------------

function Get-PimRenewalDecision {
    <#
    .SYNOPSIS
        Decides what to do with one eligibility schedule.
    .DESCRIPTION
        Decision is one of NotDue, Skip, Review, Excluded, Extend, Renew.
        Due is $true when the end date is inside the window. Call once with
        RuleKnown $false; when NeedsPolicy comes back $true, read the policy
        rule and call again with Rule and RuleKnown $true. A $null Rule with
        RuleKnown $true means the policy could not be read, and the schedule
        is skipped rather than renewed blind.

        RequestedStart is Now truncated to the second, RequestedEnd is
        RequestedStart plus ExtendDays, clamped to the rule's maximum when the
        rule requires expiration. Outcome, RequestStatus, and Error start
        empty, and MayHaveBeenApplied $false; the run fills them in.

        A group with a blank display name is skipped (Due, reported) unless
        GroupPatterns lets every name through, and a directory schedule with
        neither directoryScopeId nor appScopeId is skipped, so no request is
        ever made at a scope other than the schedule's own.
    .PARAMETER Candidate
        A candidate from one of the ConvertFrom-Pim*Schedule functions.
    .PARAMETER Now
        The clock, UTC.
    .PARAMETER RenewWithinDays
        The window in days.
    .PARAMETER ExtendDays
        The requested length in days.
    .PARAMETER GroupPatterns
        Parsed PrincipalGroupNamePattern entries.
    .PARAMETER Rule
        The admin eligibility expiration rule, or $null.
    .PARAMETER RuleKnown
        $true once the rule lookup has been attempted.
    .EXAMPLE
        Get-PimRenewalDecision -Candidate $c -Now $now -RenewWithinDays 14 -ExtendDays 365 -GroupPatterns @('*')
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Candidate,
        [Parameter(Mandatory = $true)][DateTime]$Now,
        [Parameter(Mandatory = $true)][int]$RenewWithinDays,
        [Parameter(Mandatory = $true)][int]$ExtendDays,
        [AllowNull()][AllowEmptyCollection()][string[]]$GroupPatterns = @('*'),
        [AllowNull()][object]$Rule = $null,
        [bool]$RuleKnown = $false
    )

    $nowUtc = ConvertTo-PimUtcDateTime -Value $Now
    $subSecondTicks = $nowUtc.Ticks % [TimeSpan]::TicksPerSecond
    $start = $nowUtc.AddTicks(-1 * $subSecondTicks)
    $result = [ordered]@{
        Candidate       = $Candidate
        Decision        = 'Skip'
        Due             = $false
        NeedsPolicy     = $false
        Reason          = ''
        DaysLeft        = $null
        RequestedStart  = $null
        RequestedEnd    = $null
        MaximumDuration = ''
        Outcome            = ''
        RequestStatus      = ''
        Error              = ''
        MayHaveBeenApplied = $false
    }

    $renewableStatuses = @('Provisioned', 'Granted', 'ScheduleCreated')
    $status = [string]$Candidate.Status
    if ($renewableStatuses -notcontains $status) {
        $result.Reason = 'status is "{0}", not a provisioned eligibility' -f $status
        return (New-Object -TypeName PSObject -Property $result)
    }
    $memberType = [string]$Candidate.MemberType
    if (-not [string]::IsNullOrEmpty($memberType) -and $memberType -ne 'Direct') {
        $result.Reason = 'memberType is {0}; it is renewed where it is assigned' -f $memberType
        return (New-Object -TypeName PSObject -Property $result)
    }
    if (-not [bool]$Candidate.HasEnd) {
        $result.Reason = 'no end date (permanent eligibility); nothing to renew'
        return (New-Object -TypeName PSObject -Property $result)
    }

    $end = ConvertTo-PimUtcDateTime -Value $Candidate.End
    $endText = Format-PimUtc -Value $end
    $result.DaysLeft = [Math]::Round(($end - $nowUtc).TotalDays, 1)
    if ($end -gt $nowUtc.AddDays($RenewWithinDays)) {
        $result.Decision = 'NotDue'
        $result.Reason = 'ends {0}, outside the {1}-day window' -f $endText, $RenewWithinDays
        return (New-Object -TypeName PSObject -Property $result)
    }
    $expired = ($end -le $nowUtc)
    if ($expired -and $end -lt $nowUtc.AddDays(-$RenewWithinDays)) {
        $result.Reason = 'ended {0}, more than {1} day(s) ago; restoring it is a decision for a person' -f $endText, $RenewWithinDays
        return (New-Object -TypeName PSObject -Property $result)
    }
    $result.Due = $true
    $whenText = 'ends {0}' -f $endText
    if ($expired) { $whenText = 'ended {0}' -f $endText }

    if ([string]$Candidate.PrincipalType -ne 'Group') {
        $result.Decision = 'Review'
        $result.Reason = '{0} eligibility {1}; renewing access for an individual principal is a decision for a person' -f ([string]$Candidate.PrincipalType).ToLowerInvariant(), $whenText
        return (New-Object -TypeName PSObject -Property $result)
    }
    $groupName = [string]$Candidate.PrincipalName
    if ([string]::IsNullOrWhiteSpace($groupName) -and -not (Split-PimGroupNamePattern -Patterns $GroupPatterns).MatchesAll) {
        $result.Reason = 'group eligibility {0}, but the group display name could not be read, so PrincipalGroupNamePattern cannot be checked; renewing an unnamed group needs the pattern "*"' -f $whenText
        return (New-Object -TypeName PSObject -Property $result)
    }
    if (-not (Test-PimPrincipalNameAllowed -Name $groupName -Patterns $GroupPatterns)) {
        $result.Decision = 'Excluded'
        $result.Reason = 'group eligibility {0}; the group name is excluded by PrincipalGroupNamePattern' -f $whenText
        return (New-Object -TypeName PSObject -Property $result)
    }
    if ([string]$Candidate.Plane -eq 'Directory' -and [string]::IsNullOrEmpty([string]$Candidate.DirectoryScopeId) -and [string]::IsNullOrEmpty([string]$Candidate.AppScopeId)) {
        $result.Reason = 'group eligibility {0}, but the schedule has no directoryScopeId or appScopeId; not renewing at a guessed scope' -f $whenText
        return (New-Object -TypeName PSObject -Property $result)
    }
    if (-not $RuleKnown) {
        $result.NeedsPolicy = $true
        $result.Reason = 'policy rule not read yet'
        return (New-Object -TypeName PSObject -Property $result)
    }
    if ($null -eq $Rule) {
        $result.Reason = 'group eligibility {0}, but the admin eligibility expiration rule of its policy could not be read; not renewing without knowing the maximum' -f $whenText
        return (New-Object -TypeName PSObject -Property $result)
    }

    $requested = [TimeSpan]::FromDays($ExtendDays)
    $clampText = ''
    $result.MaximumDuration = [string]$Rule.MaximumDurationText
    if ([bool]$Rule.IsExpirationRequired) {
        $maximum = $Rule.MaximumDuration
        if ($null -eq $maximum -or $maximum -le [TimeSpan]::Zero) {
            $result.Reason = 'group eligibility {0}, but the policy requires expiration and its maximum duration "{1}" is not readable' -f $whenText, $Rule.MaximumDurationText
            return (New-Object -TypeName PSObject -Property $result)
        }
        if ($maximum -lt $requested) {
            $requested = $maximum
            $clampText = ', clamped to the policy maximum {0}' -f $Rule.MaximumDurationText
        }
    }
    $newEnd = $start.Add($requested)
    if ($newEnd -le $end) {
        $result.Reason = 'group eligibility {0}; the policy maximum {1} would not move the end date' -f $whenText, $Rule.MaximumDurationText
        return (New-Object -TypeName PSObject -Property $result)
    }

    $result.RequestedStart = $start
    $result.RequestedEnd = $newEnd
    if ($expired) { $result.Decision = 'Renew' } else { $result.Decision = 'Extend' }
    $result.Reason = 'group eligibility {0}; requesting until {1}{2}' -f $whenText, (Format-PimUtc -Value $newEnd), $clampText
    return (New-Object -TypeName PSObject -Property $result)
}

# ---------------------------------------------------------------------------
# Request bodies. Pure. Shapes from learn.microsoft.com:
#   Graph  POST roleManagement/directory/roleEligibilityScheduleRequests
#   Graph  POST identityGovernance/privilegedAccess/group/eligibilityScheduleRequests
#   ARM    PUT  {scope}/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/{guid}
# ---------------------------------------------------------------------------

function New-PimRenewalJustification {
    <#
    .SYNOPSIS
        The justification text sent with every renewal request.
    .PARAMETER Decision
        Extend or Renew.
    .PARAMETER RunId
        The run's correlation id.
    .PARAMETER RenewWithinDays
        The window, for the text.
    .EXAMPLE
        New-PimRenewalJustification -Decision Extend -RunId $runId -RenewWithinDays 14
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Extend', 'Renew')][string]$Decision,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][int]$RenewWithinDays
    )

    $noun = 'extension'
    if ($Decision -eq 'Renew') { $noun = 'renewal' }
    return ('Automated {0} by runbook {1}, run {2}: group-based eligibility within {3} day(s) of its end date. Individual eligibility is never renewed by this runbook.' -f $noun, $script:PimRunbookName, $RunId, $RenewWithinDays)
}

function New-PimScheduleInfo {
    <#
    .SYNOPSIS
        The scheduleInfo object for a renewal request.
    .PARAMETER Start
        Requested start.
    .PARAMETER End
        Requested end.
    .PARAMETER ExpirationType
        afterDateTime for Graph, AfterDateTime for ARM.
    .EXAMPLE
        New-PimScheduleInfo -Start $d.RequestedStart -End $d.RequestedEnd -ExpirationType afterDateTime
    #>
    param(
        [Parameter(Mandatory = $true)][DateTime]$Start,
        [Parameter(Mandatory = $true)][DateTime]$End,
        [Parameter(Mandatory = $true)][string]$ExpirationType
    )

    return [ordered]@{
        startDateTime = (Format-PimUtc -Value $Start)
        expiration    = [ordered]@{
            type        = $ExpirationType
            endDateTime = (Format-PimUtc -Value $End)
        }
    }
}

function New-PimDirectoryRequestBody {
    <#
    .SYNOPSIS
        Body of a Graph unifiedRoleEligibilityScheduleRequest for an extension
        (adminExtend) or renewal (adminRenew).
    .DESCRIPTION
        The request carries the schedule's own directoryScopeId, or its
        appScopeId when there is no directory scope. A schedule with neither
        throws; a default of "/" would extend the tenant-wide eligibility
        on the strength of a scoped one's end date.
    .PARAMETER Decision
        An Extend or Renew decision on a Directory candidate.
    .PARAMETER Justification
        The justification text.
    .EXAMPLE
        New-PimDirectoryRequestBody -Decision $d -Justification $text | ConvertTo-Json -Depth 5
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Decision,
        [Parameter(Mandatory = $true)][string]$Justification
    )

    $c = $Decision.Candidate
    $verb = 'adminExtend'
    if ($Decision.Decision -eq 'Renew') { $verb = 'adminRenew' }
    $body = [ordered]@{
        action           = $verb
        principalId      = [string]$c.PrincipalId
        roleDefinitionId = [string]$c.RoleId
    }
    if (-not [string]::IsNullOrEmpty([string]$c.DirectoryScopeId)) { $body['directoryScopeId'] = [string]$c.DirectoryScopeId }
    elseif (-not [string]::IsNullOrEmpty([string]$c.AppScopeId)) { $body['appScopeId'] = [string]$c.AppScopeId }
    else { throw 'The directory schedule has no directoryScopeId or appScopeId; not renewing, because any scope sent would be a guess.' }
    $body['justification'] = $Justification
    $body['scheduleInfo'] = New-PimScheduleInfo -Start $Decision.RequestedStart -End $Decision.RequestedEnd -ExpirationType 'afterDateTime'
    return $body
}

function New-PimGroupRequestBody {
    <#
    .SYNOPSIS
        Body of a Graph privilegedAccessGroupEligibilityScheduleRequest for an
        extension (adminExtend) or renewal (adminRenew).
    .PARAMETER Decision
        An Extend or Renew decision on a Group candidate.
    .PARAMETER Justification
        The justification text.
    .EXAMPLE
        New-PimGroupRequestBody -Decision $d -Justification $text
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Decision,
        [Parameter(Mandatory = $true)][string]$Justification
    )

    $c = $Decision.Candidate
    $verb = 'adminExtend'
    if ($Decision.Decision -eq 'Renew') { $verb = 'adminRenew' }
    return [ordered]@{
        accessId      = [string]$c.AccessId
        principalId   = [string]$c.PrincipalId
        groupId       = [string]$c.GroupId
        action        = $verb
        justification = $Justification
        scheduleInfo  = (New-PimScheduleInfo -Start $Decision.RequestedStart -End $Decision.RequestedEnd -ExpirationType 'afterDateTime')
    }
}

function New-PimAzureRequestBody {
    <#
    .SYNOPSIS
        Body of an ARM roleEligibilityScheduleRequest for an extension
        (AdminExtend) or renewal (AdminRenew).
    .DESCRIPTION
        The schedule's condition and conditionVersion are sent unchanged when
        present, so the renewed eligibility is never broader than the old one.
    .PARAMETER Decision
        An Extend or Renew decision on an Azure candidate.
    .PARAMETER Justification
        The justification text.
    .EXAMPLE
        New-PimAzureRequestBody -Decision $d -Justification $text
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Decision,
        [Parameter(Mandatory = $true)][string]$Justification
    )

    $c = $Decision.Candidate
    $requestType = 'AdminExtend'
    if ($Decision.Decision -eq 'Renew') { $requestType = 'AdminRenew' }
    $properties = [ordered]@{
        principalId      = [string]$c.PrincipalId
        roleDefinitionId = [string]$c.RoleId
        requestType      = $requestType
        justification    = $Justification
        scheduleInfo     = (New-PimScheduleInfo -Start $Decision.RequestedStart -End $Decision.RequestedEnd -ExpirationType 'AfterDateTime')
    }
    if (-not [string]::IsNullOrEmpty([string]$c.Condition)) {
        $properties['condition'] = [string]$c.Condition
        if (-not [string]::IsNullOrEmpty([string]$c.ConditionVersion)) { $properties['conditionVersion'] = [string]$c.ConditionVersion }
    }
    return [ordered]@{ properties = $properties }
}

function New-PimAzureRequestUri {
    <#
    .SYNOPSIS
        Relative ARM path of a new roleEligibilityScheduleRequest at a scope.
    .PARAMETER Scope
        The eligibility's scope.
    .PARAMETER RequestName
        A new GUID; the request name.
    .EXAMPLE
        New-PimAzureRequestUri -Scope '/subscriptions/<id>' -RequestName ([Guid]::NewGuid().ToString())
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string]$RequestName
    )

    return ('{0}/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/{1}' -f $Scope.Trim().Trim('/'), $RequestName)
}

function New-PimReportRow {
    <#
    .SYNOPSIS
        One flat row for the CSV report and the summary lists.
    .PARAMETER Decision
        A decision object.
    .EXAMPLE
        New-PimReportRow -Decision $d
    #>
    param([Parameter(Mandatory = $true)][object]$Decision)

    $c = $Decision.Candidate
    $endText = ''
    if ($null -ne $c.End) { $endText = Format-PimUtc -Value $c.End }
    $requestedText = ''
    if ($null -ne $Decision.RequestedEnd) { $requestedText = Format-PimUtc -Value $Decision.RequestedEnd }
    return [PSCustomObject][ordered]@{
        Plane              = $c.Plane
        PrincipalType      = $c.PrincipalType
        PrincipalName      = $c.PrincipalName
        PrincipalId        = $c.PrincipalId
        Role               = $c.RoleName
        Scope              = $c.Scope
        ScopeName          = $c.ScopeName
        EndDateTime        = $endText
        DaysLeft           = $Decision.DaysLeft
        Decision           = $Decision.Decision
        RequestedEnd       = $requestedText
        PolicyMaximum      = $Decision.MaximumDuration
        Reason             = $Decision.Reason
        Outcome            = $Decision.Outcome
        RequestStatus      = $Decision.RequestStatus
        Error              = $Decision.Error
        MayHaveBeenApplied = [bool]$Decision.MayHaveBeenApplied
        ScheduleId         = $c.ScheduleId
    }
}

function New-PimRenewalDigestSubject {
    <#
    .SYNOPSIS
        The digest subject line, with every count a reader has to act on.
    .DESCRIPTION
        Always names renewed, failed, and need-a-decision counts. Pending
        requests and reads that failed are added when there are any, so a
        run that could not scan a plane never has a clean-looking subject.
    .PARAMETER Renewed
        Renewals in effect.
    .PARAMETER Pending
        Renewals PIM accepted but has not applied yet.
    .PARAMETER Failed
        Renewal requests that failed.
    .PARAMETER NeedDecision
        Individual eligibilities that need a decision.
    .PARAMETER ReadFailures
        Planes, groups, or scopes that could not be read.
    .EXAMPLE
        New-PimRenewalDigestSubject -Renewed 3 -Pending 0 -Failed 0 -NeedDecision 2 -ReadFailures 1
        PIM eligibility renewal: 3 renewed, 0 failed, 2 need a decision, 1 could not be read
    #>
    param(
        [int]$Renewed = 0,
        [int]$Pending = 0,
        [int]$Failed = 0,
        [int]$NeedDecision = 0,
        [int]$ReadFailures = 0
    )

    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add(('{0} renewed' -f $Renewed))
    if ($Pending -gt 0) { [void]$parts.Add(('{0} pending' -f $Pending)) }
    [void]$parts.Add(('{0} failed' -f $Failed))
    [void]$parts.Add(('{0} need a decision' -f $NeedDecision))
    if ($ReadFailures -gt 0) { [void]$parts.Add(('{0} could not be read' -f $ReadFailures)) }
    return ('PIM eligibility renewal: ' + ($parts -join ', '))
}

function New-PimRenewalDigestHtml {
    <#
    .SYNOPSIS
        The digest mail body: reads that failed, renewals, eligibilities
        that need a decision, and skipped due eligibilities.
    .DESCRIPTION
        Reads that failed come first: a plane, group, or scope listed there
        was not scanned, so its eligibilities were not checked and can
        lapse. Every value is HTML-encoded; error text arrives already
        scrubbed of tokens.
    .PARAMETER ReadFailures
        Summary failure items of the ReadSchedules action (Target, Detail).
    .PARAMETER Renewals
        Report rows of Extend and Renew decisions, with outcomes.
    .PARAMETER Reviews
        Report rows of Review decisions.
    .PARAMETER Skipped
        Report rows of due eligibilities that were skipped.
    .PARAMETER RunId
        The run id.
    .PARAMETER RenewWithinDays
        The window, for the text.
    .EXAMPLE
        New-PimRenewalDigestHtml -ReadFailures @() -Renewals $rows -Reviews $reviewRows -Skipped @() -RunId $runId -RenewWithinDays 14
    #>
    param(
        [AllowEmptyCollection()][object[]]$ReadFailures = @(),
        [AllowEmptyCollection()][object[]]$Renewals = @(),
        [AllowEmptyCollection()][object[]]$Reviews = @(),
        [AllowEmptyCollection()][object[]]$Skipped = @(),
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][int]$RenewWithinDays
    )

    $eligibilityColumns = @('Plane', 'PrincipalType', 'PrincipalName', 'Role', 'ScopeName', 'EndDateTime', 'Reason')
    $renewalColumns = @('Plane', 'PrincipalType', 'PrincipalName', 'Role', 'ScopeName', 'EndDateTime', 'RequestedEnd', 'Outcome', 'RequestStatus', 'Error')
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px">')
    [void]$sb.Append(('<p>PIM eligibility renewal, window {0} day(s).</p>' -f $RenewWithinDays))
    $sections = @(
        @{ Title = 'Could not be read (not scanned, so eligibilities there were not checked and can lapse)'; Rows = @($ReadFailures); Columns = @('Target', 'Detail'); ShowEmpty = $false },
        @{ Title = 'Group eligibilities extended or renewed'; Rows = @($Renewals); Columns = $renewalColumns; ShowEmpty = $true },
        @{ Title = 'Individual eligibilities that need a decision (never renewed automatically)'; Rows = @($Reviews); Columns = $eligibilityColumns; ShowEmpty = $true },
        @{ Title = 'Due group eligibilities that were skipped'; Rows = @($Skipped); Columns = $eligibilityColumns; ShowEmpty = $true }
    )
    foreach ($section in $sections) {
        $rows = @($section.Rows)
        if ($rows.Count -eq 0 -and -not $section.ShowEmpty) { continue }
        [void]$sb.Append(('<h3>{0} ({1})</h3>' -f (ConvertTo-HtmlSafe -Value $section.Title), $rows.Count))
        if ($rows.Count -eq 0) { [void]$sb.Append('<p>None.</p>'); continue }
        [void]$sb.Append('<table border="1" cellpadding="4" cellspacing="0" style="border-collapse:collapse"><tr>')
        foreach ($column in $section.Columns) { [void]$sb.Append(('<th>{0}</th>' -f $column)) }
        [void]$sb.Append('</tr>')
        foreach ($row in $rows) {
            [void]$sb.Append('<tr>')
            foreach ($column in $section.Columns) { [void]$sb.Append(('<td>{0}</td>' -f (ConvertTo-HtmlSafe -Value (Get-PimProperty -Object $row -Name $column)))) }
            [void]$sb.Append('</tr>')
        }
        [void]$sb.Append('</table>')
    }
    if (@($Renewals | Where-Object { [string](Get-PimProperty -Object $_ -Name 'Outcome') -eq 'Pending' }).Count -gt 0) {
        [void]$sb.Append('<p>Pending: PIM accepted the request but has not applied it (approval or provisioning). The eligibility still ends on its old date until it is.</p>')
    }
    if (@($Renewals | Where-Object { [bool](Get-PimProperty -Object $_ -Name 'MayHaveBeenApplied') }).Count -gt 0) {
        [void]$sb.Append('<p>May have been applied: a failure whose error says so got a server error or no response, so PIM may have acted on it. Check that eligibility in PIM before extending it by hand; the next run renews it if PIM did not.</p>')
    }
    [void]$sb.Append('<p>Renewed eligibilities get new PIM schedule identifiers. Terraform-managed cells: run terragrunt apply -refresh-only, then scripts/Export-PimEligibilityImports.ps1.</p>')
    [void]$sb.Append(('<p style="color:#666">Sent by the PIM eligibility renewal runbook (run {0}). This mailbox is not monitored.</p>' -f (ConvertTo-HtmlSafe -Value $RunId)))
    [void]$sb.Append('</body></html>')
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Reads. Every list call is wrapped in @() because the library writes list
# items to the pipeline.
# ---------------------------------------------------------------------------

function Get-PimDirectoryCandidates {
    <#
    .SYNOPSIS
        Every directory role eligibility schedule, as candidates.
    .DESCRIPTION
        GET roleManagement/directory/roleEligibilitySchedules with the
        principal and role definition expanded, all pages. Writes candidates
        to the pipeline; wrap in @().
    .EXAMPLE
        $candidates = @(Get-PimDirectoryCandidates)
    #>
    $uri = 'roleManagement/directory/roleEligibilitySchedules?$expand=principal,roleDefinition'
    foreach ($schedule in @(Invoke-CloudRequest -Api Graph -Uri $uri -AllPages)) {
        ConvertFrom-PimDirectorySchedule -Schedule $schedule
    }
}

function Get-PimRoleAssignableGroups {
    <#
    .SYNOPSIS
        Every role-assignable group, as PIM for Groups scan targets.
    .DESCRIPTION
        GET groups?$filter=isAssignableToRole eq true (advanced query form,
        ConsistencyLevel eventual), all pages. Writes Id, DisplayName, and
        Source to the pipeline; wrap in @().
    .EXAMPLE
        $targets = @(Get-PimRoleAssignableGroups)
    #>
    $filter = [Uri]::EscapeDataString('isAssignableToRole eq true')
    $uri = 'groups?$filter={0}&$select=id,displayName&$count=true&$top=999' -f $filter
    foreach ($group in @(Invoke-CloudRequest -Api Graph -Uri $uri -AllPages -Headers @{ ConsistencyLevel = 'eventual' })) {
        $id = [string](Get-PimProperty -Object $group -Name 'id')
        if ($id) {
            [PSCustomObject]@{ Id = $id; DisplayName = [string](Get-PimProperty -Object $group -Name 'displayName'); Source = 'role-assignable' }
        }
    }
}

function Resolve-PimGroupTargets {
    <#
    .SYNOPSIS
        The PIM for Groups groups to ask about: every role-assignable group
        plus the named extras, each read on its own.
    .DESCRIPTION
        The role-assignable query and each GroupScopeNames entry are tried
        separately. A failure (a typo, a renamed group, a duplicate display
        name, a denied read) is recorded as a read failure for that entry
        alone, and every target that did resolve is still returned, so one
        bad name never stops the whole plane from being scanned. Writes Id,
        DisplayName, and Source to the pipeline, unique by id; wrap in @().
    .PARAMETER ExtraGroupNames
        Display names from GroupScopeNames.
    .PARAMETER Summary
        The run summary, for read failures.
    .EXAMPLE
        $targets = @(Resolve-PimGroupTargets -ExtraGroupNames @('PIM Helpdesk Operators') -Summary $summary)
    #>
    param(
        [AllowEmptyCollection()][string[]]$ExtraGroupNames = @(),
        [Parameter(Mandatory = $true)][object]$Summary
    )

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $found = @()
    try { $found = @(Get-PimRoleAssignableGroups) }
    catch { Write-PimReadFailure -Summary $Summary -Target 'role-assignable groups (PIM for Groups targets)' -ErrorRecord $_ }
    foreach ($group in $found) {
        if ($seen.Add([string]$group.Id)) { $group }
    }

    foreach ($name in @($ExtraGroupNames)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $id = ''
        try { $id = Resolve-GroupIdByName -DisplayName $name }
        catch {
            Write-PimReadFailure -Summary $Summary -Target ('GroupScopeNames entry "{0}"' -f $name) -ErrorRecord $_
            continue
        }
        if ($id -and $seen.Add($id)) {
            [PSCustomObject]@{ Id = $id; DisplayName = $name; Source = 'GroupScopeNames' }
        }
    }
}

function Get-PimGroupCandidates {
    <#
    .SYNOPSIS
        The PIM for Groups eligibility schedules of one group, as candidates.
    .DESCRIPTION
        GET identityGovernance/privilegedAccess/group/eligibilitySchedules
        with the required groupId filter and the principal expanded, all
        pages. Writes candidates to the pipeline; wrap in @().
    .PARAMETER GroupId
        The PIM group's object id.
    .PARAMETER GroupName
        Its display name, for messages.
    .EXAMPLE
        $candidates = @(Get-PimGroupCandidates -GroupId $id -GroupName 'PIM Tier0 Admins')
    #>
    param(
        [Parameter(Mandatory = $true)][string]$GroupId,
        [AllowEmptyString()][string]$GroupName = ''
    )

    $filter = [Uri]::EscapeDataString(('groupId eq {0}' -f (ConvertTo-ODataLiteral -Value $GroupId)))
    $uri = 'identityGovernance/privilegedAccess/group/eligibilitySchedules?$filter={0}&$expand=principal' -f $filter
    foreach ($schedule in @(Invoke-CloudRequest -Api Graph -Uri $uri -AllPages)) {
        ConvertFrom-PimGroupSchedule -Schedule $schedule -GroupName $GroupName
    }
}

function Resolve-PimAzureScanTargets {
    <#
    .SYNOPSIS
        The ARM scopes to scan for one AzureScopeNames entry.
    .DESCRIPTION
        A management group yields itself plus every child management group
        and subscription from <scope>/descendants. A subscription yields
        itself. Writes Scope, Kind, and Label to the pipeline; wrap in @().
    .PARAMETER Name
        One AzureScopeNames entry.
    .EXAMPLE
        $targets = @(Resolve-PimAzureScanTargets -Name 'Platform')
    #>
    param([Parameter(Mandatory = $true)][string]$Name)

    $parsed = Split-PimAzureScopeName -Name $Name
    $managementGroupScope = $null
    if ($parsed.Kind -ne 'Subscription') {
        try { $managementGroupScope = Resolve-ArmScope -ManagementGroupName $parsed.Value }
        catch {
            if ($parsed.Kind -eq 'ManagementGroup' -or $_.Exception.Message -notlike '*was not found*') { throw }
            $managementGroupScope = $null
        }
    }

    if ($null -eq $managementGroupScope) {
        $subscriptionScope = $null
        try {
            if ($parsed.IsGuid) { $subscriptionScope = Resolve-ArmScope -SubscriptionId $parsed.Value }
            else { $subscriptionScope = Resolve-ArmScope -SubscriptionName $parsed.Value }
        }
        catch {
            if ($parsed.Kind -eq 'Auto') {
                throw ('AzureScopeNames entry "{0}" matched no management group (id or display name) and no subscription the identity can read. {1}' -f $Name, $_.Exception.Message)
            }
            throw
        }
        [PSCustomObject]@{ Scope = $subscriptionScope; Kind = 'Subscription'; Label = $Name }
        return
    }

    [PSCustomObject]@{ Scope = $managementGroupScope; Kind = 'ManagementGroup'; Label = $Name }
    $descendantsUri = $managementGroupScope.TrimStart('/') + '/descendants'
    foreach ($entry in @(Invoke-CloudRequest -Api Arm -Uri $descendantsUri -ApiVersion $script:PimDescendantsApiVersion -AllPages)) {
        $type = [string](Get-PimProperty -Object $entry -Name 'type')
        $entryName = [string](Get-PimProperty -Object $entry -Name 'name')
        if ([string]::IsNullOrEmpty($entryName)) { continue }
        if ($type.EndsWith('/subscriptions', [StringComparison]::OrdinalIgnoreCase)) {
            [PSCustomObject]@{ Scope = '/subscriptions/' + $entryName; Kind = 'Subscription'; Label = ('{0} > {1}' -f $Name, $entryName) }
        }
        elseif ($type.EndsWith('/managementGroups', [StringComparison]::OrdinalIgnoreCase)) {
            [PSCustomObject]@{ Scope = '/providers/Microsoft.Management/managementGroups/' + $entryName; Kind = 'ManagementGroup'; Label = ('{0} > {1}' -f $Name, $entryName) }
        }
    }
}

function Get-PimAzureCandidates {
    <#
    .SYNOPSIS
        The Azure role eligibility schedules that belong to one scan target.
    .DESCRIPTION
        A management group is listed with $filter=atScope() (at or above the
        scope); a subscription is listed without a filter so resource group
        and resource schedules come back too. Either way only schedules that
        Test-PimScopeWithin assigns to the target are kept. Writes candidates
        to the pipeline; wrap in @().
    .PARAMETER Target
        A target from Resolve-PimAzureScanTargets.
    .EXAMPLE
        $candidates = @(Get-PimAzureCandidates -Target $target)
    #>
    param([Parameter(Mandatory = $true)][object]$Target)

    $uri = [string]$Target.Scope.TrimStart('/') + '/providers/Microsoft.Authorization/roleEligibilitySchedules'
    if ($Target.Kind -eq 'ManagementGroup') { $uri += '?$filter=atScope()' }
    foreach ($schedule in @(Invoke-CloudRequest -Api Arm -Uri $uri -ApiVersion $script:PimArmApiVersion -AllPages)) {
        $candidate = ConvertFrom-PimAzureSchedule -Schedule $schedule
        if (Test-PimScopeWithin -Scope $candidate.Scope -TargetScope $Target.Scope -TargetKind $Target.Kind) { $candidate }
    }
}

function Get-PimDirectoryRule {
    <#
    .SYNOPSIS
        The admin eligibility expiration rule of a directory role's policy.
    .DESCRIPTION
        GET policies/roleManagementPolicyAssignments filtered on scopeId '/',
        scopeType DirectoryRole, and the role, with policy($expand=rules).
    .PARAMETER RoleDefinitionId
        The directory role definition id.
    .EXAMPLE
        Get-PimDirectoryRule -RoleDefinitionId $roleId
    #>
    param([Parameter(Mandatory = $true)][string]$RoleDefinitionId)

    $filterText = "scopeId eq '/' and scopeType eq 'DirectoryRole' and roleDefinitionId eq {0}" -f (ConvertTo-ODataLiteral -Value $RoleDefinitionId)
    $filter = [Uri]::EscapeDataString($filterText)
    $expand = [Uri]::EscapeDataString('policy($expand=rules)')
    $uri = 'policies/roleManagementPolicyAssignments?$filter={0}&$expand={1}' -f $filter, $expand
    foreach ($assignment in @(Invoke-CloudRequest -Api Graph -Uri $uri -AllPages)) {
        $policy = Get-PimProperty -Object $assignment -Name 'policy'
        $rule = Get-PimEligibilityExpirationRule -Rules @(Get-PimProperty -Object $policy -Name 'rules')
        if ($null -ne $rule) { return $rule }
    }
    return $null
}

function Get-PimGroupRule {
    <#
    .SYNOPSIS
        The admin eligibility expiration rule of a PIM for Groups policy.
    .DESCRIPTION
        GET policies/roleManagementPolicyAssignments filtered on the group id,
        scopeType Group, and member or owner, with policy($expand=rules).
    .PARAMETER GroupId
        The PIM group's object id.
    .PARAMETER AccessId
        member or owner.
    .EXAMPLE
        Get-PimGroupRule -GroupId $groupId -AccessId member
    #>
    param(
        [Parameter(Mandatory = $true)][string]$GroupId,
        [Parameter(Mandatory = $true)][string]$AccessId
    )

    $filterText = "scopeId eq {0} and scopeType eq 'Group' and roleDefinitionId eq {1}" -f (ConvertTo-ODataLiteral -Value $GroupId), (ConvertTo-ODataLiteral -Value $AccessId)
    $filter = [Uri]::EscapeDataString($filterText)
    $expand = [Uri]::EscapeDataString('policy($expand=rules)')
    $uri = 'policies/roleManagementPolicyAssignments?$filter={0}&$expand={1}' -f $filter, $expand
    foreach ($assignment in @(Invoke-CloudRequest -Api Graph -Uri $uri -AllPages)) {
        $policy = Get-PimProperty -Object $assignment -Name 'policy'
        $rule = Get-PimEligibilityExpirationRule -Rules @(Get-PimProperty -Object $policy -Name 'rules')
        if ($null -ne $rule) { return $rule }
    }
    return $null
}

function Get-PimAzureRuleTable {
    <#
    .SYNOPSIS
        Admin eligibility expiration rules at one ARM scope, keyed by role GUID.
    .DESCRIPTION
        GET <scope>/providers/Microsoft.Authorization/roleManagementPolicyAssignments
        (all pages) and reads each assignment's effectiveRules. A role whose
        assignment has no such rule maps to $null.
    .PARAMETER Scope
        The eligibility's scope.
    .EXAMPLE
        (Get-PimAzureRuleTable -Scope '/subscriptions/<id>')['<role guid>']
    #>
    param([Parameter(Mandatory = $true)][string]$Scope)

    $table = @{}
    $uri = $Scope.Trim().Trim('/') + '/providers/Microsoft.Authorization/roleManagementPolicyAssignments'
    foreach ($assignment in @(Invoke-CloudRequest -Api Arm -Uri $uri -ApiVersion $script:PimArmApiVersion -AllPages)) {
        $p = Get-PimProperty -Object $assignment -Name 'properties'
        $roleGuid = Get-PimArmRoleGuid -RoleDefinitionId ([string](Get-PimProperty -Object $p -Name 'roleDefinitionId'))
        if ([string]::IsNullOrEmpty($roleGuid)) { continue }
        $table[$roleGuid] = Get-PimEligibilityExpirationRule -Rules @(Get-PimProperty -Object $p -Name 'effectiveRules')
    }
    return $table
}

function Resolve-PimRuleForCandidate {
    <#
    .SYNOPSIS
        The policy rule for a candidate, read once per role and cached for
        the run; $null when it cannot be read.
    .DESCRIPTION
        A read failure is logged at Warn and cached as $null, so every
        eligibility of that role is skipped rather than renewed blind.
    .PARAMETER Candidate
        A candidate that needs its policy.
    .EXAMPLE
        $rule = Resolve-PimRuleForCandidate -Candidate $c
    #>
    param([Parameter(Mandatory = $true)][object]$Candidate)

    $key = ''
    switch ($Candidate.Plane) {
        'Directory' { $key = 'Directory|' + $Candidate.RoleId }
        'Group' { $key = 'Group|' + $Candidate.GroupId + '|' + $Candidate.AccessId }
        default { $key = 'Azure|' + ([string]$Candidate.Scope).ToLowerInvariant() }
    }

    if (-not $script:PimRuleCache.ContainsKey($key)) {
        $value = $null
        try {
            switch ($Candidate.Plane) {
                'Directory' { $value = Get-PimDirectoryRule -RoleDefinitionId $Candidate.RoleId }
                'Group' { $value = Get-PimGroupRule -GroupId $Candidate.GroupId -AccessId $Candidate.AccessId }
                default { $value = Get-PimAzureRuleTable -Scope $Candidate.Scope }
            }
        }
        catch {
            Write-RunLog -Level Warn -Message ('Could not read the PIM policy for {0}: {1}' -f $key, $_.Exception.Message)
            $value = $null
        }
        $script:PimRuleCache[$key] = $value
    }

    $cached = $script:PimRuleCache[$key]
    if ($Candidate.Plane -ne 'Azure') { return $cached }
    if ($null -eq $cached) { return $null }
    $roleGuid = Get-PimArmRoleGuid -RoleDefinitionId $Candidate.RoleId
    if ($cached.ContainsKey($roleGuid)) { return $cached[$roleGuid] }
    return $null
}

# ---------------------------------------------------------------------------
# Writes. Only ever called from inside Invoke-RunbookAction.
# ---------------------------------------------------------------------------

function Get-PimRequestState {
    <#
    .SYNOPSIS
        Done, Pending, or Failed for the status PIM returns on a schedule
        request.
    .DESCRIPTION
        Done only for the statuses that mean the eligibility is in effect
        (Provisioned, Granted, ScheduleCreated). Failed for denied, failed,
        canceled, revoked, timed out, locked, or invalid. Anything else,
        including PendingApproval, PendingAdminDecision,
        PendingProvisioning, Accepted, AdminApproved, and an empty or
        unknown status, is Pending: accepted, not confirmed in effect, and
        never counted as renewed.
    .PARAMETER Status
        The status text from the response.
    .EXAMPLE
        Get-PimRequestState -Status 'PendingApproval'
        Pending
    #>
    param([AllowNull()][AllowEmptyString()][string]$Status)

    $text = ''
    if ($null -ne $Status) { $text = $Status.Trim() }
    $done = @('Provisioned', 'Granted', 'ScheduleCreated')
    $failed = @('Denied', 'Failed', 'Canceled', 'Revoked', 'FailedAsResourceIsLocked', 'AdminDenied', 'TimedOut', 'Invalid')
    if ($done -contains $text) { return 'Done' }
    if ($failed -contains $text) { return 'Failed' }
    return 'Pending'
}

function Get-PimCloudErrorData {
    <#
    .SYNOPSIS
        One value from the Data of a request error, looked up along the
        inner exceptions, or $null.
    .DESCRIPTION
        The library's request errors carry HttpStatus, Attempts, and
        MayHaveBeenApplied in Exception.Data (New-CloudRequestError). An
        error raised before a request was sent carries none of them. The
        outermost exception that has the key wins, so a wrapper can
        override what an inner error says.
    .PARAMETER ErrorRecord
        $_ in a catch block, or an exception.
    .PARAMETER Name
        The Data key.
    .EXAMPLE
        Get-PimCloudErrorData -ErrorRecord $_ -Name 'Attempts'
    #>
    param(
        [AllowNull()][object]$ErrorRecord,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $ErrorRecord) { return $null }
    $exception = $ErrorRecord
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $exception = $ErrorRecord.Exception }
    while ($exception -is [Exception]) {
        if ($exception.Data.Contains($Name)) { return $exception.Data[$Name] }
        $exception = $exception.InnerException
    }
    return $null
}

function Invoke-PimAzureRequest {
    <#
    .SYNOPSIS
        Creates one ARM roleEligibilityScheduleRequest and, when the create
        may have happened behind an error, reads it back by name.
    .DESCRIPTION
        PUT {scope}/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/{name}
        through the library, which repeats a PUT after a 429, a 5xx, or a
        lost response. When the PUT still fails and any attempt may have
        reached PIM (a 5xx, no response, or more than one attempt), the
        request is read back with GET on the same name, which Reader
        allows:
          found        the recorded request is returned, so its status
                       decides the outcome (a Warn line says so);
          404          PIM never created it; the PUT error is thrown as is;
          other error  the PUT error is thrown with a note that the request
                       may have been applied, and Data MayHaveBeenApplied
                       $true.
        A first-attempt 4xx (the request was refused) and an error raised
        before sending are thrown without a read. Returns the parsed
        request.
    .PARAMETER Scope
        The eligibility's scope.
    .PARAMETER RequestName
        A new GUID; the request name.
    .PARAMETER Body
        The body from New-PimAzureRequestBody.
    .EXAMPLE
        Invoke-PimAzureRequest -Scope $c.Scope -RequestName ([Guid]::NewGuid().ToString()) -Body $body
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$RequestName,
        [Parameter(Mandatory = $true)][object]$Body
    )

    $requestUri = New-PimAzureRequestUri -Scope $Scope -RequestName $RequestName
    $caught = $null
    try {
        return (Invoke-CloudRequest -Api Arm -Method PUT -Uri $requestUri -ApiVersion $script:PimArmApiVersion -Body $Body)
    }
    catch { $caught = $_ }

    $sentStatus = Get-PimCloudErrorData -ErrorRecord $caught -Name 'HttpStatus'
    if ($null -eq $sentStatus) { throw $caught }
    $status = [int]$sentStatus
    $attempts = [int](Get-PimCloudErrorData -ErrorRecord $caught -Name 'Attempts')
    if (-not ($status -eq 0 -or $status -ge 500 -or $attempts -gt 1)) { throw $caught }

    # Short forms, so the combined message stays inside the 600 characters
    # the summary keeps; the PUT message already names the path.
    $putText = 'no HTTP response'
    if ($status -gt 0) { $putText = 'HTTP {0}' -f $status }
    $putText = '{0} after {1} attempt(s)' -f $putText, $attempts

    $record = $null
    try {
        $record = Invoke-CloudRequest -Api Arm -Uri $requestUri -ApiVersion $script:PimArmApiVersion
    }
    catch {
        $readStatus = Get-CloudErrorStatus -ErrorRecord $_
        if ($readStatus -eq 404) { throw $caught }
        if ($null -eq (Get-PimCloudErrorData -ErrorRecord $_ -Name 'HttpStatus')) { $readText = Protect-RunbookText -Text $_.Exception.Message -MaxLength 150 }
        elseif ($readStatus -eq 0) { $readText = 'no HTTP response' }
        else {
            $readText = 'HTTP {0}' -f $readStatus
            $readCode = [string](Get-PimCloudErrorData -ErrorRecord $_ -Name 'ErrorCode')
            if (-not [string]::IsNullOrWhiteSpace($readCode)) { $readText = '{0} {1}' -f $readText, $readCode }
        }
        $message = '{0} The request may have been applied: reading it back by name failed too ({1}). Check the eligibility in PIM before sending it again.' -f $caught.Exception.Message, $readText
        $uncertain = New-Object -TypeName System.InvalidOperationException -ArgumentList $message, $caught.Exception
        $uncertain.Data['MayHaveBeenApplied'] = $true
        throw $uncertain
    }
    if ($null -eq $record) { throw $caught }
    $recordedStatus = [string](Get-PimProperty -Object (Get-PimProperty -Object $record -Name 'properties') -Name 'status')
    Write-RunLog -Level Warn -Message ('ARM PUT of eligibility request {0} at {1} failed ({2}), but PIM has the request with status "{3}"; that status decides the outcome.' -f $RequestName, $Scope, $putText, $recordedStatus)
    return $record
}

function Invoke-PimRenewalRequest {
    <#
    .SYNOPSIS
        Sends one extension or renewal request and checks its status.
    .DESCRIPTION
        Graph POST through the library for directory and group eligibilities
        (repeated only after a 429), and Invoke-PimAzureRequest, an ARM PUT
        with a new request GUID, for Azure eligibilities. A response whose
        status Get-PimRequestState calls Failed throws, so the action is
        recorded as Failed. A Pending status is logged at Warn. Returns the
        status text.
    .PARAMETER Decision
        An Extend or Renew decision.
    .PARAMETER Justification
        The justification text.
    .EXAMPLE
        Invoke-PimRenewalRequest -Decision $d -Justification $text
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Decision,
        [Parameter(Mandatory = $true)][string]$Justification
    )

    $c = $Decision.Candidate
    if ([string]$c.PrincipalType -ne 'Group') { throw ('Refusing to renew a {0} eligibility; only groups are renewed.' -f $c.PrincipalType) }
    if (@('Extend', 'Renew') -notcontains [string]$Decision.Decision) { throw ('Decision {0} is not a renewal.' -f $Decision.Decision) }

    # The Graph POSTs are sent without -RetryNonIdempotent, on purpose. The
    # library repeats a POST only after HTTP 429, when Graph refused it
    # unprocessed. After a 5xx or a lost response PIM may already have
    # created the request, and a second POST would fail with "a pending
    # request exists" and hide the renewal that happened, so the library
    # fails at once and marks the error MayHaveBeenApplied. Graph picks the
    # request id, so unlike the ARM request it cannot be read back by name.
    $response = $null
    $status = ''
    switch ($c.Plane) {
        'Directory' {
            $response = Invoke-CloudRequest -Api Graph -Method POST -Uri 'roleManagement/directory/roleEligibilityScheduleRequests' -Body (New-PimDirectoryRequestBody -Decision $Decision -Justification $Justification)
            $status = [string](Get-PimProperty -Object $response -Name 'status')
        }
        'Group' {
            $response = Invoke-CloudRequest -Api Graph -Method POST -Uri 'identityGovernance/privilegedAccess/group/eligibilityScheduleRequests' -Body (New-PimGroupRequestBody -Decision $Decision -Justification $Justification)
            $status = [string](Get-PimProperty -Object $response -Name 'status')
        }
        'Azure' {
            $response = Invoke-PimAzureRequest -Scope $c.Scope -RequestName ([Guid]::NewGuid().ToString()) -Body (New-PimAzureRequestBody -Decision $Decision -Justification $Justification)
            $status = [string](Get-PimProperty -Object (Get-PimProperty -Object $response -Name 'properties') -Name 'status')
        }
        default { throw ('Unknown plane {0}.' -f $c.Plane) }
    }

    $state = Get-PimRequestState -Status $status
    if ($state -eq 'Failed') { throw ('PIM answered with status {0}.' -f $status) }
    if ($state -eq 'Pending') {
        $statusText = $status
        if ([string]::IsNullOrWhiteSpace($statusText)) { $statusText = '(none)' }
        Write-RunLog -Level Warn -Message ('PIM accepted the request for {0} with status {1}; it is not confirmed in effect, so it is reported as pending, not renewed.' -f (Format-PimCandidateLabel -Candidate $c), $statusText)
    }
    return $status
}

function Write-PimRenewalReport {
    <#
    .SYNOPSIS
        Writes the CSV report of every decision.
    .PARAMETER Path
        CSV path; the folder is created when missing.
    .PARAMETER Decisions
        The decision objects.
    .EXAMPLE
        Write-PimRenewalReport -Path .\out\pim.csv -Decisions $decisions
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyCollection()][object[]]$Decisions = @()
    )

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -Path $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $rows = @(foreach ($decision in @($Decisions)) { New-PimReportRow -Decision $decision })
    $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

function Write-PimReadFailure {
    <#
    .SYNOPSIS
        Logs a failed read and records it on the summary; the run continues.
    .PARAMETER Summary
        The run summary.
    .PARAMETER Target
        What could not be read.
    .PARAMETER ErrorRecord
        The caught error.
    .EXAMPLE
        Write-PimReadFailure -Summary $summary -Target 'directory roles' -ErrorRecord $_
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Summary,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][object]$ErrorRecord
    )

    $text = $ErrorRecord
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $text = $ErrorRecord.Exception.Message }
    Write-RunLog -Level Error -Message ('Could not read {0}: {1}' -f $Target, $text)
    Add-RunSummaryItem -Summary $Summary -Action 'ReadSchedules' -Target $Target -Outcome Failed -Detail ([string]$text)
}

# ---------------------------------------------------------------------------
# Run.
# ---------------------------------------------------------------------------

function Invoke-PimEligibilityRenewalRun {
    <#
    .SYNOPSIS
        One renewal run: read, decide, check the breaker, renew, report.
    .DESCRIPTION
        Takes the runbook's parameters plus Now, the clock, for tests.
        Returns the summary object from Complete-RunSummary.
    .PARAMETER RenewWithinDays
        See the runbook help.
    .PARAMETER ExtendDays
        See the runbook help.
    .PARAMETER PrincipalGroupNamePattern
        See the runbook help.
    .PARAMETER IncludeDirectoryRoles
        See the runbook help.
    .PARAMETER IncludeGroups
        See the runbook help.
    .PARAMETER IncludeAzureResources
        See the runbook help.
    .PARAMETER AzureScopeNames
        See the runbook help.
    .PARAMETER GroupScopeNames
        See the runbook help.
    .PARAMETER MaxRenewalsPerRun
        See the runbook help.
    .PARAMETER Recipients
        See the runbook help.
    .PARAMETER SenderMailbox
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
    .PARAMETER Now
        The clock. Default now, UTC.
    .EXAMPLE
        Invoke-PimEligibilityRenewalRun -IncludeAzureResources $true -AzureScopeNames 'mg:Platform' -AccessToken $tokens -DryRun $true
    #>
    param(
        [ValidateRange(1, 90)][int]$RenewWithinDays = 14,
        [ValidateRange(1, 3650)][int]$ExtendDays = 365,
        [AllowEmptyString()][string]$PrincipalGroupNamePattern = '*',
        [bool]$IncludeDirectoryRoles = $true,
        [bool]$IncludeGroups = $true,
        [bool]$IncludeAzureResources = $false,
        [AllowEmptyString()][string]$AzureScopeNames = '',
        [AllowEmptyString()][string]$GroupScopeNames = '',
        [ValidateRange(0, 10000)][int]$MaxRenewalsPerRun = 20,
        [AllowEmptyString()][string]$Recipients = '',
        [AllowEmptyString()][string]$SenderMailbox = '',
        [AllowEmptyString()][string]$ReportPath = '',
        [bool]$DryRun = $true,
        [ValidateSet('Global', 'USGov')][string]$Environment = 'Global',
        [AllowEmptyString()][string]$ClientId = '',
        [AllowEmptyString()][string]$AccessToken = '',
        [AllowEmptyString()][string]$RunId = '',
        [DateTime]$Now = [DateTime]::UtcNow
    )

    Initialize-RunContext -RunbookName $script:PimRunbookName -RunId $RunId -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken -DryRun $DryRun
    $summary = New-RunSummary
    $script:PimRuleCache = @{}
    $runContext = Get-RunContext
    $nowUtc = ConvertTo-PimUtcDateTime -Value $Now

    # Parameters. Everything that can be wrong is refused before any read.
    $patterns = @(ConvertTo-PimGroupNamePatternList -Value $PrincipalGroupNamePattern)
    $recipientList = @(ConvertTo-StringList -Value $Recipients -Label 'Recipients')
    foreach ($address in $recipientList) {
        if ($address -notmatch '^[^@\s]+@[^@\s]+$') { throw ('Recipients contains a value that is not a mail address: "{0}".' -f $address) }
    }
    if ($recipientList.Count -gt 0 -and $SenderMailbox -notmatch '^[^@\s]+@[^@\s]+$') {
        throw 'Recipients is set, so SenderMailbox must be the user principal name of the mailbox the digest is sent from.'
    }
    $scopeNames = @(ConvertTo-StringList -Value $AzureScopeNames -Label 'AzureScopeNames')
    $groupNames = @(ConvertTo-StringList -Value $GroupScopeNames -Label 'GroupScopeNames')
    if (-not ($IncludeDirectoryRoles -or $IncludeGroups -or $IncludeAzureResources)) {
        throw 'IncludeDirectoryRoles, IncludeGroups, and IncludeAzureResources are all false; there is nothing to renew.'
    }

    Write-RunLog -Level Info -Message ('Settings: RenewWithinDays={0} ExtendDays={1} MaxRenewalsPerRun={2} Patterns={3} Directory={4} Groups={5} Azure={6} AzureScopes={7} ExtraGroups={8} Recipients={9}' -f $RenewWithinDays, $ExtendDays, $MaxRenewalsPerRun, ($patterns -join ';'), $IncludeDirectoryRoles, $IncludeGroups, $IncludeAzureResources, $scopeNames.Count, $groupNames.Count, $recipientList.Count)

    # Read.
    $candidates = New-Object System.Collections.ArrayList
    $stats = [ordered]@{ DirectorySchedules = 0; GroupSchedules = 0; AzureSchedules = 0; GroupsScanned = 0; AzureScopesScanned = 0 }

    if ($IncludeDirectoryRoles) {
        try {
            $found = @(Get-PimDirectoryCandidates)
            foreach ($candidate in $found) { [void]$candidates.Add($candidate) }
            $stats.DirectorySchedules = $found.Count
            Write-RunLog -Level Info -Message ('Directory roles: {0} eligibility schedule(s).' -f $found.Count)
        }
        catch { Write-PimReadFailure -Summary $summary -Target 'directory role eligibility schedules' -ErrorRecord $_ }
    }

    if ($IncludeGroups) {
        $groupTargets = @(Resolve-PimGroupTargets -ExtraGroupNames $groupNames -Summary $summary)
        foreach ($groupTarget in $groupTargets) {
            try {
                $found = @(Get-PimGroupCandidates -GroupId $groupTarget.Id -GroupName $groupTarget.DisplayName)
                foreach ($candidate in $found) { [void]$candidates.Add($candidate) }
                $stats.GroupSchedules += $found.Count
                $stats.GroupsScanned++
            }
            catch { Write-PimReadFailure -Summary $summary -Target ('PIM for Groups schedules of "{0}"' -f $groupTarget.DisplayName) -ErrorRecord $_ }
        }
        Write-RunLog -Level Info -Message ('PIM for Groups: {0} eligibility schedule(s) in {1} group(s).' -f $stats.GroupSchedules, $stats.GroupsScanned)
    }

    if (-not $IncludeAzureResources -and $scopeNames.Count -gt 0) {
        Write-RunLog -Level Warn -Message ('AzureScopeNames names {0} scope(s) but IncludeAzureResources is false (the default); the Azure plane was not scanned. Pass -IncludeAzureResources $true to scan it.' -f $scopeNames.Count)
    }
    if ($IncludeAzureResources) {
        if ($scopeNames.Count -eq 0) {
            Write-RunLog -Level Warn -Message 'IncludeAzureResources is true but AzureScopeNames is empty; the Azure plane was not scanned.'
        }
        else {
            $azureTargets = New-Object System.Collections.ArrayList
            $targetScopes = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($scopeName in $scopeNames) {
                try {
                    foreach ($azureTarget in @(Resolve-PimAzureScanTargets -Name $scopeName)) {
                        if ($targetScopes.Add([string]$azureTarget.Scope)) { [void]$azureTargets.Add($azureTarget) }
                    }
                }
                catch { Write-PimReadFailure -Summary $summary -Target ('Azure scope "{0}"' -f $scopeName) -ErrorRecord $_ }
            }
            $scheduleIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($azureTarget in $azureTargets) {
                try {
                    foreach ($candidate in @(Get-PimAzureCandidates -Target $azureTarget)) {
                        if ($scheduleIds.Add([string]$candidate.ScheduleId)) {
                            [void]$candidates.Add($candidate)
                            $stats.AzureSchedules++
                        }
                    }
                    $stats.AzureScopesScanned++
                }
                catch { Write-PimReadFailure -Summary $summary -Target ('Azure eligibility schedules at {0}' -f $azureTarget.Scope) -ErrorRecord $_ }
            }
            Write-RunLog -Level Info -Message ('Azure resources: {0} eligibility schedule(s) at {1} scope(s).' -f $stats.AzureSchedules, $stats.AzureScopesScanned)
        }
    }

    # Decide.
    $decisions = New-Object System.Collections.ArrayList
    foreach ($candidate in $candidates) {
        $decision = Get-PimRenewalDecision -Candidate $candidate -Now $nowUtc -RenewWithinDays $RenewWithinDays -ExtendDays $ExtendDays -GroupPatterns $patterns
        if ($decision.NeedsPolicy) {
            $rule = Resolve-PimRuleForCandidate -Candidate $candidate
            $decision = Get-PimRenewalDecision -Candidate $candidate -Now $nowUtc -RenewWithinDays $RenewWithinDays -ExtendDays $ExtendDays -GroupPatterns $patterns -Rule $rule -RuleKnown $true
        }
        [void]$decisions.Add($decision)
    }

    $renewals = @($decisions | Where-Object { $_.Decision -eq 'Extend' -or $_.Decision -eq 'Renew' } | Sort-Object -Property { $_.Candidate.End })
    $reviews = @($decisions | Where-Object { $_.Decision -eq 'Review' })
    $excluded = @($decisions | Where-Object { $_.Decision -eq 'Excluded' })
    $skippedDue = @($decisions | Where-Object { $_.Decision -eq 'Skip' -and $_.Due })
    $notDue = @($decisions | Where-Object { $_.Decision -eq 'NotDue' })
    $dueCount = @($decisions | Where-Object { $_.Due }).Count
    Write-RunLog -Level Info -Message ('Decisions: schedules={0} due={1} extend={2} renew={3} review={4} excluded={5} skippedDue={6} notDue={7}' -f $decisions.Count, $dueCount, @($renewals | Where-Object { $_.Decision -eq 'Extend' }).Count, @($renewals | Where-Object { $_.Decision -eq 'Renew' }).Count, $reviews.Count, $excluded.Count, $skippedDue.Count, $notDue.Count)

    foreach ($item in $reviews) {
        $label = Format-PimCandidateLabel -Candidate $item.Candidate
        Write-RunLog -Level Warn -Message ('Needs a decision: {0}: {1}.' -f $label, $item.Reason)
        Add-RunSummaryItem -Summary $summary -Action 'ReviewEligibility' -Target $label -Outcome Skipped -Detail $item.Reason
        $item.Outcome = 'NeedsDecision'
    }
    foreach ($item in $excluded) {
        $label = Format-PimCandidateLabel -Candidate $item.Candidate
        Write-RunLog -Level Info -Message ('Excluded by pattern: {0}: {1}.' -f $label, $item.Reason)
        Add-RunSummaryItem -Summary $summary -Action 'ExcludedEligibility' -Target $label -Outcome Skipped -Detail $item.Reason
        $item.Outcome = 'Excluded'
    }
    foreach ($item in $skippedDue) {
        $label = Format-PimCandidateLabel -Candidate $item.Candidate
        Write-RunLog -Level Warn -Message ('Not renewing {0}: {1}.' -f $label, $item.Reason)
        Add-RunSummaryItem -Summary $summary -Action 'SkipEligibility' -Target $label -Outcome Skipped -Detail $item.Reason
        $item.Outcome = 'Skipped'
    }

    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        Write-PimRenewalReport -Path $ReportPath -Decisions $decisions.ToArray()
        Write-RunLog -Level Info -Message ('Wrote report to {0}.' -f $ReportPath)
    }

    # Breaker first, in dry runs too, so a dry run shows that the live run
    # would refuse.
    try {
        Test-CircuitBreaker -Planned $renewals.Count -Cap $MaxRenewalsPerRun -Label 'PIM eligibility renewals'
    }
    catch {
        Write-RunLog -Level Error -Message $_.Exception.Message
        throw
    }

    # Renew. Invoke-RunbookAction applies DryRun and records each outcome;
    # a failure is logged and the loop carries on. The script block writes
    # the PIM status, the scrubbed error, and whether the failed request may
    # have been applied onto the decision, because the action's own output
    # is discarded. Done in the summary counts means the request was
    # accepted; the decision's Outcome says whether it is in effect (Done)
    # or not yet (Pending).
    foreach ($renewal in $renewals) {
        $pimDecision = $renewal
        $pimDecision.RequestStatus = ''
        $pimDecision.Error = ''
        $pimDecision.MayHaveBeenApplied = $false
        $label = Format-PimCandidateLabel -Candidate $pimDecision.Candidate
        $verb = 'extend'
        $summaryAction = 'ExtendEligibility'
        if ($pimDecision.Decision -eq 'Renew') { $verb = 'renew'; $summaryAction = 'RenewEligibility' }
        $justification = New-PimRenewalJustification -Decision $pimDecision.Decision -RunId $runContext.RunId -RenewWithinDays $RenewWithinDays
        $description = '{0} the eligibility of {1} until {2}' -f $verb, $label, (Format-PimUtc -Value $pimDecision.RequestedEnd)
        $outcome = Invoke-RunbookAction -Summary $summary -Action $summaryAction -Target $label -Description $description -PassThru -ScriptBlock {
            try {
                $pimRequestStatus = Invoke-PimRenewalRequest -Decision $pimDecision -Justification $justification
                $pimDecision.RequestStatus = [string]$pimRequestStatus
            }
            catch {
                $pimDecision.Error = Protect-RunbookText -Text $_.Exception.Message -MaxLength 600
                $pimDecision.MayHaveBeenApplied = ((Get-PimCloudErrorData -ErrorRecord $_ -Name 'MayHaveBeenApplied') -eq $true)
                throw
            }
        }
        $renewal.Outcome = [string]$outcome
        if ($renewal.Outcome -eq 'Done' -and (Get-PimRequestState -Status $renewal.RequestStatus) -eq 'Pending') { $renewal.Outcome = 'Pending' }
        if ($renewal.Outcome -ne 'Failed') { $renewal.MayHaveBeenApplied = $false }
    }

    $renewedCount = @($renewals | Where-Object { $_.Outcome -eq 'Done' }).Count
    $pendingCount = @($renewals | Where-Object { $_.Outcome -eq 'Pending' }).Count
    $renewFailedCount = @($renewals | Where-Object { $_.Outcome -eq 'Failed' }).Count
    $uncertainCount = @($renewals | Where-Object { $_.Outcome -eq 'Failed' -and $_.MayHaveBeenApplied }).Count
    if ($pendingCount -gt 0) {
        Write-RunLog -Level Warn -Message ('{0} renewal request(s) are pending in PIM and not in effect yet; they are not counted as renewed. Check them in PIM, and refresh Terraform state once they are applied.' -f $pendingCount)
    }
    $followUpParts = New-Object System.Collections.ArrayList
    if ($renewedCount -gt 0) {
        $renewedText = '{0} eligibility schedule(s) were renewed and now have new PIM identifiers. In Terraform-managed cells run terragrunt apply -refresh-only, then scripts/Export-PimEligibilityImports.ps1.' -f $renewedCount
        Write-RunLog -Level Info -Message $renewedText
        [void]$followUpParts.Add($renewedText)
    }
    if ($uncertainCount -gt 0) {
        $uncertainText = '{0} failed renewal request(s) got a server error or no response and may have been applied; check them in PIM, and if they were, refresh Terraform state the same way.' -f $uncertainCount
        Write-RunLog -Level Warn -Message $uncertainText
        [void]$followUpParts.Add($uncertainText)
    }
    $followUp = $followUpParts -join ' '

    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        Write-PimRenewalReport -Path $ReportPath -Decisions $decisions.ToArray()
    }

    $renewalRows = @(foreach ($item in $renewals) { New-PimReportRow -Decision $item })
    $reviewRows = @(foreach ($item in $reviews) { New-PimReportRow -Decision $item })
    $skippedRows = @(foreach ($item in $skippedDue) { New-PimReportRow -Decision $item })

    # Digest. Reads that failed are part of it: a plane that was not
    # scanned is the one whose group eligibilities will lapse unnoticed.
    $digestSent = $false
    $readFailureRows = @($summary.Failures | Where-Object { $_.Action -eq 'ReadSchedules' })
    if ($recipientList.Count -gt 0 -and ($readFailureRows.Count + $renewalRows.Count + $reviewRows.Count + $skippedRows.Count) -gt 0) {
        $html = New-PimRenewalDigestHtml -ReadFailures $readFailureRows -Renewals $renewalRows -Reviews $reviewRows -Skipped $skippedRows -RunId $runContext.RunId -RenewWithinDays $RenewWithinDays
        $subject = New-PimRenewalDigestSubject -Renewed $renewedCount -Pending $pendingCount -Failed $renewFailedCount -NeedDecision $reviewRows.Count -ReadFailures $readFailureRows.Count
        $mailOutcome = Invoke-RunbookAction -Summary $summary -Action 'SendDigest' -Target ($recipientList -join ';') -Description ('send the renewal digest to {0}' -f ($recipientList -join ';')) -PassThru -ScriptBlock {
            Send-RunbookMail -SenderMailbox $SenderMailbox -To $recipientList -Subject $subject -HtmlBody $html
        }
        $digestSent = ($mailOutcome -eq 'Done')
    }

    $extra = [ordered]@{
        RenewWithinDays           = $RenewWithinDays
        ExtendDays                = $ExtendDays
        MaxRenewalsPerRun         = $MaxRenewalsPerRun
        PrincipalGroupNamePattern = ($patterns -join ';')
        SchedulesScanned          = $candidates.Count
        DirectorySchedules        = $stats.DirectorySchedules
        GroupSchedules            = $stats.GroupSchedules
        AzureSchedules            = $stats.AzureSchedules
        GroupsScanned             = $stats.GroupsScanned
        AzureScopesScanned        = $stats.AzureScopesScanned
        DueCount                  = $dueCount
        PlannedRenewals           = $renewals.Count
        Renewed                   = $renewedCount
        Pending                   = $pendingCount
        RenewalFailures           = $renewFailedCount
        UncertainRenewals         = $uncertainCount
        ReadFailures              = $readFailureRows.Count
        ReviewCount               = $reviews.Count
        ExcludedCount             = $excluded.Count
        SkippedDueCount           = $skippedDue.Count
        NotDueCount               = $notDue.Count
        Renewals                  = $renewalRows
        NeedsDecision             = $reviewRows
        DigestSent                = $digestSent
        ReportPath                = $ReportPath
        FollowUp                  = $followUp
    }
    return (Complete-RunSummary -Summary $summary -Extra $extra)
}

# ---------------------------------------------------------------------------
# Entry point. Skipped when dot-sourced by the tests.
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-PimEligibilityRenewalRun -RenewWithinDays $RenewWithinDays -ExtendDays $ExtendDays -PrincipalGroupNamePattern $PrincipalGroupNamePattern `
        -IncludeDirectoryRoles ([bool]$IncludeDirectoryRoles) -IncludeGroups ([bool]$IncludeGroups) -IncludeAzureResources ([bool]$IncludeAzureResources) `
        -AzureScopeNames $AzureScopeNames -GroupScopeNames $GroupScopeNames -MaxRenewalsPerRun $MaxRenewalsPerRun `
        -Recipients $Recipients -SenderMailbox $SenderMailbox -ReportPath $ReportPath -DryRun ([bool]$DryRun) `
        -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken -RunId $RunId
}
