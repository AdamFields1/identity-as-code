<#
.SYNOPSIS
    Holds the activation rules of every Azure resource PIM role that has an
    eligible assignment under the named management groups and subscriptions
    to the tenant baseline, including pairs no Terraform cell declares.

.DESCRIPTION
    Runs as an Azure Automation runbook on a user-assigned managed identity,
    against the Azure Resource Manager PIM API (Microsoft.Authorization,
    api-version 2020-10-01). For each entry in ScopeNames it:

      1. Resolves the name to a management group or a subscription with the
         library (Resolve-ArmScope). A management group expands to itself,
         every descendant management group, and every descendant
         subscription (GET .../descendants, api-version 2020-05-01).
      2. Lists the role eligibility schedule instances at each of those
         scopes, keeps memberType Direct, drops anything whose own scope is
         outside the named scope, and reduces the rest to distinct
         (scope, role definition) pairs keyed on each instance's OWN
         properties.scope, deduplicated across listings. Role settings are
         defined per role and per resource and a subscription's settings are
         not inherited by its resource groups (learn.microsoft.com,
         "Configure Azure resource role settings in PIM"), so an eligibility
         made at a resource group is governed by the policy at that resource
         group, and that is the policy this runbook reads.
      3. Reads the role management policy assignment for each pair
         (roleManagementPolicyAssignments filtered by roleDefinitionId, each
         result checked for scope and role, falling back to the whole list
         at that scope), then GETs the policy it names, with its rules.
      4. Compares three rules with the settings the pair is held to (its
         own "pairs" entry, else its role's "roles" entry, else "defaults";
         see BaselineJson), field by field:
           Expiration_EndUser_Assignment  maximumDuration, compared as a
                                          duration (PT240M equals PT4H)
           Enablement_EndUser_Assignment  MultiFactorAuthentication,
                                          Justification, Ticketing
           Approval_EndUser_Assignment    isApprovalRequired and, when
                                          approval is required, the primary
                                          approvers of the first stage
                                          (exactly the named groups)
         In mode "minimum", the default, the baseline is a floor: a shorter
         activation window, an extra enablement requirement, approval the
         baseline does not ask for, and extra approval stages are all
         compliant, and a patch only ever tightens. Mode "exact" makes any
         difference drift, so a patch can loosen a policy; choose it only in
         a reviewed baseline change. Invoke-EntraPimPolicyDrift uses the
         same two modes with the same default.
      5. PATCHes each drifted policy with only its drifted rules. The
         2020-10-01 reference documents a partial update (the
         PatchPartialRoleManagementPolicy example sends a rules array that
         holds only the rules being changed), so rules this runbook does not
         govern (notifications, eligibility and assignment expiry,
         authentication context) are never sent and never touched. Each rule
         sent is a copy of the rule as read with only the governed fields
         replaced, so settings such as the approval stage timeout survive.
         In minimum mode an enablement patch keeps every live entry and adds
         the missing ones, and an approval patch replaces the approvers of
         the first stage and keeps any later stage and the approval mode.
      6. Writes an optional CSV, mails an HTML digest when a live run finds
         drift or a failure, and emits one summary object as its last
         output.

    Where the baseline comes from, first match wins:
      1. BaselineJson, when it is not empty. For local runs and tests only.
      2. The Automation string variable named by BaselineVariableName
         (default PimPolicy_AzureBaseline), read with the library's
         Get-AutomationStringVariable. This is how a scheduled job gets its
         baseline. A job schedule binds only [bool], [int], and [string]
         values reliably, and the Automation service may parse JSON-looking
         parameter text before binding. JSON text in a schedule parameter
         can therefore arrive as "@{...}" or "System.Object[]", and the run
         refuses such a value. A variable is returned exactly as stored.
      3. The built-in defaults, when BaselineVariableName is empty or the
         variable's value is empty. The run logs which case applied.
    BaselineJson and the variable hold the same JSON document, described
    under BaselineJson. Error and log messages call its parts
    "BaselineJson ..." whichever of the two carried it. A variable that
    does not exist, or cannot be read, stops the run before any call. A
    missing variable therefore never quietly holds the declared pairs to
    the defaults.

    Why atScope() is not used. The API reference describes $filter=atScope()
    as returning schedules at or above the scope, and the PIM REST sample as
    the specified scope only, without subscopes; neither returns what is
    below. The runbook lists without a filter, applies the scoping itself
    (memberType Direct plus the containment check in step 2), and lists
    every descendant scope explicitly, so a subscription is swept even when
    a management group listing does not return its schedules.

    Unverified: coverage below a subscription. The 2020-10-01 List For Scope
    reference documents only the filtered forms: atScope() returns what is
    at or above the scope, and principalId eq returns what is at, above, or
    below it. That an unfiltered list at a subscription also returns the
    schedules made at its resource groups and resources is assumed, not
    documented, and resource group and resource coverage rests on it, in
    the same way that management group coverage rests on the descendants
    listing. The summary counts PairsAtManagementGroup, PairsAtSubscription,
    and PairsBelowSubscription, so a sweep that finds nothing below a
    subscription is visible. Verify both against a tenant that has a
    resource group eligibility before the first live run.

    How this complements stacks/azure-pim-governance. Terraform owns the
    (scope, role) pairs a tenant cell declares in var.policies: it states
    their rules, reviews every change in a plan, and holds them in state. It
    cannot see a pair nobody declared: a role made eligible from the portal,
    a subscription created under a management group last week, a custom
    role another team added. This runbook sweeps every pair that has an
    eligibility, declared or not. Its built-in baseline IS the stack's
    default baseline (PT4H, MFA and justification on, ticket information
    off, approval off), so a declared pair that inherits the stack defaults
    already agrees with it. Overrides in the stack are per (scope, role)
    pair, with their own approver groups, so they are passed the same way.
    The baseline's "pairs" takes the map the PIM governance cell passes as
    policies, and its "defaults" takes the cell's tenant-level values. Each
    declared pair is then held to its own declared values, however
    differently the same role is declared at other scopes. A
    management_group "pairs" scope is matched by display name only, as
    modules/azure/pim-role-policy matches it. A name that is only a group's
    id stops the run, because Terraform could not resolve it either.
    Alternatively, with "report_only" on the entry or
    "pairs_report_only" for all of them, it is reported and left to
    Terraform. "roles" applies only to pairs with no "pairs" entry, so it
    states a rule for a role at the scopes nobody declared; it is never a
    mirror of a declared pair. With the declared pairs passed this way and
    the default mode, a live run only moves a declared pair toward its
    declared values, and a Terraform plan after it shows no change the
    runbook caused.

    Authentication context. A policy whose AuthenticationContext_EndUser_Assignment
    rule is on asks for a Conditional Access authentication context at
    activation, and the azurerm provider treats that rule and the
    MultiFactorAuthentication requirement as mutually exclusive. In both
    modes the runbook never adds MultiFactorAuthentication to such a policy.
    The missing MFA is reported as drift, and the whole pair is reported and
    not patched until the role gets a "pairs" or "roles" entry with
    "require_multifactor_authentication": false or "report_only": true.

    Safety model.
      - DryRun defaults to $true. Everything is read and compared; every
        PATCH and the digest are logged as "Would ..."; nothing is written
        and nothing is sent.
      - The baseline is a floor unless it says "mode": "exact", so by
        default a sweep never loosens a policy, whoever declared it.
      - A baseline, ScopeNames, or Recipients value that starts with "@{",
        "System.Object", or "System.Collections." stops the run before any
        call. That text is what parameter binding makes of JSON the service
        parsed, not the value that was set. A baseline variable that is
        missing or unreadable stops the run too. Only an empty
        BaselineVariableName, or an empty variable, means the built-in
        defaults.
      - MaxPolicyUpdatesPerRun is a circuit breaker that aborts: when more
        policies would be patched than the cap, the run stops before the
        first write, in a dry run too, after writing the CSV. A number that
        large means the baseline or the scope changed, and a person should
        look before anything is written.
      - A read or a write that fails for one scope or one pair (HTTP 403
        included) is recorded as a Failed row and the run carries on. The
        failures are in the summary, the CSV, and the digest.
      - Only the three rules above are ever sent, only when they drift, and
        a policy is only patched when its id sits at the pair's own scope.
      - Overrides fail closed. When the baseline has any "roles" or "pairs"
        entry and a pair's role display name cannot be read (the
        eligibility has no expandedProperties and the policy assignment has
        no policyAssignmentProperties), the pair is a Failed row and is
        never written, so it is neither held to the defaults nor able to
        slip past report_only. A "roles" key that matches no role found in
        the sweep is logged as a warning, because it is probably misspelt.
      - A "pairs" entry whose scope is not found is logged as a warning and
        dropped: the identity cannot read that scope, so no swept pair can
        be at it. Any other lookup error stops the run before any PIM data
        is read. So do a name that matches two scopes, a management group
        named by id instead of display name, and two entries for one
        (scope, role).
      - Every approver group is resolved once by display name and its
        object id is pinned for the run. A baseline that requires approval
        somewhere with no approver group named for it stops the run before
        any call.
      - A scope name that does not resolve, or that matches both a
        management group and a subscription, stops the run before any PIM
        data is read.
      - Tokens are never logged or written (automation/lib/Runbook.Common.ps1).

    Permissions. The runbook runs as the PIM tier identity. That is the
    user-assigned managed identity that stacks/azure-automation gives the
    PIM runbooks, and ClientId selects it.
      Microsoft Graph application permissions on that identity:
        Group.Read.All  resolve the approver groups the baseline names
                        (only when it names any)
        Mail.Send       send the digest; restrict it to SenderMailbox with
                        an Exchange application access policy
                        (automation/README.md)
      Azure RBAC for that identity, at a management group that contains
      every ScopeNames scope (the corp cell assigns both roles at its root
      management group):
        Reader
          All the reads a dry run needs: eligibility schedule instances,
          policy assignments, policies, management groups, descendants,
          and subscriptions.
        PIM Policy Operator
          The custom role defined in tenants/azure/corp/azure-rbac-roles
          (stacks/azure-rbac-roles). A live run uses these actions from it:
            Microsoft.Authorization/roleManagementPolicies/read
            Microsoft.Authorization/roleManagementPolicies/write
            Microsoft.Authorization/roleManagementPolicies/approvalRule/action
            Microsoft.Authorization/roleManagementPolicyAssignments/read
            Microsoft.Authorization/roleEligibilityScheduleInstances/read
          The approvalRule action is listed separately in the operations
          reference as "Update Role Management policy approval rule".
          Those five are the whole role: it cannot create a role
          assignment or an eligibility. The wider custom role, PIM Policy
          and Eligibility Operator, exists only for
          Invoke-PimEligibilityRenewal with its Azure plane turned on. It
          adds roleEligibilityScheduleRequests/write, which makes its
          holder able to give any principal any role at the scope, Owner
          included, and this runbook never calls it: do not assign it to
          this runbook's tier.
      Do not grant Owner, User Access Administrator, or Role Based Access
      Control Administrator in place of the custom role. Each of them can
      grant roles, which this runbook never needs, and
      stacks/azure-automation refuses all three without a condition.

    Schedule. The corp cell (tenants/azure/corp/azure-automation) runs it
    daily at 05:00 UTC on its daily-0500-utc schedule. That is after the
    03:30 PIM eligibility renewal, so the sweep sees that night's renewals,
    and before the 05:15 Entra PIM drift run. A pull request that changes
    a declared pair in the azure-pim-governance cell must change the
    baseline variable's source in the same pull request, so both reach the
    tenant in the same release. Keep dry_run on for at least a week. A
    dry run sends no mail, so review each job's verbose "Would patch"
    lines, its "Baseline=" settings line, and its summary counts, plus the
    ReportPath CSV when the job writes one. The first live run patches
    what those dry runs listed, plus anything that drifted since.

    NIST SP 800-53 mapping, in plain words:
      CM-6(1)  Automated management, application, and verification of
               configuration settings: the activation settings of every
               eligible Azure role are verified daily and, when live,
               reapplied, with the RunId tying each PATCH to its summary.
      AC-2(7)  Privileged user accounts: activating a privileged role needs
               MFA, a justification, and approval where required, at every
               scope that has an eligibility, not only where a cell said so.

    Design rules shared by every runbook in this repository are in
    automation/README.md. The block between the two INLINE_LIBRARY marker
    lines below is replaced at deploy time with
    automation/lib/Runbook.Common.ps1, so the published runbook is one file.

.PARAMETER ScopeNames
    Management groups and subscriptions to sweep, as one string. In a job
    schedule, write a list separated by semicolons, such as
    "mg:Platform;sub:Identity Production" (commas also separate); a tenant
    cell writes it with join(";", [...]). A management group is matched by
    id, then by display name, and includes everything below it. A
    subscription is matched by display name. Prefix an entry with mg: or
    sub: to say which it is. Without a prefix both are looked up, and a
    name that matches both stops the run. A schedule cannot carry a display
    name that contains a comma or a semicolon, because the list splits it;
    sweep the management group above it instead. A comma or semicolon list
    that mixes prefixed and unprefixed entries is refused, because that
    usually means a name was split. A local run may use the JSON array
    form, ["sub:Example, Production","mg:Platform"], which keeps such a
    name whole. Never put the JSON array form in a schedule: the Automation
    service may parse it before binding. A value that starts with "@{" or
    "System.Object" stops the run.

.PARAMETER BaselineJson
    Optional, for local runs and tests. The rules to hold, as one JSON
    string. When set, it takes precedence over BaselineVariableName. Never
    set it in a job schedule: the Automation service may parse JSON before
    binding, and a value that starts with "@{" or "System.Object" (an
    object turned into text by parameter binding) stops the run. A
    scheduled job reads the same document from the Automation variable
    named by BaselineVariableName. When both are empty, the built-in
    baseline applies, which equals the stacks/azure-pim-governance
    defaults, in mode "minimum". The keys are the stack's variable names:

      {
        "mode": "minimum",
        "defaults": {
          "activation_maximum_duration": "PT4H",
          "require_multifactor_authentication": true,
          "require_justification": true,
          "require_ticket_info": false,
          "require_approval": false,
          "approver_groups": ["PIM Approvers"]
        },
        "roles": {
          "Contributor": { "activation_maximum_duration": "PT2H" },
          "Reader":      { "report_only": true }
        },
        "pairs": {
          "owner-at-root": {
            "role_name": "Owner",
            "scope": { "type": "management_group", "name": "Tenant Root" },
            "activation": { "maximum_duration": "PT1H", "require_approval": true, "approver_groups": ["Root Approvers"] }
          },
          "owner-at-app": {
            "role_name": "Owner",
            "scope": { "type": "resource_group", "name": "rg-app", "subscription": "Workloads" }
          }
        },
        "pairs_report_only": false
      }

    "mode" is "minimum" (the default: the baseline is a floor and a patch
    only tightens) or "exact" (any difference is drift, so a patch can
    loosen). "defaults" may set any subset; an unset or null key keeps the
    built-in value, and "approver_groups" falls back to ApproverGroupName.
    "roles" is keyed by role display name (case-insensitive), may set any
    subset plus "report_only", which reports drift and never patches, and
    applies to every pair of that role that has no "pairs" entry.

    "pairs" holds the (scope, role) pairs a tenant cell declares, as an
    array or as an object keyed by any label, with entries shaped like the
    stack's var.policies entries so a cell can pass the same map:
    "role_name"; "scope" with "type" (management_group or subscription,
    matched by display name, or resource_group, matched by name) and
    "name", plus "subscription", the subscription display name, for a
    resource_group (the runbook cannot see the provider's default
    subscription, so add it in the map passed here); "activation" with
    maximum_duration, require_multifactor_authentication,
    require_justification, require_ticket_info, require_approval, and
    approver_groups, where an unset or null value inherits "defaults" as in
    the module; and optionally "report_only". "eligible_assignment_rules"
    and "active_assignment_rules" are accepted and ignored. An entry
    applies to its own (scope, role) only and takes precedence over
    "roles". "pairs_report_only": true makes every pair entry report-only,
    which leaves the declared pairs entirely to Terraform.

    An unknown key, a duration that is not PT<n>H, PT<n>M, or PT<n>H<n>M, a
    flag that is not true or false, an approver_groups value that is not a
    list of names, approval required with no approver group, or a pair
    entry without role_name or a complete scope stops the run before any
    call. A management_group scope is matched by display name only, as the
    Terraform module matches it. In a tenant cell the document goes into
    the Automation variable, not into this parameter (see
    BaselineVariableName and the NOTES), holding the same values the PIM
    governance cell declares.

    The portal offers activation windows of 1 to 24 hours; the format check
    matches modules/azure/pim-role-policy and leaves the range to ARM, so a
    value outside it shows up as a Failed row, not a silent skip. A role
    whose activation relies on a Conditional Access authentication context
    (AuthenticationContext_EndUser_Assignment, which this runbook never
    changes) is reported and not patched while the baseline asks for MFA;
    give it an entry with "require_multifactor_authentication": false or
    "report_only": true to settle it.

.PARAMETER BaselineVariableName
    Name of the Azure Automation string variable that holds the baseline,
    the same JSON document BaselineJson describes. Default
    PimPolicy_AzureBaseline. It is read only when BaselineJson is empty,
    with the library's Get-AutomationStringVariable. That function works
    inside Azure Automation and on a Hybrid Runbook Worker, so a local run
    passes -BaselineJson instead. Precedence: BaselineJson, then this
    variable, then the built-in defaults. Pass an empty name to hold every
    pair to the built-in defaults; an empty variable value does the same.
    The run logs either case. A variable that does not exist or cannot be
    read, a value that is not JSON, and a value that starts with "@{" or
    "System.Object" all stop the run before any call.

.PARAMETER ApproverGroupName
    Display name of the Entra security group that approves activations
    where the baseline requires approval and names no approver_groups of
    its own: the fallback for "defaults" "approver_groups". When BaselineJson
    sets defaults.approver_groups, leave this empty or name one of those
    groups. Every approver group named anywhere is resolved to an object id
    once and pinned for the run. Approval required somewhere with no group
    named for it stops the run before any call.

.PARAMETER Recipients
    Mail addresses that receive the digest, as one string. In a job
    schedule, write a list separated by semicolons, such as
    "iam@corp.example.com;secops@corp.example.com" (commas also separate).
    The JSON array form, ["iam@corp.example.com"], is for local runs only.
    Empty sends no digest. The digest goes out only when there is drift or
    a failure, and never in a dry run.

.PARAMETER SenderMailbox
    Shared mailbox the digest is sent from, as a user principal name.
    stacks/azure-automation injects it into every runbook. Required when
    Recipients is set.

.PARAMETER MaxPolicyUpdatesPerRun
    Circuit breaker. More planned policy updates than this aborts the run
    before any write, in a dry run too. Default 25; 0 makes the run
    report-only in effect but still fails loudly when there is drift.

.PARAMETER ReportPath
    Optional path for a CSV with one row per (scope, role) pair and one per
    failed scope. On an Automation worker use a path under $env:TEMP.

.PARAMETER DryRun
    Default $true. Policies are read and compared; nothing is patched and
    nothing is mailed, and every action is logged as "Would ...". The
    circuit breaker is still evaluated. Pass -DryRun:$false to act.

.PARAMETER Environment
    National cloud: Global (default) or USGov. Selects the ARM and Graph
    endpoints and the token audiences.

.PARAMETER ClientId
    Client ID of the PIM tier user-assigned managed identity, passed to the
    Automation identity endpoint. stacks/azure-automation injects it.

.PARAMETER AccessToken
    Local testing only. Either one token used for every call, or a JSON
    object string with "Arm" and "Graph" keys, because this runbook calls
    both APIs. Never logged. When set, the identity endpoint and Az.Accounts
    are not used.

.PARAMETER RunId
    Correlation ID stamped on every log line and on the summary. Defaults
    to a new GUID.

.EXAMPLE
    # Dry run from a workstation with Azure CLI tokens for ARM and Graph.
    $tokens = @{
        Arm   = (az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv)
        Graph = (az account get-access-token --resource-type ms-graph --query accessToken -o tsv)
    } | ConvertTo-Json -Compress
    $baseline = '{"mode":"minimum","pairs":[{"role_name":"Owner","scope":{"type":"management_group","name":"Platform"},"activation":{"maximum_duration":"PT1H","require_approval":true}}]}'
    .\Invoke-AzurePimPolicyGovernance.ps1 -ScopeNames 'mg:Platform' -ApproverGroupName 'PIM Approvers' -BaselineJson $baseline -AccessToken $tokens -ReportPath .\out\pim-policies.csv

.EXAMPLE
    # Dry run from a workstation with the baseline file the stack publishes as the variable.
    $tokens = @{
        Arm   = (az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv)
        Graph = (az account get-access-token --resource-type ms-graph --query accessToken -o tsv)
    } | ConvertTo-Json -Compress
    .\Invoke-AzurePimPolicyGovernance.ps1 -ScopeNames 'mg:Platform;sub:Identity Production' -BaselineJson (Get-Content -Raw -Path .\azure-pim-baseline.json) -AccessToken $tokens

.EXAMPLE
    # Dry run of one subscription with the built-in baseline and one ARM token.
    $arm = az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv
    .\Invoke-AzurePimPolicyGovernance.ps1 -ScopeNames 'sub:Identity Production' -BaselineVariableName '' -AccessToken $arm

.EXAMPLE
    # What a live job in Azure Automation receives from its schedule. The
    # baseline comes from the Automation variable PimPolicy_AzureBaseline.
    .\Invoke-AzurePimPolicyGovernance.ps1 -ScopeNames 'mg:Platform' -BaselineVariableName 'PimPolicy_AzureBaseline' -Recipients 'iam@corp.example.com;secops@corp.example.com' -SenderMailbox iam-noreply@corp.example.com -DryRun:$false -ClientId <identity client id>

.NOTES
    Windows PowerShell 5.1 and PowerShell 7 compatible; no modules required.

    Endpoints, verified on learn.microsoft.com (Azure Authorization REST
    reference 2020-10-01, the PIM REST samples, Management Groups 2020-05-01):
      GET   {scope}/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01
      GET   {scope}/providers/Microsoft.Authorization/roleManagementPolicyAssignments?api-version=2020-10-01
      GET   {scope}/providers/Microsoft.Authorization/roleManagementPolicies/{name}?api-version=2020-10-01
      PATCH {scope}/providers/Microsoft.Authorization/roleManagementPolicies/{name}?api-version=2020-10-01
      GET   providers/Microsoft.Management/managementGroups/{id}/descendants?api-version=2020-05-01
      plus the library's management group, subscription, group, and sendMail calls.
    The policy assignment list is first asked with
    $filter=roleDefinitionId eq '{scope}/providers/Microsoft.Authorization/roleDefinitions/{guid}',
    the form the PIM REST sample documents for the role management policies
    list. The assignments reference does not document a filter, so every
    result is checked on the client and the unfiltered list is the fallback.

    Tenant cell entries (stacks/azure-automation). List values are
    semicolon strings. The baseline is not a parameter: the stack
    publishes it as the Automation string variable PimPolicy_AzureBaseline,
    and the schedule passes only that name. desired_state_files is the
    stack input that publishes a repository JSON file as a string
    variable. Here the file holds the document BaselineJson describes,
    with the values the azure-pim-governance cell declares (docs/adr/0015):
      desired_state_files = {
        PimPolicy_AzureBaseline = "policies/azure/pim-governance/corp-baseline.json"
      }
      runbooks = {
        azure-pim-policy-governance = {
          name         = "Invoke-AzurePimPolicyGovernance"
          file         = "Invoke-AzurePimPolicyGovernance.ps1"
          library      = "Runbook.Common.ps1"
          schedule_key = "daily-0500-utc"
          parameters = {
            scopenames             = join(";", ["mg:mg-example-root"])
            baselinevariablename   = "PimPolicy_AzureBaseline"
            recipients             = join(";", ["iam@corp.example.com"])
            maxpolicyupdatesperrun = "25"
          }
        }
      }
    with a baseline file such as:
      {
        "mode": "minimum",
        "defaults": { "activation_maximum_duration": "PT4H", "require_approval": false },
        "pairs": {
          "owner-at-root": {
            "role_name": "Owner",
            "scope": { "type": "management_group", "name": "mg-example-root" },
            "activation": { "maximum_duration": "PT1H", "require_approval": true, "approver_groups": ["PIM Approvers"] }
          }
        },
        "pairs_report_only": false
      }
    The stack adds clientid, environment, sendermailbox, and dryrun. No
    list element may contain a semicolon or a comma.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ScopeNames,

    [string]$BaselineJson = '',

    [string]$BaselineVariableName = 'PimPolicy_AzureBaseline',

    [string]$ApproverGroupName = '',

    [string]$Recipients = '',

    [string]$SenderMailbox = '',

    [ValidateRange(0, 10000)]
    [int]$MaxPolicyUpdatesPerRun = 25,

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
# Constants. The api-versions are the ones the learn.microsoft.com references
# document for these operations; see the NOTES in the header.
# ---------------------------------------------------------------------------

$script:PimArmApiVersion = '2020-10-01'
$script:PimManagementGroupsApiVersion = '2020-05-01'
$script:PimAssignmentCache = @{}
$script:PimManagementGroupList = $null
$script:PimDefaultBaselineVariableName = 'PimPolicy_AzureBaseline'
# How PowerShell writes an object that was converted to a string: what a
# [string] parameter receives when the Automation service parsed a JSON value
# before binding it.
$script:PimConvertedTextMarkers = @('@{', 'System.Object', 'System.Collections.')
$script:PimRuleIds = [ordered]@{
    Expiration = 'Expiration_EndUser_Assignment'
    Enablement = 'Enablement_EndUser_Assignment'
    Approval   = 'Approval_EndUser_Assignment'
}
$script:PimAuthenticationContextRuleId = 'AuthenticationContext_EndUser_Assignment'
$script:PimBaselineKeys = @(
    'activation_maximum_duration',
    'require_multifactor_authentication',
    'require_justification',
    'require_ticket_info',
    'require_approval'
)
# A pairs entry's "activation" keys (the stack's var.policies names) and the
# baseline keys they set.
$script:PimActivationKeyMap = [ordered]@{
    maximum_duration                   = 'activation_maximum_duration'
    require_multifactor_authentication = 'require_multifactor_authentication'
    require_justification              = 'require_justification'
    require_ticket_info                = 'require_ticket_info'
    require_approval                   = 'require_approval'
    approver_groups                    = 'approver_groups'
}
$script:PimReportColumns = @(
    'Scope', 'ScopeLevel', 'RoleName', 'RoleDefinitionId', 'PolicyId', 'Principals', 'Eligibilities',
    'Baseline', 'Mode', 'Status', 'DriftedRules', 'Drift', 'Outcome', 'Detail'
)

# ---------------------------------------------------------------------------
# Small helpers. Pure: no calls, no logging.
# ---------------------------------------------------------------------------

function Get-PimValue {
    <#
    .SYNOPSIS
        The value at a dotted property path, or $null when any step is missing.
    .DESCRIPTION
        Works on objects from ConvertFrom-Json and on dictionaries. An array
        value is written to the pipeline item by item; use Get-PimList for
        lists.
    .PARAMETER Object
        The object to read.
    .PARAMETER Path
        Dotted path, for example properties.scope.
    .EXAMPLE
        Get-PimValue -Object $instance -Path 'properties.memberType'
    #>
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $current = $Object
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            if ($current.Contains($segment)) { $current = $current[$segment] } else { return $null }
            continue
        }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return $null }
        $current = $property.Value
    }
    return $current
}

function Get-PimList {
    <#
    .SYNOPSIS
        The non-null items of a list at a dotted path, written to the pipeline.
    .PARAMETER Object
        The object to read.
    .PARAMETER Path
        Dotted path to the list.
    .EXAMPLE
        $enabled = @(Get-PimList -Object $rule -Path 'enabledRules')
    #>
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $value = Get-PimValue -Object $Object -Path $Path
    foreach ($item in @($value)) {
        if ($null -ne $item) { $item }
    }
}

function Set-PimProperty {
    <#
    .SYNOPSIS
        Sets a property on an object, adding it when it does not exist.
    .PARAMETER Object
        The object to change.
    .PARAMETER Name
        Property name.
    .PARAMETER Value
        New value. Arrays are stored as they are.
    .EXAMPLE
        Set-PimProperty -Object $rule -Name 'maximumDuration' -Value 'PT4H'
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Value
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { $property.Value = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Copy-PimObject {
    <#
    .SYNOPSIS
        A deep copy of a JSON-shaped object, as PSCustomObjects.
    .PARAMETER Value
        Object or hashtable. $null returns $null.
    .EXAMPLE
        $copy = Copy-PimObject -Value $rule
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    return (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 20 -Compress))
}

function Test-PimJsonObject {
    <#
    .SYNOPSIS
        True only for a JSON object as ConvertFrom-Json returns it.
    .DESCRIPTION
        The [PSCustomObject] accelerator names PSObject, so "-is [PSCustomObject]"
        is also true for a JSON array that Windows PowerShell 5.1 returns
        wrapped in a PSObject. The full type name tests the object itself.
    .PARAMETER Value
        The parsed value.
    .EXAMPLE
        Test-PimJsonObject -Value (ConvertFrom-Json -InputObject '{"a":1}')
    #>
    param([AllowNull()][object]$Value)

    return ($null -ne $Value -and $Value -is [System.Management.Automation.PSCustomObject])
}

function Assert-PimTextNotConverted {
    <#
    .SYNOPSIS
        Throws when a value is the text PowerShell makes of an object ("@{...}",
        "System.Object[]", "System.Collections...") rather than the JSON or
        list that was set.
    .DESCRIPTION
        The Automation service may parse a JSON-looking job parameter before
        binding it. Bound to a [string], a parsed object becomes "@{key=value}"
        and a parsed array can become "System.Object[]". Neither is what
        the cell set, and neither must be read as configuration, so the run
        stops and says where the value belongs. Blank input passes.
    .PARAMETER Value
        The raw text.
    .PARAMETER Label
        What the text is, for example BaselineJson.
    .PARAMETER Reason
        How the text most likely got that way. Default: parameter binding.
    .PARAMETER Remedy
        What to do instead.
    .EXAMPLE
        Assert-PimTextNotConverted -Value $BaselineJson -Label 'BaselineJson' -Remedy (Get-PimBaselineRemedy)
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label,
        [string]$Reason = 'The Automation service parsed the JSON value that was set, and parameter binding converted the result to a string.',
        [Parameter(Mandatory = $true)][string]$Remedy
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    $text = $Value.TrimStart()
    foreach ($marker in $script:PimConvertedTextMarkers) {
        if ($text.StartsWith($marker, [StringComparison]::Ordinal)) {
            throw ('{0} starts with "{1}", which is how PowerShell writes an object converted to a string, not JSON or a list. {2} {3}' -f $Label, $marker, $Reason, $Remedy)
        }
    }
}

function ConvertTo-PimBool {
    <#
    .SYNOPSIS
        A service value read as a boolean: only $true or the text "true" is true.
    .PARAMETER Value
        The value.
    .EXAMPLE
        ConvertTo-PimBool -Value $setting.isApprovalRequired
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    return ([string]$Value).Trim().Equals('true', [StringComparison]::OrdinalIgnoreCase)
}

function Format-PimBool {
    <#
    .SYNOPSIS
        "true" or "false", for drift text and the CSV.
    .PARAMETER Value
        The boolean.
    .EXAMPLE
        Format-PimBool -Value $true
    #>
    param([bool]$Value)

    if ($Value) { return 'true' }
    return 'false'
}

function Test-PimActivationDuration {
    <#
    .SYNOPSIS
        True when a value is an activation window the pim-role-policy module
        accepts: PT<n>H, PT<n>M, or PT<n>H<n>M.
    .PARAMETER Value
        The text.
    .EXAMPLE
        Test-PimActivationDuration -Value 'PT4H'
    #>
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $text = $Value.Trim().ToUpperInvariant()
    return ($text -cmatch '^PT([0-9]+H)?([0-9]+M)?$' -and $text -ne 'PT')
}

function ConvertFrom-PimIsoDuration {
    <#
    .SYNOPSIS
        An ISO 8601 duration as a TimeSpan, or $null when it does not parse.
    .PARAMETER Value
        The duration, for example PT4H or PT240M.
    .EXAMPLE
        (ConvertFrom-PimIsoDuration -Value 'PT240M').TotalHours
    #>
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    try { return [System.Xml.XmlConvert]::ToTimeSpan($Value.Trim().ToUpperInvariant()) }
    catch { return $null }
}

# ---------------------------------------------------------------------------
# Baseline. Same names and defaults as stacks/azure-pim-governance.
# ---------------------------------------------------------------------------

function Get-PimDefaultBaseline {
    <#
    .SYNOPSIS
        The built-in baseline: the stacks/azure-pim-governance defaults.
    .DESCRIPTION
        activation_maximum_duration PT4H, MFA and justification required,
        ticket information not required, approval not required, no approver
        groups. Keep these equal to the stack's variables.tf so the runbook
        and Terraform agree on every pair that inherits the stack defaults.
    .EXAMPLE
        (Get-PimDefaultBaseline)['activation_maximum_duration']
    #>
    return [ordered]@{
        activation_maximum_duration        = 'PT4H'
        require_multifactor_authentication = $true
        require_justification              = $true
        require_ticket_info                = $false
        require_approval                   = $false
        approver_groups                    = [string[]]@()
    }
}

function ConvertTo-PimApproverGroupList {
    <#
    .SYNOPSIS
        Validates an approver_groups value and returns its group names.
    .DESCRIPTION
        The value must be a JSON array of non-empty strings. Names are
        trimmed and duplicates (case-insensitive) are dropped. The result is
        always a string array, possibly empty; whether empty is acceptable
        is decided by Assert-PimBaselineApprovers.
    .PARAMETER Value
        The parsed JSON value.
    .PARAMETER Label
        Where it came from, for error messages.
    .EXAMPLE
        $names = ConvertTo-PimApproverGroupList -Value $parsed.defaults.approver_groups -Label 'defaults'
    #>
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($null -eq $Value -or $Value -is [string] -or (Test-PimJsonObject -Value $Value) -or -not ($Value -is [System.Collections.IEnumerable])) {
        throw ('BaselineJson {0}.approver_groups must be a JSON array of group display names.' -f $Label)
    }
    $names = New-Object System.Collections.ArrayList
    foreach ($item in $Value) {
        if (-not ($item -is [string]) -or [string]::IsNullOrWhiteSpace($item)) {
            throw ('BaselineJson {0}.approver_groups must hold non-empty group display names only.' -f $Label)
        }
        $name = $item.Trim()
        if (-not ($names -contains $name)) { [void]$names.Add($name) }
    }
    return , ([string[]]$names.ToArray())
}

function ConvertTo-PimBaselineValues {
    <#
    .SYNOPSIS
        Validates one baseline object ("defaults", one role override, or the
        "activation" of one pair entry) and returns its values as a
        hashtable keyed by the baseline key names.
    .DESCRIPTION
        A null value is treated as unset, as Terraform treats an unset
        optional attribute, so jsonencode() output can be passed as it is.
    .PARAMETER Value
        The parsed JSON object.
    .PARAMETER Label
        Where it came from, for error messages.
    .PARAMETER AllowReportOnly
        Accept "report_only" (role overrides only).
    .PARAMETER KeyMap
        Accepted key names mapped to baseline key names. Default: the
        baseline key names plus approver_groups, unmapped.
    .EXAMPLE
        ConvertTo-PimBaselineValues -Value $parsed.defaults -Label 'defaults'
    #>
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Label,
        [bool]$AllowReportOnly = $false,
        [AllowNull()][System.Collections.IDictionary]$KeyMap = $null
    )

    if (-not (Test-PimJsonObject -Value $Value)) { throw ('BaselineJson {0} must be a JSON object.' -f $Label) }
    $allowed = @($script:PimBaselineKeys) + @('approver_groups')
    if ($null -ne $KeyMap) { $allowed = @($KeyMap.Keys) }
    if ($AllowReportOnly) { $allowed += 'report_only' }

    $values = @{}
    foreach ($property in $Value.PSObject.Properties) {
        $name = $property.Name.ToLowerInvariant()
        if ($allowed -notcontains $name) {
            throw ('BaselineJson {0} has an unknown key "{1}". Allowed: {2}.' -f $Label, $property.Name, ($allowed -join ', '))
        }
        $item = $property.Value
        if ($null -eq $item) { continue }
        $key = $name
        if ($null -ne $KeyMap -and $KeyMap.Contains($name)) { $key = [string]$KeyMap[$name] }

        if ($key -eq 'activation_maximum_duration') {
            if (-not ($item -is [string]) -or -not (Test-PimActivationDuration -Value $item)) {
                throw ('BaselineJson {0}.{1} must be an ISO 8601 time duration such as "PT4H" or "PT30M".' -f $Label, $name)
            }
            $values[$key] = $item.Trim().ToUpperInvariant()
        }
        elseif ($key -eq 'approver_groups') {
            $values[$key] = ConvertTo-PimApproverGroupList -Value $item -Label $Label
        }
        else {
            if (-not ($item -is [bool])) { throw ('BaselineJson {0}.{1} must be true or false.' -f $Label, $name) }
            $values[$key] = [bool]$item
        }
    }
    return $values
}

function ConvertFrom-PimPairEntry {
    <#
    .SYNOPSIS
        Validates one "pairs" entry and returns it with its activation
        values under the baseline key names. The scope is resolved later,
        by Resolve-PimPairEntries.
    .DESCRIPTION
        The entry has the shape of a stacks/azure-pim-governance var.policies
        entry: role_name, scope { type, name }, and activation, plus an
        optional report_only. A resource_group scope also needs
        "subscription", the display name of its subscription.
        eligible_assignment_rules and active_assignment_rules are accepted
        and ignored, because this runbook does not govern them.
    .PARAMETER Value
        The parsed JSON object.
    .PARAMETER Label
        Where it came from, for example pairs."owner-at-root".
    .EXAMPLE
        ConvertFrom-PimPairEntry -Value $entry -Label 'pairs[0]'
    #>
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not (Test-PimJsonObject -Value $Value)) { throw ('BaselineJson {0} must be a JSON object.' -f $Label) }
    $allowed = @('role_name', 'scope', 'activation', 'report_only', 'eligible_assignment_rules', 'active_assignment_rules')
    $roleName = ''
    $scope = $null
    $values = @{}
    $reportOnly = $false
    foreach ($property in $Value.PSObject.Properties) {
        $name = $property.Name.ToLowerInvariant()
        if ($allowed -notcontains $name) {
            throw ('BaselineJson {0} has an unknown key "{1}". Allowed: {2}.' -f $Label, $property.Name, ($allowed -join ', '))
        }
        $item = $property.Value
        if ($name -eq 'role_name') {
            if ($item -is [string]) { $roleName = $item.Trim() }
        }
        elseif ($name -eq 'scope') {
            $scope = $item
        }
        elseif ($name -eq 'activation') {
            if ($null -ne $item) { $values = ConvertTo-PimBaselineValues -Value $item -Label ($Label + '.activation') -KeyMap $script:PimActivationKeyMap }
        }
        elseif ($name -eq 'report_only') {
            if ($null -ne $item) {
                if (-not ($item -is [bool])) { throw ('BaselineJson {0}.report_only must be true or false.' -f $Label) }
                $reportOnly = [bool]$item
            }
        }
    }
    if (-not $roleName) { throw ('BaselineJson {0}.role_name must be a role display name.' -f $Label) }
    if (-not (Test-PimJsonObject -Value $scope)) { throw ('BaselineJson {0}.scope must be an object with "type" and "name".' -f $Label) }

    $scopeValues = @{ type = ''; name = ''; subscription = '' }
    foreach ($property in $scope.PSObject.Properties) {
        $name = $property.Name.ToLowerInvariant()
        if (-not $scopeValues.ContainsKey($name)) {
            throw ('BaselineJson {0}.scope has an unknown key "{1}". Allowed: type, name, subscription.' -f $Label, $property.Name)
        }
        if ($null -eq $property.Value) { continue }
        if (-not ($property.Value -is [string])) { throw ('BaselineJson {0}.scope.{1} must be a string.' -f $Label, $name) }
        $scopeValues[$name] = $property.Value.Trim()
    }
    $scopeType = $scopeValues['type'].ToLowerInvariant()
    if (@('management_group', 'subscription', 'resource_group') -notcontains $scopeType) {
        throw ('BaselineJson {0}.scope.type must be "management_group", "subscription", or "resource_group".' -f $Label)
    }
    if (-not $scopeValues['name']) { throw ('BaselineJson {0}.scope.name must be set.' -f $Label) }
    if ($scopeType -eq 'resource_group' -and -not $scopeValues['subscription']) {
        throw ('BaselineJson {0}.scope needs "subscription", the display name of the subscription that holds resource group "{1}". The runbook cannot see the Terraform provider''s default subscription.' -f $Label, $scopeValues['name'])
    }
    if ($scopeType -ne 'resource_group' -and $scopeValues['subscription']) {
        throw ('BaselineJson {0}.scope.subscription applies to a resource_group scope only.' -f $Label)
    }

    return [PSCustomObject]@{
        Label             = $Label
        RoleName          = $roleName
        ScopeType         = $scopeType
        ScopeName         = $scopeValues['name']
        ScopeSubscription = $scopeValues['subscription']
        Values            = $values
        ReportOnly        = $reportOnly
        Scope             = ''
        Key               = ''
    }
}

function ConvertFrom-PimBaselineJson {
    <#
    .SYNOPSIS
        Parses and validates BaselineJson.
    .DESCRIPTION
        Returns an object with Mode ("minimum" or "exact"), Defaults (the
        built-in baseline with any "defaults" values applied, including
        approver_groups), Roles (a case-insensitive table of role display
        name to override values), PairEntries (the validated "pairs"
        entries), Pairs (filled by Resolve-PimPairEntries, keyed by resolved
        scope and role name), HasOverrides, and Source (a short description
        for the log). Empty input returns the built-in baseline in mode
        minimum. Any problem throws before the run makes a call.
    .PARAMETER Json
        The baseline document: the BaselineJson parameter or the text of the
        baseline Automation variable (Resolve-PimBaselineText).
    .PARAMETER DefaultApproverGroupName
        The ApproverGroupName parameter: the default approver group when
        "defaults" sets no approver_groups. When "defaults" does set them,
        it must be empty or one of them.
    .PARAMETER Origin
        Where the document came from, for Source. Empty means "BaselineJson"
        for a document and "built-in stack defaults" for empty input.
    .EXAMPLE
        $baseline = ConvertFrom-PimBaselineJson -Json '{"roles":{"Owner":{"require_approval":true}}}' -DefaultApproverGroupName 'PIM Approvers'
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Json,
        [AllowNull()][AllowEmptyString()][string]$DefaultApproverGroupName = '',
        [AllowNull()][AllowEmptyString()][string]$Origin = ''
    )

    $defaults = Get-PimDefaultBaseline
    $roles = @{}
    $pairEntries = New-Object System.Collections.ArrayList
    $mode = 'minimum'
    $pairsReportOnly = $false
    $jsonApprovers = $null
    $sourceLabel = 'built-in stack defaults'
    $text = ''
    if ($null -ne $Json) { $text = $Json.Trim() }

    if ($text.Length -gt 0) {
        $sourceLabel = 'BaselineJson'
        Assert-PimTextNotConverted -Value $text -Label 'BaselineJson' -Remedy (Get-PimBaselineRemedy)
        $parsed = $null
        try { $parsed = ConvertFrom-Json -InputObject $text }
        catch { throw ('BaselineJson does not parse as JSON: {0}' -f (Protect-RunbookText -Text $_.Exception.Message -MaxLength 200)) }
        if (-not (Test-PimJsonObject -Value $parsed)) { throw 'BaselineJson must be a JSON object with "mode", "defaults", "roles", "pairs", or "pairs_report_only".' }

        foreach ($property in $parsed.PSObject.Properties) {
            $name = $property.Name.ToLowerInvariant()
            $item = $property.Value
            if ($name -eq 'mode') {
                if ($null -eq $item) { continue }
                if (-not ($item -is [string])) { throw 'BaselineJson "mode" must be "minimum" or "exact".' }
                $mode = $item.Trim().ToLowerInvariant()
                if (@('minimum', 'exact') -notcontains $mode) { throw ('BaselineJson "mode" "{0}" is not valid. Use "minimum" or "exact".' -f $item) }
            }
            elseif ($name -eq 'defaults') {
                $values = ConvertTo-PimBaselineValues -Value $item -Label 'defaults'
                foreach ($key in @($values.Keys)) {
                    if ($key -eq 'approver_groups') { $jsonApprovers = $values[$key] }
                    else { $defaults[$key] = $values[$key] }
                }
            }
            elseif ($name -eq 'roles') {
                if (-not (Test-PimJsonObject -Value $item)) { throw 'BaselineJson "roles" must be a JSON object keyed by role display name.' }
                foreach ($roleProperty in $item.PSObject.Properties) {
                    $roleName = $roleProperty.Name.Trim()
                    if ($roleName.Length -eq 0) { throw 'BaselineJson "roles" has an empty role name.' }
                    if ($roles.ContainsKey($roleName)) { throw ('BaselineJson "roles" names "{0}" twice.' -f $roleName) }
                    $roles[$roleName] = ConvertTo-PimBaselineValues -Value $roleProperty.Value -Label ('roles."{0}"' -f $roleName) -AllowReportOnly $true
                }
            }
            elseif ($name -eq 'pairs') {
                if ($null -eq $item) { continue }
                if (Test-PimJsonObject -Value $item) {
                    foreach ($pairProperty in $item.PSObject.Properties) {
                        [void]$pairEntries.Add((ConvertFrom-PimPairEntry -Value $pairProperty.Value -Label ('pairs."{0}"' -f $pairProperty.Name)))
                    }
                }
                elseif ($item -is [System.Collections.IEnumerable] -and -not ($item -is [string])) {
                    $index = 0
                    foreach ($pairItem in $item) {
                        [void]$pairEntries.Add((ConvertFrom-PimPairEntry -Value $pairItem -Label ('pairs[{0}]' -f $index)))
                        $index++
                    }
                }
                else {
                    throw 'BaselineJson "pairs" must be a JSON array of pair entries, or an object of them keyed by label.'
                }
            }
            elseif ($name -eq 'pairs_report_only') {
                if ($null -eq $item) { continue }
                if (-not ($item -is [bool])) { throw 'BaselineJson "pairs_report_only" must be true or false.' }
                $pairsReportOnly = [bool]$item
            }
            else {
                throw ('BaselineJson has an unknown top-level key "{0}". Allowed: mode, defaults, roles, pairs, pairs_report_only.' -f $property.Name)
            }
        }
    }

    $fallback = ''
    if ($null -ne $DefaultApproverGroupName) { $fallback = $DefaultApproverGroupName.Trim() }
    if ($null -ne $jsonApprovers) {
        if ($fallback -and -not (@($jsonApprovers) -contains $fallback)) {
            throw ('ApproverGroupName "{0}" is not one of BaselineJson defaults.approver_groups ({1}). Name the default approver groups in one place.' -f $fallback, (@($jsonApprovers) -join ', '))
        }
        $defaults['approver_groups'] = [string[]]@($jsonApprovers)
    }
    elseif ($fallback) {
        $defaults['approver_groups'] = [string[]]@($fallback)
    }
    if ($pairsReportOnly) {
        foreach ($entry in $pairEntries) { $entry.ReportOnly = $true }
    }

    if (-not [string]::IsNullOrWhiteSpace($Origin)) { $sourceLabel = $Origin.Trim() }
    $source = Format-PimBaselineSource -Origin $sourceLabel -Defaults $defaults -RoleCount $roles.Count -PairCount $pairEntries.Count -Mode $mode
    return [PSCustomObject]@{
        Mode            = $mode
        Defaults        = $defaults
        Roles           = $roles
        PairEntries     = [object[]]$pairEntries.ToArray()
        Pairs           = @{}
        PairsReportOnly = $pairsReportOnly
        HasOverrides    = ($roles.Count -gt 0 -or $pairEntries.Count -gt 0)
        ApproversInJson = ($null -ne $jsonApprovers)
        Source          = $source
    }
}

function Format-PimBaselineSource {
    <#
    .SYNOPSIS
        One line describing the baseline in force, for the log and the summary.
    .PARAMETER Origin
        Where the baseline came from.
    .PARAMETER Defaults
        The default values.
    .PARAMETER RoleCount
        Number of role overrides.
    .PARAMETER PairCount
        Number of pair entries.
    .PARAMETER Mode
        minimum or exact.
    .EXAMPLE
        Format-PimBaselineSource -Origin 'BaselineJson' -Defaults (Get-PimDefaultBaseline) -RoleCount 2 -PairCount 3 -Mode minimum
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Origin,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Defaults,
        [int]$RoleCount = 0,
        [int]$PairCount = 0,
        [string]$Mode = 'minimum'
    )

    return ('{0}: activation={1} mfa={2} justification={3} ticket={4} approval={5} approvers={6}; mode {7}; {8} role override(s), {9} pair override(s)' -f $Origin,
        $Defaults['activation_maximum_duration'],
        (Format-PimBool -Value ([bool]$Defaults['require_multifactor_authentication'])),
        (Format-PimBool -Value ([bool]$Defaults['require_justification'])),
        (Format-PimBool -Value ([bool]$Defaults['require_ticket_info'])),
        (Format-PimBool -Value ([bool]$Defaults['require_approval'])),
        @($Defaults['approver_groups'] | Where-Object { $_ }).Count,
        $Mode,
        $RoleCount,
        $PairCount)
}

function Get-PimBaselineRemedy {
    <#
    .SYNOPSIS
        The sentence that tells an operator where a baseline belongs.
    .PARAMETER VariableName
        The BaselineVariableName in force. Empty means the default name.
    .EXAMPLE
        Get-PimBaselineRemedy -VariableName 'PimPolicy_AzureBaseline'
    #>
    param([AllowNull()][AllowEmptyString()][string]$VariableName = '')

    $name = $script:PimDefaultBaselineVariableName
    if (-not [string]::IsNullOrWhiteSpace($VariableName)) { $name = $VariableName.Trim() }
    return ('A baseline cannot pass through a job schedule parameter: supply it through the Automation string variable named by BaselineVariableName ("{0}") and leave BaselineJson empty. BaselineJson is for local runs and tests only.' -f $name)
}

function Get-PimPairOverrideKey {
    <#
    .SYNOPSIS
        The key a pair override is stored under: normalised scope, a bar,
        and the role display name in lower case.
    .PARAMETER Scope
        ARM scope.
    .PARAMETER RoleName
        Role display name.
    .EXAMPLE
        Get-PimPairOverrideKey -Scope '/subscriptions/x' -RoleName 'Owner'
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Scope,
        [AllowNull()][AllowEmptyString()][string]$RoleName
    )

    $name = ''
    if ($null -ne $RoleName) { $name = $RoleName.Trim().ToLowerInvariant() }
    return ((ConvertTo-PimScopeKey -Scope $Scope) + '|' + $name)
}

function Get-PimEffectiveSettings {
    <#
    .SYNOPSIS
        The settings one (scope, role) pair is held to.
    .DESCRIPTION
        The pair's own "pairs" entry when there is one (defaults plus that
        entry, as the pim-role-policy module merges a policy entry), else
        the role's "roles" entry (defaults plus that override), else the
        defaults. Approver group names come from the same place, falling
        back to defaults.approver_groups, and are mapped to the object ids
        pinned for the run when ApproverGroupIds is given.
    .PARAMETER Baseline
        The object from ConvertFrom-PimBaselineJson.
    .PARAMETER RoleName
        Role display name. Empty or unknown uses the defaults.
    .PARAMETER Scope
        The pair's scope, for the "pairs" lookup. Empty skips it.
    .PARAMETER ApproverGroupIds
        Pinned object ids keyed by lower-case group display name. A needed
        name that is missing throws.
    .EXAMPLE
        Get-PimEffectiveSettings -Baseline $baseline -RoleName 'Owner' -Scope $pair.Scope -ApproverGroupIds $pinned
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Baseline,
        [AllowNull()][AllowEmptyString()][string]$RoleName = '',
        [AllowNull()][AllowEmptyString()][string]$Scope = '',
        [AllowNull()][System.Collections.IDictionary]$ApproverGroupIds = $null
    )

    $values = @{}
    foreach ($key in $script:PimBaselineKeys) { $values[$key] = $Baseline.Defaults[$key] }
    $values['approver_groups'] = $Baseline.Defaults['approver_groups']
    $reportOnly = $false
    $source = 'defaults'
    $name = ''
    if ($null -ne $RoleName) { $name = $RoleName.Trim() }

    $pairEntry = $null
    if ($name.Length -gt 0 -and -not [string]::IsNullOrWhiteSpace($Scope) -and $null -ne $Baseline.Pairs) {
        $pairKey = Get-PimPairOverrideKey -Scope $Scope -RoleName $name
        if ($Baseline.Pairs.ContainsKey($pairKey)) { $pairEntry = $Baseline.Pairs[$pairKey] }
    }

    if ($null -ne $pairEntry) {
        foreach ($key in @($pairEntry.Values.Keys)) { $values[$key] = $pairEntry.Values[$key] }
        $reportOnly = [bool]$pairEntry.ReportOnly
        $source = $pairEntry.Label
    }
    elseif ($name.Length -gt 0 -and $Baseline.Roles.ContainsKey($name)) {
        $override = $Baseline.Roles[$name]
        foreach ($key in @($override.Keys)) {
            if ($key -eq 'report_only') { $reportOnly = [bool]$override[$key] }
            else { $values[$key] = $override[$key] }
        }
        $source = 'roles."{0}"' -f $name
    }

    $approverNames = @(@($values['approver_groups']) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() })
    $approverIds = @()
    if ($null -ne $ApproverGroupIds) {
        foreach ($approverName in $approverNames) {
            $lookup = $approverName.ToLowerInvariant()
            if (-not $ApproverGroupIds.Contains($lookup)) { throw ('Approver group "{0}" was not resolved for this run.' -f $approverName) }
            $approverIds += [string]$ApproverGroupIds[$lookup]
        }
    }

    return [PSCustomObject]@{
        ActivationMaximumDuration        = [string]$values['activation_maximum_duration']
        RequireMultiFactorAuthentication = [bool]$values['require_multifactor_authentication']
        RequireJustification             = [bool]$values['require_justification']
        RequireTicketInfo                = [bool]$values['require_ticket_info']
        RequireApproval                  = [bool]$values['require_approval']
        ApproverGroupNames               = [string[]]$approverNames
        ApproverGroupIds                 = [string[]]$approverIds
        ReportOnly                       = $reportOnly
        Source                           = $source
    }
}

function Get-PimBaselineEntryList {
    <#
    .SYNOPSIS
        Every place in the baseline that states settings, as Label and
        Values, written to the pipeline: defaults, each role, each pair.
    .PARAMETER Baseline
        The object from ConvertFrom-PimBaselineJson.
    .EXAMPLE
        $entries = @(Get-PimBaselineEntryList -Baseline $baseline)
    #>
    param([Parameter(Mandatory = $true)][object]$Baseline)

    [PSCustomObject]@{ Label = 'defaults'; Values = $Baseline.Defaults }
    foreach ($name in @($Baseline.Roles.Keys | Sort-Object)) {
        [PSCustomObject]@{ Label = ('roles."{0}"' -f $name); Values = $Baseline.Roles[$name] }
    }
    foreach ($entry in @($Baseline.PairEntries)) {
        if ($null -eq $entry) { continue }
        [PSCustomObject]@{ Label = $entry.Label; Values = $entry.Values }
    }
}

function Test-PimBaselineRequiresApprover {
    <#
    .SYNOPSIS
        True when the defaults, any role override, or any pair entry
        require approval.
    .PARAMETER Baseline
        The object from ConvertFrom-PimBaselineJson.
    .EXAMPLE
        if (Test-PimBaselineRequiresApprover -Baseline $baseline) { 'an approver group is required' }
    #>
    param([Parameter(Mandatory = $true)][object]$Baseline)

    foreach ($entry in @(Get-PimBaselineEntryList -Baseline $Baseline)) {
        if ($entry.Values.Contains('require_approval') -and [bool]$entry.Values['require_approval']) { return $true }
    }
    return $false
}

function Assert-PimBaselineApprovers {
    <#
    .SYNOPSIS
        Throws when any place in the baseline requires approval but names no
        approver group, after inheritance from the defaults.
    .PARAMETER Baseline
        The object from ConvertFrom-PimBaselineJson.
    .EXAMPLE
        Assert-PimBaselineApprovers -Baseline $baseline
    #>
    param([Parameter(Mandatory = $true)][object]$Baseline)

    foreach ($entry in @(Get-PimBaselineEntryList -Baseline $Baseline)) {
        $required = [bool]$Baseline.Defaults['require_approval']
        if ($entry.Values.Contains('require_approval')) { $required = [bool]$entry.Values['require_approval'] }
        if (-not $required) { continue }

        $ownGroups = ($entry.Label -ne 'defaults' -and $entry.Values.Contains('approver_groups'))
        $groups = $Baseline.Defaults['approver_groups']
        if ($ownGroups) { $groups = $entry.Values['approver_groups'] }
        $named = @(@($groups) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($named.Count -gt 0) { continue }
        if ($ownGroups) {
            throw ('The baseline requires approval for {0} but its approver_groups is empty. Approval is never enabled without an approver group.' -f $entry.Label)
        }
        if ([bool](Get-PimValue -Object $Baseline -Path 'ApproversInJson')) {
            throw ('The baseline requires approval for {0} but names no approver group there: defaults.approver_groups is empty. Approval is never enabled without one.' -f $entry.Label)
        }
        throw ('The baseline requires approval for {0} but names no approver group there: ApproverGroupName is empty and approver_groups is not set. Approval is never enabled without one.' -f $entry.Label)
    }
}

function Get-PimApproverGroupNames {
    <#
    .SYNOPSIS
        Every distinct approver group display name the baseline names,
        written to the pipeline.
    .PARAMETER Baseline
        The object from ConvertFrom-PimBaselineJson.
    .EXAMPLE
        $names = @(Get-PimApproverGroupNames -Baseline $baseline)
    #>
    param([Parameter(Mandatory = $true)][object]$Baseline)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @(Get-PimBaselineEntryList -Baseline $Baseline)) {
        if (-not $entry.Values.Contains('approver_groups')) { continue }
        foreach ($name in @($entry.Values['approver_groups'])) {
            if ([string]::IsNullOrWhiteSpace([string]$name)) { continue }
            $trimmed = ([string]$name).Trim()
            if ($seen.Add($trimmed)) { $trimmed }
        }
    }
}

# ---------------------------------------------------------------------------
# Scopes and pairs. Pure.
# ---------------------------------------------------------------------------

function ConvertTo-PimScopeReference {
    <#
    .SYNOPSIS
        Splits a ScopeNames entry into its kind (ManagementGroup, Subscription,
        or Any) and name.
    .PARAMETER Value
        The entry, for example "mg:Platform" or "sub:Identity Production".
    .EXAMPLE
        (ConvertTo-PimScopeReference -Value 'sub:Identity Production').Kind
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $text = $Value.Trim()
    $kind = 'Any'
    $name = $text
    if ($text -match '^(mg|managementgroup)\s*:(.*)$') { $kind = 'ManagementGroup'; $name = $Matches[2] }
    elseif ($text -match '^(sub|subscription)\s*:(.*)$') { $kind = 'Subscription'; $name = $Matches[2] }
    $name = $name.Trim()
    if ($name.Length -eq 0) { throw ('ScopeNames entry "{0}" has no name.' -f $text) }
    return [PSCustomObject]@{ Kind = $kind; Name = $name; Text = $text }
}

function ConvertTo-PimScopeKey {
    <#
    .SYNOPSIS
        A scope normalised for comparison: leading slash, no trailing slash,
        lower case. Empty input returns an empty string.
    .PARAMETER Scope
        ARM scope.
    .EXAMPLE
        ConvertTo-PimScopeKey -Scope '/Subscriptions/ABC/'
    #>
    param([AllowNull()][AllowEmptyString()][string]$Scope)

    if ([string]::IsNullOrWhiteSpace($Scope)) { return '' }
    $text = $Scope.Trim().TrimEnd('/')
    if (-not $text.StartsWith('/')) { $text = '/' + $text }
    return $text.ToLowerInvariant()
}

function Test-PimScopeInSweep {
    <#
    .SYNOPSIS
        True when a scope is one of the swept scopes, or below a swept
        subscription.
    .DESCRIPTION
        A management group entry matches only itself (every descendant group
        and subscription is its own entry); a subscription entry matches
        itself and every resource group and resource under it. The
        comparison is on whole path segments, so /subscriptions/1 does not
        contain /subscriptions/12.
    .PARAMETER Scope
        The scope to test.
    .PARAMETER Allowed
        Entries with Scope and Kind (ManagementGroup or Subscription).
    .EXAMPLE
        Test-PimScopeInSweep -Scope $scope -Allowed @([PSCustomObject]@{ Scope = '/subscriptions/x'; Kind = 'Subscription' })
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Scope,
        [AllowNull()][object[]]$Allowed = @()
    )

    $key = ConvertTo-PimScopeKey -Scope $Scope
    if (-not $key) { return $false }
    foreach ($entry in @($Allowed)) {
        if ($null -eq $entry) { continue }
        $allowedKey = ConvertTo-PimScopeKey -Scope ([string]$entry.Scope)
        if (-not $allowedKey) { continue }
        if ($key -eq $allowedKey) { return $true }
        if ([string]$entry.Kind -eq 'Subscription' -and $key.StartsWith($allowedKey + '/')) { return $true }
    }
    return $false
}

function Get-PimScopeLevel {
    <#
    .SYNOPSIS
        Where a scope sits: ManagementGroup, Subscription, BelowSubscription
        (a resource group or a resource), or Other.
    .PARAMETER Scope
        ARM scope.
    .EXAMPLE
        Get-PimScopeLevel -Scope '/subscriptions/x/resourceGroups/rg'
    #>
    param([AllowNull()][AllowEmptyString()][string]$Scope)

    $key = ConvertTo-PimScopeKey -Scope $Scope
    if ($key -match '^/providers/microsoft\.management/managementgroups/[^/]+$') { return 'ManagementGroup' }
    if ($key -match '^/subscriptions/[^/]+$') { return 'Subscription' }
    if ($key -match '^/subscriptions/[^/]+/.+') { return 'BelowSubscription' }
    return 'Other'
}

function Test-PimJsonArrayText {
    <#
    .SYNOPSIS
        True when a list parameter is written as a JSON array (also when it
        is wrapped as a quoted JSON string), which is the only form that
        keeps a comma or a semicolon inside a name.
    .PARAMETER Text
        The raw parameter value.
    .EXAMPLE
        Test-PimJsonArrayText -Text '["sub:Example, Production"]'
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $value = $Text.Trim()
    if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
        try { $value = ([string](ConvertFrom-Json -InputObject $value)).Trim() }
        catch { return $false }
    }
    return $value.StartsWith('[')
}

function Get-PimRoleDefinitionGuid {
    <#
    .SYNOPSIS
        The role definition GUID at the end of a role definition id, in lower
        case, or an empty string.
    .DESCRIPTION
        The same role is written as /providers/..., /subscriptions/x/providers/...,
        or with a management group prefix depending on the API and scope;
        the GUID is the stable part.
    .PARAMETER RoleDefinitionId
        Role definition resource id.
    .EXAMPLE
        Get-PimRoleDefinitionGuid -RoleDefinitionId $instance.properties.roleDefinitionId
    #>
    param([AllowNull()][AllowEmptyString()][string]$RoleDefinitionId)

    if ([string]::IsNullOrWhiteSpace($RoleDefinitionId)) { return '' }
    if ($RoleDefinitionId.Trim() -match '/providers/Microsoft\.Authorization/roleDefinitions/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/?$') {
        return $Matches[1].ToLowerInvariant()
    }
    return ''
}

function ConvertTo-PimDescendantScope {
    <#
    .SYNOPSIS
        A management group descendants entry as a swept scope, or $null for
        any other type.
    .PARAMETER Entry
        One item of GET .../descendants.
    .EXAMPLE
        ConvertTo-PimDescendantScope -Entry $descendant
    #>
    param([AllowNull()][object]$Entry)

    if ($null -eq $Entry) { return $null }
    $type = [string](Get-PimValue -Object $Entry -Path 'type')
    $name = [string](Get-PimValue -Object $Entry -Path 'name')
    $id = [string](Get-PimValue -Object $Entry -Path 'id')
    if ([string]::IsNullOrWhiteSpace($name) -or $name -match '[/?#]') { return $null }

    if ($type.EndsWith('/subscriptions', [StringComparison]::OrdinalIgnoreCase)) {
        $scope = '/subscriptions/' + $name
        if ($id -match '^/subscriptions/[^/]+$') { $scope = $id }
        return [PSCustomObject]@{ Scope = $scope; Kind = 'Subscription' }
    }
    if ($type.Equals('Microsoft.Management/managementGroups', [StringComparison]::OrdinalIgnoreCase)) {
        $scope = '/providers/Microsoft.Management/managementGroups/' + $name
        if ($id -match '^/providers/Microsoft\.Management/managementGroups/[^/]+$') { $scope = $id }
        return [PSCustomObject]@{ Scope = $scope; Kind = 'ManagementGroup' }
    }
    return $null
}

function New-PimPairState {
    <#
    .SYNOPSIS
        The accumulator Add-PimEligibilityPairs fills across listings.
    .DESCRIPTION
        Pairs is keyed "<scope key>|<role guid>". SeenIds holds instance ids
        already counted, so an instance returned by a management group
        listing and again by its subscription's listing counts once.
    .EXAMPLE
        $state = New-PimPairState
    #>
    return [PSCustomObject]@{
        Pairs   = (New-Object System.Collections.Specialized.OrderedDictionary)
        SeenIds = (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))
        Read    = 0
        Direct  = 0
        Ignored = 0
    }
}

function Add-PimEligibilityPairs {
    <#
    .SYNOPSIS
        Reduces eligibility schedule instances to distinct (scope, role)
        pairs, keyed on each instance's own scope.
    .DESCRIPTION
        Keeps memberType Direct whose own scope is inside the sweep. Inherited
        and group-expanded instances, instances above or beside the sweep,
        and instances without a readable scope or role are counted as
        ignored. Returns the number of new pairs.
    .PARAMETER State
        The object from New-PimPairState.
    .PARAMETER Instances
        Items from roleEligibilityScheduleInstances.
    .PARAMETER Allowed
        The sweep entries for the listing (Test-PimScopeInSweep).
    .EXAMPLE
        Add-PimEligibilityPairs -State $state -Instances $items -Allowed $target.Allowed
    #>
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [AllowNull()][object[]]$Instances = @(),
        [AllowNull()][object[]]$Allowed = @()
    )

    $added = 0
    foreach ($instance in @($Instances)) {
        if ($null -eq $instance) { continue }
        $State.Read = $State.Read + 1

        $memberType = [string](Get-PimValue -Object $instance -Path 'properties.memberType')
        $scope = [string](Get-PimValue -Object $instance -Path 'properties.scope')
        $roleDefinitionId = [string](Get-PimValue -Object $instance -Path 'properties.roleDefinitionId')
        $roleGuid = Get-PimRoleDefinitionGuid -RoleDefinitionId $roleDefinitionId
        $scopeKey = ConvertTo-PimScopeKey -Scope $scope
        if ($memberType -ne 'Direct' -or -not $roleGuid -or -not $scopeKey -or -not (Test-PimScopeInSweep -Scope $scope -Allowed $Allowed)) {
            $State.Ignored = $State.Ignored + 1
            continue
        }

        $principalId = [string](Get-PimValue -Object $instance -Path 'properties.principalId')
        $instanceId = [string](Get-PimValue -Object $instance -Path 'id')
        if ([string]::IsNullOrWhiteSpace($instanceId)) { $instanceId = '{0}|{1}|{2}' -f $scopeKey, $roleGuid, $principalId }
        if (-not $State.SeenIds.Add($instanceId)) { continue }
        $State.Direct = $State.Direct + 1

        $key = $scopeKey + '|' + $roleGuid
        if (-not $State.Pairs.Contains($key)) {
            $State.Pairs[$key] = [PSCustomObject]@{
                Key              = $key
                Scope            = $scope.Trim().TrimEnd('/')
                RoleDefinitionId = $roleDefinitionId.Trim()
                RoleGuid         = $roleGuid
                RoleName         = ''
                Principals       = (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))
                Eligibilities    = 0
            }
            $added++
        }
        $pair = $State.Pairs[$key]
        $pair.Eligibilities = $pair.Eligibilities + 1
        if ($principalId) { [void]$pair.Principals.Add($principalId) }
        if (-not $pair.RoleName) {
            $pair.RoleName = [string](Get-PimValue -Object $instance -Path 'properties.expandedProperties.roleDefinition.displayName')
        }
    }
    return $added
}

function Select-PimPolicyAssignment {
    <#
    .SYNOPSIS
        The one role management policy assignment for a scope and role, or
        $null when there is none.
    .DESCRIPTION
        Checks each item's own properties.scope and role definition GUID, so
        the result is right whether or not the service applied the filter.
        More than one match throws.
    .PARAMETER Assignments
        Items from roleManagementPolicyAssignments.
    .PARAMETER Scope
        The pair's scope.
    .PARAMETER RoleGuid
        The pair's role definition GUID.
    .EXAMPLE
        Select-PimPolicyAssignment -Assignments $items -Scope $pair.Scope -RoleGuid $pair.RoleGuid
    #>
    param(
        [AllowNull()][object[]]$Assignments = @(),
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$RoleGuid
    )

    $scopeKey = ConvertTo-PimScopeKey -Scope $Scope
    $guid = $RoleGuid.ToLowerInvariant()
    $found = New-Object System.Collections.ArrayList
    foreach ($assignment in @($Assignments)) {
        if ($null -eq $assignment) { continue }
        $assignmentScope = ConvertTo-PimScopeKey -Scope ([string](Get-PimValue -Object $assignment -Path 'properties.scope'))
        $assignmentGuid = Get-PimRoleDefinitionGuid -RoleDefinitionId ([string](Get-PimValue -Object $assignment -Path 'properties.roleDefinitionId'))
        if ($assignmentScope -eq $scopeKey -and $assignmentGuid -eq $guid) { [void]$found.Add($assignment) }
    }
    if ($found.Count -gt 1) {
        throw ('{0} role management policy assignments match role {1} at {2}; expected exactly one.' -f $found.Count, $guid, $Scope)
    }
    if ($found.Count -eq 1) { return $found[0] }
    return $null
}

function Test-PimPolicyIdAtScope {
    <#
    .SYNOPSIS
        True when a policy id is a role management policy directly at the
        given scope.
    .DESCRIPTION
        The policy is only patched when this is true, so a malformed id, a
        path with dot segments, or a policy at another scope is never
        written.
    .PARAMETER PolicyId
        properties.policyId of the policy assignment.
    .PARAMETER Scope
        The pair's scope.
    .EXAMPLE
        Test-PimPolicyIdAtScope -PolicyId $policyId -Scope $pair.Scope
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$PolicyId,
        [Parameter(Mandatory = $true)][string]$Scope
    )

    if ([string]::IsNullOrWhiteSpace($PolicyId)) { return $false }
    $text = $PolicyId.Trim()
    if ($text -match '[?#\s]' -or $text -match '/\.\.?(/|$)') { return $false }
    $prefix = (ConvertTo-PimScopeKey -Scope $Scope) + '/providers/microsoft.authorization/rolemanagementpolicies/'
    if (-not $text.ToLowerInvariant().StartsWith($prefix)) { return $false }
    $name = $text.Substring($prefix.Length)
    return ($name -match '^[0-9A-Za-z_\-]+$')
}

# ---------------------------------------------------------------------------
# Drift and the PATCH body. Pure.
# ---------------------------------------------------------------------------

function Get-PimRuleById {
    <#
    .SYNOPSIS
        The rule with this id from a policy's rules, or $null.
    .PARAMETER Rules
        properties.rules of the policy.
    .PARAMETER RuleId
        For example Expiration_EndUser_Assignment.
    .EXAMPLE
        Get-PimRuleById -Rules $rules -RuleId 'Approval_EndUser_Assignment'
    #>
    param(
        [AllowNull()][object[]]$Rules = @(),
        [Parameter(Mandatory = $true)][string]$RuleId
    )

    foreach ($rule in @($Rules)) {
        if ($null -eq $rule) { continue }
        if ([string](Get-PimValue -Object $rule -Path 'id') -eq $RuleId) { return $rule }
    }
    return $null
}

function Get-PimApproverIds {
    <#
    .SYNOPSIS
        The distinct primary approver ids of the first approval stage of an
        approval rule, lower case, written to the pipeline.
    .DESCRIPTION
        Only the first stage is read: that is the stage the baseline and the
        pim-role-policy module state. Later stages are judged by the mode in
        Compare-PimPolicyRules.
    .PARAMETER ApprovalRule
        The Approval_EndUser_Assignment rule, or $null.
    .EXAMPLE
        $ids = @(Get-PimApproverIds -ApprovalRule $rule)
    #>
    param([AllowNull()][object]$ApprovalRule)

    $stages = @(Get-PimList -Object $ApprovalRule -Path 'setting.approvalStages')
    if ($stages.Count -eq 0) { return }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($approver in @(Get-PimList -Object $stages[0] -Path 'primaryApprovers')) {
        $id = [string](Get-PimValue -Object $approver -Path 'id')
        if ($id -and $seen.Add($id)) { $id.ToLowerInvariant() }
    }
}

function Get-PimDesiredApprovers {
    <#
    .SYNOPSIS
        The approver groups a policy that requires approval must name in its
        first stage, as objects with Id and Name, written to the pipeline.
    .DESCRIPTION
        Settings.ApproverGroupIds, with Settings.ApproverGroupNames as the
        descriptions, when the run has pinned them; otherwise the single
        ApproverGroupId given. Nothing when neither is set. Wrap the call in
        @().
    .PARAMETER Settings
        The object from Get-PimEffectiveSettings.
    .PARAMETER ApproverGroupId
        Fallback object id.
    .PARAMETER ApproverGroupName
        Fallback description.
    .EXAMPLE
        $approvers = @(Get-PimDesiredApprovers -Settings $settings)
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Settings,
        [AllowEmptyString()][string]$ApproverGroupId = '',
        [AllowEmptyString()][string]$ApproverGroupName = ''
    )

    $ids = @(Get-PimList -Object $Settings -Path 'ApproverGroupIds' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $names = @(Get-PimList -Object $Settings -Path 'ApproverGroupNames')
    if ($ids.Count -gt 0) {
        for ($i = 0; $i -lt $ids.Count; $i++) {
            $description = ''
            if ($i -lt $names.Count) { $description = [string]$names[$i] }
            [PSCustomObject]@{ Id = ([string]$ids[$i]).Trim(); Name = $description }
        }
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($ApproverGroupId)) {
        [PSCustomObject]@{ Id = $ApproverGroupId.Trim(); Name = $ApproverGroupName }
    }
}

function New-PimDriftItem {
    <#
    .SYNOPSIS
        One field-level difference.
    .PARAMETER RuleId
        Rule id.
    .PARAMETER Field
        Field within the rule.
    .PARAMETER Current
        Live value as text.
    .PARAMETER Desired
        Baseline value as text.
    .PARAMETER Blocked
        Why this difference must not be patched; empty when it may be.
    .EXAMPLE
        New-PimDriftItem -RuleId 'Expiration_EndUser_Assignment' -Field 'maximumDuration' -Current 'PT8H' -Desired 'PT4H'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RuleId,
        [Parameter(Mandatory = $true)][string]$Field,
        [AllowEmptyString()][string]$Current = '',
        [AllowEmptyString()][string]$Desired = '',
        [AllowEmptyString()][string]$Blocked = ''
    )

    return [PSCustomObject]@{ RuleId = $RuleId; Field = $Field; Current = $Current; Desired = $Desired; Blocked = $Blocked }
}

function Compare-PimPolicyRules {
    <#
    .SYNOPSIS
        The field-level differences between a policy's rules and the
        settings it should hold, written to the pipeline.
    .DESCRIPTION
        Governs maximumDuration of Expiration_EndUser_Assignment (compared as
        a duration), the MultiFactorAuthentication, Justification, and
        Ticketing entries of Enablement_EndUser_Assignment, and
        isApprovalRequired of Approval_EndUser_Assignment plus, when approval
        is required, the primary approvers of its first stage, which must be
        exactly the named groups. Other enablement values and every other
        rule are ignored. A missing rule reads as empty.

        Mode minimum treats the settings as a floor: a shorter window, an
        extra governed enablement value, approval that is not asked for,
        and extra approval stages are compliant. Mode exact reports each of
        those as drift. In both modes a missing MultiFactorAuthentication is
        marked Blocked when AuthenticationContext_EndUser_Assignment is on,
        because the two are mutually exclusive in the azurerm provider and
        the runbook never adds MFA next to an authentication context.
        Wrap the call in @().
    .PARAMETER Rules
        properties.rules of the policy.
    .PARAMETER Settings
        The object from Get-PimEffectiveSettings.
    .PARAMETER ApproverGroupId
        Fallback approver group object id, used when Settings carries no
        pinned ids.
    .PARAMETER Mode
        minimum (default) or exact.
    .EXAMPLE
        $drift = @(Compare-PimPolicyRules -Rules $rules -Settings $settings -Mode minimum)
    #>
    param(
        [AllowNull()][object[]]$Rules = @(),
        [Parameter(Mandatory = $true)][object]$Settings,
        [AllowEmptyString()][string]$ApproverGroupId = '',
        [ValidateSet('minimum', 'exact')][string]$Mode = 'minimum'
    )

    $exact = ($Mode -eq 'exact')

    $expirationId = $script:PimRuleIds.Expiration
    $expiration = Get-PimRuleById -Rules $Rules -RuleId $expirationId
    $currentDuration = [string](Get-PimValue -Object $expiration -Path 'maximumDuration')
    $currentSpan = ConvertFrom-PimIsoDuration -Value $currentDuration
    $desiredSpan = ConvertFrom-PimIsoDuration -Value $Settings.ActivationMaximumDuration
    $durationDrift = $true
    if ($null -ne $currentSpan -and $null -ne $desiredSpan) {
        if ($exact) { $durationDrift = ($currentSpan -ne $desiredSpan) }
        else { $durationDrift = ($currentSpan -gt $desiredSpan) }
    }
    if ($durationDrift) {
        $shown = $currentDuration
        if ([string]::IsNullOrWhiteSpace($shown)) { $shown = '(not set)' }
        New-PimDriftItem -RuleId $expirationId -Field 'maximumDuration' -Current $shown -Desired $Settings.ActivationMaximumDuration
    }

    $enablementId = $script:PimRuleIds.Enablement
    $enablement = Get-PimRuleById -Rules $Rules -RuleId $enablementId
    $enabled = @(Get-PimList -Object $enablement -Path 'enabledRules' | ForEach-Object { [string]$_ })
    $authenticationContext = Get-PimRuleById -Rules $Rules -RuleId $script:PimAuthenticationContextRuleId
    $authenticationContextOn = ConvertTo-PimBool -Value (Get-PimValue -Object $authenticationContext -Path 'isEnabled')
    $flags = [ordered]@{
        MultiFactorAuthentication = [bool]$Settings.RequireMultiFactorAuthentication
        Justification             = [bool]$Settings.RequireJustification
        Ticketing                 = [bool]$Settings.RequireTicketInfo
    }
    foreach ($flag in @($flags.Keys)) {
        $has = ($enabled -contains $flag)
        $want = [bool]$flags[$flag]
        if ($has -eq $want) { continue }
        if ($has -and -not $exact) { continue }
        $blocked = ''
        if ($flag -eq 'MultiFactorAuthentication' -and $want -and $authenticationContextOn) {
            $blocked = ('{0} is on, and MultiFactorAuthentication is never added next to it' -f $script:PimAuthenticationContextRuleId)
        }
        New-PimDriftItem -RuleId $enablementId -Field ('enabledRules.' + $flag) -Current (Format-PimBool $has) -Desired (Format-PimBool $want) -Blocked $blocked
    }

    $approvalId = $script:PimRuleIds.Approval
    $approval = Get-PimRuleById -Rules $Rules -RuleId $approvalId
    $currentRequired = ConvertTo-PimBool -Value (Get-PimValue -Object $approval -Path 'setting.isApprovalRequired')
    $wantApproval = [bool]$Settings.RequireApproval
    if (-not $wantApproval) {
        if ($currentRequired -and $exact) {
            New-PimDriftItem -RuleId $approvalId -Field 'setting.isApprovalRequired' -Current 'true' -Desired 'false'
        }
        return
    }

    $desired = @(Get-PimDesiredApprovers -Settings $Settings -ApproverGroupId $ApproverGroupId)
    if ($desired.Count -eq 0) { throw 'Approval is required but no approver group id is pinned for this run.' }
    if (-not $currentRequired) {
        New-PimDriftItem -RuleId $approvalId -Field 'setting.isApprovalRequired' -Current 'false' -Desired 'true'
    }
    $currentApprovers = @(Get-PimApproverIds -ApprovalRule $approval | Sort-Object)
    $desiredIds = @($desired | ForEach-Object { $_.Id.ToLowerInvariant() } | Sort-Object -Unique)
    if (($currentApprovers -join ',') -ne ($desiredIds -join ',')) {
        $shown = '(none)'
        if ($currentApprovers.Count -gt 0) { $shown = $currentApprovers -join ',' }
        New-PimDriftItem -RuleId $approvalId -Field 'setting.approvalStages.primaryApprovers' -Current $shown -Desired ($desiredIds -join ',')
    }
    if ($exact) {
        $stageCount = @(Get-PimList -Object $approval -Path 'setting.approvalStages').Count
        if ($stageCount -gt 1) {
            New-PimDriftItem -RuleId $approvalId -Field 'setting.approvalStages' -Current ('{0} stages' -f $stageCount) -Desired '1 stage'
        }
    }
}

function Format-PimDriftText {
    <#
    .SYNOPSIS
        Drift items as one line: "rule field: current -> desired; ...", with
        the reason appended to an item that must not be patched.
    .PARAMETER Drift
        Items from Compare-PimPolicyRules.
    .EXAMPLE
        Format-PimDriftText -Drift $drift
    #>
    param([AllowNull()][object[]]$Drift = @())

    $parts = @()
    foreach ($item in @($Drift)) {
        if ($null -eq $item) { continue }
        $text = '{0} {1}: {2} -> {3}' -f $item.RuleId, $item.Field, $item.Current, $item.Desired
        $blocked = [string](Get-PimValue -Object $item -Path 'Blocked')
        if ($blocked) { $text += (' (not patched: {0})' -f $blocked) }
        $parts += $text
    }
    return ($parts -join '; ')
}

function Get-PimBlockedReason {
    <#
    .SYNOPSIS
        The distinct reasons in a drift list that forbid a patch, joined, or
        an empty string when the drift may be patched.
    .PARAMETER Drift
        Items from Compare-PimPolicyRules.
    .EXAMPLE
        if (Get-PimBlockedReason -Drift $drift) { 'report only' }
    #>
    param([AllowNull()][object[]]$Drift = @())

    $reasons = @()
    foreach ($item in @($Drift)) {
        if ($null -eq $item) { continue }
        $blocked = [string](Get-PimValue -Object $item -Path 'Blocked')
        if ($blocked -and $reasons -notcontains $blocked) { $reasons += $blocked }
    }
    return ($reasons -join '; ')
}

function New-PimRuleSkeleton {
    <#
    .SYNOPSIS
        An empty EndUser Assignment rule of the right type, used only when a
        policy lacks a governed rule.
    .PARAMETER RuleId
        One of the three governed rule ids.
    .EXAMPLE
        New-PimRuleSkeleton -RuleId 'Enablement_EndUser_Assignment'
    #>
    param([Parameter(Mandatory = $true)][string]$RuleId)

    $target = @{ caller = 'EndUser'; operations = @('All'); level = 'Assignment'; targetObjects = $null; inheritableSettings = $null; enforcedSettings = $null }
    if ($RuleId -eq $script:PimRuleIds.Expiration) {
        $shape = @{ id = $RuleId; ruleType = 'RoleManagementPolicyExpirationRule'; isExpirationRequired = $true; maximumDuration = $null; target = $target }
    }
    elseif ($RuleId -eq $script:PimRuleIds.Enablement) {
        $shape = @{ id = $RuleId; ruleType = 'RoleManagementPolicyEnablementRule'; enabledRules = @(); target = $target }
    }
    elseif ($RuleId -eq $script:PimRuleIds.Approval) {
        $setting = @{ isApprovalRequired = $false; isApprovalRequiredForExtension = $false; isRequestorJustificationRequired = $true; approvalMode = 'SingleStage'; approvalStages = @() }
        $shape = @{ id = $RuleId; ruleType = 'RoleManagementPolicyApprovalRule'; setting = $setting; target = $target }
    }
    else {
        throw ('Rule "{0}" is not governed by this runbook.' -f $RuleId)
    }
    return (Copy-PimObject -Value $shape)
}

function New-PimRuleUpdate {
    <#
    .SYNOPSIS
        The rule to send for one drifted rule: a copy of the live rule with
        only the governed fields moved to the settings.
    .DESCRIPTION
        Expiration: maximumDuration is set to the settings value (in minimum
        mode this is only called when the live window is longer, so it
        tightens). Enablement: in minimum mode every live entry is kept and
        each required governed value that is missing is added; in exact mode
        the governed values are replaced and other entries kept. Approval:
        when approval is required, isApprovalRequired is set and the first
        stage's primary approvers become exactly the named groups; minimum
        mode keeps later stages and the approval mode, exact mode leaves one
        stage. When approval is not required, exact mode turns it off and
        minimum mode leaves the setting alone.
    .PARAMETER RuleId
        One of the three governed rule ids.
    .PARAMETER CurrentRule
        The live rule, or $null when the policy lacks it.
    .PARAMETER Settings
        The object from Get-PimEffectiveSettings.
    .PARAMETER ApproverGroupId
        Fallback approver group object id, used when Settings carries no
        pinned ids.
    .PARAMETER ApproverGroupName
        Fallback approver description.
    .PARAMETER Mode
        minimum (default) or exact.
    .EXAMPLE
        New-PimRuleUpdate -RuleId 'Approval_EndUser_Assignment' -CurrentRule $rule -Settings $settings -Mode minimum
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RuleId,
        [AllowNull()][object]$CurrentRule,
        [Parameter(Mandatory = $true)][object]$Settings,
        [AllowEmptyString()][string]$ApproverGroupId = '',
        [AllowEmptyString()][string]$ApproverGroupName = '',
        [ValidateSet('minimum', 'exact')][string]$Mode = 'minimum'
    )

    $exact = ($Mode -eq 'exact')
    if ($null -ne $CurrentRule) { $rule = Copy-PimObject -Value $CurrentRule }
    else { $rule = New-PimRuleSkeleton -RuleId $RuleId }

    if ($RuleId -eq $script:PimRuleIds.Expiration) {
        Set-PimProperty -Object $rule -Name 'maximumDuration' -Value ([string]$Settings.ActivationMaximumDuration)
        if ($null -eq (Get-PimValue -Object $rule -Path 'isExpirationRequired')) { Set-PimProperty -Object $rule -Name 'isExpirationRequired' -Value $true }
    }
    elseif ($RuleId -eq $script:PimRuleIds.Enablement) {
        $governed = @('MultiFactorAuthentication', 'Justification', 'Ticketing')
        $wanted = [ordered]@{
            MultiFactorAuthentication = [bool]$Settings.RequireMultiFactorAuthentication
            Justification             = [bool]$Settings.RequireJustification
            Ticketing                 = [bool]$Settings.RequireTicketInfo
        }
        $values = New-Object System.Collections.ArrayList
        foreach ($existing in @(Get-PimList -Object $rule -Path 'enabledRules')) {
            $text = [string]$existing
            if ($exact -and $governed -contains $text) { continue }
            if (-not ($values -contains $text)) { [void]$values.Add($text) }
        }
        foreach ($flag in @($wanted.Keys)) {
            if ($wanted[$flag] -and -not ($values -contains $flag)) { [void]$values.Add($flag) }
        }
        Set-PimProperty -Object $rule -Name 'enabledRules' -Value ([object[]]$values.ToArray())
    }
    elseif ($RuleId -eq $script:PimRuleIds.Approval) {
        $setting = Get-PimValue -Object $rule -Path 'setting'
        if ($null -eq $setting) {
            $setting = Get-PimValue -Object (New-PimRuleSkeleton -RuleId $RuleId) -Path 'setting'
            Set-PimProperty -Object $rule -Name 'setting' -Value $setting
        }
        if (-not [bool]$Settings.RequireApproval) {
            if ($exact) { Set-PimProperty -Object $setting -Name 'isApprovalRequired' -Value $false }
        }
        else {
            $desired = @(Get-PimDesiredApprovers -Settings $Settings -ApproverGroupId $ApproverGroupId -ApproverGroupName $ApproverGroupName)
            if ($desired.Count -eq 0) { throw 'Approval is required but no approver group id is pinned for this run.' }
            Set-PimProperty -Object $setting -Name 'isApprovalRequired' -Value $true
            $stages = @(Get-PimList -Object $setting -Path 'approvalStages')
            if ($stages.Count -gt 0) { $stage = $stages[0] }
            else {
                $stage = Copy-PimObject -Value @{
                    approvalStageTimeOutInDays      = 1
                    isApproverJustificationRequired = $true
                    escalationTimeInMinutes         = 0
                    primaryApprovers                = @()
                    isEscalationEnabled             = $false
                    escalationApprovers             = $null
                }
            }
            $approvers = New-Object System.Collections.ArrayList
            foreach ($d in $desired) {
                [void]$approvers.Add([PSCustomObject]@{ id = $d.Id; description = $d.Name; isBackup = $false; userType = 'Group' })
            }
            Set-PimProperty -Object $stage -Name 'primaryApprovers' -Value ([object[]]$approvers.ToArray())
            $kept = New-Object System.Collections.ArrayList
            [void]$kept.Add($stage)
            if (-not $exact) {
                for ($i = 1; $i -lt $stages.Count; $i++) { [void]$kept.Add($stages[$i]) }
            }
            Set-PimProperty -Object $setting -Name 'approvalStages' -Value ([object[]]$kept.ToArray())
            if ($kept.Count -eq 1) { Set-PimProperty -Object $setting -Name 'approvalMode' -Value 'SingleStage' }
        }
    }
    else {
        throw ('Rule "{0}" is not governed by this runbook.' -f $RuleId)
    }
    return $rule
}

function New-PimPolicyPatchBody {
    <#
    .SYNOPSIS
        The PATCH body for a drifted policy: properties.rules holding only the
        drifted rules, in a fixed order. $null when nothing drifted.
    .DESCRIPTION
        Throws when any drift item is Blocked, so a policy the runbook must
        only report can never be sent.
    .PARAMETER Rules
        properties.rules of the live policy.
    .PARAMETER Settings
        The object from Get-PimEffectiveSettings.
    .PARAMETER Drift
        Items from Compare-PimPolicyRules.
    .PARAMETER ApproverGroupId
        Fallback approver group object id.
    .PARAMETER ApproverGroupName
        Fallback approver description.
    .PARAMETER Mode
        minimum (default) or exact; must be the mode the drift was found in.
    .EXAMPLE
        $body = New-PimPolicyPatchBody -Rules $rules -Settings $settings -Drift $drift -Mode minimum
    #>
    param(
        [AllowNull()][object[]]$Rules = @(),
        [Parameter(Mandatory = $true)][object]$Settings,
        [AllowNull()][object[]]$Drift = @(),
        [AllowEmptyString()][string]$ApproverGroupId = '',
        [AllowEmptyString()][string]$ApproverGroupName = '',
        [ValidateSet('minimum', 'exact')][string]$Mode = 'minimum'
    )

    $blocked = Get-PimBlockedReason -Drift $Drift
    if ($blocked) { throw ('This policy is reported only and must not be patched: {0}.' -f $blocked) }
    $driftIds = @(@($Drift) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.RuleId })
    $updates = New-Object System.Collections.ArrayList
    foreach ($ruleId in @($script:PimRuleIds.Values)) {
        if ($driftIds -notcontains $ruleId) { continue }
        $current = Get-PimRuleById -Rules $Rules -RuleId $ruleId
        [void]$updates.Add((New-PimRuleUpdate -RuleId $ruleId -CurrentRule $current -Settings $Settings -ApproverGroupId $ApproverGroupId -ApproverGroupName $ApproverGroupName -Mode $Mode))
    }
    if ($updates.Count -eq 0) { return $null }
    return @{ properties = @{ rules = [object[]]$updates.ToArray() } }
}

# ---------------------------------------------------------------------------
# Report and digest. Pure.
# ---------------------------------------------------------------------------

function ConvertTo-PimReportRows {
    <#
    .SYNOPSIS
        CSV rows: one per evaluated pair and one per scope that could not be
        listed. Written to the pipeline.
    .PARAMETER Evaluations
        Pair evaluations from the run.
    .PARAMETER ScopeFailures
        Summary items for scopes that failed to list.
    .EXAMPLE
        $rows = @(ConvertTo-PimReportRows -Evaluations $evaluations -ScopeFailures $failures)
    #>
    param(
        [AllowNull()][object[]]$Evaluations = @(),
        [AllowNull()][object[]]$ScopeFailures = @()
    )

    foreach ($e in @($Evaluations)) {
        if ($null -eq $e) { continue }
        [PSCustomObject]@{
            Scope            = $e.Scope
            ScopeLevel       = (Get-PimScopeLevel -Scope ([string]$e.Scope))
            RoleName         = $e.RoleName
            RoleDefinitionId = $e.RoleDefinitionId
            PolicyId         = $e.PolicyId
            Principals       = $e.Principals
            Eligibilities    = $e.Eligibilities
            Baseline         = $e.BaselineSource
            Mode             = [string](Get-PimValue -Object $e -Path 'Mode')
            Status           = $e.Status
            DriftedRules     = ((@(@($e.Drift) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.RuleId } | Select-Object -Unique)) -join ';')
            Drift            = (Format-PimDriftText -Drift $e.Drift)
            Outcome          = $e.Outcome
            Detail           = $e.Detail
        }
    }
    foreach ($f in @($ScopeFailures)) {
        if ($null -eq $f) { continue }
        [PSCustomObject]@{
            Scope            = $f.Target
            ScopeLevel       = (Get-PimScopeLevel -Scope ([string]$f.Target))
            RoleName         = ''
            RoleDefinitionId = ''
            PolicyId         = ''
            Principals       = 0
            Eligibilities    = 0
            Baseline         = ''
            Mode             = ''
            Status           = 'Failed'
            DriftedRules     = ''
            Drift            = ''
            Outcome          = 'Failed'
            Detail           = ('{0}: {1}' -f $f.Action, $f.Detail)
        }
    }
}

function Get-PimDriftHandling {
    <#
    .SYNOPSIS
        What happened to a drifted pair, in words, for the digest.
    .PARAMETER Evaluation
        One pair evaluation with Status, Outcome, and optionally ReportReason.
    .EXAMPLE
        Get-PimDriftHandling -Evaluation $e
    #>
    param([Parameter(Mandatory = $true)][object]$Evaluation)

    if ([string]$Evaluation.Status -eq 'DriftReportOnly') {
        $reason = [string](Get-PimValue -Object $Evaluation -Path 'ReportReason')
        if (-not $reason) { $reason = 'report_only' }
        return ('reported only ({0})' -f $reason)
    }
    switch ([string]$Evaluation.Outcome) {
        'Done' { return 'patched' }
        'Failed' { return 'patch failed' }
        'Blocked' { return 'not patched (circuit breaker)' }
    }
    return 'would be patched'
}

function New-PimDigestHtml {
    <#
    .SYNOPSIS
        The HTML digest: drifted pairs field by field, then failures.
    .DESCRIPTION
        The run sends it only from a live run (a dry run sends nothing), so
        DryRun only changes the wording when the digest is rendered by hand.
    .PARAMETER Evaluations
        Pair evaluations from the run.
    .PARAMETER Failures
        Failed summary items.
    .PARAMETER RunId
        Correlation id.
    .PARAMETER DryRun
        Whether this was a dry run.
    .PARAMETER Environment
        Global or USGov.
    .PARAMETER PairsScanned
        Number of (scope, role) pairs evaluated.
    .PARAMETER BaselineMode
        minimum or exact.
    .EXAMPLE
        New-PimDigestHtml -Evaluations $evaluations -Failures $failures -RunId $id -DryRun $false -PairsScanned 12 -BaselineMode minimum
    #>
    param(
        [AllowNull()][object[]]$Evaluations = @(),
        [AllowNull()][object[]]$Failures = @(),
        [Parameter(Mandatory = $true)][string]$RunId,
        [bool]$DryRun = $true,
        [string]$Environment = 'Global',
        [int]$PairsScanned = 0,
        [string]$BaselineMode = 'minimum'
    )

    $drifted = @(@($Evaluations) | Where-Object { $null -ne $_ -and ($_.Status -eq 'Drift' -or $_.Status -eq 'DriftReportOnly') })
    $failed = @(@($Failures) | Where-Object { $null -ne $_ })
    $cell = 'style="border:1px solid #ccc;padding:4px 6px;text-align:left;vertical-align:top"'

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px">')
    [void]$sb.Append('<p><b>Azure PIM role management policy governance</b></p>')
    $mode = 'live: drifted policies were patched'
    if ($DryRun) { $mode = 'dry run: nothing was changed' }
    [void]$sb.Append(('<p>{0} (scope, role) pair(s) evaluated, {1} with drift, {2} failure(s). Mode: {3}. Baseline mode: {4}. Cloud: {5}.</p>' -f $PairsScanned, $drifted.Count, $failed.Count, (ConvertTo-HtmlSafe -Value $mode), (ConvertTo-HtmlSafe -Value $BaselineMode), (ConvertTo-HtmlSafe -Value $Environment)))

    if ($drifted.Count -gt 0) {
        [void]$sb.Append('<p><b>Drift</b></p><table style="border-collapse:collapse">')
        [void]$sb.Append(('<tr><th {0}>Scope</th><th {0}>Role</th><th {0}>Rule</th><th {0}>Field</th><th {0}>Current</th><th {0}>Baseline</th><th {0}>Handling</th></tr>' -f $cell))
        foreach ($e in $drifted) {
            $handling = Get-PimDriftHandling -Evaluation $e
            foreach ($item in @($e.Drift)) {
                if ($null -eq $item) { continue }
                $itemHandling = $handling
                $blocked = [string](Get-PimValue -Object $item -Path 'Blocked')
                if ($blocked) { $itemHandling = 'not patched: ' + $blocked }
                [void]$sb.Append(('<tr><td {0}>{1}</td><td {0}>{2}</td><td {0}>{3}</td><td {0}>{4}</td><td {0}>{5}</td><td {0}>{6}</td><td {0}>{7}</td></tr>' -f $cell,
                        (ConvertTo-HtmlSafe -Value $e.Scope), (ConvertTo-HtmlSafe -Value $e.RoleName), (ConvertTo-HtmlSafe -Value $item.RuleId),
                        (ConvertTo-HtmlSafe -Value $item.Field), (ConvertTo-HtmlSafe -Value $item.Current), (ConvertTo-HtmlSafe -Value $item.Desired),
                        (ConvertTo-HtmlSafe -Value $itemHandling)))
            }
        }
        [void]$sb.Append('</table>')
    }

    if ($failed.Count -gt 0) {
        [void]$sb.Append('<p><b>Failures</b></p><table style="border-collapse:collapse">')
        [void]$sb.Append(('<tr><th {0}>Step</th><th {0}>Target</th><th {0}>Detail</th></tr>' -f $cell))
        foreach ($f in $failed) {
            [void]$sb.Append(('<tr><td {0}>{1}</td><td {0}>{2}</td><td {0}>{3}</td></tr>' -f $cell, (ConvertTo-HtmlSafe -Value $f.Action), (ConvertTo-HtmlSafe -Value $f.Target), (ConvertTo-HtmlSafe -Value $f.Detail)))
        }
        [void]$sb.Append('</table>')
    }

    [void]$sb.Append('<p>Declared pairs belong to stacks/azure-pim-governance; change the baseline in the repository, not in the portal.</p>')
    [void]$sb.Append(('<p style="color:#666">Sent by the Azure PIM policy governance runbook (run {0}). This mailbox is not monitored.</p>' -f (ConvertTo-HtmlSafe -Value $RunId)))
    [void]$sb.Append('</body></html>')
    return $sb.ToString()
}

function Write-PimReport {
    <#
    .SYNOPSIS
        Writes the CSV report, creating the folder when needed.
    .DESCRIPTION
        A relative path is resolved against the PowerShell location first,
        the way New-Item and Export-Csv resolve it, because .NET file calls
        resolve against the process directory, which Push-Location and
        Set-Location do not change. With no rows, the header line alone is
        written, with the same columns as a full report.
    .PARAMETER Path
        CSV path, absolute or relative to the current location.
    .PARAMETER Rows
        Rows from ConvertTo-PimReportRows.
    .EXAMPLE
        Write-PimReport -Path $ReportPath -Rows $rows
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][object[]]$Rows = @()
    )

    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $directory = Split-Path -Path $fullPath -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $items = @(@($Rows) | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) {
        $header = '"' + ($script:PimReportColumns -join '","') + '"'
        [System.IO.File]::WriteAllText($fullPath, $header + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    }
    else {
        $items | Select-Object -Property $script:PimReportColumns | Export-Csv -LiteralPath $fullPath -NoTypeInformation -Encoding UTF8
    }
    Write-RunLog -Level Info -Message ('Wrote {0} report row(s) to {1}.' -f $items.Count, $fullPath)
}

# ---------------------------------------------------------------------------
# Reads. Every call goes through the library (Invoke-CloudRequest, and
# Get-AutomationStringVariable for the baseline).
# ---------------------------------------------------------------------------

function Resolve-PimBaselineText {
    <#
    .SYNOPSIS
        Picks the baseline document: BaselineJson, else the Automation
        variable, else the built-in defaults.
    .DESCRIPTION
        Returns Text (the JSON, or '' for the built-in defaults), Origin
        (for the baseline Source line), FromVariable, and VariableName.

          1. A non-blank BaselineJson wins. It must not be text that
             parameter binding made of an object.
          2. Otherwise a non-blank VariableName is read with the library's
             Get-AutomationStringVariable -AllowEmpty. A variable that is
             missing or unreadable throws, with a hint for local runs,
             because falling back to the defaults would quietly hold the
             declared pairs to them. A value that is text made of an object
             throws. An empty value means the built-in defaults, with a
             warning, because a cell that names a variable means to
             supply a baseline.
          3. Otherwise (both empty) the built-in defaults, logged.

        The variable's value is never logged, only its length.
    .PARAMETER BaselineJson
        The BaselineJson parameter.
    .PARAMETER VariableName
        The BaselineVariableName parameter.
    .EXAMPLE
        $baselineInput = Resolve-PimBaselineText -BaselineJson $BaselineJson -VariableName $BaselineVariableName
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$BaselineJson = '',
        [AllowNull()][AllowEmptyString()][string]$VariableName = ''
    )

    $name = ''
    if ($null -ne $VariableName) { $name = $VariableName.Trim() }

    if (-not [string]::IsNullOrWhiteSpace($BaselineJson)) {
        Assert-PimTextNotConverted -Value $BaselineJson -Label 'BaselineJson' -Remedy (Get-PimBaselineRemedy -VariableName $name)
        $ignored = ''
        if ($name) { $ignored = (' Automation variable "{0}" is not read.' -f $name) }
        Write-RunLog -Level Info -Message ('Baseline from the BaselineJson parameter ({0} characters).{1}' -f $BaselineJson.Trim().Length, $ignored)
        return [PSCustomObject]@{ Text = $BaselineJson; Origin = 'BaselineJson'; FromVariable = $false; VariableName = $name }
    }

    if (-not $name) {
        Write-RunLog -Level Info -Message 'BaselineJson and BaselineVariableName are both empty, so every pair is held to the built-in stack defaults.'
        return [PSCustomObject]@{ Text = ''; Origin = 'built-in stack defaults (no BaselineJson, no BaselineVariableName)'; FromVariable = $false; VariableName = '' }
    }

    $text = ''
    try {
        $text = Get-AutomationStringVariable -Name $name -AllowEmpty
    }
    catch {
        throw ('BaselineJson is empty, so the baseline is read from Automation variable "{0}", and that failed: {1} Create the string variable (stacks/azure-automation publishes it), or pass BaselineVariableName '''' to hold every pair to the built-in defaults. For a local run, pass the baseline with -BaselineJson, for example -BaselineJson (Get-Content -Raw -Path .\baseline.json).' -f $name, (Protect-RunbookText -Text $_.Exception.Message -MaxLength 400))
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-RunLog -Level Warn -Message ('BaselineJson is empty and Automation variable "{0}" is empty, so every pair is held to the built-in stack defaults.' -f $name)
        return [PSCustomObject]@{ Text = ''; Origin = ('built-in stack defaults (Automation variable "{0}" is empty)' -f $name); FromVariable = $true; VariableName = $name }
    }
    Assert-PimTextNotConverted -Value $text -Label ('Automation variable "{0}"' -f $name) -Reason 'The value was converted from an object to a string before it was stored.' -Remedy 'Store the baseline JSON text itself in the variable, as stacks/azure-automation publishes it from the repository file.'
    Write-RunLog -Level Info -Message ('Baseline from Automation variable "{0}" ({1} characters).' -f $name, $text.Trim().Length)
    return [PSCustomObject]@{ Text = $text; Origin = ('Automation variable "{0}"' -f $name); FromVariable = $true; VariableName = $name }
}

function Resolve-PimPairManagementGroup {
    <#
    .SYNOPSIS
        The scope of the management group a "pairs" entry names, matched by
        display name only, as modules/azure/pim-role-policy matches it.
    .DESCRIPTION
        The library's Resolve-ArmScope matches a group id first and a display
        name second, which suits ScopeNames. A "pairs" entry mirrors a
        Terraform declaration, and the module looks the group up with the
        azurerm_management_group data source by display_name. So a pair name
        that is a group's id, or that matches another group's id, would
        resolve differently here than in Terraform. The management group
        list is read once per run.

        No display name matches: throws "... was not found ...", which
        Resolve-PimPairEntries treats as a scope the identity cannot read,
        unless the name is some group's id. Then it throws a message
        without "was not found", which stops the run, because Terraform
        cannot resolve that declaration either. Two or more matches, or a
        matched group whose id is not a valid group id, also throw.
    .PARAMETER DisplayName
        The entry's scope.name.
    .EXAMPLE
        $scope = Resolve-PimPairManagementGroup -DisplayName 'Platform'
    #>
    param([Parameter(Mandatory = $true)][string]$DisplayName)

    if ($null -eq $script:PimManagementGroupList) {
        $script:PimManagementGroupList = @(Invoke-CloudRequest -Api Arm -Uri 'providers/Microsoft.Management/managementGroups' -ApiVersion $script:PimManagementGroupsApiVersion -AllPages)
    }
    $groups = @($script:PimManagementGroupList)
    $name = $DisplayName.Trim()
    $byDisplay = @($groups | Where-Object { ([string](Get-PimValue -Object $_ -Path 'properties.displayName')).Trim().Equals($name, [StringComparison]::OrdinalIgnoreCase) })
    if ($byDisplay.Count -gt 1) {
        throw ('Management group display name "{0}" is not unique ({1} matches: {2}), so neither this runbook nor the Terraform module can tell which group the entry means.' -f $name, $byDisplay.Count, ((@($byDisplay | ForEach-Object { [string]$_.name })) -join ', '))
    }
    if ($byDisplay.Count -eq 0) {
        $byId = @($groups | Where-Object { ([string]$_.name).Equals($name, [StringComparison]::OrdinalIgnoreCase) })
        if ($byId.Count -gt 0) {
            throw ('"{0}" is no management group''s display name, but it is the id of the management group whose display name is "{1}". A "pairs" scope is matched by display name only, as the Terraform module matches it, so write the display name.' -f $name, [string](Get-PimValue -Object $byId[0] -Path 'properties.displayName'))
        }
        throw ('Management group with display name "{0}" was not found among the {1} management group(s) the identity can read.' -f $name, $groups.Count)
    }
    $groupId = [string]$byDisplay[0].name
    if ($groupId -notmatch '^[\w\-\.\(\)]{1,90}$' -or $groupId.EndsWith('.')) {
        throw ('Management group display name "{0}" matched an entry whose id "{1}" is not a valid management group id; refusing to build a scope from it.' -f $name, (Protect-RunbookText -Text $groupId -MaxLength 100))
    }
    return ('/providers/Microsoft.Management/managementGroups/' + $groupId)
}

function Resolve-PimSweepTarget {
    <#
    .SYNOPSIS
        Resolves one ScopeNames entry to the scopes to list and the scopes
        whose eligibilities count.
    .DESCRIPTION
        A subscription is one scope and covers everything under it. A
        management group is itself plus every descendant management group
        and subscription. A name that cannot be resolved, or (without a
        prefix) matches both kinds, throws. A descendants read that fails is
        recorded on the summary and the group itself is still swept.
    .PARAMETER Reference
        The ScopeNames entry.
    .PARAMETER Summary
        The run summary, for a failed descendants read.
    .EXAMPLE
        $target = Resolve-PimSweepTarget -Reference 'mg:Platform' -Summary $summary
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Reference,
        [Parameter(Mandatory = $true)][object]$Summary
    )

    $ref = ConvertTo-PimScopeReference -Value $Reference
    $mgScope = ''
    $subScope = ''
    $notFound = @()

    # Without a prefix, only a plain "not found" from one lookup is tolerated;
    # an HTTP error or a duplicate name stops the run.
    if ($ref.Kind -ne 'Subscription') {
        try { $mgScope = Resolve-ArmScope -ManagementGroupName $ref.Name }
        catch {
            $message = $_.Exception.Message
            if ($ref.Kind -eq 'ManagementGroup' -or (Get-CloudErrorStatus -ErrorRecord $_) -ne 0 -or $message -notlike '*was not found*') {
                throw ('ScopeNames entry "{0}": {1}' -f $ref.Text, $message)
            }
            $notFound += $message
        }
    }
    if ($ref.Kind -ne 'ManagementGroup') {
        try { $subScope = Resolve-ArmScope -SubscriptionName $ref.Name }
        catch {
            $message = $_.Exception.Message
            if ($ref.Kind -eq 'Subscription' -or (Get-CloudErrorStatus -ErrorRecord $_) -ne 0 -or $message -notlike '*was not found*') {
                throw ('ScopeNames entry "{0}": {1}' -f $ref.Text, $message)
            }
            $notFound += $message
        }
    }
    if ($mgScope -and $subScope) {
        throw ('ScopeNames entry "{0}" matches both management group {1} and subscription {2}. Prefix it with mg: or sub:.' -f $ref.Text, $mgScope, $subScope)
    }
    if (-not $mgScope -and -not $subScope) {
        throw ('ScopeNames entry "{0}" is neither a management group nor a subscription the identity can read. {1}' -f $ref.Text, ($notFound -join ' '))
    }

    if ($subScope) {
        Write-RunLog -Level Info -Message ('Scope "{0}" is subscription {1}.' -f $ref.Text, $subScope)
        return [PSCustomObject]@{
            Reference  = $ref.Text
            Kind       = 'Subscription'
            RootScope  = $subScope
            ListScopes = [object[]]@($subScope)
            Allowed    = [object[]]@([PSCustomObject]@{ Scope = $subScope; Kind = 'Subscription' })
        }
    }

    $allowed = New-Object System.Collections.ArrayList
    [void]$allowed.Add([PSCustomObject]@{ Scope = $mgScope; Kind = 'ManagementGroup' })
    try {
        $descendants = @(Invoke-CloudRequest -Api Arm -Uri ($mgScope.TrimStart('/') + '/descendants') -ApiVersion $script:PimManagementGroupsApiVersion -AllPages)
        $groups = @()
        $subscriptions = @()
        foreach ($entry in $descendants) {
            $descendant = ConvertTo-PimDescendantScope -Entry $entry
            if ($null -eq $descendant) { continue }
            if ($descendant.Kind -eq 'ManagementGroup') { $groups += $descendant } else { $subscriptions += $descendant }
        }
        foreach ($d in @($groups + $subscriptions)) { [void]$allowed.Add($d) }
        Write-RunLog -Level Info -Message ('Scope "{0}" is management group {1} with {2} descendant group(s) and {3} subscription(s).' -f $ref.Text, $mgScope, $groups.Count, $subscriptions.Count)
    }
    catch {
        $detail = Protect-RunbookText -Text $_.Exception.Message -MaxLength 600
        Write-RunLog -Level Error -Message ('Could not list the descendants of {0}; sweeping the group itself only: {1}' -f $mgScope, $detail)
        Add-RunSummaryItem -Summary $Summary -Action 'ListDescendants' -Target $mgScope -Outcome Failed -Detail $detail
    }

    $scopes = @($allowed | ForEach-Object { [string]$_.Scope })
    return [PSCustomObject]@{
        Reference  = $ref.Text
        Kind       = 'ManagementGroup'
        RootScope  = $mgScope
        ListScopes = [object[]]$scopes
        Allowed    = [object[]]$allowed.ToArray()
    }
}

function Resolve-PimPairEntries {
    <#
    .SYNOPSIS
        Resolves the scope of every "pairs" entry and fills Baseline.Pairs.
    .DESCRIPTION
        Every entry is matched by display name, as the Terraform module
        matches it. A management_group entry uses
        Resolve-PimPairManagementGroup (display name only, never the group
        id). A subscription entry uses Resolve-ArmScope -SubscriptionName.
        A resource_group entry is built under its named subscription. An
        entry whose scope is not found is logged as a warning and dropped:
        the identity cannot read that scope, so no swept pair can be at it.
        These errors throw and stop the run before any PIM data is read: an
        HTTP failure, a name that matches two scopes, a management group
        named by its id, a bad resource group name, and two entries that
        resolve to one (scope, role). Returns the number of entries
        resolved.
    .PARAMETER Baseline
        The object from ConvertFrom-PimBaselineJson.
    .EXAMPLE
        $resolved = Resolve-PimPairEntries -Baseline $baseline
    #>
    param([Parameter(Mandatory = $true)][object]$Baseline)

    $Baseline.Pairs.Clear()
    $resolved = 0
    foreach ($entry in @($Baseline.PairEntries)) {
        if ($null -eq $entry) { continue }
        $described = '{0} at {1} "{2}"' -f $entry.RoleName, $entry.ScopeType, $entry.ScopeName
        if ($entry.ScopeType -eq 'resource_group') { $described += (' in subscription "{0}"' -f $entry.ScopeSubscription) }
        $scope = ''
        try {
            if ($entry.ScopeType -eq 'management_group') { $scope = Resolve-PimPairManagementGroup -DisplayName $entry.ScopeName }
            elseif ($entry.ScopeType -eq 'subscription') { $scope = Resolve-ArmScope -SubscriptionName $entry.ScopeName }
            else { $scope = Resolve-ArmScope -SubscriptionName $entry.ScopeSubscription -ResourceGroupName $entry.ScopeName }
        }
        catch {
            $message = $_.Exception.Message
            if ((Get-CloudErrorStatus -ErrorRecord $_) -eq 0 -and $message -like '*was not found*') {
                Write-RunLog -Level Warn -Message ('BaselineJson {0} ({1}) was dropped because its scope was not found, so no swept pair can be at it: {2}' -f $entry.Label, $described, $message)
                continue
            }
            throw ('BaselineJson {0} ({1}): {2}' -f $entry.Label, $described, $message)
        }

        $key = Get-PimPairOverrideKey -Scope $scope -RoleName $entry.RoleName
        if ($Baseline.Pairs.ContainsKey($key)) {
            throw ('BaselineJson {0} and {1} both name role "{2}" at {3}. Azure has one policy per (scope, role) pair, so merge them.' -f $Baseline.Pairs[$key].Label, $entry.Label, $entry.RoleName, $scope)
        }
        $entry.Scope = $scope
        $entry.Key = $key
        $Baseline.Pairs[$key] = $entry
        $resolved++
        Write-RunLog -Level Info -Message ('BaselineJson {0} ({1}) is {2}.' -f $entry.Label, $described, $scope)
    }
    return $resolved
}

function Get-PimEligibilityInstances {
    <#
    .SYNOPSIS
        Every role eligibility schedule instance the list returns at a scope,
        written to the pipeline.
    .DESCRIPTION
        GET {scope}/providers/Microsoft.Authorization/roleEligibilityScheduleInstances
        with api-version 2020-10-01 and no $filter, all pages. Wrap in @().
    .PARAMETER Scope
        ARM scope.
    .EXAMPLE
        $items = @(Get-PimEligibilityInstances -Scope '/subscriptions/x')
    #>
    param([Parameter(Mandatory = $true)][string]$Scope)

    $uri = '{0}/providers/Microsoft.Authorization/roleEligibilityScheduleInstances' -f $Scope.Trim().Trim('/')
    $items = @(Invoke-CloudRequest -Api Arm -Uri $uri -ApiVersion $script:PimArmApiVersion -AllPages)
    return $items
}

function Get-PimPolicyAssignmentForPair {
    <#
    .SYNOPSIS
        The role management policy assignment for one (scope, role) pair, or
        $null.
    .DESCRIPTION
        First GET roleManagementPolicyAssignments at the pair's scope with
        $filter=roleDefinitionId eq '<scope>/providers/Microsoft.Authorization/roleDefinitions/<guid>'
        (the filter form the PIM REST sample documents for role management
        policies). Every result is checked with Select-PimPolicyAssignment.
        When that finds nothing, or the service refuses the filter with
        HTTP 400, the unfiltered list for the scope (the documented List For
        Scope call) is read once, cached for the run, and searched instead.
        Any other error is thrown to the caller.
    .PARAMETER Pair
        A pair from Add-PimEligibilityPairs.
    .EXAMPLE
        $assignment = Get-PimPolicyAssignmentForPair -Pair $pair
    #>
    param([Parameter(Mandatory = $true)][object]$Pair)

    $scopePath = $Pair.Scope.Trim().Trim('/')
    $roleValue = '/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $scopePath, $Pair.RoleGuid
    $filter = [Uri]::EscapeDataString('roleDefinitionId eq ' + (ConvertTo-ODataLiteral -Value $roleValue))
    $filteredUri = '{0}/providers/Microsoft.Authorization/roleManagementPolicyAssignments?$filter={1}' -f $scopePath, $filter

    $assignment = $null
    $filterRefused = $false
    try {
        $filtered = @(Invoke-CloudRequest -Api Arm -Uri $filteredUri -ApiVersion $script:PimArmApiVersion -AllPages)
        $assignment = Select-PimPolicyAssignment -Assignments $filtered -Scope $Pair.Scope -RoleGuid $Pair.RoleGuid
    }
    catch {
        if ((Get-CloudErrorStatus -ErrorRecord $_) -ne 400) { throw }
        $filterRefused = $true
    }
    if ($null -ne $assignment) { return $assignment }

    $scopeKey = ConvertTo-PimScopeKey -Scope $Pair.Scope
    if (-not $script:PimAssignmentCache.ContainsKey($scopeKey)) {
        $reason = 'the roleDefinitionId filter returned no match'
        if ($filterRefused) { $reason = 'the roleDefinitionId filter was refused' }
        Write-RunLog -Level Info -Message ('Reading every policy assignment at {0} because {1}.' -f $Pair.Scope, $reason)
        $all = @(Invoke-CloudRequest -Api Arm -Uri ('{0}/providers/Microsoft.Authorization/roleManagementPolicyAssignments' -f $scopePath) -ApiVersion $script:PimArmApiVersion -AllPages)
        $script:PimAssignmentCache[$scopeKey] = $all
    }
    return (Select-PimPolicyAssignment -Assignments $script:PimAssignmentCache[$scopeKey] -Scope $Pair.Scope -RoleGuid $Pair.RoleGuid)
}

# ---------------------------------------------------------------------------
# Run.
# ---------------------------------------------------------------------------

function Invoke-AzurePimPolicyGovernanceRun {
    <#
    .SYNOPSIS
        The runbook body. Parameters are those of the script; see the header.
    .PARAMETER ScopeNames
        See the script help.
    .PARAMETER BaselineJson
        See the script help.
    .PARAMETER BaselineVariableName
        See the script help. Same default as the script.
    .PARAMETER ApproverGroupName
        See the script help.
    .PARAMETER Recipients
        See the script help.
    .PARAMETER SenderMailbox
        See the script help.
    .PARAMETER MaxPolicyUpdatesPerRun
        See the script help.
    .PARAMETER ReportPath
        See the script help.
    .PARAMETER DryRun
        See the script help.
    .PARAMETER Environment
        See the script help.
    .PARAMETER ClientId
        See the script help.
    .PARAMETER AccessToken
        See the script help.
    .PARAMETER RunId
        See the script help.
    .EXAMPLE
        Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'sub:Identity Production' -BaselineVariableName '' -AccessToken $token
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ScopeNames,
        [AllowEmptyString()][string]$BaselineJson = '',
        [AllowEmptyString()][string]$BaselineVariableName = $script:PimDefaultBaselineVariableName,
        [AllowEmptyString()][string]$ApproverGroupName = '',
        [AllowEmptyString()][string]$Recipients = '',
        [AllowEmptyString()][string]$SenderMailbox = '',
        [ValidateRange(0, 10000)][int]$MaxPolicyUpdatesPerRun = 25,
        [AllowEmptyString()][string]$ReportPath = '',
        [bool]$DryRun = $true,
        [ValidateSet('Global', 'USGov')][string]$Environment = 'Global',
        [AllowEmptyString()][string]$ClientId = '',
        [AllowEmptyString()][string]$AccessToken = '',
        [AllowEmptyString()][string]$RunId = ''
    )

    Initialize-RunContext -RunbookName 'Invoke-AzurePimPolicyGovernance' -RunId $RunId -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken -DryRun $DryRun
    $summary = New-RunSummary
    $script:PimAssignmentCache = @{}
    $script:PimManagementGroupList = $null

    # Inputs. Every problem here stops the run before the first call.
    $listRemedy = 'Write the list as one string separated by semicolons, such as "{0}", never as a JSON array.'
    Assert-PimTextNotConverted -Value $ScopeNames -Label 'ScopeNames' -Remedy ($listRemedy -f 'mg:Platform;sub:Identity Production')
    Assert-PimTextNotConverted -Value $Recipients -Label 'Recipients' -Remedy ($listRemedy -f 'iam@corp.example.com;secops@corp.example.com')
    $references = New-Object System.Collections.ArrayList
    foreach ($entry in @(ConvertTo-StringList -Value $ScopeNames -Label 'ScopeNames')) {
        $already = @($references | Where-Object { $_.Equals($entry, [StringComparison]::OrdinalIgnoreCase) })
        if ($already.Count -eq 0) { [void]$references.Add($entry) }
    }
    if ($references.Count -eq 0) { throw 'ScopeNames is empty. Name at least one management group or subscription.' }
    $parsedReferences = @($references | ForEach-Object { ConvertTo-PimScopeReference -Value $_ })
    if ($parsedReferences.Count -gt 1 -and -not (Test-PimJsonArrayText -Text $ScopeNames)) {
        $prefixed = @($parsedReferences | Where-Object { $_.Kind -ne 'Any' })
        $bare = @($parsedReferences | Where-Object { $_.Kind -eq 'Any' })
        if ($prefixed.Count -gt 0 -and $bare.Count -gt 0) {
            throw ('ScopeNames mixes prefixed and unprefixed entries in a comma or semicolon list ({0}), which usually means a display name that contains a comma or a semicolon was split. Prefix every entry with mg: or sub:. A job schedule cannot carry such a name, so sweep the management group above it; a local run can keep it whole with the JSON array form, for example ["sub:Example, Production","mg:Platform"].' -f (@($bare | ForEach-Object { '"' + $_.Text + '"' }) -join ', '))
        }
    }

    $recipientList = @(ConvertTo-StringList -Value $Recipients -Label 'Recipients')
    foreach ($address in $recipientList) {
        if ($address -notmatch '^[^@\s]+@[^@\s]+$') { throw ('Recipients: "{0}" is not a mail address.' -f $address) }
    }
    if ($recipientList.Count -gt 0 -and $SenderMailbox -notmatch '^[^@\s]+@[^@\s]+$') {
        throw 'SenderMailbox must be a mailbox address when Recipients is set.'
    }

    # Baseline: BaselineJson, else the Automation variable, else the defaults.
    $defaultApprover = ''
    if ($null -ne $ApproverGroupName) { $defaultApprover = $ApproverGroupName.Trim() }
    $baselineInput = Resolve-PimBaselineText -BaselineJson $BaselineJson -VariableName $BaselineVariableName
    try {
        $baseline = ConvertFrom-PimBaselineJson -Json $baselineInput.Text -DefaultApproverGroupName $defaultApprover -Origin $baselineInput.Origin
        Assert-PimBaselineApprovers -Baseline $baseline
    }
    catch {
        if ($baselineInput.FromVariable) {
            throw ('The baseline in Automation variable "{0}" is not valid: {1}' -f $baselineInput.VariableName, $_.Exception.Message)
        }
        throw
    }
    $approverNames = @(Get-PimApproverGroupNames -Baseline $baseline)

    Write-RunLog -Level Info -Message ('Settings: ScopeNames={0} MaxPolicyUpdatesPerRun={1} Baseline=[{2}] ApproverGroups={3} Recipients={4}' -f ($references -join '; '), $MaxPolicyUpdatesPerRun, $baseline.Source, ($approverNames -join ', '), $recipientList.Count)

    # Every approver group named anywhere, resolved once and pinned.
    $pinnedApprovers = @{}
    foreach ($name in $approverNames) {
        $groupId = Resolve-GroupIdByName -DisplayName $name
        $pinnedApprovers[$name.ToLowerInvariant()] = $groupId
        Write-RunLog -Level Info -Message ('Approver group "{0}" pinned to object id {1} for this run.' -f $name, $groupId)
    }
    $approverGroupId = ''
    if ($defaultApprover -and $pinnedApprovers.ContainsKey($defaultApprover.ToLowerInvariant())) { $approverGroupId = [string]$pinnedApprovers[$defaultApprover.ToLowerInvariant()] }

    $targets = New-Object System.Collections.ArrayList
    foreach ($entry in $references) { [void]$targets.Add((Resolve-PimSweepTarget -Reference $entry -Summary $summary)) }

    $pairEntriesResolved = 0
    if (@($baseline.PairEntries).Count -gt 0) { $pairEntriesResolved = Resolve-PimPairEntries -Baseline $baseline }

    # Discovery.
    $state = New-PimPairState
    $listed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $listFailures = 0
    foreach ($target in $targets) {
        foreach ($listScope in @($target.ListScopes)) {
            if (-not $listed.Add((ConvertTo-PimScopeKey -Scope $listScope))) { continue }
            try {
                $instances = @(Get-PimEligibilityInstances -Scope $listScope)
            }
            catch {
                $listFailures++
                $detail = Protect-RunbookText -Text $_.Exception.Message -MaxLength 600
                Write-RunLog -Level Error -Message ('Could not list eligibilities at {0}: {1}' -f $listScope, $detail)
                Add-RunSummaryItem -Summary $summary -Action 'ListEligibilities' -Target $listScope -Outcome Failed -Detail $detail
                continue
            }
            $new = Add-PimEligibilityPairs -State $state -Instances $instances -Allowed $target.Allowed
            Write-RunLog -Level Info -Message ('Listed {0} eligibility instance(s) at {1}; {2} new (scope, role) pair(s).' -f $instances.Count, $listScope, $new)
        }
    }
    $pairs = @($state.Pairs.Values | Sort-Object -Property Scope, RoleGuid)
    Write-RunLog -Level Info -Message ('Discovery: {0} scope(s) listed, {1} instance(s) read, {2} direct in scope, {3} ignored, {4} pair(s).' -f $listed.Count, $state.Read, $state.Direct, $state.Ignored, $pairs.Count)

    # Evaluation.
    $evaluations = New-Object System.Collections.ArrayList
    foreach ($pair in $pairs) {
        $evaluation = [PSCustomObject]@{
            Key              = $pair.Key
            Scope            = $pair.Scope
            RoleName         = $pair.RoleName
            RoleDefinitionId = $pair.RoleDefinitionId
            RoleGuid         = $pair.RoleGuid
            Principals       = $pair.Principals.Count
            Eligibilities    = $pair.Eligibilities
            ScopeLevel       = (Get-PimScopeLevel -Scope $pair.Scope)
            PolicyId         = ''
            BaselineSource   = ''
            Mode             = $baseline.Mode
            ReportOnly       = $false
            ReportReason     = ''
            Status           = 'Failed'
            Drift            = @()
            Rules            = @()
            Settings         = $null
            Outcome          = 'Failed'
            Detail           = ''
        }
        [void]$evaluations.Add($evaluation)
        $shownName = $pair.RoleName
        if (-not $shownName) { $shownName = '(role name not read)' }
        $label = '{0} ({1}) at {2}' -f $shownName, $pair.RoleGuid, $pair.Scope
        try {
            $assignment = Get-PimPolicyAssignmentForPair -Pair $pair
            if ($null -eq $assignment) { throw 'No role management policy assignment was found for this role at this scope.' }
            if (-not $evaluation.RoleName) {
                $evaluation.RoleName = ([string](Get-PimValue -Object $assignment -Path 'properties.policyAssignmentProperties.roleDefinition.displayName')).Trim()
                if ($evaluation.RoleName) { $label = '{0} ({1}) at {2}' -f $evaluation.RoleName, $pair.RoleGuid, $pair.Scope }
            }
            # Fail closed: without a name no "roles" or "pairs" entry can be
            # matched, and holding the pair to the defaults would bypass them.
            if (-not $evaluation.RoleName -and $baseline.HasOverrides) {
                throw 'The role display name could not be read (no expandedProperties on the eligibility and no policyAssignmentProperties on the policy assignment), so the "roles" and "pairs" entries cannot be matched; the pair is left alone rather than held to the defaults.'
            }
            $policyId = [string](Get-PimValue -Object $assignment -Path 'properties.policyId')
            if (-not (Test-PimPolicyIdAtScope -PolicyId $policyId -Scope $pair.Scope)) {
                throw ('The policy assignment names policy "{0}", which is not a role management policy at this scope; it is left alone.' -f $policyId)
            }
            $evaluation.PolicyId = $policyId.Trim()
            $policy = Invoke-CloudRequest -Api Arm -Uri $evaluation.PolicyId.TrimStart('/') -ApiVersion $script:PimArmApiVersion
            $rules = @(Get-PimList -Object $policy -Path 'properties.rules')
            if ($rules.Count -eq 0) { throw ('Policy {0} returned no rules.' -f $evaluation.PolicyId) }

            $settings = Get-PimEffectiveSettings -Baseline $baseline -RoleName $evaluation.RoleName -Scope $pair.Scope -ApproverGroupIds $pinnedApprovers
            $drift = @(Compare-PimPolicyRules -Rules $rules -Settings $settings -Mode $baseline.Mode)
            $blockedReason = Get-PimBlockedReason -Drift $drift
            $evaluation.Rules = $rules
            $evaluation.Settings = $settings
            $evaluation.Drift = $drift
            $evaluation.BaselineSource = $settings.Source
            $evaluation.ReportOnly = $settings.ReportOnly
            if ($drift.Count -eq 0) {
                $evaluation.Status = 'Compliant'
                $evaluation.Outcome = 'None'
                Write-RunLog -Level Info -Message ('Compliant: {0} (baseline {1}, mode {2}).' -f $label, $settings.Source, $baseline.Mode)
            }
            elseif ($settings.ReportOnly -or $blockedReason) {
                $evaluation.Status = 'DriftReportOnly'
                $evaluation.Outcome = 'Skipped'
                if ($settings.ReportOnly) {
                    $evaluation.ReportReason = 'report_only'
                    $evaluation.Detail = 'report_only: drift reported, not patched'
                }
                else {
                    $evaluation.ReportReason = 'authentication context'
                    $evaluation.Detail = ('not patched: {0}. Give this role a "pairs" or "roles" entry with require_multifactor_authentication false, or report_only.' -f $blockedReason)
                }
                Write-RunLog -Level Warn -Message ('Drift on {0}, reported only ({1}, {2}): {3}' -f $label, $settings.Source, $evaluation.ReportReason, (Format-PimDriftText -Drift $drift))
                Add-RunSummaryItem -Summary $summary -Action 'ReportDrift' -Target $label -Outcome Skipped -Detail (Format-PimDriftText -Drift $drift)
            }
            else {
                $evaluation.Status = 'Drift'
                $evaluation.Outcome = 'Pending'
                Write-RunLog -Level Info -Message ('Drift on {0} (baseline {1}): {2}' -f $label, $settings.Source, (Format-PimDriftText -Drift $drift))
            }
        }
        catch {
            $detail = Protect-RunbookText -Text $_.Exception.Message -MaxLength 600
            $evaluation.Status = 'Failed'
            $evaluation.Outcome = 'Failed'
            $evaluation.Detail = $detail
            Write-RunLog -Level Error -Message ('Could not evaluate {0}: {1}' -f $label, $detail)
            Add-RunSummaryItem -Summary $summary -Action 'ReadPolicy' -Target $label -Outcome Failed -Detail $detail
        }
    }

    # Overrides that matched nothing. A "roles" key that names no role found
    # in the sweep is probably misspelt, and its role would silently get the
    # defaults, so it is a warning. A pair entry with no eligibility is
    # normal (a policy can be declared ahead of its eligibilities).
    $seenRoleNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $seenPairKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $evaluations) {
        if (-not $e.RoleName) { continue }
        [void]$seenRoleNames.Add(([string]$e.RoleName).Trim())
        [void]$seenPairKeys.Add((Get-PimPairOverrideKey -Scope $e.Scope -RoleName $e.RoleName))
    }
    $unmatchedRoleKeys = @(@($baseline.Roles.Keys) | Where-Object { -not $seenRoleNames.Contains([string]$_) } | Sort-Object)
    foreach ($roleKey in $unmatchedRoleKeys) {
        Write-RunLog -Level Warn -Message ('BaselineJson roles."{0}" matched no role with a direct eligibility in the sweep. Check the spelling against the role display name; until it matches, that role is held to the defaults.' -f $roleKey)
    }
    $pairEntriesMatched = @(@($baseline.Pairs.Keys) | Where-Object { $seenPairKeys.Contains([string]$_) }).Count
    foreach ($pairKey in @($baseline.Pairs.Keys | Sort-Object)) {
        if ($seenPairKeys.Contains([string]$pairKey)) { continue }
        $unused = $baseline.Pairs[$pairKey]
        Write-RunLog -Level Info -Message ('BaselineJson {0} ({1} at {2}) matched no pair with a direct eligibility in the sweep.' -f $unused.Label, $unused.RoleName, $unused.Scope)
    }

    $toUpdate = @($evaluations | Where-Object { $_.Status -eq 'Drift' })
    $scopeFailureItems = @($summary.Failures | Where-Object { $_.Action -eq 'ListEligibilities' -or $_.Action -eq 'ListDescendants' })

    # Breaker before any write, in a dry run too. The CSV is written first so
    # the reviewer has the list the breaker refused.
    try {
        Test-CircuitBreaker -Planned $toUpdate.Count -Cap $MaxPolicyUpdatesPerRun -Label 'PIM policy updates'
    }
    catch {
        $breakerError = $_
        foreach ($e in $toUpdate) { $e.Outcome = 'Blocked' }
        if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
            Write-PimReport -Path $ReportPath -Rows @(ConvertTo-PimReportRows -Evaluations $evaluations.ToArray() -ScopeFailures $scopeFailureItems)
        }
        Write-RunLog -Level Error -Message $breakerError.Exception.Message
        throw $breakerError
    }

    # Writes. Names inside the block avoid Invoke-RunbookAction's parameter
    # names, which would hide the values set here.
    foreach ($e in $toUpdate) {
        $patchUri = $e.PolicyId.TrimStart('/')
        $patchBody = New-PimPolicyPatchBody -Rules $e.Rules -Settings $e.Settings -Drift $e.Drift -Mode $baseline.Mode
        $ruleList = (@($patchBody.properties.rules | ForEach-Object { [string]$_.id }) -join ', ')
        $roleShown = [string]$e.RoleName
        if (-not $roleShown) { $roleShown = 'role ' + $e.RoleGuid }
        $pairLabel = '{0} at {1}' -f $roleShown, $e.Scope
        $actionText = 'patch {0} on the {1} policy at {2} ({3})' -f $ruleList, $roleShown, $e.Scope, (Format-PimDriftText -Drift $e.Drift)
        $e.Outcome = Invoke-RunbookAction -Summary $summary -Action 'UpdatePolicy' -Target $pairLabel -Description $actionText -PassThru -ScriptBlock {
            Invoke-CloudRequest -Api Arm -Method PATCH -Uri $patchUri -ApiVersion $script:PimArmApiVersion -Body $patchBody
        }
        if ($e.Outcome -eq 'Failed') {
            $failure = @($summary.Failures | Where-Object { $_.Action -eq 'UpdatePolicy' -and $_.Target -eq $pairLabel } | Select-Object -Last 1)
            if ($failure.Count -gt 0) { $e.Detail = $failure[0].Detail }
        }
    }

    # Digest, only when there is something to read.
    $driftCount = @($evaluations | Where-Object { $_.Status -eq 'Drift' -or $_.Status -eq 'DriftReportOnly' }).Count
    $failureCount = $summary.Failures.Count
    $digestSent = $false
    if ($driftCount -eq 0 -and $failureCount -eq 0) {
        Write-RunLog -Level Info -Message 'No drift and no failures; no digest.'
    }
    elseif ($recipientList.Count -eq 0) {
        Write-RunLog -Level Info -Message ('{0} drifted pair(s) and {1} failure(s); no Recipients, so no digest.' -f $driftCount, $failureCount)
    }
    else {
        # Invoke-RunbookAction sends nothing in a dry run, so this is only
        # ever mailed from a live run.
        $mailHtml = New-PimDigestHtml -Evaluations $evaluations.ToArray() -Failures $summary.Failures.ToArray() -RunId (Get-RunContext).RunId -DryRun $DryRun -Environment $Environment -PairsScanned $evaluations.Count -BaselineMode $baseline.Mode
        $mailSubject = 'Azure PIM policy governance: {0} drifted pair(s), {1} failure(s)' -f $driftCount, $failureCount
        $mailTo = $recipientList
        $mailOutcome = Invoke-RunbookAction -Summary $summary -Action 'SendDigest' -Target ($recipientList -join ';') -Description ('send the drift digest to {0}' -f ($recipientList -join ';')) -PassThru -ScriptBlock {
            Send-RunbookMail -SenderMailbox $SenderMailbox -To $mailTo -Subject $mailSubject -HtmlBody $mailHtml
        }
        $digestSent = ($mailOutcome -eq 'Done')
    }

    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        Write-PimReport -Path $ReportPath -Rows @(ConvertTo-PimReportRows -Evaluations $evaluations.ToArray() -ScopeFailures $scopeFailureItems)
    }

    $extra = [ordered]@{
        ScopeNames             = ($references -join '; ')
        ScopesListed           = $listed.Count
        ScopeListFailures      = $listFailures
        EligibilitiesRead      = $state.Read
        DirectEligibilities    = $state.Direct
        EligibilitiesIgnored   = $state.Ignored
        PairsFound             = $pairs.Count
        PairsAtManagementGroup = @($evaluations | Where-Object { $_.ScopeLevel -eq 'ManagementGroup' }).Count
        PairsAtSubscription    = @($evaluations | Where-Object { $_.ScopeLevel -eq 'Subscription' }).Count
        PairsBelowSubscription = @($evaluations | Where-Object { $_.ScopeLevel -eq 'BelowSubscription' }).Count
        PairsCompliant         = @($evaluations | Where-Object { $_.Status -eq 'Compliant' }).Count
        PairsDrifted           = $toUpdate.Count
        PairsReportOnly        = @($evaluations | Where-Object { $_.Status -eq 'DriftReportOnly' }).Count
        PairsAuthContextOnly   = @($evaluations | Where-Object { $_.ReportReason -eq 'authentication context' }).Count
        PairsFailed            = @($evaluations | Where-Object { $_.Status -eq 'Failed' }).Count
        PolicyUpdatesPlanned   = $toUpdate.Count
        MaxPolicyUpdatesPerRun = $MaxPolicyUpdatesPerRun
        Baseline               = $baseline.Source
        BaselineVariableName   = $baselineInput.VariableName
        BaselineFromVariable   = [bool]$baselineInput.FromVariable
        BaselineMode           = $baseline.Mode
        RoleOverrides          = $baseline.Roles.Count
        RoleOverridesUnmatched = $unmatchedRoleKeys.Count
        PairOverrides          = @($baseline.PairEntries).Count
        PairOverridesResolved  = $pairEntriesResolved
        PairOverridesMatched   = $pairEntriesMatched
        ApproverGroupName      = $ApproverGroupName
        ApproverGroupId        = $approverGroupId
        ApproverGroups         = ($approverNames -join '; ')
        DigestSent             = $digestSent
        ReportPath             = $ReportPath
    }
    return (Complete-RunSummary -Summary $summary -Extra $extra)
}

# ---------------------------------------------------------------------------
# Entry point. Skipped when dot-sourced by the tests.
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AzurePimPolicyGovernanceRun -ScopeNames $ScopeNames -BaselineJson $BaselineJson -BaselineVariableName $BaselineVariableName -ApproverGroupName $ApproverGroupName `
        -Recipients $Recipients -SenderMailbox $SenderMailbox -MaxPolicyUpdatesPerRun $MaxPolicyUpdatesPerRun -ReportPath $ReportPath `
        -DryRun ([bool]$DryRun) -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken -RunId $RunId
}
