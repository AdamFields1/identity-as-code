<#
.SYNOPSIS
    Daily cloud governance guard: finds Enabled subscriptions of restricted
    offer types (by default the Visual Studio and MSDN offers on
    MSDN_2014-09-01, free trial, and pay-as-you-go) whose direct owners are
    not on an allowlist, and cancels each one through a just-in-time,
    self-removed Owner assignment, but only when -DryRun is false and
    -AllowCancel is true. A canceled subscription shows the Disabled state.

.DESCRIPTION
    Runs as an Azure Automation runbook on its own user-assigned managed
    identity (see "The identity" below). It lists the subscriptions the
    identity can see (or only the descendants of -ManagementGroupName), and
    decides each one with pure functions:

      NotEnabled     state is not Enabled                           nothing
      Excluded       id is in -ExcludedSubscriptionNames, or a
                     name there resolved to this id                 nothing; listed in the digest
                                                                    when the offer is restricted
      NotRestricted  subscriptionPolicies.quotaId matches no
                     -RestrictedQuotaIdPatterns pattern             nothing
      Allowed        a User direct Owner at subscription scope, or
                     a User eligible for Owner there through Azure
                     PIM, is an allowed principal                   nothing; listed in the digest
                                                                    when a human direct Owner who is
                                                                    not allowed is also there
      NeedsReview    no human (User) direct Owner with a valid
                     object id, or the owners or the eligible
                     owners could not be read                       reported, never canceled
      Candidate      restricted offer, human owners, none allowed,
                     and AllowCancel is true                        canceled
      WouldCancel    the same as Candidate, but AllowCancel is
                     false                                          reported with the reason
                                                                    "AllowCancel is false", never
                                                                    canceled

    A principal is allowed when its object id is one of the users named in
    -AllowedOwnerUpns, or a transitive user member of one of the groups
    named in -AllowedOwnerGroupNames. Only User owners are compared with
    that set. Only Owner assignments whose scope is exactly
    /subscriptions/<id> count; inherited management group owners do not make
    a subscription allowed, because they did not create it. Service
    principals, managed identities, agent identities, devices, foreign
    groups, and owners whose principalId is empty or not a GUID are ignored
    when judging: a subscription whose only owners are workloads has nobody
    to hold to account or to notify, so it is reported as NeedsReview and
    left alone. An owner that is a group, allowlisted or not, is not a human
    owner and does not make a subscription allowed (the runbook does not
    guess which member is responsible, and any Owner can assign Owner to any
    group), so a group-only subscription is also NeedsReview.

    Co-ownership. Any Owner of a subscription can add an Owner assignment
    for an allowlisted user. The subscription is then Allowed, because an
    accountable person now owns it, but the owners who are not allowed are
    still on it, so every Allowed subscription with such a human direct
    Owner is listed in the digest with those owners counted. The runbook
    does not use properties.createdBy to discount an allowlisted owner's
    assignment: what that field holds for the assignment made when a
    subscription is created is not documented, and a wrong guess would
    cancel an allowlisted owner's subscription.

    Azure PIM. An allowlisted user who holds Owner on a subscription only
    through an eligible Azure PIM assignment counts as an allowed owner.
    Before a subscription becomes a Candidate or WouldCancel, the runbook
    lists its role eligibility schedule instances
    (GET /subscriptions/{id}/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?$filter=atScope(),
    api-version 2020-10-01) and keeps the Owner instances of a User made
    directly at /subscriptions/<id> (memberType Direct), whose status is
    Provisioned and whose start and end times include now. An instance
    whose status or times are missing or unreadable counts, because the
    safe mistake is not to cancel. One such allowlisted user makes the
    subscription Allowed, listed in the digest like any co-owned one. An
    eligibility list that cannot be read makes it NeedsReview. Eligibility
    only ever protects a subscription: an eligible owner who is not
    allowlisted does not make one a Candidate.

    Why ownership is judged by object id. Display names and UPNs change and
    are not unique over time; the principalId on a role assignment is the
    object id and never changes. Every id the runbook compares, from ARM, from
    Graph, or from a parameter, goes through ConvertTo-NormalizedObjectId,
    which returns the lower-case GUID string and throws when it is handed an
    object instead of a string. An earlier design compared a Graph user object
    with a principalId string; PowerShell -contains and -eq then quietly
    return $false, every allowlisted owner looks unauthorised, and the guard
    cancels the subscriptions it was meant to protect. The throw makes that
    mistake loud, and the tests pin it.

    Exclusions are matched by subscription id, for the same reason. Any
    Owner can rename a subscription (Microsoft.Subscription/rename), so list
    ids in -ExcludedSubscriptionNames. A display name entry still works: at
    the start of the run it is resolved, trimmed and ignoring case, among
    the swept subscriptions. A name that matches more than one stops the run
    before any write, a name that matches none is logged, and every name
    entry is logged as a warning with the id it resolved to. The owners of
    an excluded subscription are never read, but an excluded subscription of
    a restricted offer is listed in the digest, so a subscription renamed to
    an excluded name is seen.

    List parameters. RestrictedQuotaIdPatterns, AllowedOwnerUpns,
    AllowedOwnerGroupNames, ExcludedSubscriptionNames, and Recipients are
    each one [string] holding a semicolon list ("a;b;c"), the form a job
    schedule carries safely; commas also separate. A local run may pass a
    JSON array (["a","b"]) instead, which is the only way to keep a ';' or
    ',' inside an entry. Do not put a JSON array in a schedule: the
    Automation service may parse JSON-looking parameter values before they
    are bound (see ConvertTo-StringList in automation/lib/Runbook.Common.ps1).

    Why the name says Disable. The runbook is named for the result: a
    canceled subscription shows the Disabled state. The operation is not a
    "disable", though. Azure Resource Manager documents no operation of
    that name; the Subscription operation group (2021-10-01) lists Accept
    Ownership, Accept Ownership Status, Cancel, Enable, and Rename, and the
    runbook calls Cancel:
      POST /subscriptions/{id}/providers/Microsoft.Subscription/cancel?api-version=2021-10-01
    Cancel starts the documented deletion timeline, so treat every cancel
    as the first step towards deletion, not as a switch that can be turned
    back. Parameter names that say Disable (MaxDisablesPerRun,
    MaxDisableAttempts) predate this wording and count cancels.

    DECISION NEEDED BEFORE ANY LIVE CANCEL. The runbook never calls Delete.
    What the cancel documentation says follows: billing stops, services are
    disabled (virtual machines deallocated, temporary IP addresses freed,
    storage read-only), an owner can delete the subscription 3 days after
    cancellation (7 for field and partner channel subscriptions), Azure
    deletes it automatically 90 days after
    cancellation, and Microsoft keeps the data for 30 to 90 days. A
    canceled subscription usually shows as Disabled; the subscription
    states page also lists Warned and Expired, and any state other than
    Enabled is NotEnabled here. Cancel is reversible only inside that
    window, and not by this runbook: a pay-as-you-go subscription can be
    reactivated in the Azure portal, and every other offer needs an Azure
    support request within 90 days of cancellation. The Enable operation
    exists, but its reference page says nothing about canceled
    subscriptions, so do not count on it until a sandbox round trip has
    shown it working. Whether REST Cancel is accepted on each targeted
    offer (Visual Studio, MSDN, free trial, pay-as-you-go) is also
    unproven. The code gate is -AllowCancel, false by default. Before
    allowcancel = "true" in the cell: get written sign-off from the owners
    of this control that Cancel is the intended action, and cancel and
    reactivate one sandbox subscription of each targeted offer. The cancel
    documentation says only a subscription owner without a condition can
    cancel, which is why the temporary assignment below carries no
    condition.

    DryRun and AllowCancel. A subscription is canceled only when DryRun is
    false and AllowCancel is true; both default to the safe value (DryRun
    true, AllowCancel false).
      DryRun true             Everything is read and decided, and every
                              write is logged as "Would" and not made. With
                              AllowCancel true the log shows the grant,
                              cancel, removal, and notice each Candidate
                              would get; with AllowCancel false it shows
                              WouldCancel subscriptions and no grant.
      DryRun false and        A report-only live run. Leftover temporary
      AllowCancel false       Owner assignments are removed and the digest
                              is sent, listing each WouldCancel
                              subscription. No Owner assignment is
                              created, nothing is canceled, and owners get
                              no notice: the notice says the subscription
                              was canceled, which would be false.
      DryRun false and        Live. Each Candidate is canceled as below and
      AllowCancel true        its owners are notified.
    The circuit breaker is evaluated in every mode. With AllowCancel false,
    a count above the cap is a warning and a note in the digest, not a
    stop, because nothing the breaker guards can happen and the digest is
    what that mode is for.

    Just-in-time elevation, per Candidate, only when DryRun is false and
    AllowCancel is true (the elevation never happens unless the cancel
    would):
      1. PUT a role assignment named with a new GUID: the built-in Owner role
         (resolved by name at the subscription scope and checked against the
         documented id 8e3af657-a8ff-443c-a75c-2fe8c4bcb635) for the
         identity's own principal id, principalType ServicePrincipal, and a
         description naming this runbook and the RunId.
      2. Wait -ElevationPropagationSeconds, then POST cancel. While ARM
         answers 403 (the assignment has not propagated yet) the call is
         retried with a doubling delay, up to -MaxDisableAttempts attempts.
         The library repeats the POST after a 429 only. After a server
         error or a lost response it is not repeated, because the cancel
         may already have been applied; the runbook then reads the
         subscription once more. A state other than Enabled counts as
         canceled and the owners get their notice. Enabled is reported in
         the digest as uncertain, and the next run reads the state again.
      3. In a finally block, whatever happened in 1 and 2: DELETE the
         assignment and GET it until ARM answers 404. When the PUT was
         refused with a 4xx, nothing was created, so only the GET runs. A
         failed DELETE is followed by the GET anyway, and only an assignment
         that is still there counts as a failure.

    A removal that cannot be confirmed is never swallowed. It is logged at
    Error, recorded as a Failed item, listed in the digest, named in
    UnconfirmedRemovals and counted in CleanupFailureCount on the summary,
    and it stops the run from elevating on any further subscription. The
    job then ends Failed: the entry point emits the summary and throws,
    naming each subscription id and assignment name, so
    Watch-AutomationJobFailures reports it even if nobody reads the digest.
    A failed look-up for leftovers (below) fails the job the same way. A
    live run, with AllowCancel true or false, refuses to start without
    -Recipients.

    Leftovers from an interrupted job. A job killed mid-run (fair share,
    sandbox crash) cannot run its finally block. So every run, in every
    mode and before the circuit breaker, looks for direct Owner assignments
    of its own principal whose description marks them as these temporary
    assignments, and removes them; that removal only takes this identity's
    own access away, so AllowCancel does not hold it back. With
    -ManagementGroupName it asks once at the management group; without it,
    it asks each swept subscription whose owners the decision pass did not
    read (NotEnabled, Excluded, NotRestricted, or a failed read) and takes
    the rest from that pass. An assignment created less than the elevation
    window ago (propagation wait, 403 retries, removal checks, plus 30
    minutes) is left alone and logged as Skipped, because another job may
    still be using it; the next run removes it. Other direct Owner
    assignments of the identity are reported, not touched. That includes
    every Owner assignment of the identity whose scope is not exactly one
    subscription: a management group, a resource group, or a resource. The
    runbook only ever creates subscription-scoped ones, so it did not create
    those, and it never removes them; each is logged at Warn, counted as a
    Failed ReviewOwnerAssignment item in the summary, and named in the
    digest. That is the one escalation the delegation condition cannot
    prevent (it limits what and to whom, not where), so the run says so
    rather than passing over it.

    The identity. This runbook runs on its own user-assigned managed
    identity, in an identity tier of its own that no other runbook shares
    (-ClientId selects it). That identity holds two Azure role assignments,
    both at one narrow sandbox management group, the one
    -ManagementGroupName names:
      - Reader, for the subscription, management group, role assignment,
        role definition, and role eligibility reads.
      - Role Based Access Control Administrator
        (f58310d9-a9f6-439a-9e8d-f62e7b41a168), for
        Microsoft.Authorization/roleAssignments/write and /delete,
        constrained by an Azure ABAC delegation condition (conditionVersion
        2.0) to assignments of the Owner role for its own principal id. It
        cannot grant anything to anyone else, cannot grant itself any other
        role, and cannot remove anybody else's access.
    Example condition, with <identity principal id> replaced by the object
    id of the identity's service principal:

      (
       (
        !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
       )
       OR
       (
        @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {8e3af657-a8ff-443c-a75c-2fe8c4bcb635}
        AND
        @Request[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAnyValues:GuidEquals {<identity principal id>}
       )
      )
      AND
      (
       (
        !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
       )
       OR
       (
        @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {8e3af657-a8ff-443c-a75c-2fe8c4bcb635}
        AND
        @Resource[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAnyValues:GuidEquals {<identity principal id>}
       )
      )

    The write half reads @Request (the assignment being created), the delete
    half reads @Resource (the assignment being removed); that split is how
    the delegation examples on learn.microsoft.com are written.

    What that permission really amounts to. The condition limits WHAT the
    identity can assign (the Owner role, to itself), not WHERE under that
    management group it can assign it: the delegation attributes
    (RoleDefinitionId, PrincipalId, PrincipalType) say nothing about scope.
    The identity can therefore, at any time, make itself an unconditioned
    Owner of the management group and of every subscription below it. It is
    effectively Owner-capable across that management group, and it belongs
    in the most restricted identity tier (control-plane tier 0 for that
    scope):
      - Assign both roles at the narrowest management group that holds
        only the targeted dev, test, and sandbox subscriptions. Never at the
        tenant root group, and never at a management group that holds
        production.
      - Anyone who can edit or publish a runbook on the account, start a
        job, change a schedule or its parameters (AllowCancel included),
        register a hybrid worker, or otherwise obtain the identity's token
        has the same power. Restrict write access to the account (runbooks,
        jobs, schedules, variables, hybrid worker groups) to the deployment
        pipeline and to people who already hold Owner at that scope.
      - Alert on misuse: send the management group's activity log to Log
        Analytics and alert on Microsoft.Authorization/roleAssignments/write
        by this principal whose scope is not a single /subscriptions/<id>,
        or whose request body lacks the description prefix
        "Temporary elevation by Disable-UnauthorizedSubscriptions".
    What this code does with the permission is narrower: it creates the
    Owner assignment only on a subscription it is about to cancel, only
    when AllowCancel is true, removes it in the same run, and every grant
    and removal is an entry in the Azure activity log under the identity's
    name and this RunId.

    Circuit breaker. After the leftover removal and before any grant or
    cancel, in dry runs too, the number of subscriptions that meet the
    cancel rule (Candidate or WouldCancel) is compared with
    -MaxDisablesPerRun (default 3). With AllowCancel true, more than that
    aborts the run with an error: a burst of unauthorised subscriptions is a
    symptom (a broken allowlist group, a renamed owner group, a new offer
    pattern) and needs a person, not a partial run. The one write allowed
    before the breaker is the leftover removal, because it only takes this
    identity's own access away; when the breaker trips, its error names
    every leftover the run removed, left alone, or could not confirm
    removed. With AllowCancel false the same count is logged as a warning,
    noted in the digest, and set as BreakerWouldTrip on the summary.

    Offer patterns. The quota id alone cannot tell an Enterprise Agreement
    subscription from a Microsoft Customer Agreement Azure plan
    (EnterpriseAgreement_2014-09-01 for both), or their Dev/Test offers from
    pay-as-you-go Dev/Test (MSDNDevTest_2014-09-01), so a pattern that
    matches any of those, or a CSP quota id, is refused. The Cost Management
    offer table on learn.microsoft.com spells the pay-as-you-go quota id
    Pay-as-you-go_2014-09-01, while ARM responses commonly carry
    PayAsYouGo_2014-09-01; the default pattern list carries both spellings.

    Visual Studio offers the defaults do not cover. The offer table maps
    Visual Studio Enterprise (MPN) (MS-AZR-0029P) to MPN_2014-09-01, which
    is not a default: adding MPN_* is a policy choice, because the Microsoft
    Cloud Partner Program pay-as-you-go offer (MS-AZR-0025P) shares that
    quota id. Visual Studio Test Professional (MS-AZR-0060P) uses
    MSDNDevTest_2014-09-01, which the pattern check refuses for the reason
    above. Subscriptions of both offers are NotRestricted.

    Graph application permissions: User.Read.All (resolve allowlisted UPNs,
    read owner mail addresses), GroupMember.Read.All (resolve allowlisted
    groups by name and read their transitive user members), Mail.Send
    (restricted to -SenderMailbox by an Exchange application access policy,
    see automation/README.md).

    ARM: Reader and the conditioned Role Based Access Control Administrator
    assignment above, both at the narrow sandbox management group, on this
    runbook's own identity. No standing Owner, Contributor, or User Access
    Administrator anywhere, but, as above, the conditioned assignment is
    Owner-capable across its management group.

    Schedule: daily at 04:00 UTC in the corp cell
    (tenants/azure/corp/azure-automation, schedule daily-0400-utc). Rollout:
    keep dry_run true until the job output (the summary, whose Reviewable
    list names every WouldCancel and NeedsReview subscription, and the
    verbose lines) has been read once, because a dry run sends no mail; then
    set dry_run = false and leave allowcancel = "false" (the default) for at
    least two weeks, a report-only live run whose digest lists every
    WouldCancel and NeedsReview subscription while those lists are worked
    through; set allowcancel = "true" only after the Cancel decision above is
    signed off and proven. dry_run is a stack input and allowcancel is a key
    in this runbook's parameters map; both are in the corp cell. MaxDisablesPerRun stays small; a day with more
    candidates than that is a day for a person.

    Design rules shared by every runbook in this repository are in
    automation/README.md. Transport, identity, logging, the breaker, and the
    summary come from automation/lib/Runbook.Common.ps1.

.PARAMETER ManagementGroupName
    Management group id or display name whose descendant subscriptions (any
    depth) are swept. Set it, to the same narrow sandbox management group
    the identity's two roles are assigned at. When empty, every subscription
    the identity can read is swept.

.PARAMETER RestrictedQuotaIdPatterns
    One string: a semicolon list of wildcard patterns matched
    (case-insensitive, -like) against subscriptionPolicies.quotaId, as a
    schedule passes it. Letters, digits, _ . - * ? only. Default
    MSDN_*;FreeTrial_*;PayAsYouGo_*;Pay-as-you-go_*. A local run may pass a
    JSON array instead.

.PARAMETER AllowedOwnerUpns
    One string: a semicolon list of user principal names whose direct or
    eligible Owner assignment makes a subscription allowed, for example
    alex@corp.example.com;blair@corp.example.com. A local run may pass a
    JSON array instead.

.PARAMETER AllowedOwnerGroupNames
    One string: a semicolon list of group display names. Every transitive
    user member counts as an allowed owner. The group itself does not: a
    group that holds Owner on a subscription does not make it allowed. Each
    name must match exactly one group. A name that contains ';' or ','
    cannot come from a schedule; rename the group, or, in a local run, pass
    a JSON array.

.PARAMETER ExcludedSubscriptionNames
    One string: a semicolon list of subscription ids (use these) or display
    names that are never judged or canceled. A display name is resolved to
    exactly one swept subscription at the start of the run, and a name that
    matches more than one stops the run. Any Owner can rename a
    subscription, so a name is not an identity. A local run may pass a JSON
    array instead.

.PARAMETER MaxDisablesPerRun
    Circuit breaker: the largest number of subscriptions one run may cancel
    (the name predates the Cancel wording). With AllowCancel true, more
    subscriptions that meet the cancel rule than this aborts the run before
    any grant or cancel (the leftover removal has already run); with
    AllowCancel false it is a warning. Default 3.

.PARAMETER ElevationPropagationSeconds
    Seconds to wait after creating the temporary Owner assignment before the
    first cancel call, and the base of the doubling delay between 403
    retries (capped at 300 seconds). Default 60.

.PARAMETER MaxDisableAttempts
    Attempts at the cancel call while ARM answers 403 (the name predates
    the Cancel wording). Default 5.

.PARAMETER Recipients
    One string: a semicolon list of addresses copied on every owner notice
    and sent the run digest (governance or identity team mailbox). Required
    for a live run, whatever AllowCancel says. A local run may pass a JSON
    array instead.

.PARAMETER SenderMailbox
    Mailbox the notices are sent from. Requires Mail.Send restricted to this
    mailbox by an Exchange application access policy.

.PARAMETER IdentityPrincipalId
    Optional object id of this runbook's managed identity's service
    principal (the principal_id Terraform knows). When empty the runbook
    reads the oid claim of its own ARM token. When both are known they must
    match, or a live run stops before any write.

.PARAMETER ReportPath
    Optional path for a CSV of every subscription with its decision.

.PARAMETER DryRun
    Default $true. Everything is read and decided, the breaker is evaluated,
    and every write (leftover removal, grant, cancel, removal, mail) is
    logged as "Would" and not made. Pass -DryRun:$false (dry_run = false in
    the cell) to make the non-destructive writes; a cancel also needs
    -AllowCancel.

.PARAMETER AllowCancel
    Default $false. The gate on the one destructive action: a subscription
    is canceled only when DryRun is false and AllowCancel is true, and the
    temporary Owner assignment is created only then. While it is false,
    each subscription that meets the cancel rule is reported as WouldCancel
    with the reason "AllowCancel is false", and its owners get no notice.
    Set it (allowcancel = "true" in the cell's parameters map) only after the
    Cancel decision in the description is signed off.

.PARAMETER Environment
    National cloud: Global (default) or USGov.

.PARAMETER ClientId
    Client id of this runbook's own user-assigned managed identity, the one
    that holds the conditioned role; not the identity other runbooks use.

.PARAMETER AccessToken
    Local runs and tests only: one token for every resource, or a JSON object
    string with Graph and Arm keys. Never logged.

.PARAMETER RunId
    Correlation id stamped on every log line, on the temporary assignment's
    description, and on the summary.

.EXAMPLE
    $arm = az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv
    $graph = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
    $tokens = @{ Arm = $arm; Graph = $graph } | ConvertTo-Json -Compress
    .\Disable-UnauthorizedSubscriptions.ps1 -SenderMailbox iam-noreply@corp.example.com -Recipients 'cloud-governance@corp.example.com' -AllowedOwnerGroupNames 'SEC Subscription Owners;SEC Platform Owners' -ManagementGroupName 'Sandbox' -AccessToken $tokens -ReportPath .\out\subscriptions.csv

    Dry run from a workstation. The summary and the CSV show which
    subscriptions would be canceled (WouldCancel) and which need review.
    Add -AllowCancel $true to see the grant and cancel steps in the log as
    well; the dry run still changes nothing.

.EXAMPLE
    .\Disable-UnauthorizedSubscriptions.ps1 -SenderMailbox iam-noreply@corp.example.com -Recipients 'cloud-governance@corp.example.com;iam-team@corp.example.com' -AllowedOwnerUpns 'alex@corp.example.com;blair@corp.example.com' -ManagementGroupName 'Sandbox' -ExcludedSubscriptionNames '88888888-8888-8888-8888-888888888888' -DryRun:$false -ClientId <identity client id>

    Report-only live run, as the Automation job runs it before the Cancel
    sign-off: leftovers are removed and the digest is sent, nothing is
    canceled.

.EXAMPLE
    .\Disable-UnauthorizedSubscriptions.ps1 -SenderMailbox iam-noreply@corp.example.com -Recipients 'cloud-governance@corp.example.com' -AllowedOwnerGroupNames 'SEC Subscription Owners' -ManagementGroupName 'Sandbox' -ExcludedSubscriptionNames '["88888888-8888-8888-8888-888888888888"]' -DryRun:$false -AllowCancel:$true -ClientId <identity client id>

    Live with cancel, after the sign-off. A local run may pass a list as a
    JSON array, as here. The job ends Failed, after emitting the summary,
    when a temporary Owner assignment could not be confirmed removed.

.NOTES
    Windows PowerShell 5.1 and PowerShell 7 compatible; no modules required.
    There is no #Requires line: the Azure Automation runbook types page says
    #Requires is not supported in the sandbox or on Hybrid Runbook Workers
    for PowerShell 5.1 and may make the job fail.
#>

[CmdletBinding()]
param(
    [string]$ManagementGroupName = '',

    [string]$RestrictedQuotaIdPatterns = 'MSDN_*;FreeTrial_*;PayAsYouGo_*;Pay-as-you-go_*',

    [string]$AllowedOwnerUpns = '',

    [string]$AllowedOwnerGroupNames = '',

    [string]$ExcludedSubscriptionNames = '',

    [ValidateRange(0, 100)]
    [int]$MaxDisablesPerRun = 3,

    [ValidateRange(0, 3600)]
    [int]$ElevationPropagationSeconds = 60,

    [ValidateRange(1, 20)]
    [int]$MaxDisableAttempts = 5,

    [string]$Recipients = '',

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^@\s]+@[^@\s]+$')]
    [string]$SenderMailbox,

    [string]$IdentityPrincipalId = '',

    [string]$ReportPath = '',

    [bool]$DryRun = $true,

    [bool]$AllowCancel = $false,

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
# Constants. Every value below is from learn.microsoft.com: the Subscription
# REST API (2021-10-01), Role Assignments and Role Definitions (2022-04-01),
# Role Eligibility Schedule Instances (2020-10-01), Subscriptions List and Get
# (2022-12-01, the library's value), and the built-in role ids in "Azure
# built-in roles for Privileged".
# ---------------------------------------------------------------------------

$script:DusApiVersions = @{
    Authorization = '2022-04-01'
    Eligibility   = '2020-10-01'
    Subscription  = '2021-10-01'
    Subscriptions = '2022-12-01'
}
# The default of -RestrictedQuotaIdPatterns, in the semicolon form a schedule
# passes.
$script:DusDefaultQuotaIdPatterns = 'MSDN_*;FreeTrial_*;PayAsYouGo_*;Pay-as-you-go_*'
$script:DusOwnerRoleId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
$script:DusDescriptionPrefix = 'Temporary elevation by Disable-UnauthorizedSubscriptions'
$script:DusAgreementQuotaIds = @(
    'EnterpriseAgreement_2014-09-01',
    'MSDNDevTest_2014-09-01',
    'CSP_2015-05-01',
    'CSP_MG_2017-12-01',
    'CSPDEVTEST_2018-05-01'
)
# Added to the worst-case elevation time when deciding whether a temporary
# assignment is old enough to be a leftover rather than another job's.
$script:DusLeftoverMarginMinutes = 30

# ---------------------------------------------------------------------------
# Object ids. Pure. Every comparison of principals goes through these.
# ---------------------------------------------------------------------------

function ConvertTo-NormalizedObjectId {
    <#
    .SYNOPSIS
        The lower-case GUID string of an object id, or '' when the value is
        empty or not a GUID.
    .DESCRIPTION
        Accepts a string or a [Guid]. Anything else (a Graph user object, a
        role assignment, a hashtable) throws, because comparing an object with
        an id string is always false in PowerShell and silently turns every
        allowlisted owner into an unauthorised one.
    .PARAMETER Value
        The id.
    .EXAMPLE
        ConvertTo-NormalizedObjectId -Value '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
        aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [Guid]) { return $Value.ToString('D').ToLowerInvariant() }
    if (-not ($Value -is [string])) {
        throw ('An object id must be a string or a Guid, not {0}. Pass the id property, never the object.' -f $Value.GetType().FullName)
    }
    $text = ([string]$Value).Trim()
    if ($text.Length -eq 0) { return '' }
    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParse($text, [ref]$parsed)) { return '' }
    return $parsed.ToString('D').ToLowerInvariant()
}

function New-PrincipalIdSet {
    <#
    .SYNOPSIS
        A case-insensitive set of normalised object id strings.
    .DESCRIPTION
        Every element must be an object id string or Guid; an object or a
        string that is not a GUID throws. Returns one HashSet[string].
    .PARAMETER Ids
        The ids.
    .EXAMPLE
        $allowed = New-PrincipalIdSet -Ids @($userId, $groupId)
    #>
    param([AllowNull()][AllowEmptyCollection()][object[]]$Ids = @())

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($Ids)) {
        if ($null -eq $id) { continue }
        $normalized = ConvertTo-NormalizedObjectId -Value $id
        if ([string]::IsNullOrEmpty($normalized)) {
            throw ('"{0}" is not an object id.' -f (Protect-RunbookText -Text ([string]$id) -MaxLength 80))
        }
        [void]$set.Add($normalized)
    }
    return , $set
}

function Test-PrincipalIdSet {
    <#
    .SYNOPSIS
        Throws unless the value is a HashSet[string] built by New-PrincipalIdSet.
    .PARAMETER Value
        The candidate set.
    .EXAMPLE
        Test-PrincipalIdSet -Value $allowed
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return }
    if (-not ($Value -is [System.Collections.Generic.HashSet[string]])) {
        throw ('The allowed principal set must be a HashSet[string] from New-PrincipalIdSet, not {0}.' -f $Value.GetType().FullName)
    }
}

# ---------------------------------------------------------------------------
# Offer patterns and exclusions. Pure.
# ---------------------------------------------------------------------------

function Confirm-RestrictedQuotaIdPatterns {
    <#
    .SYNOPSIS
        Validates the restricted quota id patterns and returns them.
    .DESCRIPTION
        Throws when the list is empty, when a pattern has characters other
        than letters, digits, _ . - * ?, or when a pattern matches a quota id
        that agreement-billed offers share (Enterprise Agreement, Microsoft
        Customer Agreement Azure plan, their Dev/Test offers, CSP). Writes
        the patterns to the pipeline; wrap in @().
    .PARAMETER Patterns
        The parsed list.
    .EXAMPLE
        $patterns = @(Confirm-RestrictedQuotaIdPatterns -Patterns @('MSDN_*'))
    #>
    param([AllowNull()][AllowEmptyCollection()][string[]]$Patterns = @())

    $list = @($Patterns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    if ($list.Count -eq 0) {
        throw 'RestrictedQuotaIdPatterns is empty. Name at least one offer pattern, for example ["MSDN_*","FreeTrial_*"].'
    }
    foreach ($pattern in $list) {
        if ($pattern -notmatch '^[A-Za-z0-9_.*?-]+$') {
            throw ('Restricted quota id pattern "{0}" may contain only letters, digits, _ . - * and ?.' -f $pattern)
        }
        foreach ($shared in $script:DusAgreementQuotaIds) {
            if ($shared -like $pattern) {
                throw ('Restricted quota id pattern "{0}" matches {1}, a quota id that agreement-billed offers (EA, MCA Azure plan, their Dev/Test offers, CSP) share. The quota id cannot tell those apart, so the pattern is refused.' -f $pattern, $shared)
            }
        }
    }
    foreach ($pattern in $list) { $pattern }
}

function Get-MatchingQuotaPattern {
    <#
    .SYNOPSIS
        The first restricted pattern the quota id matches, or ''.
    .PARAMETER QuotaId
        subscriptionPolicies.quotaId.
    .PARAMETER Patterns
        Validated patterns.
    .EXAMPLE
        Get-MatchingQuotaPattern -QuotaId 'MSDN_2014-09-01' -Patterns @('MSDN_*')
        MSDN_*
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$QuotaId,
        [AllowEmptyCollection()][string[]]$Patterns = @()
    )

    if ([string]::IsNullOrWhiteSpace($QuotaId)) { return '' }
    foreach ($pattern in $Patterns) {
        if ($QuotaId.Trim() -like $pattern) { return $pattern }
    }
    return ''
}

function Test-SubscriptionExcluded {
    <#
    .SYNOPSIS
        True when the subscription's display name or id is in the exclusion list.
    .DESCRIPTION
        Both sides are trimmed and names compare ignoring case. The run
        passes only ids (see Resolve-ExcludedSubscriptionIds), so a renamed
        subscription cannot match by name there.
    .PARAMETER Subscription
        ARM subscription object.
    .PARAMETER Excluded
        Display names or subscription ids.
    .EXAMPLE
        Test-SubscriptionExcluded -Subscription $sub -Excluded @('Lab Shared')
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Subscription,
        [AllowEmptyCollection()][string[]]$Excluded = @()
    )

    $name = ([string]$Subscription.displayName).Trim()
    $id = ConvertTo-NormalizedObjectId -Value ([string]$Subscription.subscriptionId)
    foreach ($entry in $Excluded) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if ($entry.Trim().Equals($name, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        $entryId = ConvertTo-NormalizedObjectId -Value $entry
        if ($entryId -and $id -and $entryId -eq $id) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Owners and the decision. Pure.
# ---------------------------------------------------------------------------

function Get-RoleDefinitionGuid {
    <#
    .SYNOPSIS
        The normalised GUID at the end of a roleDefinitionId, or ''.
    .DESCRIPTION
        ARM returns the id both as /subscriptions/<id>/providers/... and as
        /providers/..., so only the last segment is compared.
    .PARAMETER RoleDefinitionId
        properties.roleDefinitionId.
    .EXAMPLE
        Get-RoleDefinitionGuid -RoleDefinitionId '/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
    #>
    param([AllowNull()][AllowEmptyString()][string]$RoleDefinitionId)

    if ([string]::IsNullOrWhiteSpace($RoleDefinitionId)) { return '' }
    $segments = $RoleDefinitionId.Trim().TrimEnd('/').Split('/')
    return (ConvertTo-NormalizedObjectId -Value ([string]$segments[$segments.Length - 1]))
}

function Get-DirectOwnerAssignments {
    <#
    .SYNOPSIS
        The Owner role assignments made exactly at the subscription scope.
    .DESCRIPTION
        Keeps assignments whose properties.scope is /subscriptions/<id> (not
        a management group above it, not a resource group below it) and whose
        role definition is the Owner id. Writes one object per assignment:
        Name, PrincipalId (normalised, '' when empty or not a GUID),
        PrincipalType, Description, CreatedOn. Wrap in @().
    .PARAMETER RoleAssignments
        Items from the roleAssignments list with $filter=atScope().
    .PARAMETER SubscriptionId
        Subscription id.
    .PARAMETER OwnerRoleId
        Owner role definition GUID.
    .EXAMPLE
        $owners = @(Get-DirectOwnerAssignments -RoleAssignments $items -SubscriptionId $id -OwnerRoleId $ownerId)
    #>
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$RoleAssignments = @(),
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][string]$OwnerRoleId
    )

    $ownerGuid = ConvertTo-NormalizedObjectId -Value $OwnerRoleId
    $scope = '/subscriptions/' + (ConvertTo-NormalizedObjectId -Value $SubscriptionId)
    foreach ($assignment in @($RoleAssignments)) {
        if ($null -eq $assignment) { continue }
        $properties = $assignment.properties
        if ($null -eq $properties) { continue }
        $assignmentScope = ([string]$properties.scope).Trim().TrimEnd('/')
        if (-not $assignmentScope.Equals($scope, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ((Get-RoleDefinitionGuid -RoleDefinitionId ([string]$properties.roleDefinitionId)) -ne $ownerGuid) { continue }
        # No [string] cast on principalId: the object guard must see the value.
        [PSCustomObject]@{
            Name          = [string]$assignment.name
            PrincipalId   = (ConvertTo-NormalizedObjectId -Value $properties.principalId)
            PrincipalType = [string]$properties.principalType
            Description   = [string]$properties.description
            CreatedOn     = (ConvertTo-TimestampText -Value $properties.createdOn)
        }
    }
}

function ConvertTo-TimestampText {
    <#
    .SYNOPSIS
        A timestamp from a JSON reply as round-trip UTC text, or ''.
    .DESCRIPTION
        PowerShell 7 ConvertFrom-Json turns ISO 8601 strings into DateTime
        values and Windows PowerShell 5.1 leaves them as strings; this gives
        the same text either way, so the age of an assignment is read the
        same way in both.
    .PARAMETER Value
        properties.createdOn as parsed.
    .EXAMPLE
        ConvertTo-TimestampText -Value $properties.createdOn
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
    return ([string]$Value).Trim()
}

function ConvertFrom-TimestampText {
    <#
    .SYNOPSIS
        A UTC DateTime from timestamp text, or $null when the text is empty
        or unreadable.
    .DESCRIPTION
        Text without an offset is taken as UTC, as ARM writes it. Pass the
        output of ConvertTo-TimestampText so a PowerShell 7 DateTime and a
        5.1 string are read the same way.
    .PARAMETER Text
        The timestamp text.
    .EXAMPLE
        ConvertFrom-TimestampText -Text '2026-09-17T06:00:00Z'
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $parsed = [DateTime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    if (-not [DateTime]::TryParse($Text.Trim(), [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $null }
    return $parsed
}

function Get-EligibleOwnerIds {
    <#
    .SYNOPSIS
        The users who are eligible, now, for Owner directly at a subscription
        through Azure PIM.
    .DESCRIPTION
        Pure. Keeps role eligibility schedule instances whose scope is
        exactly /subscriptions/<id>, whose role definition is the Owner id,
        whose principalType is User, whose memberType is Direct (or not
        reported), and whose status is Provisioned (or not reported). An
        instance whose startDateTime is later than Now, or whose endDateTime
        is earlier than Now, is not current and is dropped; a time that is
        missing or unreadable does not drop it, because this list only ever
        protects a subscription. Writes the normalised user ids, each once;
        wrap in @().
    .PARAMETER Instances
        Items from the roleEligibilityScheduleInstances list with
        $filter=atScope().
    .PARAMETER SubscriptionId
        Subscription id.
    .PARAMETER OwnerRoleId
        Owner role definition GUID.
    .PARAMETER Now
        The clock.
    .EXAMPLE
        $eligible = @(Get-EligibleOwnerIds -Instances $items -SubscriptionId $id -OwnerRoleId $ownerId -Now $now)
    #>
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Instances = @(),
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][string]$OwnerRoleId,
        [DateTime]$Now = [DateTime]::UtcNow
    )

    $ownerGuid = ConvertTo-NormalizedObjectId -Value $OwnerRoleId
    $scope = '/subscriptions/' + (ConvertTo-NormalizedObjectId -Value $SubscriptionId)
    $clock = $Now.ToUniversalTime()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($instance in @($Instances)) {
        if ($null -eq $instance) { continue }
        $properties = $instance.properties
        if ($null -eq $properties) { continue }
        $instanceScope = ([string]$properties.scope).Trim().TrimEnd('/')
        if (-not $instanceScope.Equals($scope, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ((Get-RoleDefinitionGuid -RoleDefinitionId ([string]$properties.roleDefinitionId)) -ne $ownerGuid) { continue }
        if (-not ([string]$properties.principalType).Equals('User', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $memberType = ([string]$properties.memberType).Trim()
        if ($memberType -and -not $memberType.Equals('Direct', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $status = ([string]$properties.status).Trim()
        if ($status -and -not $status.Equals('Provisioned', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $start = ConvertFrom-TimestampText -Text (ConvertTo-TimestampText -Value $properties.startDateTime)
        if ($null -ne $start -and $start -gt $clock) { continue }
        $end = ConvertFrom-TimestampText -Text (ConvertTo-TimestampText -Value $properties.endDateTime)
        if ($null -ne $end -and $end -lt $clock) { continue }
        # No [string] cast on principalId: the object guard must see the value.
        $principal = ConvertTo-NormalizedObjectId -Value $properties.principalId
        if ($principal -and $seen.Add($principal)) { $principal }
    }
}

function Test-TemporaryElevation {
    <#
    .SYNOPSIS
        True when an assignment description marks it as this runbook's
        temporary Owner assignment.
    .PARAMETER Description
        properties.description.
    .EXAMPLE
        Test-TemporaryElevation -Description $owner.Description
    #>
    param([AllowNull()][AllowEmptyString()][string]$Description)

    if ([string]::IsNullOrWhiteSpace($Description)) { return $false }
    return $Description.Trim().StartsWith($script:DusDescriptionPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-SubscriptionDecision {
    <#
    .SYNOPSIS
        Decides one subscription: NotEnabled, Excluded, NotRestricted,
        Allowed, NeedsReview, or Candidate.
    .DESCRIPTION
        Pure. The gates run in that order and the owners are judged only when
        the subscription is Enabled, not excluded, and of a restricted offer
        (MatchedPattern is also set on an Excluded decision, for the digest).
        Owners are the direct Owner assignments at subscription scope. Only a
        User owner whose normalised id is in AllowedPrincipalIds makes the
        subscription Allowed; the other User owners are listed in
        OtherHumanOwnerIds. Otherwise User owners are the human owners: none
        means NeedsReview, some means Candidate. Group owners, allowlisted or
        not, are listed in GroupOwnerIds and never count. Service principals,
        managed identities, agent identities, devices, foreign groups, owners
        with no principal type or with an empty or non-GUID principalId, and
        the runbook's own identity are ignored. OwnersRead is true when the
        owners were judged.

        Azure PIM. When EligibleAssignments is given (an empty list counts)
        or EligibilityReadError is set, a subscription that would be a
        Candidate is checked once more: an eligibility read error makes it
        NeedsReview, and an allowlisted user in Get-EligibleOwnerIds makes it
        Allowed (EligibleAllowedOwnerIds, with every human direct Owner in
        OtherHumanOwnerIds). EligibilityRead is true when that check ran.
        When neither is given the check is skipped; the run always gives one.
        This function never returns WouldCancel: the run turns a Candidate
        into WouldCancel when AllowCancel is false.
    .PARAMETER Subscription
        ARM subscription object (subscriptionId, displayName, state,
        subscriptionPolicies.quotaId).
    .PARAMETER RoleAssignments
        Role assignments at or above the subscription (atScope()).
    .PARAMETER RestrictedQuotaIdPatterns
        Validated patterns.
    .PARAMETER AllowedPrincipalIds
        HashSet[string] from New-PrincipalIdSet, or $null for an empty set.
    .PARAMETER ExcludedSubscriptions
        Display names or ids.
    .PARAMETER OwnerRoleId
        Owner role definition GUID.
    .PARAMETER IdentityPrincipalId
        The runbook identity's object id, ignored as an owner.
    .PARAMETER AssignmentReadError
        Set when the role assignments could not be read; the decision is then
        NeedsReview.
    .PARAMETER EligibleAssignments
        Role eligibility schedule instances at or above the subscription
        (atScope()), or $null (the default) to skip the Azure PIM check.
    .PARAMETER EligibilityReadError
        Set when the eligibility instances could not be read; a subscription
        that would be a Candidate is then NeedsReview.
    .PARAMETER Now
        The clock for the eligibility time window.
    .EXAMPLE
        Get-SubscriptionDecision -Subscription $sub -RoleAssignments $items -RestrictedQuotaIdPatterns @('MSDN_*') -AllowedPrincipalIds $allowed
    .EXAMPLE
        Get-SubscriptionDecision -Subscription $sub -RoleAssignments $items -EligibleAssignments $eligible -RestrictedQuotaIdPatterns @('MSDN_*') -AllowedPrincipalIds $allowed -Now $now
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Subscription,
        [AllowNull()][AllowEmptyCollection()][object[]]$RoleAssignments = @(),
        [AllowEmptyCollection()][string[]]$RestrictedQuotaIdPatterns = @(),
        [AllowNull()][object]$AllowedPrincipalIds = $null,
        [AllowEmptyCollection()][string[]]$ExcludedSubscriptions = @(),
        [ValidateNotNullOrEmpty()][string]$OwnerRoleId = $script:DusOwnerRoleId,
        [AllowEmptyString()][string]$IdentityPrincipalId = '',
        [AllowEmptyString()][string]$AssignmentReadError = '',
        [AllowNull()][AllowEmptyCollection()][object[]]$EligibleAssignments = $null,
        [AllowEmptyString()][string]$EligibilityReadError = '',
        [DateTime]$Now = [DateTime]::UtcNow
    )

    Test-PrincipalIdSet -Value $AllowedPrincipalIds
    $subscriptionId = [string]$Subscription.subscriptionId
    $state = [string]$Subscription.state
    $quotaId = ''
    if ($null -ne $Subscription.subscriptionPolicies) { $quotaId = [string]$Subscription.subscriptionPolicies.quotaId }
    $selfId = ConvertTo-NormalizedObjectId -Value $IdentityPrincipalId

    $decision = [ordered]@{
        SubscriptionId          = $subscriptionId
        DisplayName             = [string]$Subscription.displayName
        State                   = $state
        QuotaId                 = $quotaId
        MatchedPattern          = ''
        Decision                = ''
        Reason                  = ''
        DirectOwnerCount        = 0
        HumanOwnerIds           = @()
        AllowedOwnerIds         = @()
        OtherHumanOwnerIds      = @()
        GroupOwnerIds           = @()
        EligibleAllowedOwnerIds = @()
        IgnoredOwnerCount       = 0
        OwnersRead              = $false
        EligibilityRead         = $false
        TemporaryAssignments    = @()
        OtherSelfAssignments    = @()
    }

    if (-not $state.Equals('Enabled', [StringComparison]::OrdinalIgnoreCase)) {
        $decision.Decision = 'NotEnabled'
        $decision.Reason = ('state is {0}' -f $state)
        return [PSCustomObject]$decision
    }
    $decision.MatchedPattern = Get-MatchingQuotaPattern -QuotaId $quotaId -Patterns $RestrictedQuotaIdPatterns
    if (Test-SubscriptionExcluded -Subscription $Subscription -Excluded $ExcludedSubscriptions) {
        $decision.Decision = 'Excluded'
        $decision.Reason = 'listed in ExcludedSubscriptionNames'
        return [PSCustomObject]$decision
    }
    if ([string]::IsNullOrEmpty($decision.MatchedPattern)) {
        $decision.Decision = 'NotRestricted'
        if ([string]::IsNullOrWhiteSpace($quotaId)) { $decision.Reason = 'quotaId not reported' }
        else { $decision.Reason = ('offer {0} is not restricted' -f $quotaId) }
        return [PSCustomObject]$decision
    }
    if (-not [string]::IsNullOrWhiteSpace($AssignmentReadError)) {
        $decision.Decision = 'NeedsReview'
        $decision.Reason = ('owners could not be read: {0}' -f $AssignmentReadError)
        return [PSCustomObject]$decision
    }

    $decision.OwnersRead = $true
    $owners = @(Get-DirectOwnerAssignments -RoleAssignments $RoleAssignments -SubscriptionId $subscriptionId -OwnerRoleId $OwnerRoleId)
    $decision.DirectOwnerCount = $owners.Count
    $human = New-Object System.Collections.ArrayList
    $allowedOwners = New-Object System.Collections.ArrayList
    $otherHuman = New-Object System.Collections.ArrayList
    $groups = New-Object System.Collections.ArrayList
    $temporary = New-Object System.Collections.ArrayList
    $otherSelf = New-Object System.Collections.ArrayList
    $ignored = 0

    foreach ($owner in $owners) {
        $principal = [string]$owner.PrincipalId
        if ([string]::IsNullOrEmpty($principal)) {
            # No usable object id: nobody to compare, notify, or hold to account.
            $ignored++
            continue
        }
        if ($selfId -and $principal -eq $selfId) {
            if (Test-TemporaryElevation -Description $owner.Description) {
                [void]$temporary.Add([PSCustomObject]@{ Name = [string]$owner.Name; CreatedOn = [string]$owner.CreatedOn })
            }
            else { [void]$otherSelf.Add($owner.Name) }
            $ignored++
            continue
        }
        switch -Regex ($owner.PrincipalType) {
            '^(?i)User$' {
                if ($human.Contains($principal)) { break }
                [void]$human.Add($principal)
                if ($null -ne $AllowedPrincipalIds -and $AllowedPrincipalIds.Contains($principal)) { [void]$allowedOwners.Add($principal) }
                else { [void]$otherHuman.Add($principal) }
                break
            }
            '^(?i)Group$' {
                # A group never makes a subscription allowed, even an allowlisted one.
                if (-not $groups.Contains($principal)) { [void]$groups.Add($principal) }
                break
            }
            default { $ignored++ }
        }
    }

    $decision.HumanOwnerIds = @($human.ToArray())
    $decision.AllowedOwnerIds = @($allowedOwners.ToArray())
    $decision.OtherHumanOwnerIds = @($otherHuman.ToArray())
    $decision.GroupOwnerIds = @($groups.ToArray())
    $decision.IgnoredOwnerCount = $ignored
    $decision.TemporaryAssignments = @($temporary.ToArray())
    $decision.OtherSelfAssignments = @($otherSelf.ToArray())

    if ($allowedOwners.Count -gt 0) {
        $decision.Decision = 'Allowed'
        $decision.Reason = ('{0} allowlisted direct Owner(s)' -f $allowedOwners.Count)
        if ($otherHuman.Count -gt 0) {
            $decision.Reason += ('; also {0} human direct Owner(s) not allowlisted ({1}), review the co-ownership' -f $otherHuman.Count, ($otherHuman.ToArray() -join ', '))
        }
    }
    elseif ($human.Count -eq 0) {
        $decision.Decision = 'NeedsReview'
        $decision.Reason = ('restricted offer {0} with no human direct Owner ({1} direct Owner assignment(s): {2} group, {3} workload, unknown, or other)' -f $quotaId, $owners.Count, $groups.Count, $ignored)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($EligibilityReadError)) {
        # Fail closed: an allowlisted eligible owner may be hiding here.
        $decision.Decision = 'NeedsReview'
        $decision.Reason = ('restricted offer {0}; {1} human direct Owner(s), none allowlisted, but the eligible (Azure PIM) Owner assignments could not be read: {2}' -f $quotaId, $human.Count, $EligibilityReadError)
    }
    else {
        $eligibleAllowed = @()
        if ($null -ne $EligibleAssignments) {
            $decision.EligibilityRead = $true
            $eligibleAllowed = @(Get-EligibleOwnerIds -Instances $EligibleAssignments -SubscriptionId $subscriptionId -OwnerRoleId $OwnerRoleId -Now $Now | Where-Object { $null -ne $AllowedPrincipalIds -and $AllowedPrincipalIds.Contains($_) })
        }
        if ($eligibleAllowed.Count -gt 0) {
            $decision.Decision = 'Allowed'
            $decision.EligibleAllowedOwnerIds = $eligibleAllowed
            $decision.Reason = ('{0} allowlisted eligible (Azure PIM) Owner(s) at subscription scope; also {1} human direct Owner(s) not allowlisted ({2}), review the co-ownership' -f $eligibleAllowed.Count, $otherHuman.Count, ($otherHuman.ToArray() -join ', '))
        }
        else {
            $decision.Decision = 'Candidate'
            $decision.Reason = ('restricted offer {0} (pattern {1}); {2} human direct Owner(s), none allowlisted' -f $quotaId, $decision.MatchedPattern, $human.Count)
            if ($decision.EligibilityRead) { $decision.Reason += '; no allowlisted eligible Owner' }
        }
    }
    return [PSCustomObject]$decision
}

# ---------------------------------------------------------------------------
# Elevation helpers. Pure.
# ---------------------------------------------------------------------------

function Get-ElevationRetryDelaySeconds {
    <#
    .SYNOPSIS
        Seconds to wait after a 403 on attempt N while the temporary Owner
        assignment propagates.
    .DESCRIPTION
        BaseSeconds (at least 5) doubled per attempt, capped at 300: with the
        default 60 the waits are 60, 120, 240, 300.
    .PARAMETER Attempt
        The attempt that just failed, starting at 1.
    .PARAMETER BaseSeconds
        ElevationPropagationSeconds.
    .EXAMPLE
        Get-ElevationRetryDelaySeconds -Attempt 2 -BaseSeconds 60
        120
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 100)][int]$Attempt,
        [ValidateRange(0, 3600)][int]$BaseSeconds = 60
    )

    $base = [Math]::Max(5, $BaseSeconds)
    return [int][Math]::Min(300, $base * [Math]::Pow(2, $Attempt - 1))
}

function Get-ElevationWindowMinutes {
    <#
    .SYNOPSIS
        Minutes a temporary Owner assignment can legitimately exist while a
        job uses it.
    .DESCRIPTION
        The propagation wait, every 403 retry delay, the removal checks (2
        and 4 seconds), rounded up to minutes, plus a 30 minute margin for
        library retries and slow calls. With the defaults (60 seconds, 5
        attempts) the window is 44 minutes. A temporary assignment younger
        than this may belong to another job that is still running.
    .PARAMETER PropagationSeconds
        ElevationPropagationSeconds.
    .PARAMETER MaxAttempts
        MaxDisableAttempts.
    .EXAMPLE
        Get-ElevationWindowMinutes -PropagationSeconds 60 -MaxAttempts 5
        44
    #>
    param(
        [ValidateRange(0, 3600)][int]$PropagationSeconds = 60,
        [ValidateRange(1, 20)][int]$MaxAttempts = 5
    )

    $seconds = $PropagationSeconds + 6
    for ($attempt = 1; $attempt -lt $MaxAttempts; $attempt++) {
        $seconds += Get-ElevationRetryDelaySeconds -Attempt $attempt -BaseSeconds $PropagationSeconds
    }
    return ([int][Math]::Ceiling($seconds / 60.0) + $script:DusLeftoverMarginMinutes)
}

function Test-LeftoverOldEnough {
    <#
    .SYNOPSIS
        True when a temporary Owner assignment is older than the elevation
        window, so no running job can still be using it.
    .DESCRIPTION
        A missing or unreadable createdOn counts as old: an unconditioned
        Owner assignment that nobody can date is removed rather than kept. A
        createdOn in the future (clock skew) counts as young.
    .PARAMETER CreatedOn
        properties.createdOn.
    .PARAMETER Now
        The clock.
    .PARAMETER WindowMinutes
        From Get-ElevationWindowMinutes.
    .EXAMPLE
        Test-LeftoverOldEnough -CreatedOn '2026-09-17T06:00:00Z' -Now $now -WindowMinutes 44
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$CreatedOn,
        [DateTime]$Now = [DateTime]::UtcNow,
        [ValidateRange(0, 100000)][int]$WindowMinutes = 44
    )

    $created = ConvertFrom-TimestampText -Text $CreatedOn
    if ($null -eq $created) { return $true }
    return (($Now.ToUniversalTime() - $created).TotalMinutes -ge $WindowMinutes)
}

function Get-AccessTokenObjectId {
    <#
    .SYNOPSIS
        The normalised oid claim of a JSON Web Token.
    .DESCRIPTION
        Decodes the payload segment only; the signature is not checked
        because the value is used to name the caller's own principal, and
        the delegation condition rejects any other id. Errors never include
        the token or its claims.
    .PARAMETER AccessToken
        The token.
    .EXAMPLE
        Get-AccessTokenObjectId -AccessToken (Get-RunbookAccessToken -Resource Arm)
    #>
    param([AllowNull()][AllowEmptyString()][string]$AccessToken)

    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($AccessToken)) { $parts = @($AccessToken.Split('.')) }
    if ($parts.Count -lt 3 -or [string]::IsNullOrEmpty($parts[1])) {
        throw 'The ARM access token is not a JSON Web Token, so its oid claim cannot be read. Pass -IdentityPrincipalId. The token is not shown.'
    }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
        1 { throw 'The ARM access token payload is not valid base64url. The token is not shown.' }
    }
    $claims = $null
    try {
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        $claims = ConvertFrom-Json -InputObject $json
    }
    catch {
        throw 'The ARM access token payload could not be decoded. Pass -IdentityPrincipalId. The token is not shown.'
    }
    $oid = ''
    if ($null -ne $claims -and $claims.PSObject.Properties['oid']) { $oid = ConvertTo-NormalizedObjectId -Value ([string]$claims.oid) }
    if ([string]::IsNullOrEmpty($oid)) { throw 'The ARM access token has no oid claim. Pass -IdentityPrincipalId.' }
    return $oid
}

# ---------------------------------------------------------------------------
# Mail content and the report. Pure.
# ---------------------------------------------------------------------------

function Get-UserMailAddress {
    <#
    .SYNOPSIS
        The deliverable address of a Graph user: mail, else a UPN that is not
        a guest #EXT# name, else ''.
    .PARAMETER User
        Graph user with mail and userPrincipalName.
    .EXAMPLE
        Get-UserMailAddress -User $user
    #>
    param([AllowNull()][object]$User)

    if ($null -eq $User) { return '' }
    $mail = [string]$User.mail
    if ($mail -match '^[^@\s]+@[^@\s]+$') { return $mail }
    $upn = [string]$User.userPrincipalName
    if ($upn -match '^[^@\s]+@[^@\s]+$' -and $upn -notmatch '#EXT#') { return $upn }
    return ''
}

function New-CancelNoticeHtml {
    <#
    .SYNOPSIS
        HTML body of the notice sent to a canceled subscription's owners.
    .DESCRIPTION
        Sent only after a cancel (or a dry run with AllowCancel true), never
        for a WouldCancel subscription, because it says the subscription was
        canceled.
    .PARAMETER Decision
        The Candidate decision.
    .PARAMETER OwnerNames
        Display names or UPNs of the human owners.
    .PARAMETER ContactAddresses
        Where the owners should write.
    .PARAMETER RunId
        Correlation id.
    .PARAMETER Now
        The clock.
    .EXAMPLE
        New-CancelNoticeHtml -Decision $d -OwnerNames @('Alex') -ContactAddresses @('cloud-governance@corp.example.com') -RunId $id
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Decision,
        [AllowEmptyCollection()][string[]]$OwnerNames = @(),
        [AllowEmptyCollection()][string[]]$ContactAddresses = @(),
        [AllowEmptyString()][string]$RunId = '',
        [DateTime]$Now = [DateTime]::UtcNow
    )

    $contact = 'the cloud governance team'
    if (@($ContactAddresses).Count -gt 0) { $contact = (@($ContactAddresses) -join ', ') }
    $owners = '(unknown)'
    if (@($OwnerNames).Count -gt 0) { $owners = (@($OwnerNames) -join ', ') }
    $deleteDate = $Now.ToUniversalTime().AddDays(90).ToString('yyyy-MM-dd')

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px">')
    [void]$sb.Append(('<p>The Azure subscription <b>{0}</b> ({1}) was canceled, which disables it, on {2} UTC by the cloud governance guard.</p>' -f (ConvertTo-HtmlSafe -Value $Decision.DisplayName), (ConvertTo-HtmlSafe -Value $Decision.SubscriptionId), $Now.ToUniversalTime().ToString('yyyy-MM-dd HH:mm')))
    [void]$sb.Append(('<p>Why: its offer type ({0}) may only be used by approved owners, and none of its direct owners ({1}) is on the approved list.</p>' -f (ConvertTo-HtmlSafe -Value $Decision.QuotaId), (ConvertTo-HtmlSafe -Value $owners)))
    [void]$sb.Append('<p>What this means: billing has stopped, virtual machines are deallocated, temporary IP addresses are released, storage is read-only, and other services are stopped. Nothing has been deleted yet.</p>')
    [void]$sb.Append(('<p>What to do: if the subscription is needed, write to {0} now. A canceled subscription can be reactivated only for a limited time: a pay-as-you-go subscription in the Azure portal, any other offer through an Azure support request within 90 days of cancellation. Azure deletes a canceled subscription automatically 90 days after cancellation (around {1}), an owner can delete it after 3 days, and Microsoft may permanently delete its data from 30 days after cancellation.</p>' -f (ConvertTo-HtmlSafe -Value $contact), $deleteDate))
    [void]$sb.Append(('<p style="color:#666">Sent by the Disable-UnauthorizedSubscriptions runbook (run {0}). This mailbox is not monitored.</p>' -f (ConvertTo-HtmlSafe -Value $RunId)))
    [void]$sb.Append('</body></html>')
    return $sb.ToString()
}

function New-RunDigestHtml {
    <#
    .SYNOPSIS
        HTML body of the run digest: candidates, WouldCancel subscriptions,
        subscriptions needing review, co-owned allowed and excluded
        restricted subscriptions, notes, and failed actions.
    .PARAMETER Decisions
        The decisions to list (see Test-DecisionReportable).
    .PARAMETER Failures
        Failed summary items.
    .PARAMETER DryRun
        Whether the run was dry.
    .PARAMETER AllowCancel
        Whether the run could cancel.
    .PARAMETER Notes
        Extra sentences, one paragraph each (the breaker count while
        AllowCancel is false, cancels without a clear answer).
    .PARAMETER RunId
        Correlation id.
    .EXAMPLE
        New-RunDigestHtml -Decisions $interesting -Failures $failed -DryRun $false -AllowCancel $false -RunId $id
    #>
    param(
        [AllowEmptyCollection()][object[]]$Decisions = @(),
        [AllowEmptyCollection()][object[]]$Failures = @(),
        [bool]$DryRun = $true,
        [bool]$AllowCancel = $false,
        [AllowEmptyCollection()][string[]]$Notes = @(),
        [AllowEmptyString()][string]$RunId = ''
    )

    $mode = 'live'
    if ($DryRun) { $mode = 'dry run, nothing was changed' }
    if (-not $AllowCancel) { $mode += '; AllowCancel is false, so no Owner assignment was created and nothing was canceled' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px">')
    [void]$sb.Append(('<p>Unauthorized subscription guard, run {0} ({1}).</p>' -f (ConvertTo-HtmlSafe -Value $RunId), (ConvertTo-HtmlSafe -Value $mode)))
    if (-not $AllowCancel -and @($Decisions | Where-Object { $null -ne $_ -and $_.Decision -eq 'WouldCancel' }).Count -gt 0) {
        [void]$sb.Append('<p>WouldCancel rows meet the cancel rule. They are not canceled, and their owners are not told, while AllowCancel is false. Set allowcancel = "true" in the tenant cell only after the Cancel decision in the runbook header is signed off.</p>')
    }
    foreach ($note in @($Notes)) {
        if ([string]::IsNullOrWhiteSpace($note)) { continue }
        [void]$sb.Append(('<p>{0}</p>' -f (ConvertTo-HtmlSafe -Value $note)))
    }
    [void]$sb.Append('<table border="1" cellpadding="4" cellspacing="0" style="border-collapse:collapse"><tr><th>Subscription</th><th>Id</th><th>Offer</th><th>Decision</th><th>Reason</th></tr>')
    foreach ($d in @($Decisions)) {
        if ($null -eq $d) { continue }
        [void]$sb.Append(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>' -f (ConvertTo-HtmlSafe -Value $d.DisplayName), (ConvertTo-HtmlSafe -Value $d.SubscriptionId), (ConvertTo-HtmlSafe -Value $d.QuotaId), (ConvertTo-HtmlSafe -Value $d.Decision), (ConvertTo-HtmlSafe -Value $d.Reason)))
    }
    [void]$sb.Append('</table>')
    if (@($Failures).Count -gt 0) {
        [void]$sb.Append('<p><b>Failed actions</b> (a failed RemoveTemporaryOwner or RemoveLeftoverOwner means the identity may still be an unconditioned Owner on that subscription; remove the assignment by hand. A failed FindLeftoverOwner means leftovers there could not be looked for):</p><ul>')
        foreach ($f in @($Failures)) {
            if ($null -eq $f) { continue }
            [void]$sb.Append(('<li>{0} {1}: {2}</li>' -f (ConvertTo-HtmlSafe -Value $f.Action), (ConvertTo-HtmlSafe -Value $f.Target), (ConvertTo-HtmlSafe -Value $f.Detail)))
        }
        [void]$sb.Append('</ul>')
    }
    [void]$sb.Append('</body></html>')
    return $sb.ToString()
}

function Test-DecisionReportable {
    <#
    .SYNOPSIS
        True when a decision belongs in the digest.
    .DESCRIPTION
        Candidate, WouldCancel, and NeedsReview always; Allowed when a human
        direct Owner who is not allowlisted is also on the subscription
        (co-ownership can hide an unauthorised owner); Excluded when the
        offer is restricted (a subscription can be renamed to an excluded
        name).
    .PARAMETER Decision
        Output of Get-SubscriptionDecision, after the run's WouldCancel step.
    .EXAMPLE
        $reportable = @($decisions | Where-Object { Test-DecisionReportable -Decision $_ })
    #>
    param([Parameter(Mandatory = $true)][object]$Decision)

    switch ([string]$Decision.Decision) {
        'Candidate' { return $true }
        'WouldCancel' { return $true }
        'NeedsReview' { return $true }
        'Allowed' { return (@($Decision.OtherHumanOwnerIds | Where-Object { $_ }).Count -gt 0) }
        'Excluded' { return (-not [string]::IsNullOrEmpty([string]$Decision.MatchedPattern)) }
    }
    return $false
}

function Get-DisableRunFailureMessage {
    <#
    .SYNOPSIS
        The message the entry point throws after emitting the summary, or ''
        when no temporary Owner assignment is in doubt.
    .DESCRIPTION
        Non-empty when UnconfirmedRemovals or CleanupFailureCount shows a
        temporary Owner assignment that could not be confirmed removed, or
        LeftoverLookupFailures shows a scope where leftovers could not be
        looked for. Names each subscription id and assignment, so the failed
        job alone is enough to act on.
    .PARAMETER Summary
        The object from Complete-RunSummary.
    .EXAMPLE
        $message = Get-DisableRunFailureMessage -Summary $result
    #>
    param([Parameter(Mandatory = $true)][object]$Summary)

    $unconfirmed = @()
    if ($Summary.PSObject.Properties['UnconfirmedRemovals']) { $unconfirmed = @($Summary.UnconfirmedRemovals | Where-Object { $null -ne $_ }) }
    $count = 0
    if ($Summary.PSObject.Properties['CleanupFailureCount']) { $count = [int]$Summary.CleanupFailureCount }
    if ($count -lt $unconfirmed.Count) { $count = $unconfirmed.Count }
    $lookups = @()
    if ($Summary.PSObject.Properties['LeftoverLookupFailures']) { $lookups = @($Summary.LeftoverLookupFailures | Where-Object { $null -ne $_ }) }
    if ($count -eq 0 -and $lookups.Count -eq 0) { return '' }

    $parts = New-Object System.Collections.ArrayList
    if ($count -gt 0) {
        $named = @($unconfirmed | ForEach-Object { 'subscription {0} assignment {1}' -f $_.SubscriptionId, $_.AssignmentName })
        if ($named.Count -eq 0) { $named = @('see Failures in the summary') }
        [void]$parts.Add(('{0} temporary Owner assignment(s) of this identity could not be confirmed removed, so it may still be an unconditioned Owner there: {1}. Remove each by hand: DELETE /subscriptions/<subscription>/providers/Microsoft.Authorization/roleAssignments/<assignment>.' -f $count, ($named -join '; ')))
    }
    if ($lookups.Count -gt 0) {
        $scopes = @($lookups | ForEach-Object { [string]$_.Scope })
        [void]$parts.Add(('Leftover temporary Owner assignments could not be looked for at {0} scope(s): {1}. Check those scopes for assignments whose description starts with "{2}".' -f $lookups.Count, ($scopes -join '; '), $script:DusDescriptionPrefix))
    }
    return ('Disable-UnauthorizedSubscriptions run {0} failed after emitting its summary. {1}' -f $Summary.RunId, ($parts.ToArray() -join ' '))
}

function ConvertTo-DecisionReportRow {
    <#
    .SYNOPSIS
        A flat CSV row for one decision.
    .PARAMETER Decision
        Output of Get-SubscriptionDecision.
    .EXAMPLE
        $decisions | ForEach-Object { ConvertTo-DecisionReportRow -Decision $_ } | Export-Csv -Path $path -NoTypeInformation
    #>
    param([Parameter(Mandatory = $true)][object]$Decision)

    return [PSCustomObject]([ordered]@{
            SubscriptionId          = $Decision.SubscriptionId
            DisplayName             = $Decision.DisplayName
            State                   = $Decision.State
            QuotaId                 = $Decision.QuotaId
            MatchedPattern          = $Decision.MatchedPattern
            Decision                = $Decision.Decision
            Reason                  = $Decision.Reason
            DirectOwnerCount        = $Decision.DirectOwnerCount
            HumanOwnerIds           = (@($Decision.HumanOwnerIds) -join ';')
            AllowedOwnerIds         = (@($Decision.AllowedOwnerIds) -join ';')
            OtherHumanOwnerIds      = (@($Decision.OtherHumanOwnerIds) -join ';')
            GroupOwnerIds           = (@($Decision.GroupOwnerIds) -join ';')
            EligibleAllowedOwnerIds = (@($Decision.EligibleAllowedOwnerIds) -join ';')
            IgnoredOwnerCount       = $Decision.IgnoredOwnerCount
        })
}

# ---------------------------------------------------------------------------
# Reads. Graph and ARM through the library.
# ---------------------------------------------------------------------------

function Get-AllowedPrincipalIds {
    <#
    .SYNOPSIS
        The set of allowed owner object ids: users by UPN, plus the
        transitive user members of each allowed group.
    .DESCRIPTION
        The group ids themselves are not in the set: only a User owner can
        make a subscription allowed.
    .PARAMETER Upns
        Allowed user principal names.
    .PARAMETER GroupNames
        Allowed group display names.
    .EXAMPLE
        $allowed = Get-AllowedPrincipalIds -Upns @('alex@corp.example.com') -GroupNames @('SEC Subscription Owners')
    #>
    param(
        [AllowEmptyCollection()][string[]]$Upns = @(),
        [AllowEmptyCollection()][string[]]$GroupNames = @()
    )

    $ids = New-Object System.Collections.ArrayList
    foreach ($upn in $Upns) {
        $userId = [string](Resolve-UserIdByUpn -UserPrincipalName $upn)
        [void]$ids.Add($userId)
        Write-RunLog -Level Info -Message ('Allowed owner {0} is object {1}.' -f $upn, $userId)
    }
    foreach ($groupName in $GroupNames) {
        $groupId = [string](Resolve-GroupIdByName -DisplayName $groupName)
        $members = @(Get-TransitiveGroupMemberIds -GroupId $groupId -MemberType User)
        foreach ($member in $members) { [void]$ids.Add([string]$member) }
        Write-RunLog -Level Info -Message ('Allowed owner group "{0}" ({1}) has {2} transitive user member(s).' -f $groupName, $groupId, $members.Count)
    }
    $set = New-PrincipalIdSet -Ids $ids.ToArray()
    return , $set
}

function Resolve-ExcludedSubscriptionIds {
    <#
    .SYNOPSIS
        Turns the exclusion list into subscription ids, before any write.
    .DESCRIPTION
        An entry that is a GUID is kept as an id. Any other entry is a
        display name and is matched, trimmed and ignoring case, against the
        swept subscriptions: more than one match throws (any Owner can
        rename a subscription, so an ambiguous name cannot be trusted), no
        match is logged as a warning, and one match is logged as a warning
        that names the id to use instead. Returns an ordered dictionary of
        normalised id to how it was listed ('by id' or 'by display name
        "<name>"').
    .PARAMETER Entries
        The parsed ExcludedSubscriptionNames.
    .PARAMETER Subscriptions
        The swept ARM subscription objects.
    .EXAMPLE
        $excludedIds = Resolve-ExcludedSubscriptionIds -Entries $excluded -Subscriptions $subscriptions
    #>
    param(
        [AllowEmptyCollection()][string[]]$Entries = @(),
        [AllowEmptyCollection()][object[]]$Subscriptions = @()
    )

    $map = [ordered]@{}
    foreach ($entry in $Entries) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $text = $entry.Trim()
        $asId = ConvertTo-NormalizedObjectId -Value $text
        if ($asId) {
            if (-not $map.Contains($asId)) { $map[$asId] = 'by id' }
            continue
        }
        $named = @($Subscriptions | Where-Object { $null -ne $_ -and ([string]$_.displayName).Trim().Equals($text, [StringComparison]::OrdinalIgnoreCase) })
        if ($named.Count -gt 1) {
            $ids = @($named | ForEach-Object { ConvertTo-NormalizedObjectId -Value ([string]$_.subscriptionId) })
            throw ('ExcludedSubscriptionNames entry "{0}" matches {1} subscriptions ({2}). Any Owner can rename a subscription, so an ambiguous name cannot be trusted; list the subscription id instead. Nothing was changed.' -f $text, $named.Count, ($ids -join ', '))
        }
        if ($named.Count -eq 0) {
            Write-RunLog -Level Warn -Message ('ExcludedSubscriptionNames entry "{0}" matches no swept subscription.' -f $text)
            continue
        }
        $id = ConvertTo-NormalizedObjectId -Value ([string]$named[0].subscriptionId)
        Write-RunLog -Level Warn -Message ('ExcludedSubscriptionNames entry "{0}" is a display name, resolved to subscription {1}. Any Owner can rename a subscription; list the id instead.' -f $text, $id)
        if ($id -and -not $map.Contains($id)) { $map[$id] = ('by display name "{0}"' -f $text) }
    }
    return $map
}

function Resolve-OwnerRoleId {
    <#
    .SYNOPSIS
        The Owner role definition GUID, resolved by name at a subscription
        scope and checked against the documented built-in id.
    .DESCRIPTION
        GET /subscriptions/{id}/providers/Microsoft.Authorization/roleDefinitions
        with $filter=roleName eq 'Owner'. Throws when there is not exactly one
        built-in Owner, or when its id differs from the one the delegation
        condition names, because the grant would then be refused anyway.
    .PARAMETER SubscriptionId
        A subscription to resolve at.
    .EXAMPLE
        $ownerRoleId = Resolve-OwnerRoleId -SubscriptionId $id
    #>
    param([Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SubscriptionId)

    $filter = [Uri]::EscapeDataString("roleName eq 'Owner'")
    $uri = 'subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions?$filter={1}' -f $SubscriptionId, $filter
    $definitions = @(Invoke-CloudRequest -Api Arm -Uri $uri -ApiVersion $script:DusApiVersions.Authorization -AllPages)
    $named = @($definitions | Where-Object { $null -ne $_.properties -and ([string]$_.properties.roleName).Equals('Owner', [StringComparison]::OrdinalIgnoreCase) })
    $builtIn = @($named | Where-Object { ([string]$_.properties.type).Equals('BuiltInRole', [StringComparison]::OrdinalIgnoreCase) })
    if ($builtIn.Count -eq 1) { $named = $builtIn }
    if ($named.Count -ne 1) {
        throw ('Expected one built-in Owner role definition at /subscriptions/{0}, found {1}.' -f $SubscriptionId, $named.Count)
    }
    $roleId = ConvertTo-NormalizedObjectId -Value ([string]$named[0].name)
    if ([string]::IsNullOrEmpty($roleId)) { $roleId = Get-RoleDefinitionGuid -RoleDefinitionId ([string]$named[0].id) }
    if ($roleId -ne $script:DusOwnerRoleId) {
        throw ('The Owner role resolved to {0}, not the documented built-in id {1} that the delegation condition names. Nothing was changed.' -f $roleId, $script:DusOwnerRoleId)
    }
    Write-RunLog -Level Info -Message ('Owner role definition resolved by name: {0}.' -f $roleId)
    return $roleId
}

function Get-SubscriptionRoleAssignments {
    <#
    .SYNOPSIS
        Role assignments at or above a subscription ($filter=atScope()).
    .PARAMETER SubscriptionId
        Subscription id.
    .EXAMPLE
        $items = @(Get-SubscriptionRoleAssignments -SubscriptionId $id)
    #>
    param([Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SubscriptionId)

    $uri = 'subscriptions/{0}/providers/Microsoft.Authorization/roleAssignments?$filter={1}' -f $SubscriptionId, [Uri]::EscapeDataString('atScope()')
    return @(Invoke-CloudRequest -Api Arm -Uri $uri -ApiVersion $script:DusApiVersions.Authorization -AllPages)
}

function Get-SubscriptionEligibilityInstances {
    <#
    .SYNOPSIS
        Azure PIM role eligibility schedule instances at or above a
        subscription ($filter=atScope()).
    .DESCRIPTION
        GET /subscriptions/{id}/providers/Microsoft.Authorization/roleEligibilityScheduleInstances
        with api-version 2020-10-01, every page. Reader covers it. Wrap in
        @(); Get-EligibleOwnerIds picks the Owner instances at the
        subscription itself.
    .PARAMETER SubscriptionId
        Subscription id.
    .EXAMPLE
        $eligible = @(Get-SubscriptionEligibilityInstances -SubscriptionId $id)
    #>
    param([Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SubscriptionId)

    $uri = 'subscriptions/{0}/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?$filter={1}' -f $SubscriptionId, [Uri]::EscapeDataString('atScope()')
    return @(Invoke-CloudRequest -Api Arm -Uri $uri -ApiVersion $script:DusApiVersions.Eligibility -AllPages)
}

function Get-SubscriptionState {
    <#
    .SYNOPSIS
        The state ARM reports for one subscription now (Enabled, Disabled,
        Warned, PastDue, Deleted), or '' when the reply has none.
    .DESCRIPTION
        GET /subscriptions/{id} with the library's Subscriptions
        api-version. Used after a cancel call that ended without a clear
        answer. Throws when the read fails.
    .PARAMETER SubscriptionId
        Subscription id.
    .EXAMPLE
        Get-SubscriptionState -SubscriptionId $id
    #>
    param([Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SubscriptionId)

    $subscription = Invoke-CloudRequest -Api Arm -Uri ('subscriptions/{0}' -f $SubscriptionId) -ApiVersion $script:DusApiVersions.Subscriptions
    if ($null -eq $subscription -or -not (Test-RunbookJsonObject -Value $subscription)) { return '' }
    if ($null -eq $subscription.PSObject.Properties['state']) { return '' }
    return ([string]$subscription.state).Trim()
}

function Get-IdentityOwnerAssignments {
    <#
    .SYNOPSIS
        Direct Owner assignments of one principal on subscriptions at or
        below a scope.
    .DESCRIPTION
        GET <scope>/providers/Microsoft.Authorization/roleAssignments with
        $filter=principalId eq '<id>', which returns the principal's
        assignments at, above, and below the scope. Keeps every Owner
        assignment of the principal, whatever its scope: a management group,
        a resource group, or a resource is reported rather than dropped,
        because an unconditioned Owner assignment of this identity at the
        management group is the escalation the delegation condition cannot
        prevent (docs/adr/0014). Writes SubscriptionId (empty unless the
        scope is exactly one subscription), Scope, Name, Description,
        CreatedOn, IsTemporary. Only an item with a SubscriptionId is ever
        removed. Wrap in @().
    .PARAMETER Scope
        /providers/Microsoft.Management/managementGroups/<id> or /subscriptions/<id>.
    .PARAMETER PrincipalId
        The identity's object id.
    .PARAMETER OwnerRoleId
        Owner role definition GUID.
    .EXAMPLE
        @(Get-IdentityOwnerAssignments -Scope $mgScope -PrincipalId $selfId -OwnerRoleId $ownerRoleId)
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$PrincipalId,
        [Parameter(Mandatory = $true)][string]$OwnerRoleId
    )

    $filter = [Uri]::EscapeDataString(("principalId eq '{0}'" -f $PrincipalId))
    $uri = '{0}/providers/Microsoft.Authorization/roleAssignments?$filter={1}' -f $Scope.Trim().Trim('/'), $filter
    $ownerGuid = ConvertTo-NormalizedObjectId -Value $OwnerRoleId
    $selfId = ConvertTo-NormalizedObjectId -Value $PrincipalId
    foreach ($assignment in @(Invoke-CloudRequest -Api Arm -Uri $uri -ApiVersion $script:DusApiVersions.Authorization -AllPages)) {
        $properties = $assignment.properties
        if ($null -eq $properties) { continue }
        if ((ConvertTo-NormalizedObjectId -Value $properties.principalId) -ne $selfId) { continue }
        if ((Get-RoleDefinitionGuid -RoleDefinitionId ([string]$properties.roleDefinitionId)) -ne $ownerGuid) { continue }
        $assignmentScope = ([string]$properties.scope).Trim().TrimEnd('/')
        if ([string]::IsNullOrEmpty($assignmentScope)) { $assignmentScope = '/' }
        $subscriptionId = ''
        if ($assignmentScope -match '^/subscriptions/([0-9a-fA-F-]{36})$') {
            $subscriptionId = ConvertTo-NormalizedObjectId -Value $Matches[1]
        }
        [PSCustomObject]@{
            SubscriptionId = $subscriptionId
            Scope          = $assignmentScope
            Name           = [string]$assignment.name
            Description    = [string]$properties.description
            CreatedOn      = (ConvertTo-TimestampText -Value $properties.createdOn)
            IsTemporary    = (Test-TemporaryElevation -Description ([string]$properties.description))
        }
    }
}

function Resolve-IdentityPrincipalId {
    <#
    .SYNOPSIS
        The object id of the principal this run acts as.
    .DESCRIPTION
        Uses -IdentityPrincipalId when given and the oid claim of the ARM
        token otherwise; when both are known they must agree. A live run
        throws when the id cannot be determined or the two disagree; a dry
        run warns and carries on.
    .PARAMETER Configured
        The IdentityPrincipalId parameter.
    .PARAMETER DryRun
        Whether the run is dry.
    .EXAMPLE
        $selfId = Resolve-IdentityPrincipalId -Configured $IdentityPrincipalId -DryRun $DryRun
    #>
    param(
        [AllowEmptyString()][string]$Configured = '',
        [bool]$DryRun = $true
    )

    $configuredId = ConvertTo-NormalizedObjectId -Value $Configured
    if (-not [string]::IsNullOrWhiteSpace($Configured) -and [string]::IsNullOrEmpty($configuredId)) {
        throw 'IdentityPrincipalId is not a GUID.'
    }
    $tokenId = ''
    $tokenProblem = ''
    try { $tokenId = Get-AccessTokenObjectId -AccessToken (Get-RunbookAccessToken -Resource Arm) }
    catch { $tokenProblem = Protect-RunbookText -Text $_.Exception.Message -MaxLength 300 }

    if ($configuredId -and $tokenId -and $configuredId -ne $tokenId) {
        $message = ('IdentityPrincipalId {0} does not match the oid {1} of the ARM token, so this run is not signed in as the identity the delegation condition names.' -f $configuredId, $tokenId)
        if ($DryRun) { Write-RunLog -Level Warn -Message $message; return $configuredId }
        throw $message
    }
    if ($configuredId) { return $configuredId }
    if ($tokenId) { return $tokenId }
    if ($DryRun) {
        Write-RunLog -Level Warn -Message ('The identity principal id is unknown ({0}). The dry run continues; a live run would stop here.' -f $tokenProblem)
        return ''
    }
    throw $tokenProblem
}

function Get-OwnerContacts {
    <#
    .SYNOPSIS
        Display name and mail address of each human owner.
    .DESCRIPTION
        GET users/{id}?$select=id,displayName,userPrincipalName,mail per
        owner. An id that is empty or not a GUID is skipped without a
        request (users/?$select=... would list users instead). A user that
        cannot be read is logged and skipped. Writes Id, Name, Address; wrap
        in @().
    .PARAMETER UserIds
        Owner object ids.
    .EXAMPLE
        $contacts = @(Get-OwnerContacts -UserIds $decision.HumanOwnerIds)
    #>
    param([AllowEmptyCollection()][string[]]$UserIds = @())

    foreach ($rawId in $UserIds) {
        $userId = ConvertTo-NormalizedObjectId -Value $rawId
        if ([string]::IsNullOrEmpty($userId)) {
            Write-RunLog -Level Warn -Message 'Skipped an owner without a valid object id; no notice for that owner.'
            continue
        }
        $user = $null
        try {
            $user = Invoke-CloudRequest -Api Graph -Uri ('users/{0}?$select=id,displayName,userPrincipalName,mail' -f $userId)
        }
        catch {
            Write-RunLog -Level Warn -Message ('Could not read owner {0} (HTTP {1}); no notice for this owner.' -f $userId, (Get-CloudErrorStatus -ErrorRecord $_))
            continue
        }
        $name = [string]$user.displayName
        if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$user.userPrincipalName }
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $userId }
        [PSCustomObject]@{ Id = $userId; Name = $name; Address = (Get-UserMailAddress -User $user) }
    }
}

# ---------------------------------------------------------------------------
# Writes. Called only from Invoke-RunbookAction blocks.
# ---------------------------------------------------------------------------

function New-TemporaryOwnerAssignment {
    <#
    .SYNOPSIS
        PUT the temporary Owner assignment for the identity on one subscription.
    .PARAMETER SubscriptionId
        Subscription id.
    .PARAMETER AssignmentName
        New GUID naming the assignment.
    .PARAMETER PrincipalId
        The identity's object id.
    .PARAMETER OwnerRoleId
        Owner role definition GUID.
    .PARAMETER RunId
        Stamped into the description.
    .EXAMPLE
        New-TemporaryOwnerAssignment -SubscriptionId $id -AssignmentName ([Guid]::NewGuid().ToString()) -PrincipalId $selfId -OwnerRoleId $ownerRoleId -RunId $runId
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][string]$AssignmentName,
        [Parameter(Mandatory = $true)][string]$PrincipalId,
        [Parameter(Mandatory = $true)][string]$OwnerRoleId,
        [AllowEmptyString()][string]$RunId = ''
    )

    $body = @{
        properties = @{
            roleDefinitionId = ('/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $SubscriptionId, $OwnerRoleId)
            principalId      = $PrincipalId
            principalType    = 'ServicePrincipal'
            description      = ('{0}, run {1}. Removed by the same run.' -f $script:DusDescriptionPrefix, $RunId)
        }
    }
    $uri = 'subscriptions/{0}/providers/Microsoft.Authorization/roleAssignments/{1}' -f $SubscriptionId, $AssignmentName
    return (Invoke-CloudRequest -Api Arm -Method PUT -Uri $uri -ApiVersion $script:DusApiVersions.Authorization -Body $body)
}

function Test-CancelMayHaveBeenApplied {
    <#
    .SYNOPSIS
        True when a failed request carries the library's MayHaveBeenApplied
        flag: a POST that was not repeated after a server error or a lost
        response.
    .DESCRIPTION
        Walks the exception and its inner exceptions for
        Data['MayHaveBeenApplied'].
    .PARAMETER ErrorRecord
        $_ in a catch block, or the exception itself.
    .EXAMPLE
        catch { $uncertain = Test-CancelMayHaveBeenApplied -ErrorRecord $_; throw }
    #>
    param([AllowNull()][object]$ErrorRecord)

    $exception = $ErrorRecord
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $exception = $ErrorRecord.Exception }
    while ($exception -is [Exception]) {
        if ($exception.Data.Contains('MayHaveBeenApplied') -and [bool]$exception.Data['MayHaveBeenApplied']) { return $true }
        $exception = $exception.InnerException
    }
    return $false
}

function Invoke-SubscriptionCancel {
    <#
    .SYNOPSIS
        POST the cancel operation (the subscription then shows Disabled),
        retrying while ARM answers 403.
    .DESCRIPTION
        A 403 right after the temporary Owner assignment is created means the
        assignment has not propagated; the call is repeated after
        Get-ElevationRetryDelaySeconds, up to MaxAttempts. Any other failure,
        or a 403 on the last attempt, is thrown. The library repeats the
        POST after a 429 only: a server error or a lost response is thrown
        at once with MayHaveBeenApplied set (see
        Test-CancelMayHaveBeenApplied), because the cancel may already have
        been applied. The call deliberately does not pass
        -RetryNonIdempotent.
    .PARAMETER SubscriptionId
        Subscription id.
    .PARAMETER MaxAttempts
        Attempts while the answer is 403.
    .PARAMETER BaseSeconds
        ElevationPropagationSeconds.
    .EXAMPLE
        Invoke-SubscriptionCancel -SubscriptionId $id -MaxAttempts 5 -BaseSeconds 60
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [ValidateRange(1, 20)][int]$MaxAttempts = 5,
        [ValidateRange(0, 3600)][int]$BaseSeconds = 60
    )

    $uri = 'subscriptions/{0}/providers/Microsoft.Subscription/cancel' -f $SubscriptionId
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return (Invoke-CloudRequest -Api Arm -Method POST -Uri $uri -ApiVersion $script:DusApiVersions.Subscription)
        }
        catch {
            $status = Get-CloudErrorStatus -ErrorRecord $_
            if ($status -ne 403 -or $attempt -ge $MaxAttempts) { throw }
            $wait = Get-ElevationRetryDelaySeconds -Attempt $attempt -BaseSeconds $BaseSeconds
            Write-RunLog -Level Warn -Message ('Cancel on subscription {0} returned HTTP 403 while the temporary Owner assignment propagates; retrying in {1}s (attempt {2} of {3}).' -f $SubscriptionId, $wait, $attempt, $MaxAttempts)
            Start-Sleep -Seconds $wait
        }
    }
}

function Remove-TemporaryOwnerAssignment {
    <#
    .SYNOPSIS
        DELETE a temporary Owner assignment and confirm with GET that it is gone.
    .DESCRIPTION
        Repeats DELETE then GET until the GET answers 404, up to MaxChecks
        times. With -VerifyOnly the first pass only checks (the PUT was
        refused, so nothing should exist); if the assignment exists after
        all, it is deleted. A DELETE that fails is still followed by the GET:
        a 404 there means the assignment is gone and the error is dropped,
        and only an assignment that is still present rethrows the DELETE
        error. Throws when the removal cannot be confirmed.
    .PARAMETER SubscriptionId
        Subscription id.
    .PARAMETER AssignmentName
        Assignment GUID.
    .PARAMETER VerifyOnly
        Check before deleting.
    .PARAMETER MaxChecks
        Default 3.
    .EXAMPLE
        Remove-TemporaryOwnerAssignment -SubscriptionId $id -AssignmentName $name
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][string]$AssignmentName,
        [switch]$VerifyOnly,
        [ValidateRange(1, 10)][int]$MaxChecks = 3
    )

    $uri = 'subscriptions/{0}/providers/Microsoft.Authorization/roleAssignments/{1}' -f $SubscriptionId, $AssignmentName
    $deleteFirst = -not $VerifyOnly
    $manual = 'Remove it by hand: DELETE /subscriptions/{0}/providers/Microsoft.Authorization/roleAssignments/{1}' -f $SubscriptionId, $AssignmentName
    for ($check = 1; $check -le $MaxChecks; $check++) {
        $deleteError = ''
        if ($deleteFirst) {
            try {
                Invoke-CloudRequest -Api Arm -Method DELETE -Uri $uri -ApiVersion $script:DusApiVersions.Authorization | Out-Null
            }
            catch {
                $deleteError = Protect-RunbookText -Text $_.Exception.Message -MaxLength 300
            }
        }
        $present = $true
        try {
            Invoke-CloudRequest -Api Arm -Uri $uri -ApiVersion $script:DusApiVersions.Authorization | Out-Null
        }
        catch {
            $status = Get-CloudErrorStatus -ErrorRecord $_
            if ($status -eq 404) { $present = $false }
            else {
                $readError = Protect-RunbookText -Text $_.Exception.Message -MaxLength 300
                if ($deleteError) { $readError = ('{0} (the DELETE before it also failed: {1})' -f $readError, $deleteError) }
                throw ('Could not confirm that temporary Owner assignment {0} on subscription {1} is gone: {2}. {3}' -f $AssignmentName, $SubscriptionId, $readError, $manual)
            }
        }
        if (-not $present) {
            if ($deleteError) {
                Write-RunLog -Level Info -Message ('DELETE of temporary Owner assignment {0} on subscription {1} failed, but ARM reports it gone (HTTP 404): {2}' -f $AssignmentName, $SubscriptionId, $deleteError)
            }
            return
        }
        if ($deleteError) {
            throw ('Could not remove temporary Owner assignment {0} on subscription {1}, and it is still present: {2}. {3}' -f $AssignmentName, $SubscriptionId, $deleteError, $manual)
        }
        $deleteFirst = $true
        if ($check -lt $MaxChecks) {
            $wait = Get-RetryDelaySeconds -Attempt $check
            Write-RunLog -Level Warn -Message ('Temporary Owner assignment {0} on subscription {1} still exists (check {2} of {3}); removing again in {4}s.' -f $AssignmentName, $SubscriptionId, $check, $MaxChecks, $wait)
            Start-Sleep -Seconds $wait
        }
    }
    throw ('Temporary Owner assignment {0} on subscription {1} still exists after {2} check(s). {3}' -f $AssignmentName, $SubscriptionId, $MaxChecks, $manual)
}

function Invoke-JitSubscriptionCancel {
    <#
    .SYNOPSIS
        Grant, cancel, and always remove: the elevation sequence for one
        candidate, with every step recorded on the summary.
    .DESCRIPTION
        Throws before anything else unless AllowCancel is true: the
        elevation must never happen unless the cancel would. Actions
        recorded: GrantTemporaryOwner, CancelSubscription (Skipped when the
        grant failed), RemoveTemporaryOwner. The removal runs in a finally
        block whatever happened before it. In a dry run each step is logged
        as "Would" and nothing is called. Returns Grant, Cancel, Cleanup
        (Planned, Done, Failed, or Skipped), Canceled, CancelMayHaveBeenApplied
        (the cancel call failed without a clear answer), and AssignmentName.
    .PARAMETER AllowCancel
        Must be true.
    .PARAMETER Summary
        The run summary.
    .PARAMETER Decision
        The Candidate decision.
    .PARAMETER PrincipalId
        The identity's object id.
    .PARAMETER OwnerRoleId
        Owner role definition GUID.
    .PARAMETER PropagationSeconds
        ElevationPropagationSeconds.
    .PARAMETER MaxAttempts
        MaxDisableAttempts.
    .PARAMETER RunId
        Correlation id.
    .EXAMPLE
        $result = Invoke-JitSubscriptionCancel -AllowCancel $AllowCancel -Summary $summary -Decision $d -PrincipalId $selfId -OwnerRoleId $ownerRoleId
    #>
    param(
        [Parameter(Mandatory = $true)][bool]$AllowCancel,
        [Parameter(Mandatory = $true)][object]$Summary,
        [Parameter(Mandatory = $true)][object]$Decision,
        [AllowEmptyString()][string]$PrincipalId = '',
        [Parameter(Mandatory = $true)][string]$OwnerRoleId,
        [ValidateRange(0, 3600)][int]$PropagationSeconds = 60,
        [ValidateRange(1, 20)][int]$MaxAttempts = 5,
        [AllowEmptyString()][string]$RunId = ''
    )

    if (-not $AllowCancel) {
        throw ('Refusing to elevate on subscription {0}: AllowCancel is false, and the temporary Owner assignment exists only for a cancel. Nothing was changed.' -f $Decision.SubscriptionId)
    }

    # Names inside the blocks avoid Invoke-RunbookAction's parameter names.
    $jit = @{ Name = [Guid]::NewGuid().ToString(); CreateStatus = -1; Canceled = $false; Uncertain = $false }
    $subId = [string]$Decision.SubscriptionId
    $label = '{0} ({1})' -f $Decision.DisplayName, $subId
    $grantOutcome = 'Skipped'
    $cancelOutcome = 'Skipped'
    $cleanupOutcome = 'Skipped'
    try {
        $grantOutcome = Invoke-RunbookAction -Summary $Summary -Action 'GrantTemporaryOwner' -Target $label -PassThru `
            -Description ('grant temporary Owner assignment {0} on {1} to this identity ({2})' -f $jit.Name, $label, $PrincipalId) `
            -ScriptBlock {
            if ([string]::IsNullOrEmpty($PrincipalId)) { throw 'The identity principal id is unknown.' }
            $jit.CreateStatus = 0
            try {
                New-TemporaryOwnerAssignment -SubscriptionId $subId -AssignmentName $jit.Name -PrincipalId $PrincipalId -OwnerRoleId $OwnerRoleId -RunId $RunId | Out-Null
                $jit.CreateStatus = 201
            }
            catch {
                $jit.CreateStatus = Get-CloudErrorStatus -ErrorRecord $_
                throw
            }
        }

        if ($grantOutcome -eq 'Failed') {
            Add-RunSummaryItem -Summary $Summary -Action 'CancelSubscription' -Target $label -Outcome Skipped -Detail 'not attempted: the temporary Owner assignment was not created'
            Write-RunLog -Level Warn -Message ('Not canceling {0}: the temporary Owner assignment was not created.' -f $label)
        }
        else {
            $cancelOutcome = Invoke-RunbookAction -Summary $Summary -Action 'CancelSubscription' -Target $label -PassThru `
                -Description ('cancel {0} with Microsoft.Subscription/cancel, which leaves it Disabled (quotaId {1}; Azure deletes it 90 days after cancellation; reactivation within 90 days: portal for pay-as-you-go, Azure support for other offers)' -f $label, $Decision.QuotaId) `
                -ScriptBlock {
                if ($PropagationSeconds -gt 0) { Start-Sleep -Seconds $PropagationSeconds }
                try {
                    Invoke-SubscriptionCancel -SubscriptionId $subId -MaxAttempts $MaxAttempts -BaseSeconds $PropagationSeconds | Out-Null
                }
                catch {
                    $jit.Uncertain = Test-CancelMayHaveBeenApplied -ErrorRecord $_
                    throw
                }
                $jit.Canceled = $true
            }
        }
    }
    finally {
        # A PUT refused with a 4xx created nothing: check, do not delete.
        $refused = ($jit.CreateStatus -ge 400 -and $jit.CreateStatus -lt 500)
        $cleanupOutcome = Invoke-RunbookAction -Summary $Summary -Action 'RemoveTemporaryOwner' -Target $label -PassThru `
            -Description ('remove temporary Owner assignment {0} from {1} and confirm it is gone' -f $jit.Name, $label) `
            -ScriptBlock {
            Remove-TemporaryOwnerAssignment -SubscriptionId $subId -AssignmentName $jit.Name -VerifyOnly:$refused
        }
    }

    return [PSCustomObject]@{
        Grant                    = $grantOutcome
        Cancel                   = $cancelOutcome
        Cleanup                  = $cleanupOutcome
        Canceled                 = [bool]$jit.Canceled
        CancelMayHaveBeenApplied = ([bool]$jit.Uncertain -and -not [bool]$jit.Canceled)
        AssignmentName           = $jit.Name
    }
}

function Invoke-LeftoverOwnerSweep {
    <#
    .SYNOPSIS
        Finds and removes this identity's temporary Owner assignments left
        by a job that could not finish.
    .DESCRIPTION
        Runs before the circuit breaker, because it only takes this
        identity's own access away. Starts from the TemporaryAssignments the
        decision pass found, then asks ARM with a principalId filter at
        ManagementGroupScope when one is given, or otherwise at every swept
        subscription whose owners were not read (OwnersRead false). A direct
        Owner assignment of the identity without the temporary description
        is logged as a warning and left alone. An Owner assignment of the
        identity whose scope is not exactly one subscription is never
        removed either, whatever its description: this runbook only creates
        subscription-scoped ones, so it did not create that. Each is logged
        at Warn, recorded as a Failed ReviewOwnerAssignment item, and carried
        in OffScope for the digest, because an unconditioned Owner assignment
        of this identity at the management group is the escalation the
        delegation condition cannot prevent (docs/adr/0014). A temporary
        assignment younger than WindowMinutes is left alone, logged, and
        recorded as a Skipped RemoveLeftoverOwner item, because another job
        may still be using it. Every other one is removed through
        Invoke-RunbookAction as RemoveLeftoverOwner. A look-up that fails is
        logged at Error and recorded as a Failed FindLeftoverOwner item.
        Returns Found, Removed, Planned, and Skipped (assignment names),
        Unconfirmed (SubscriptionId, AssignmentName, Detail), LookupFailures
        (Scope, Detail), and OffScope (Scope, Name, CreatedOn, IsTemporary).
    .PARAMETER RunSummary
        The run summary.
    .PARAMETER Decisions
        Output of Get-SubscriptionDecision for every swept subscription.
    .PARAMETER ManagementGroupScope
        /providers/Microsoft.Management/managementGroups/<id>, or ''.
    .PARAMETER PrincipalId
        The identity's object id. Nothing is looked for when it is empty.
    .PARAMETER OwnerRoleId
        Owner role definition GUID.
    .PARAMETER Now
        The clock.
    .PARAMETER WindowMinutes
        From Get-ElevationWindowMinutes.
    .EXAMPLE
        $sweep = Invoke-LeftoverOwnerSweep -RunSummary $summary -Decisions $decisions -PrincipalId $selfId -OwnerRoleId $ownerRoleId
    #>
    param(
        [Parameter(Mandatory = $true)][object]$RunSummary,
        [AllowNull()][AllowEmptyCollection()][object[]]$Decisions = @(),
        [AllowEmptyString()][string]$ManagementGroupScope = '',
        [AllowEmptyString()][string]$PrincipalId = '',
        [Parameter(Mandatory = $true)][string]$OwnerRoleId,
        [DateTime]$Now = [DateTime]::UtcNow,
        [ValidateRange(0, 100000)][int]$WindowMinutes = 44
    )

    $sweep = [PSCustomObject]@{
        Found          = (New-Object System.Collections.ArrayList)
        Removed        = (New-Object System.Collections.ArrayList)
        Planned        = (New-Object System.Collections.ArrayList)
        Skipped        = (New-Object System.Collections.ArrayList)
        Unconfirmed    = (New-Object System.Collections.ArrayList)
        LookupFailures = (New-Object System.Collections.ArrayList)
        OffScope       = (New-Object System.Collections.ArrayList)
    }
    if ([string]::IsNullOrEmpty($PrincipalId)) {
        Write-RunLog -Level Warn -Message 'The identity principal id is unknown, so leftover temporary Owner assignments were not looked for.'
        return $sweep
    }

    $labels = @{}
    $reported = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $offScope = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $leftovers = New-Object System.Collections.ArrayList
    $unread = New-Object System.Collections.ArrayList
    foreach ($decision in @($Decisions)) {
        if ($null -eq $decision) { continue }
        $subscriptionId = ConvertTo-NormalizedObjectId -Value ([string]$decision.SubscriptionId)
        if ([string]::IsNullOrEmpty($subscriptionId)) { continue }
        $label = '{0} ({1})' -f $decision.DisplayName, $subscriptionId
        $labels[$subscriptionId] = $label
        if (-not $decision.OwnersRead) { [void]$unread.Add('/subscriptions/' + $subscriptionId) }
        foreach ($name in @($decision.OtherSelfAssignments)) {
            if ($name) { [void]$reported.Add([string]$name) }
        }
        foreach ($temporary in @($decision.TemporaryAssignments)) {
            if ($null -eq $temporary) { continue }
            if ($seen.Add([string]$temporary.Name)) {
                [void]$leftovers.Add([PSCustomObject]@{ SubscriptionId = $subscriptionId; Name = [string]$temporary.Name; CreatedOn = [string]$temporary.CreatedOn; Label = $label })
            }
        }
    }

    $scopes = @($unread.ToArray())
    if ($ManagementGroupScope) { $scopes = @($ManagementGroupScope) }
    foreach ($scope in $scopes) {
        $found = @()
        try { $found = @(Get-IdentityOwnerAssignments -Scope $scope -PrincipalId $PrincipalId -OwnerRoleId $OwnerRoleId) }
        catch {
            $problem = Protect-RunbookText -Text $_.Exception.Message -MaxLength 300
            Write-RunLog -Level Error -Message ('Could not look for leftover temporary Owner assignments of this identity at {0}: {1}' -f $scope, $problem)
            Add-RunSummaryItem -Summary $RunSummary -Action 'FindLeftoverOwner' -Target $scope -Outcome Failed -Detail $problem
            [void]$sweep.LookupFailures.Add([PSCustomObject]@{ Scope = $scope; Detail = $problem })
            continue
        }
        foreach ($item in $found) {
            # An Owner assignment of this identity whose scope is not exactly
            # one subscription (a management group, a resource group, a
            # resource) is never removed: this runbook only ever creates
            # subscription-scoped ones, so it did not create this. It is the
            # escalation the delegation condition cannot prevent, so it is
            # reported loudly instead of being dropped (docs/adr/0014).
            if ([string]::IsNullOrEmpty([string]$item.SubscriptionId)) {
                $itemScope = [string]$item.Scope
                if ([string]::IsNullOrEmpty($itemScope)) { $itemScope = '(scope not reported)' }
                if ($offScope.Add(([string]$item.Name) + '|' + $itemScope)) {
                    $why = ('scope {0} is not a single subscription, so this runbook did not create it and does not remove it; an unconditioned Owner assignment of this identity above a subscription is an escalation: review it and remove it by hand' -f $itemScope)
                    Write-RunLog -Level Warn -Message ('This identity holds a direct Owner assignment {0} at {1}. {2}' -f $item.Name, $itemScope, $why)
                    Add-RunSummaryItem -Summary $RunSummary -Action 'ReviewOwnerAssignment' -Target $itemScope -Outcome Failed -Detail ('{0}: {1}' -f $item.Name, $why)
                    [void]$sweep.OffScope.Add([PSCustomObject]@{ Scope = $itemScope; Name = [string]$item.Name; CreatedOn = [string]$item.CreatedOn; IsTemporary = [bool]$item.IsTemporary })
                }
                continue
            }
            $label = [string]$item.SubscriptionId
            if ($labels.ContainsKey($item.SubscriptionId)) { $label = $labels[$item.SubscriptionId] }
            if (-not $item.IsTemporary) {
                if ($reported.Add([string]$item.Name)) {
                    Write-RunLog -Level Warn -Message ('This identity holds a direct Owner assignment {0} on {1} that this runbook did not create. Review it; it is not removed.' -f $item.Name, $label)
                }
                continue
            }
            if ($seen.Add([string]$item.Name)) {
                [void]$leftovers.Add([PSCustomObject]@{ SubscriptionId = [string]$item.SubscriptionId; Name = [string]$item.Name; CreatedOn = [string]$item.CreatedOn; Label = $label })
            }
        }
    }

    foreach ($leftover in $leftovers) {
        [void]$sweep.Found.Add($leftover.Name)
        # Names inside the block avoid Invoke-RunbookAction's parameter names.
        $leftoverSub = [string]$leftover.SubscriptionId
        $leftoverName = [string]$leftover.Name
        $leftoverLabel = [string]$leftover.Label
        if (-not (Test-LeftoverOldEnough -CreatedOn $leftover.CreatedOn -Now $Now -WindowMinutes $WindowMinutes)) {
            $why = ('left alone: created {0}, less than {1} minutes ago, so another job may still be using it; the next run removes it if it is still there' -f $leftover.CreatedOn, $WindowMinutes)
            Write-RunLog -Level Warn -Message ('Temporary Owner assignment {0} of this identity on {1} was {2}.' -f $leftoverName, $leftoverLabel, $why)
            Add-RunSummaryItem -Summary $RunSummary -Action 'RemoveLeftoverOwner' -Target $leftoverLabel -Outcome Skipped -Detail $why
            [void]$sweep.Skipped.Add($leftoverName)
            continue
        }
        $created = 'creation time not reported'
        if ($leftover.CreatedOn) { $created = 'created ' + $leftover.CreatedOn }
        Write-RunLog -Level Warn -Message ('Found temporary Owner assignment {0} of this identity on {1} ({2}), left by a run that could not finish.' -f $leftoverName, $leftoverLabel, $created)
        $outcome = Invoke-RunbookAction -Summary $RunSummary -Action 'RemoveLeftoverOwner' -Target $leftoverLabel -PassThru `
            -Description ('remove leftover temporary Owner assignment {0} of this identity from {1}' -f $leftoverName, $leftoverLabel) `
            -ScriptBlock { Remove-TemporaryOwnerAssignment -SubscriptionId $leftoverSub -AssignmentName $leftoverName }
        switch ($outcome) {
            'Done' { [void]$sweep.Removed.Add($leftoverName) }
            'Planned' { [void]$sweep.Planned.Add($leftoverName) }
            'Failed' {
                $detail = ''
                if ($RunSummary.Failures.Count -gt 0) { $detail = [string]$RunSummary.Failures[$RunSummary.Failures.Count - 1].Detail }
                [void]$sweep.Unconfirmed.Add([PSCustomObject]@{ SubscriptionId = $leftoverSub; AssignmentName = $leftoverName; Detail = $detail })
            }
        }
    }
    return $sweep
}

# ---------------------------------------------------------------------------
# Run.
# ---------------------------------------------------------------------------

function Invoke-DisableUnauthorizedSubscriptionsRun {
    <#
    .SYNOPSIS
        One sweep: read, decide, leftover removal, breaker, then either
        elevate, cancel, and notify each candidate (AllowCancel true) or
        report each as WouldCancel (AllowCancel false); digest; summary.
    .DESCRIPTION
        Takes the runbook's parameters (see the script help) plus Now, the
        clock used in the notices, for the eligibility window, and for the
        age of leftovers. Returns the one summary object; the entry point
        then throws when Get-DisableRunFailureMessage finds a temporary Owner
        assignment in doubt. Throws before any write on bad input, a live run
        without Recipients, an ambiguous exclusion name, or an identity
        mismatch, and, with AllowCancel true, after the leftover removal when
        the breaker trips.

        Summary values beyond the library's: AllowCancel,
        SubscriptionsScanned, CandidateCount (subscriptions that meet the
        cancel rule, whether Candidate or WouldCancel), WouldCancelCount,
        CanceledCount, NeedsReviewCount, AllowedCount, CoOwnedAllowedCount,
        EligibleAllowedCount, ExcludedCount, ExcludedRestrictedCount,
        NotRestrictedCount, NotEnabledCount, BreakerWouldTrip,
        UncertainCancels, the leftover counts and lists,
        OffScopeOwnerCount and OffScopeOwnerAssignments (Owner assignments of
        this identity above a subscription, which are never removed),
        CleanupFailureCount, UnconfirmedRemovals, IdentityPrincipalId,
        ManagementGroupName, ReportPath, and Reviewable.
    .PARAMETER ManagementGroupName
        See the script help.
    .PARAMETER RestrictedQuotaIdPatterns
        See the script help.
    .PARAMETER AllowedOwnerUpns
        See the script help.
    .PARAMETER AllowedOwnerGroupNames
        See the script help.
    .PARAMETER ExcludedSubscriptionNames
        See the script help.
    .PARAMETER MaxDisablesPerRun
        See the script help.
    .PARAMETER ElevationPropagationSeconds
        See the script help.
    .PARAMETER MaxDisableAttempts
        See the script help.
    .PARAMETER Recipients
        See the script help.
    .PARAMETER SenderMailbox
        See the script help.
    .PARAMETER IdentityPrincipalId
        See the script help.
    .PARAMETER ReportPath
        See the script help.
    .PARAMETER DryRun
        See the script help.
    .PARAMETER AllowCancel
        See the script help. Default $false, as in the script.
    .PARAMETER Environment
        See the script help.
    .PARAMETER ClientId
        See the script help.
    .PARAMETER AccessToken
        See the script help. Tests may pass a hashtable keyed Graph and Arm.
    .PARAMETER RunId
        See the script help.
    .PARAMETER Now
        The clock for the notices, the eligibility window, and the age of
        leftover assignments.
    .EXAMPLE
        Invoke-DisableUnauthorizedSubscriptionsRun -SenderMailbox 'iam-noreply@corp.example.com' -AccessToken $tokens
    .EXAMPLE
        Invoke-DisableUnauthorizedSubscriptionsRun -SenderMailbox 'iam-noreply@corp.example.com' -Recipients 'cloud-governance@corp.example.com' -DryRun $false -AllowCancel $true -AccessToken $tokens
    #>
    param(
        [AllowEmptyString()][string]$ManagementGroupName = '',
        [AllowEmptyString()][string]$RestrictedQuotaIdPatterns = $script:DusDefaultQuotaIdPatterns,
        [AllowEmptyString()][string]$AllowedOwnerUpns = '',
        [AllowEmptyString()][string]$AllowedOwnerGroupNames = '',
        [AllowEmptyString()][string]$ExcludedSubscriptionNames = '',
        [ValidateRange(0, 100)][int]$MaxDisablesPerRun = 3,
        [ValidateRange(0, 3600)][int]$ElevationPropagationSeconds = 60,
        [ValidateRange(1, 20)][int]$MaxDisableAttempts = 5,
        [AllowEmptyString()][string]$Recipients = '',
        [Parameter(Mandatory = $true)][ValidatePattern('^[^@\s]+@[^@\s]+$')][string]$SenderMailbox,
        [AllowEmptyString()][string]$IdentityPrincipalId = '',
        [AllowEmptyString()][string]$ReportPath = '',
        [bool]$DryRun = $true,
        [bool]$AllowCancel = $false,
        [ValidateSet('Global', 'USGov')][string]$Environment = 'Global',
        [AllowEmptyString()][string]$ClientId = '',
        [AllowNull()][object]$AccessToken = '',
        [AllowEmptyString()][string]$RunId = '',
        [DateTime]$Now = [DateTime]::UtcNow
    )

    Initialize-RunContext -RunbookName 'Disable-UnauthorizedSubscriptions' -RunId $RunId -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken -DryRun $DryRun
    $summary = New-RunSummary
    $runIdText = (Get-RunContext).RunId

    # ---- Inputs. Everything is validated before the first request. -------
    # Lists arrive as semicolon lists from a schedule; ConvertTo-StringList
    # also accepts a JSON array from a local run.
    $patterns = @(Confirm-RestrictedQuotaIdPatterns -Patterns @(ConvertTo-StringList -Value $RestrictedQuotaIdPatterns -Label 'RestrictedQuotaIdPatterns'))
    $upns = @(ConvertTo-StringList -Value $AllowedOwnerUpns -Label 'AllowedOwnerUpns')
    $groupNames = @(ConvertTo-StringList -Value $AllowedOwnerGroupNames -Label 'AllowedOwnerGroupNames')
    $excluded = @(ConvertTo-StringList -Value $ExcludedSubscriptionNames -Label 'ExcludedSubscriptionNames')
    $recipientList = @(ConvertTo-StringList -Value $Recipients -Label 'Recipients')
    foreach ($address in $recipientList) {
        if ($address -notmatch '^[^@\s]+@[^@\s]+$') { throw ('Recipients: "{0}" is not a mail address.' -f $address) }
    }
    if (-not $DryRun -and $recipientList.Count -eq 0) {
        throw 'Recipients is empty. A live run needs at least one address for the digest, which is where subscriptions to review or that would be canceled, and failed removals, are reported. Nothing was changed.'
    }
    Write-RunLog -Level Info -Message ('Settings: ManagementGroup={0} Patterns={1} AllowedUpns={2} AllowedGroups={3} Excluded={4} MaxDisablesPerRun={5} ElevationPropagationSeconds={6} MaxDisableAttempts={7} Recipients={8} DryRun={9} AllowCancel={10}' -f $(if ($ManagementGroupName) { $ManagementGroupName } else { '(all visible)' }), ($patterns -join ';'), $upns.Count, $groupNames.Count, $excluded.Count, $MaxDisablesPerRun, $ElevationPropagationSeconds, $MaxDisableAttempts, $recipientList.Count, $DryRun, $AllowCancel)
    if (-not $AllowCancel) {
        Write-RunLog -Level Info -Message 'AllowCancel is false: this run creates no temporary Owner assignment and cancels nothing; subscriptions that meet the cancel rule are reported as WouldCancel.'
    }
    if ($upns.Count -eq 0 -and $groupNames.Count -eq 0) {
        Write-RunLog -Level Warn -Message 'No allowed owners are configured: every restricted subscription with a human owner meets the cancel rule.'
    }

    $allowed = Get-AllowedPrincipalIds -Upns $upns -GroupNames $groupNames
    $selfId = Resolve-IdentityPrincipalId -Configured $IdentityPrincipalId -DryRun $DryRun
    Write-RunLog -Level Info -Message ('Acting principal: {0}.' -f $(if ($selfId) { $selfId } else { '(unknown)' }))

    # ---- Scope. ------------------------------------------------------------
    $subscriptions = @(Invoke-CloudRequest -Api Arm -Uri 'subscriptions' -ApiVersion $script:DusApiVersions.Subscriptions -AllPages)
    $mgScope = ''
    if (-not [string]::IsNullOrWhiteSpace($ManagementGroupName)) {
        $mgScope = Resolve-ArmScope -ManagementGroupName $ManagementGroupName
        $descendants = @(Get-ManagementGroupDescendantSubscriptions -ManagementGroupName $ManagementGroupName)
        $inScope = New-PrincipalIdSet -Ids @($descendants | ForEach-Object { [string]$_.SubscriptionId })
        $listed = @($subscriptions | Where-Object { $inScope.Contains((ConvertTo-NormalizedObjectId -Value ([string]$_.subscriptionId))) })
        if ($listed.Count -lt $descendants.Count) {
            Write-RunLog -Level Warn -Message ('{0} descendant subscription(s) of {1} are not readable by this identity and were not swept.' -f ($descendants.Count - $listed.Count), $mgScope)
        }
        $subscriptions = $listed
    }
    Write-RunLog -Level Info -Message ('Sweeping {0} subscription(s).' -f $subscriptions.Count)

    # ---- Exclusions, resolved to ids before any write. ---------------------
    $excludedIds = Resolve-ExcludedSubscriptionIds -Entries $excluded -Subscriptions $subscriptions
    $excludedIdList = @($excludedIds.Keys | ForEach-Object { [string]$_ })

    # ---- Decisions. --------------------------------------------------------
    $ownerRoleId = ''
    $decisions = New-Object System.Collections.ArrayList
    foreach ($subscription in $subscriptions) {
        $subId = [string]$subscription.subscriptionId
        $label = '{0} ({1})' -f $subscription.displayName, $subId
        $decision = Get-SubscriptionDecision -Subscription $subscription -RestrictedQuotaIdPatterns $patterns -AllowedPrincipalIds $allowed -ExcludedSubscriptions $excludedIdList -IdentityPrincipalId $selfId
        if (@('NotEnabled', 'Excluded', 'NotRestricted') -notcontains $decision.Decision) {
            if (-not $ownerRoleId) { $ownerRoleId = Resolve-OwnerRoleId -SubscriptionId $subId }
            $assignments = @()
            $readError = ''
            try { $assignments = @(Get-SubscriptionRoleAssignments -SubscriptionId $subId) }
            catch { $readError = Protect-RunbookText -Text $_.Exception.Message -MaxLength 300 }
            $judge = @{
                Subscription              = $subscription
                RoleAssignments           = $assignments
                RestrictedQuotaIdPatterns = $patterns
                AllowedPrincipalIds       = $allowed
                ExcludedSubscriptions     = $excludedIdList
                OwnerRoleId               = $ownerRoleId
                IdentityPrincipalId       = $selfId
                AssignmentReadError       = $readError
                Now                       = $Now
            }
            $decision = Get-SubscriptionDecision @judge
            if ($decision.Decision -eq 'Candidate') {
                # Only a subscription that would be canceled needs the Azure
                # PIM check; a read failure makes it NeedsReview.
                $eligible = @()
                $eligibleError = ''
                try { $eligible = @(Get-SubscriptionEligibilityInstances -SubscriptionId $subId) }
                catch { $eligibleError = Protect-RunbookText -Text $_.Exception.Message -MaxLength 300 }
                $decision = Get-SubscriptionDecision @judge -EligibleAssignments $eligible -EligibilityReadError $eligibleError
            }
        }
        if ($decision.Decision -eq 'Candidate' -and -not $AllowCancel) {
            $decision.Decision = 'WouldCancel'
            $decision.Reason = 'AllowCancel is false; ' + $decision.Reason
        }
        if ($decision.Decision -eq 'Excluded') {
            $how = $excludedIds[(ConvertTo-NormalizedObjectId -Value $subId)]
            if ($how) { $decision.Reason = 'listed in ExcludedSubscriptionNames ' + $how }
        }
        [void]$decisions.Add($decision)

        switch ($decision.Decision) {
            'NeedsReview' {
                Write-RunLog -Level Warn -Message ('Needs review {0}: {1}. Not canceled.' -f $label, $decision.Reason)
                Add-RunSummaryItem -Summary $summary -Action 'ReviewSubscription' -Target $label -Outcome Skipped -Detail $decision.Reason
            }
            default { Write-RunLog -Level Info -Message ('{0} {1}: {2}.' -f $decision.Decision, $label, $decision.Reason) }
        }
        foreach ($other in @($decision.OtherSelfAssignments)) {
            Write-RunLog -Level Warn -Message ('This identity holds a direct Owner assignment {0} on {1} that this runbook did not create. Review it; it is not removed.' -f $other, $label)
        }
    }

    $countOf = @{}
    foreach ($name in @('Candidate', 'WouldCancel', 'NeedsReview', 'Allowed', 'Excluded', 'NotRestricted', 'NotEnabled')) {
        $countOf[$name] = @($decisions | Where-Object { $_.Decision -eq $name }).Count
    }
    $coOwnedCount = @($decisions | Where-Object { $_.Decision -eq 'Allowed' -and (Test-DecisionReportable -Decision $_) }).Count
    $eligibleAllowedCount = @($decisions | Where-Object { $_.Decision -eq 'Allowed' -and @($_.EligibleAllowedOwnerIds).Count -gt 0 }).Count
    $excludedRestrictedCount = @($decisions | Where-Object { $_.Decision -eq 'Excluded' -and (Test-DecisionReportable -Decision $_) }).Count
    Write-RunLog -Level Info -Message ('Decisions: candidate={0} wouldCancel={1} needsReview={2} allowed={3} (co-owned {4}, through an eligible owner {5}) excluded={6} (restricted offer {7}) notRestricted={8} notEnabled={9}' -f $countOf.Candidate, $countOf.WouldCancel, $countOf.NeedsReview, $countOf.Allowed, $coOwnedCount, $eligibleAllowedCount, $countOf.Excluded, $excludedRestrictedCount, $countOf.NotRestricted, $countOf.NotEnabled)

    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        $directory = Split-Path -Path $ReportPath -Parent
        if ($directory -and -not (Test-Path -Path $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
        @($decisions | ForEach-Object { ConvertTo-DecisionReportRow -Decision $_ }) | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
        Write-RunLog -Level Info -Message ('Wrote report to {0}.' -f $ReportPath)
    }

    # ---- Leftover temporary assignments from a run that could not finish. ---
    # This runs before the breaker, and with AllowCancel false too, on
    # purpose: it only removes this identity's own access, and neither a
    # tripped breaker nor the cancel gate may keep an unconditioned Owner
    # assignment alive.
    if (-not $ownerRoleId) { $ownerRoleId = $script:DusOwnerRoleId }
    $windowMinutes = Get-ElevationWindowMinutes -PropagationSeconds $ElevationPropagationSeconds -MaxAttempts $MaxDisableAttempts
    $sweep = Invoke-LeftoverOwnerSweep -RunSummary $summary -Decisions $decisions.ToArray() -ManagementGroupScope $mgScope -PrincipalId $selfId -OwnerRoleId $ownerRoleId -Now $Now -WindowMinutes $windowMinutes
    $unconfirmed = New-Object System.Collections.ArrayList
    foreach ($item in $sweep.Unconfirmed) { [void]$unconfirmed.Add($item) }

    # ---- Breaker, in every mode, before any grant or cancel. ---------------
    # The leftover removal above is the one write allowed before it. With
    # AllowCancel false nothing it guards can happen, so a trip is a warning
    # and a digest note instead of a stop.
    $toCancel = @($decisions | Where-Object { $_.Decision -eq 'Candidate' -or $_.Decision -eq 'WouldCancel' } | Sort-Object -Property DisplayName, SubscriptionId)
    $digestNotes = New-Object System.Collections.ArrayList

    # An Owner assignment of this identity above a subscription is reported in
    # every mode, including a dry run: the sweep cannot remove it, and nothing
    # else in this run would mention it.
    if ($sweep.OffScope.Count -gt 0) {
        $offScopeText = @($sweep.OffScope | ForEach-Object { 'assignment {0} at {1}' -f $_.Name, $_.Scope })
        [void]$digestNotes.Add(('This identity holds {0} direct Owner assignment(s) whose scope is not a single subscription: {1}. This runbook did not create them and does not remove them. An unconditioned Owner assignment of this identity at a management group is Owner over every subscription below it, whatever the delegation condition says: review each one and remove it by hand.' -f $sweep.OffScope.Count, ($offScopeText -join '; ')))
    }
    $breakerWouldTrip = $false
    $breakerError = ''
    try {
        Test-CircuitBreaker -Planned $toCancel.Count -Cap $MaxDisablesPerRun -Label 'subscription cancels'
    }
    catch {
        $breakerError = $_.Exception.Message
    }
    if ($breakerError -and $AllowCancel) {
        $message = $breakerError
        $notes = New-Object System.Collections.ArrayList
        if ($sweep.Removed.Count -gt 0) { [void]$notes.Add(('it removed {0} leftover temporary Owner assignment(s) of this identity ({1})' -f $sweep.Removed.Count, ($sweep.Removed.ToArray() -join ', '))) }
        if ($sweep.Planned.Count -gt 0) { [void]$notes.Add(('it would remove {0} leftover temporary Owner assignment(s) of this identity ({1})' -f $sweep.Planned.Count, ($sweep.Planned.ToArray() -join ', '))) }
        if ($sweep.Skipped.Count -gt 0) { [void]$notes.Add(('it left {0} recent temporary Owner assignment(s) of this identity alone ({1})' -f $sweep.Skipped.Count, ($sweep.Skipped.ToArray() -join ', '))) }
        if ($unconfirmed.Count -gt 0) {
            $named = @($unconfirmed | ForEach-Object { 'subscription {0} assignment {1}' -f $_.SubscriptionId, $_.AssignmentName })
            [void]$notes.Add(('it could NOT confirm the removal of {0} leftover(s), so this identity may still be an unconditioned Owner there; remove them by hand: {1}' -f $unconfirmed.Count, ($named -join '; ')))
        }
        if ($sweep.LookupFailures.Count -gt 0) {
            [void]$notes.Add(('it could not look for leftovers at {0}' -f (@($sweep.LookupFailures | ForEach-Object { [string]$_.Scope }) -join '; ')))
        }
        if ($sweep.OffScope.Count -gt 0) {
            [void]$notes.Add(('it found {0} Owner assignment(s) of this identity above a subscription, which it never removes: {1}' -f $sweep.OffScope.Count, (@($sweep.OffScope | ForEach-Object { '{0} at {1}' -f $_.Name, $_.Scope }) -join '; ')))
        }
        if ($notes.Count -gt 0) {
            $message = ('{0} Before the breaker, the leftover sweep ran, which only takes this identity''s own access away: {1}.' -f $message, ($notes.ToArray() -join '; '))
        }
        Write-RunLog -Level Error -Message $message
        throw $message
    }
    if ($breakerError) {
        $breakerWouldTrip = $true
        $note = ('{0} subscription(s) meet the cancel rule, more than MaxDisablesPerRun ({1}). AllowCancel is false, so this run cancels nothing and carries on; with AllowCancel true the circuit breaker would stop the run before any grant or cancel.' -f $toCancel.Count, $MaxDisablesPerRun)
        Write-RunLog -Level Warn -Message $note
        [void]$digestNotes.Add($note)
    }

    # ---- Cancel gate. --------------------------------------------------------
    $canceledCount = 0
    $uncertain = New-Object System.Collections.ArrayList
    $toElevate = @()
    if ($AllowCancel) { $toElevate = $toCancel }
    else {
        # No grant, no cancel, no owner notice (it would say "was canceled").
        foreach ($held in $toCancel) {
            $label = '{0} ({1})' -f $held.DisplayName, $held.SubscriptionId
            Add-RunSummaryItem -Summary $summary -Action 'CancelSubscription' -Target $label -Outcome Skipped -Detail 'WouldCancel: AllowCancel is false'
        }
        if ($toCancel.Count -gt 0) {
            Write-RunLog -Level Info -Message ('{0} subscription(s) would be canceled if AllowCancel were true. None was, and no temporary Owner assignment was created.' -f $toCancel.Count)
        }
    }

    # ---- Elevate, cancel, always remove, notify (AllowCancel true only). ---
    foreach ($candidate in $toElevate) {
        $label = '{0} ({1})' -f $candidate.DisplayName, $candidate.SubscriptionId
        if ($unconfirmed.Count -gt 0) {
            $why = 'not attempted: a temporary Owner removal earlier in this run could not be confirmed, so the run stopped elevating'
            Add-RunSummaryItem -Summary $summary -Action 'CancelSubscription' -Target $label -Outcome Skipped -Detail $why
            Write-RunLog -Level Warn -Message ('Skipping {0}: {1}.' -f $label, $why)
            continue
        }

        $contacts = @(Get-OwnerContacts -UserIds @($candidate.HumanOwnerIds))
        $result = Invoke-JitSubscriptionCancel -AllowCancel $AllowCancel -Summary $summary -Decision $candidate -PrincipalId $selfId -OwnerRoleId $ownerRoleId -PropagationSeconds $ElevationPropagationSeconds -MaxAttempts $MaxDisableAttempts -RunId $runIdText
        if ($result.Cleanup -eq 'Failed') {
            $detail = ''
            $lastRemoval = @($summary.Failures | Where-Object { $_.Action -eq 'RemoveTemporaryOwner' } | Select-Object -Last 1)
            if ($lastRemoval.Count -gt 0) { $detail = [string]$lastRemoval[0].Detail }
            [void]$unconfirmed.Add([PSCustomObject]@{ SubscriptionId = [string]$candidate.SubscriptionId; AssignmentName = [string]$result.AssignmentName; Detail = $detail })
        }

        $canceled = [bool]$result.Canceled
        if ($result.CancelMayHaveBeenApplied) {
            # The library did not repeat the POST after a server error or a
            # lost response; one read tells whether it took effect.
            $state = ''
            $stateProblem = ''
            try { $state = Get-SubscriptionState -SubscriptionId ([string]$candidate.SubscriptionId) }
            catch { $stateProblem = Protect-RunbookText -Text $_.Exception.Message -MaxLength 300 }
            if ($state -and -not $state.Equals('Enabled', [StringComparison]::OrdinalIgnoreCase)) {
                $canceled = $true
                $why = ('the cancel call ended without a clear answer, and the subscription now reports state {0}, so it is counted as canceled' -f $state)
                $stateOutcome = 'Done'
            }
            elseif ($stateProblem) {
                $why = ('the cancel call ended without a clear answer, and its state could not be read ({0}); check the subscription by hand before the next run' -f $stateProblem)
                $stateOutcome = 'Skipped'
            }
            else {
                $shown = $state
                if (-not $shown) { $shown = '(not reported)' }
                $why = ('the cancel call ended without a clear answer, and the subscription still reports state {0}; the cancel may still take effect, and the next run reads the state again' -f $shown)
                $stateOutcome = 'Skipped'
            }
            Write-RunLog -Level Warn -Message ('{0}: {1}.' -f $label, $why)
            Add-RunSummaryItem -Summary $summary -Action 'CheckCancelState' -Target $label -Outcome $stateOutcome -Detail $why
            [void]$digestNotes.Add(('{0}: {1}.' -f $label, $why))
            [void]$uncertain.Add([PSCustomObject]@{ SubscriptionId = [string]$candidate.SubscriptionId; State = $state; CountedAsCanceled = $canceled; Detail = $why })
        }
        if ($canceled) { $canceledCount++ }
        if (-not ($canceled -or $DryRun)) { continue }

        $mailTo = @($contacts | ForEach-Object { [string]$_.Address } | Where-Object { $_ } | Select-Object -Unique)
        $mailCc = @($recipientList)
        if ($mailTo.Count -eq 0) { $mailTo = $mailCc; $mailCc = @() }
        if ($mailTo.Count -eq 0) {
            Write-RunLog -Level Warn -Message ('No owner address and no Recipients for {0}; no notice sent.' -f $label)
            continue
        }
        $mailSubject = 'Azure subscription {0} was canceled and is disabled' -f $candidate.DisplayName
        $mailHtml = New-CancelNoticeHtml -Decision $candidate -OwnerNames @($contacts | ForEach-Object { [string]$_.Name }) -ContactAddresses $recipientList -RunId $runIdText -Now $Now
        Invoke-RunbookAction -Summary $summary -Action 'NotifyOwners' -Target $label `
            -Description ('send the cancel notice for {0} to {1}' -f $label, ($mailTo -join ', ')) `
            -ScriptBlock { Send-RunbookMail -SenderMailbox $SenderMailbox -To $mailTo -Cc $mailCc -Subject $mailSubject -HtmlBody $mailHtml }
    }

    $cleanupFailures = $unconfirmed.Count
    if ($cleanupFailures -gt 0) {
        $named = @($unconfirmed | ForEach-Object { 'subscription {0} assignment {1}' -f $_.SubscriptionId, $_.AssignmentName })
        Write-RunLog -Level Error -Message ('{0} temporary Owner assignment(s) could not be confirmed removed; this identity may still be an unconditioned Owner there: {1}. Remove them by hand. The job ends Failed after the summary.' -f $cleanupFailures, ($named -join '; '))
    }

    # ---- Digest. -------------------------------------------------------------
    $reportable = @($decisions | Where-Object { Test-DecisionReportable -Decision $_ })
    $failedItems = @($summary.Failures.ToArray())
    $noteList = @($digestNotes.ToArray() | ForEach-Object { [string]$_ })
    if ($recipientList.Count -gt 0 -and ($reportable.Count -gt 0 -or $failedItems.Count -gt 0 -or $noteList.Count -gt 0)) {
        if ($AllowCancel) {
            $digestSubject = 'Unauthorized subscription guard: {0} candidate(s), {1} canceled, {2} to review, {3} failure(s)' -f $toCancel.Count, $canceledCount, $countOf.NeedsReview, $failedItems.Count
        }
        else {
            $digestSubject = 'Unauthorized subscription guard (AllowCancel is false): {0} would be canceled, {1} to review, {2} failure(s)' -f $toCancel.Count, $countOf.NeedsReview, $failedItems.Count
        }
        $digestHtml = New-RunDigestHtml -Decisions $reportable -Failures $failedItems -DryRun $DryRun -AllowCancel $AllowCancel -Notes $noteList -RunId $runIdText
        Invoke-RunbookAction -Summary $summary -Action 'SendDigest' -Target ($recipientList -join ', ') `
            -Description ('send the run digest to {0}' -f ($recipientList -join ', ')) `
            -ScriptBlock { Send-RunbookMail -SenderMailbox $SenderMailbox -To $recipientList -Subject $digestSubject -HtmlBody $digestHtml }
    }

    $extra = [ordered]@{
        AllowCancel                = $AllowCancel
        SubscriptionsScanned       = $subscriptions.Count
        CandidateCount             = $toCancel.Count
        WouldCancelCount           = $countOf.WouldCancel
        CanceledCount              = $canceledCount
        NeedsReviewCount           = $countOf.NeedsReview
        AllowedCount               = $countOf.Allowed
        CoOwnedAllowedCount        = $coOwnedCount
        EligibleAllowedCount       = $eligibleAllowedCount
        ExcludedCount              = $countOf.Excluded
        ExcludedRestrictedCount    = $excludedRestrictedCount
        NotRestrictedCount         = $countOf.NotRestricted
        NotEnabledCount            = $countOf.NotEnabled
        BreakerWouldTrip           = $breakerWouldTrip
        UncertainCancels           = @($uncertain.ToArray())
        LeftoverCount              = $sweep.Found.Count
        LeftoverSkippedCount       = $sweep.Skipped.Count
        LeftoverLookupFailureCount = $sweep.LookupFailures.Count
        LeftoverLookupFailures     = @($sweep.LookupFailures.ToArray())
        OffScopeOwnerCount         = $sweep.OffScope.Count
        OffScopeOwnerAssignments   = @($sweep.OffScope.ToArray())
        CleanupFailureCount        = $cleanupFailures
        UnconfirmedRemovals        = @($unconfirmed.ToArray())
        IdentityPrincipalId        = $selfId
        ManagementGroupName        = $ManagementGroupName
        ReportPath                 = $ReportPath
        Reviewable                 = @($reportable | Select-Object -Property SubscriptionId, DisplayName, QuotaId, Decision, Reason)
    }
    return (Complete-RunSummary -Summary $summary -Extra $extra)
}

# ---------------------------------------------------------------------------
# Entry point. Skipped when dot-sourced by the tests. A run with a temporary
# Owner assignment in doubt still emits its summary, then throws so the job
# ends Failed and Watch-AutomationJobFailures reports it.
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-DisableUnauthorizedSubscriptionsRun -ManagementGroupName $ManagementGroupName -RestrictedQuotaIdPatterns $RestrictedQuotaIdPatterns `
        -AllowedOwnerUpns $AllowedOwnerUpns -AllowedOwnerGroupNames $AllowedOwnerGroupNames -ExcludedSubscriptionNames $ExcludedSubscriptionNames `
        -MaxDisablesPerRun $MaxDisablesPerRun -ElevationPropagationSeconds $ElevationPropagationSeconds -MaxDisableAttempts $MaxDisableAttempts `
        -Recipients $Recipients -SenderMailbox $SenderMailbox -IdentityPrincipalId $IdentityPrincipalId -ReportPath $ReportPath `
        -DryRun ([bool]$DryRun) -AllowCancel ([bool]$AllowCancel) -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken -RunId $RunId
    $result
    $failureMessage = Get-DisableRunFailureMessage -Summary $result
    if (-not [string]::IsNullOrEmpty($failureMessage)) { throw $failureMessage }
}
