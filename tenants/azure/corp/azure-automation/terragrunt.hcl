# Azure corp tenant, automation cell.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack.
#
# Nine runbooks, nine schedules, four identities, all dry. dry_run = true is
# the shipped default and stays true until the job output of a few dry runs
# has been read and the counts look right; flipping it is a one-line change
# here whose plan shows the job schedules being replaced. The three lifecycle
# stage groups the guest runbook names below are ordinary security groups
# created with the tenant's other groups, and the sender mailbox is a shared
# mailbox restricted to these identities by Exchange application access
# policies applied outside Terraform (one per identity that holds Mail.Send;
# the stack's identities output lists them and their client IDs).
#
# Identity tiers (docs/adr/0016). Each runbook names the tier it runs as in
# identity_key, and each tier holds only what its own runbooks use:
#
#   observer            job watcher, runbook backup, authentication methods
#                       drift. Read-only in Graph plus Mail.Send; Reader and
#                       the custom Automation Variable Writer on this account;
#                       Storage Blob Data Contributor on the backup container,
#                       which the stack grants because the backup runbook asks
#                       for the backup storage names. Not read-only in Azure:
#                       see the note on that assignment below, which is write
#                       on every variable in this account.
#   lifecycle           application credential hygiene and guest lifecycle.
#                       Directory writes in Graph, nothing in Azure.
#   pim                 tier 0: the two PIM policy runbooks and the eligibility
#                       renewal. Its Graph permissions can rewrite the
#                       activation rules of every directory role, Global
#                       Administrator included, and create directory and group
#                       eligibilities.
#   subscription-guard  tier 0 for its management group: the only holder of the
#                       conditioned Role Based Access Control Administrator
#                       assignment, and the only runbook that can cancel a
#                       subscription.
#
# All four are attached to this one Automation account, so anyone who can
# publish a runbook or start a job here can obtain a token for any of them.
# The tiers bound a runbook defect or a bad parameter, not a compromise of the
# account; docs/adr/0016 says when separate accounts are warranted instead.
#
# Migration note for an account that already ran on one shared identity: this
# cell no longer declares identity_name, so the plan destroys that identity
# together with its Graph grants and role assignments and creates the four
# tier identities. Add every new client ID to the Exchange application access
# policy before dry_run is turned off, and expect every job schedule to be
# replaced, because clientid changes.
#
# The six newer runbooks share automation/lib/Runbook.Common.ps1, which the
# stack inlines into each at deploy time (docs/adr/0013). Every list a runbook
# takes is one string joined with semicolons, written join(";", [...]) here,
# never jsonencode: the Automation service may parse a JSON-looking parameter
# value before it binds it, and what reaches a [string] parameter is then
# "@{...}" or a space-joined array. No list element may contain a semicolon or
# a comma.
#
# The two PIM baselines are not parameters for the same reason. They are JSON
# files in this repository, published as Automation string variables by
# desired_state_files (PimPolicy_AzureBaseline, PimPolicy_EntraBaseline), and
# each runbook is given the variable's name. Those files hold the same values
# as ../azure-pim-governance and ../entra-pim-governance (docs/adr/0015), so a
# pull request that changes a policy there changes the baseline file in the
# same pull request. Both runbooks run in "minimum" mode, so a live run only
# ever tightens a policy towards what the cells declare and a Terraform plan
# after it shows no change the runbook caused.
#
# Subscription guard: the call it makes is Cancel, not a documented "disable".
# Two switches have to be turned before anything is canceled, and they are
# turned in this order: dry_run = false first (a report-only live run that
# sends the digest and cancels nothing), then allowcancel = "true", only after
# the owners of that control have signed off on Cancel in writing and one
# sandbox subscription of each targeted offer has been canceled and
# reactivated (see the runbook header and docs/adr/0014).
#
# Schedule start_time values are anchors: the date must be in the future when
# the schedule is first created, and only the time of day (and the weekday for
# the weekly ones) matters afterwards. 2027-01-04 is a Monday and 2027-01-10
# is a Sunday.
#
# tenant_id and subscription_id are not set here. root.hcl supplies them from
# ARM_TENANT_ID and ARM_SUBSCRIPTION_ID so no cell ever contains a GUID. The
# one GUID-shaped value the runbooks need, an identity's own principal ID, is
# supplied by the stack (stack_parameters and the <principal_id> token).
#
# State key (derived by root.hcl): azure/corp/azure-automation/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/azure-automation"
}

# Ordering only. The identities below name two custom roles defined in
# ../azure-rbac-roles, resolved by name at plan time, so that cell is applied
# first. No outputs are read from it. A pull request that adds a custom role
# and its first use here plans red in this cell until the roles cell is
# applied, which is why role definitions land in their own pull request first
# (README.md, "Verification status", and stacks/azure-automation/README.md).
dependencies {
  paths = ["../azure-rbac-roles"]
}

inputs = {
  # -------------------------------------------------------------------------
  # Account. The resource group exists already; the identities are created.
  # -------------------------------------------------------------------------
  resource_group_name     = "rg-example-identity-automation"
  automation_account_name = "aa-example-identity-corp"
  tenant_label            = "corp"

  tags = {
    workload = "identity-automation"
    owner    = "iam"
  }

  # -------------------------------------------------------------------------
  # Values every runbook receives. Dry by default.
  # -------------------------------------------------------------------------
  sender_mailbox    = "iam-noreply@corp.example.com"
  graph_environment = "Global"
  dry_run           = true

  # -------------------------------------------------------------------------
  # Backup storage for Backup-AutomationRunbooks: shared key access off,
  # TLS 1.2, infrastructure encryption, versioning, soft delete, one private
  # container, and Storage Blob Data Contributor on that container for the
  # observer identity (the tier of the only runbook that asks for the backup
  # storage names).
  # -------------------------------------------------------------------------
  backup_storage = {
    storage_account_name   = "stexampleaabackupcorp"
    container_name         = "runbook-backups"
    retention_days         = 14
    version_retention_days = 30
  }

  # -------------------------------------------------------------------------
  # Identity tiers (docs/adr/0016). One user-assigned managed identity per
  # tier, each holding only the Graph permissions and Azure role assignments
  # its own runbooks use. Every runbook below names its tier in identity_key.
  # -------------------------------------------------------------------------
  identities = {
    # Reads this account, writes one state variable, writes backups, and
    # reports. Its Graph permissions are read-only apart from Mail.Send.
    #
    # Invoke-AuthenticationMethodsDrift runs here on its report path: with
    # Policy.Read.AuthenticationMethod it detects and mails drift, and the
    # release train (scripts/Set-AuthenticationMethods.ps1 after the corp
    # governance cell) is what patches the tenant. A live run of this runbook
    # in this tier therefore logs a 403 for each PATCH it would make and
    # records it as a failed patch; move the runbook to a tier that holds
    # Policy.ReadWrite.AuthenticationMethod to let it enforce.
    observer = {
      name = "id-example-automation-observer-corp"

      graph_app_roles = [
        # Invoke-AuthenticationMethodsDrift: compare the policy, resolve the
        # group display names in it, mail the digest.
        "Policy.Read.AuthenticationMethod",
        "Group.Read.All",
        # Watch-AutomationJobFailures and Invoke-AuthenticationMethodsDrift.
        # Backup-AutomationRunbooks calls no Graph API at all.
        "Mail.Send",
      ]

      arm_role_assignments = {
        watcher-reader-on-account = {
          role_name   = "Reader"
          scope       = { type = "automation_account" }
          description = "Watch-AutomationJobFailures reads jobs, streams, schedules, and its state variable; Backup-AutomationRunbooks reads runbooks and their content."
        }

        # Account-wide, and there is no narrower scope. Azure RBAC has no
        # per-variable scope for Automation, so this assignment is write on
        # EVERY variable in this account, not only JobWatch_AlertedJobIds:
        # that includes PimPolicy_AzureBaseline, PimPolicy_EntraBaseline, and
        # the nine AuthMethods_* variables published by desired_state_files
        # below. The lowest tier can therefore replace a tier 0 input, and a
        # weakened Entra baseline in mode "exact" would be applied to Global
        # Administrator by the next live Invoke-EntraPimPolicyDrift run.
        # What holds it down (docs/adr/0016, none of it an RBAC boundary):
        # the watcher writes no variable whose name does not begin with
        # JobWatch_ and refuses any other statevariablename; every
        # desired-state variable is owned by Terraform, so a value changed
        # outside a release is drift the next plan shows; and the watcher
        # reports any other variable in this account changed inside its
        # lookback window in its hourly digest. Where the tenant has activity
        # log alerting, add one on
        # Microsoft.Automation/automationAccounts/variables/write by this
        # principal for any name other than JobWatch_AlertedJobIds.
        watcher-state-on-account = {
          role_name   = "Automation Variable Writer"
          scope       = { type = "automation_account" }
          description = "Watch-AutomationJobFailures saves what it has reported in its state variable. Azure RBAC has no per-variable scope, so this is write on every variable in this account."
        }
      }
    }

    # Directory hygiene. No Azure role assignment: both runbooks are Graph
    # only. Not a low-privilege tier: Application.ReadWrite.All can add a
    # credential to any application registration, and Group.ReadWrite.All can
    # change the membership of any group that is not role-assignable, so this
    # identity is as privileged as whatever those grant (docs/adr/0016).
    lifecycle = {
      name = "id-example-automation-lifecycle-corp"

      graph_app_roles = [
        # Invoke-AppCredentialHygiene
        "Application.ReadWrite.All",
        "Directory.Read.All",
        # Invoke-GuestLifecycle
        "User.ReadWrite.All",
        "Group.ReadWrite.All",
        "AuditLog.Read.All",
        # both
        "Mail.Send",
      ]
    }

    # Tier 0. RoleManagementPolicy.ReadWrite.Directory can remove MFA or
    # approval from Global Administrator activation, and
    # RoleEligibilitySchedule.ReadWrite.Directory can make any principal
    # eligible for any directory role. Treat this identity, the baseline
    # variables, and write access to this account as tier 0 (docs/adr/0015).
    pim = {
      name = "id-example-automation-pim-corp"

      graph_app_roles = [
        # Invoke-EntraPimPolicyDrift
        "RoleManagementPolicy.ReadWrite.Directory",
        "RoleManagementPolicy.ReadWrite.AzureADGroup",
        "RoleManagement.Read.Directory",
        # Invoke-PimEligibilityRenewal
        "RoleEligibilitySchedule.ReadWrite.Directory",
        "PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup",
        "RoleManagementPolicy.Read.Directory",
        "RoleManagementPolicy.Read.AzureADGroup",
        # all three: approver and PIM group names, and the digests
        "Group.Read.All",
        "Mail.Send",
      ]

      # Invoke-AzurePimPolicyGovernance reads with Reader and patches role
      # management policies with the custom role. The eligibility renewal
      # needs no Azure role while includeazureresources is false; turning it
      # on means adding "PIM Policy and Eligibility Operator" here instead,
      # which also carries roleEligibilityScheduleRequests/write (see the
      # renewal's entry below).
      arm_role_assignments = {
        pim-reader-at-root = {
          role_name   = "Reader"
          scope       = { type = "management_group", name = "mg-example-root" }
          description = "Invoke-AzurePimPolicyGovernance: eligibility schedule instances, policy assignments, policies, and management group descendants."
        }

        pim-policy-operator-at-root = {
          role_name   = "PIM Policy Operator"
          scope       = { type = "management_group", name = "mg-example-root" }
          description = "Invoke-AzurePimPolicyGovernance patches Azure role management policies. Used only when dry_run is false."
        }
      }
    }

    # Tier 0 for the sandbox management group. The condition limits what this
    # identity may assign (Owner) and to whom (itself), not where under that
    # management group, so it can make itself an unconditioned Owner of the
    # management group and every subscription below it. That is why the
    # assignment is at mg-example-sandbox and never at the root, and why this
    # runbook has an identity nothing else uses (docs/adr/0014, docs/adr/0016).
    subscription-guard = {
      name = "id-example-automation-subguard-corp"

      graph_app_roles = [
        # Disable-UnauthorizedSubscriptions: resolve allowlisted users,
        # expand the allowlist group, read owner addresses, send the notices
        # and the digest.
        "User.Read.All",
        "GroupMember.Read.All",
        "Mail.Send",
      ]

      arm_role_assignments = {
        subscription-guard-reader-at-sandbox = {
          role_name   = "Reader"
          scope       = { type = "management_group", name = "mg-example-sandbox" }
          description = "Disable-UnauthorizedSubscriptions reads subscriptions, their owners, role definitions, and role eligibility schedule instances."
        }

        subscription-guard-at-sandbox = {
          role_name         = "Role Based Access Control Administrator"
          scope             = { type = "management_group", name = "mg-example-sandbox" }
          description       = "Disable-UnauthorizedSubscriptions: just-in-time Owner on a subscription it is about to cancel, for itself only, removed in the same run."
          condition         = <<-EOT
            (
             (
              !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
             )
             OR
             (
              @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {<role_id:Owner>}
              AND
              @Request[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAnyValues:GuidEquals {<principal_id>}
             )
            )
            AND
            (
             (
              !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
             )
             OR
             (
              @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {<role_id:Owner>}
              AND
              @Resource[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAnyValues:GuidEquals {<principal_id>}
             )
            )
          EOT
          condition_version = "2.0"
        }
      }
    }
  }

  # -------------------------------------------------------------------------
  # Schedules. Nightly work first, in this order, so the Azure and Entra PIM
  # runs see the renewals of the same night: runbook backup 02:00, PIM
  # eligibility renewal 03:30, subscription guard 04:00, Azure PIM policy
  # governance 05:00, Entra PIM policy drift 05:15, credential hygiene 06:00.
  # Guest lifecycle weekly on Monday at 07:00, authentication methods drift
  # weekly on Sunday at 08:00. The job watcher runs every hour at 45 minutes
  # past, when none of the others starts.
  # -------------------------------------------------------------------------
  schedules = {
    daily-0200-utc = {
      name        = "daily-0200-utc"
      description = "Every day at 02:00 UTC."
      frequency   = "Day"
      interval    = 1
      timezone    = "Etc/UTC"
      start_time  = "2027-01-04T02:00:00Z"
    }

    daily-0330-utc = {
      name        = "daily-0330-utc"
      description = "Every day at 03:30 UTC."
      frequency   = "Day"
      interval    = 1
      timezone    = "Etc/UTC"
      start_time  = "2027-01-04T03:30:00Z"
    }

    daily-0400-utc = {
      name        = "daily-0400-utc"
      description = "Every day at 04:00 UTC."
      frequency   = "Day"
      interval    = 1
      timezone    = "Etc/UTC"
      start_time  = "2027-01-04T04:00:00Z"
    }

    daily-0500-utc = {
      name        = "daily-0500-utc"
      description = "Every day at 05:00 UTC."
      frequency   = "Day"
      interval    = 1
      timezone    = "Etc/UTC"
      start_time  = "2027-01-04T05:00:00Z"
    }

    daily-0515-utc = {
      name        = "daily-0515-utc"
      description = "Every day at 05:15 UTC."
      frequency   = "Day"
      interval    = 1
      timezone    = "Etc/UTC"
      start_time  = "2027-01-04T05:15:00Z"
    }

    daily-0600-utc = {
      name        = "daily-0600-utc"
      description = "Every day at 06:00 UTC."
      frequency   = "Day"
      interval    = 1
      timezone    = "Etc/UTC"
      start_time  = "2027-01-04T06:00:00Z"
    }

    weekly-monday-0700-utc = {
      name        = "weekly-monday-0700-utc"
      description = "Every Monday at 07:00 UTC."
      frequency   = "Week"
      interval    = 1
      timezone    = "Etc/UTC"
      start_time  = "2027-01-04T07:00:00Z"
      week_days   = ["Monday"]
    }

    weekly-sunday-0800-utc = {
      name        = "weekly-sunday-0800-utc"
      description = "Every Sunday at 08:00 UTC."
      frequency   = "Week"
      interval    = 1
      timezone    = "Etc/UTC"
      start_time  = "2027-01-10T08:00:00Z"
      week_days   = ["Sunday"]
    }

    hourly-45-utc = {
      name        = "hourly-45-utc"
      description = "Every hour at 45 minutes past, UTC."
      frequency   = "Hour"
      interval    = 1
      timezone    = "Etc/UTC"
      start_time  = "2027-01-04T00:45:00Z"
    }
  }

  # -------------------------------------------------------------------------
  # Runbooks. Parameter keys are lowercase (Azure Automation normalises them).
  # clientid, environment, sendermailbox, and dryrun are added by the stack,
  # identity_key picks the identity whose client ID clientid carries, and
  # stack_parameters names the other values only the stack knows.
  # -------------------------------------------------------------------------
  runbooks = {
    app-credential-hygiene = {
      name         = "Invoke-AppCredentialHygiene"
      file         = "Invoke-AppCredentialHygiene.ps1"
      description  = "Expiring and expired application credentials: digest to owners, removal after a grace period."
      schedule_key = "daily-0600-utc"
      identity_key = "lifecycle"
      parameters = {
        warndays          = "30"
        removeexpired     = "false"
        removeafterdays   = "30"
        maxremovalsperrun = "25"
        excludedapptag    = "NoCredentialHygiene"
        fallbackrecipient = "iam@corp.example.com"
      }
    }

    guest-lifecycle = {
      name         = "Invoke-GuestLifecycle"
      file         = "Invoke-GuestLifecycle.ps1"
      description  = "Dormant guests: warn at 60 days, disable at 90, purge 120 days after disable. Stage held in group membership."
      schedule_key = "weekly-monday-0700-utc"
      identity_key = "lifecycle"
      parameters = {
        warndays          = "60"
        disabledays       = "90"
        purgedays         = "120"
        warnedgroupname   = "LC Guests Warned"
        disabledgroupname = "LC Guests Disabled"
        exemptgroupname   = "LC Guests Exempt"
        maxdisableperrun  = "25"
        maxpurgeperrun    = "10"
        fallbackrecipient = "iam@corp.example.com"
      }
    }

    # Report path: the observer tier holds Policy.Read.AuthenticationMethod,
    # so this run detects and mails drift and the release train patches it.
    authentication-methods-drift = {
      name         = "Invoke-AuthenticationMethodsDrift"
      file         = "Invoke-AuthenticationMethodsDrift.ps1"
      library      = "AuthenticationMethods.Common.ps1"
      description  = "Weekly comparison of the authentication methods policy with the repository's desired state, mailed as a digest when they differ."
      schedule_key = "weekly-sunday-0800-utc"
      identity_key = "observer"
      parameters = {
        recipients                = join(";", ["iam@corp.example.com"])
        allowmigrationstatechange = "false"
      }
    }

    # Published source of every runbook in this account, zipped, verified by
    # a restore, pruned by age with a floor. The account, its resource group
    # and subscription, and the storage names all come from the stack, and
    # asking for the storage names is what gives the observer identity the
    # Storage Blob Data Contributor assignment on the container.
    runbook-backup = {
      name         = "Backup-AutomationRunbooks"
      file         = "Backup-AutomationRunbooks.ps1"
      library      = "Runbook.Common.ps1"
      description  = "Nightly backup of every published runbook in this account to blob storage, with restore verification and capped retention."
      schedule_key = "daily-0200-utc"
      identity_key = "observer"
      parameters = {
        prefix           = "automation"
        retentiondays    = "30"
        keepatleast      = "7"
        maxdeletesperrun = "20"
        maxshrinkpercent = "25"
      }
      stack_parameters = {
        automationaccountnames = "automation_account_names"
        resourcegroupname      = "resource_group_name"
        subscriptionname       = "subscription_id"
        storageaccountname     = "backup_storage_account_name"
        containername          = "backup_container_name"
      }
    }

    # Groups only. Every group ../azure-pim-governance gives an end date is
    # excluded, because Terraform owns those dates; permanent eligibilities
    # are skipped by the runbook anyway.
    #
    # includeazureresources is false, so this run covers directory roles and
    # PIM for Groups only and needs no Azure role. Turning it on also means
    # giving the pim tier roleEligibilityScheduleRequests/write at the scopes
    # in azurescopenames (the custom role "PIM Policy and Eligibility
    # Operator"), and that action creates an eligibility as readily as it
    # extends one: the tier could then make any principal eligible for Owner
    # anywhere under mg-example-root, which is Owner-equivalent over those
    # scopes. Turn it on only with that in the change description.
    pim-eligibility-renewal = {
      name         = "Invoke-PimEligibilityRenewal"
      file         = "Invoke-PimEligibilityRenewal.ps1"
      library      = "Runbook.Common.ps1"
      description  = "Extends group PIM eligibilities that are about to expire on directory roles and PIM for Groups; reports individual ones for a person."
      schedule_key = "daily-0330-utc"
      identity_key = "pim"
      parameters = {
        renewwithindays           = "14"
        extenddays                = "365"
        includedirectoryroles     = "true"
        includegroups             = "true"
        includeazureresources     = "false"
        azurescopenames           = join(";", ["mg:mg-example-root"])
        principalgroupnamepattern = join(";", ["*", "!Break Glass Owners", "!Cloud Engineers", "!Platform Operators", "!FinOps Analysts"])
        maxrenewalsperrun         = "20"
        recipients                = join(";", ["iam@corp.example.com"])
      }
    }

    # Sweeps only the sandbox management group, the same one its conditioned
    # role is assigned at above. Allowlisted owners are the transitive user
    # members of the named group. To exclude a subscription, add its ID (not
    # its name; any Owner can rename one) to excludedsubscriptionnames.
    #
    # Two switches, in this order: dry_run = false makes this a report-only
    # live run that mails the digest and cancels nothing; allowcancel = "true"
    # is the second, and only after the Cancel sign-off and a sandbox round
    # trip. While it is false the runbook reports every subscription it would
    # cancel as WouldCancel and creates no Owner assignment at all.
    subscription-guard = {
      name         = "Disable-UnauthorizedSubscriptions"
      file         = "Disable-UnauthorizedSubscriptions.ps1"
      library      = "Runbook.Common.ps1"
      description  = "Reports, and once allowed cancels, Enabled subscriptions of restricted offer types whose direct owners are not allowlisted, through a just-in-time Owner assignment it removes in the same run."
      schedule_key = "daily-0400-utc"
      identity_key = "subscription-guard"
      parameters = {
        managementgroupname         = "mg-example-sandbox"
        restrictedquotaidpatterns   = join(";", ["MSDN_*", "FreeTrial_*", "PayAsYouGo_*", "Pay-as-you-go_*"])
        allowedownergroupnames      = join(";", ["SEC Subscription Owners"])
        allowcancel                 = "false"
        maxdisablesperrun           = "3"
        elevationpropagationseconds = "60"
        maxdisableattempts          = "5"
        recipients                  = join(";", ["cloud-governance@corp.example.com"])
      }
      stack_parameters = {
        identityprincipalid = "identity_principal_id"
      }
    }

    # The baseline is the Automation variable PimPolicy_AzureBaseline, which
    # desired_state_files publishes from
    # policies/azure/pim-governance/corp-baseline.json. That file mirrors
    # ../azure-pim-governance: tenant defaults and every policies entry, so
    # each declared pair is held to its own declared values and the pairs
    # nobody declared are held to the defaults.
    azure-pim-policy-governance = {
      name         = "Invoke-AzurePimPolicyGovernance"
      file         = "Invoke-AzurePimPolicyGovernance.ps1"
      library      = "Runbook.Common.ps1"
      description  = "Holds the activation rules of every eligible Azure resource role under the root management group to the tenant baseline, declared pairs included."
      schedule_key = "daily-0500-utc"
      identity_key = "pim"
      parameters = {
        scopenames             = join(";", ["mg:mg-example-root"])
        baselinevariablename   = "PimPolicy_AzureBaseline"
        maxpolicyupdatesperrun = "25"
        recipients             = join(";", ["iam@corp.example.com"])
      }
    }

    # Directory roles hold the default baseline. Global Administrator's
    # approval is asked once, on the member policy of its PIM group, which
    # mirrors ../entra-pim-governance; the three groups are checked too. The
    # baseline is the Automation variable PimPolicy_EntraBaseline, published
    # from policies/entra/pim-governance/corp-baseline.json.
    entra-pim-policy-drift = {
      name         = "Invoke-EntraPimPolicyDrift"
      file         = "Invoke-EntraPimPolicyDrift.ps1"
      library      = "Runbook.Common.ps1"
      description  = "Compares the PIM settings of every Entra directory role and the privileged PIM groups with the baseline, and mails the drift."
      schedule_key = "daily-0515-utc"
      identity_key = "pim"
      parameters = {
        baselinevariablename = "PimPolicy_EntraBaseline"
        includegroupnames    = join(";", ["PIM Global Administrators", "PIM Security Administrators", "PIM User Administrators"])
        maxruleupdatesperrun = "40"
        recipients           = join(";", ["iam@corp.example.com"])
      }
    }

    # Watches this account. The watcher keeps what it has reported in the
    # Automation variable JobWatch_AlertedJobIds, which it creates itself;
    # never declare that variable in Terraform.
    job-failure-watch = {
      name         = "Watch-AutomationJobFailures"
      file         = "Watch-AutomationJobFailures.ps1"
      library      = "Runbook.Common.ps1"
      description  = "Hourly: mails one digest when a job in this account failed or a scheduled run did not happen."
      schedule_key = "hourly-45-utc"
      identity_key = "observer"
      parameters = {
        lookbackminutes       = "70"
        heartbeatgraceminutes = "30"
        statevariablename     = "JobWatch_AlertedJobIds"
        recipients            = join(";", ["iam@corp.example.com"])
      }
      stack_parameters = {
        automationaccountname = "automation_account_name"
        resourcegroupname     = "resource_group_name"
        subscriptionname      = "subscription_id"
      }
    }
  }

  # -------------------------------------------------------------------------
  # Desired-state files published as Automation string variables, one per
  # file, named as the runbook that reads it expects. Paths are relative to
  # the repository root, and a file edit is a plan diff on the variable.
  # -------------------------------------------------------------------------
  desired_state_files = {
    AuthMethods_Policy                 = "policies/entra/authentication-methods/policy.json"
    AuthMethods_Fido2                  = "policies/entra/authentication-methods/methods/Fido2.json"
    AuthMethods_MicrosoftAuthenticator = "policies/entra/authentication-methods/methods/MicrosoftAuthenticator.json"
    AuthMethods_TemporaryAccessPass    = "policies/entra/authentication-methods/methods/TemporaryAccessPass.json"
    AuthMethods_Sms                    = "policies/entra/authentication-methods/methods/Sms.json"
    AuthMethods_Voice                  = "policies/entra/authentication-methods/methods/Voice.json"
    AuthMethods_Email                  = "policies/entra/authentication-methods/methods/Email.json"
    AuthMethods_SoftwareOath           = "policies/entra/authentication-methods/methods/SoftwareOath.json"
    AuthMethods_X509Certificate        = "policies/entra/authentication-methods/methods/X509Certificate.json"

    PimPolicy_AzureBaseline = "policies/azure/pim-governance/corp-baseline.json"
    PimPolicy_EntraBaseline = "policies/entra/pim-governance/corp-baseline.json"
  }
}
