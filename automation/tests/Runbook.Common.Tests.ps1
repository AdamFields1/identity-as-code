# Pester tests for automation/lib/Runbook.Common.ps1.
#
# Written in the Pester 3/4 assertion syntax ("Should Be") because Windows
# PowerShell 5.1 ships Pester 3.4.0. The library is dot-sourced exactly as a
# runbook's INLINE_LIBRARY block does on a workstation. Every HTTP request in
# the library goes through Invoke-HttpCore, which is mocked here with a queue
# of canned responses shaped like the Graph, ARM, Storage, and identity
# endpoint documentation; Start-Sleep and the Az.Accounts probe are mocked
# too, so nothing in this file leaves the machine or waits. The last context
# assembles a sample runbook the way modules/azure/automation-runbooks does
# and runs it, so the inline contract is tested, not just described.
#
# Get-AutomationVariable exists only in the Automation sandbox. The tests that
# need it define a global stand-in and remove it again; every other test
# relies on it being absent.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$automationRoot = Split-Path -Parent $here
$repoRoot = Split-Path -Parent $automationRoot
$library = Join-Path -Path $automationRoot -ChildPath 'lib\Runbook.Common.ps1'
$runbooksModule = Join-Path -Path $repoRoot -ChildPath 'modules\azure\automation-runbooks\main.tf'

Describe 'Runbook.Common' {
    . $library
    $VerbosePreference = 'SilentlyContinue'
    $WarningPreference = 'SilentlyContinue'

    Remove-Item -Path Env:\IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
    Remove-Item -Path Env:\IDENTITY_HEADER -ErrorAction SilentlyContinue

    $global:RbcQueue = New-Object System.Collections.Queue
    $global:RbcRequests = New-Object System.Collections.ArrayList

    # Fake values only. The GUIDs are all-same-digit on purpose.
    $graphToken = 'eyJ0eXAiOiJKV1QifQ.graphpayload0000000000.graphsignature000'
    $armToken = 'eyJ0eXAiOiJKV1QifQ.armpayload00000000000.armsignature00000'
    $storageToken = 'eyJ0eXAiOiJKV1QifQ.storagepayload0000000.storagesig0000000'
    $runId = '00000000-0000-0000-0000-000000000000'
    $clientId = '11111111-1111-1111-1111-111111111111'
    $groupId = '22222222-2222-2222-2222-222222222222'
    $subscriptionA = '33333333-3333-3333-3333-333333333333'
    $subscriptionB = '44444444-4444-4444-4444-444444444444'

    function New-TestResponse {
        param(
            [int]$Status = 200,
            [object]$Json = $null,
            [string]$Text = '',
            [hashtable]$Headers = @{}
        )
        $content = $Text
        if ($null -ne $Json) { $content = ConvertTo-Json -InputObject $Json -Depth 20 -Compress }
        return @{ StatusCode = $Status; Content = $content; Headers = $Headers }
    }

    function Set-TestResponses {
        param([object[]]$Responses = @())
        $global:RbcQueue.Clear()
        $global:RbcRequests.Clear()
        foreach ($response in $Responses) { $global:RbcQueue.Enqueue($response) }
    }

    function Get-TestRequest {
        param([int]$Index)
        return $global:RbcRequests[$Index]
    }

    function Start-TestRun {
        param(
            [string]$Environment = 'Global',
            [object]$AccessToken = @{ Graph = $graphToken; Arm = $armToken; Storage = $storageToken },
            [bool]$DryRun = $true,
            [string]$ClientId = ''
        )
        Initialize-RunContext -RunbookName 'Runbook.Common.Tests' -RunId $runId -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken -DryRun $DryRun
    }

    # A queued scriptblock is run instead of returned, so a test can simulate
    # a request that got no HTTP response at all, or a download that writes
    # the file it is given (the block receives OutFile as its argument).
    Mock Invoke-HttpCore {
        [void]$global:RbcRequests.Add(@{ Method = $Method; Uri = $Uri; Headers = $Headers; Body = $Body; ContentType = $ContentType; OutFile = $OutFile })
        if ($global:RbcQueue.Count -eq 0) { throw 'Test queue is empty: an unexpected HTTP call was made.' }
        $next = $global:RbcQueue.Dequeue()
        if ($next -is [scriptblock]) { return (& $next $OutFile) }
        return $next
    }
    Mock Start-Sleep { }
    Mock Test-AzAccountsAvailable { return $false }

    # Stand-ins so the Az.Accounts path can be mocked whether or not the
    # module is installed on the machine running the tests.
    function Get-AzContext { [CmdletBinding()] param() }
    function Connect-AzAccount { [CmdletBinding()] param([switch]$Identity, [string]$AccountId, [string]$Environment) }
    function Get-AzAccessToken { [CmdletBinding()] param([string]$ResourceUrl) }

    Context 'cloud endpoints' {
        It 'returns the global endpoints and token resources' {
            $e = Get-CloudEndpoints -Environment Global
            $e.Graph | Should Be 'https://graph.microsoft.com'
            $e.Arm | Should Be 'https://management.azure.com'
            $e.Login | Should Be 'https://login.microsoftonline.com'
            $e.BlobSuffix | Should Be 'blob.core.windows.net'
            $e.GraphResource | Should Be 'https://graph.microsoft.com'
            $e.ArmResource | Should Be 'https://management.azure.com/'
            $e.StorageResource | Should Be 'https://storage.azure.com/'
        }

        It 'returns the US Government endpoints and token resources' {
            $e = Get-CloudEndpoints -Environment USGov
            $e.Graph | Should Be 'https://graph.microsoft.us'
            $e.Arm | Should Be 'https://management.usgovcloudapi.net'
            $e.Login | Should Be 'https://login.microsoftonline.us'
            $e.BlobSuffix | Should Be 'blob.core.usgovcloudapi.net'
            $e.GraphResource | Should Be 'https://graph.microsoft.us'
            $e.ArmResource | Should Be 'https://management.usgovcloudapi.net/'
            $e.StorageResource | Should Be 'https://storage.azure.com/'
        }

        It 'rejects an unknown cloud' {
            { Get-CloudEndpoints -Environment 'China' } | Should Throw
        }

        It 'sends a relative Graph request to the US Government v1.0 endpoint' {
            Start-TestRun -Environment USGov
            Set-TestResponses @((New-TestResponse -Json @{ id = 'org' }))
            $r = Invoke-CloudRequest -Api Graph -Uri 'organization'
            $r.id | Should Be 'org'
            (Get-TestRequest 0).Uri | Should Be 'https://graph.microsoft.us/v1.0/organization'
        }

        It 'keeps an explicit beta segment and a leading slash' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json @{ id = 'p' }))
            Invoke-CloudRequest -Api Graph -Uri '/beta/policies/authenticationMethodsPolicy' | Out-Null
            (Get-TestRequest 0).Uri | Should Be 'https://graph.microsoft.com/beta/policies/authenticationMethodsPolicy'
        }

        It 'appends api-version to a relative ARM request in US Government' {
            Start-TestRun -Environment USGov
            Set-TestResponses @((New-TestResponse -Json @{ value = @() }))
            Invoke-CloudRequest -Api Arm -Uri "subscriptions/$subscriptionA/resourceGroups?`$top=5" -ApiVersion '2021-04-01' | Out-Null
            (Get-TestRequest 0).Uri | Should Be "https://management.usgovcloudapi.net/subscriptions/$subscriptionA/resourceGroups?`$top=5&api-version=2021-04-01"
        }

        It 'keeps an api-version already in the ARM URI' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json @{ value = @() }))
            Invoke-CloudRequest -Api Arm -Uri 'subscriptions?api-version=2022-12-01' -ApiVersion '1999-01-01' | Out-Null
            (Get-TestRequest 0).Uri | Should Be 'https://management.azure.com/subscriptions?api-version=2022-12-01'
        }

        It 'refuses an ARM request without an api-version before calling anything' {
            Start-TestRun
            Set-TestResponses @()
            { Invoke-CloudRequest -Api Arm -Uri 'subscriptions' } | Should Throw 'Pass -ApiVersion'
            Assert-MockCalled Invoke-HttpCore -Exactly 0 -Scope It
        }

        It 'refuses to send a token to another host' {
            Start-TestRun
            Set-TestResponses @()
            { Invoke-CloudRequest -Api Graph -Uri 'https://graph.example.com/v1.0/users' } | Should Throw 'Refusing to send a Graph token'
            { Invoke-CloudRequest -Api Arm -Uri 'https://graph.microsoft.com/subscriptions?api-version=2022-12-01' } | Should Throw 'Refusing to send a Arm token'
            Assert-MockCalled Invoke-HttpCore -Exactly 0 -Scope It
        }

        It 'refuses a US Government run calling the global Graph host' {
            Start-TestRun -Environment USGov
            Set-TestResponses @()
            { Invoke-CloudRequest -Api Graph -Uri 'https://graph.microsoft.com/v1.0/users' } | Should Throw 'must go to https://graph.microsoft.us'
        }

        It 'refuses plain http' {
            Start-TestRun
            Set-TestResponses @()
            { Invoke-CloudRequest -Api Graph -Uri 'http://graph.microsoft.com/v1.0/users' } | Should Throw 'Refusing'
        }
    }

    Context 'token source selection and caching' {
        It 'uses one supplied string for every resource without calling an identity endpoint' {
            Start-TestRun -AccessToken $graphToken
            Set-TestResponses @((New-TestResponse -Json @{ id = 'a' }), (New-TestResponse -Json @{ value = @() }))
            Invoke-CloudRequest -Api Graph -Uri 'organization' | Out-Null
            Invoke-CloudRequest -Api Arm -Uri 'subscriptions' -ApiVersion '2022-12-01' | Out-Null
            $global:RbcRequests.Count | Should Be 2
            (Get-TestRequest 0).Headers['Authorization'] | Should Be ('Bearer ' + $graphToken)
            (Get-TestRequest 1).Headers['Authorization'] | Should Be ('Bearer ' + $graphToken)
        }

        It 'picks the supplied token per resource from a hashtable' {
            Start-TestRun
            (Get-RunbookAccessToken -Resource Graph) | Should Be $graphToken
            (Get-RunbookAccessToken -Resource Arm) | Should Be $armToken
            (Get-RunbookAccessToken -Resource Storage) | Should Be $storageToken
            Assert-MockCalled Invoke-HttpCore -Exactly 0 -Scope It
        }

        It 'matches hashtable keys without regard to case' {
            Start-TestRun -AccessToken @{ graph = $graphToken }
            (Get-RunbookAccessToken -Resource Graph) | Should Be $graphToken
        }

        It 'reads a JSON object string keyed by resource' {
            $json = '{"Graph":"' + $graphToken + '","Arm":"' + $armToken + '"}'
            Start-TestRun -AccessToken $json
            (Get-RunbookAccessToken -Resource Arm) | Should Be $armToken
            (Get-RunContext).HasSuppliedToken | Should Be $true
        }

        It 'fails clearly when a supplied table has no entry for the resource' {
            Start-TestRun -AccessToken @{ Graph = $graphToken }
            { Get-RunbookAccessToken -Resource Storage } | Should Throw 'no entry for Storage'
        }

        It 'rejects a malformed JSON token string without echoing it' {
            $bad = '{"Graph":"' + $graphToken
            $message = ''
            try { Start-TestRun -AccessToken $bad } catch { $message = $_.Exception.Message }
            $message | Should Match 'not a JSON object'
            $message.Contains($graphToken) | Should Be $false
        }

        It 'rejects a token object that lacks its closing brace, without echoing it' {
            $bad = '{"Graph":"' + $graphToken + '"'
            $message = ''
            try { Start-TestRun -AccessToken $bad } catch { $message = $_.Exception.Message }
            $message | Should Match 'not a JSON object'
            $message.Contains($graphToken) | Should Be $false
        }

        It 'rejects a token object followed by trailing text, without echoing it' {
            $bad = '{"Graph":"' + $graphToken + '"} // note'
            $message = ''
            try { Start-TestRun -AccessToken $bad } catch { $message = $_.Exception.Message }
            $message | Should Match 'not a JSON object'
            $message.Contains($graphToken) | Should Be $false
        }

        It 'lets an explicit AccessToken argument override the run context' {
            Start-TestRun
            (Get-RunbookAccessToken -Resource Graph -AccessToken 'explicit-token-value-0000') | Should Be 'explicit-token-value-0000'
        }

        It 'asks the Automation identity endpoint with the resource, client id, and headers' {
            try {
                $env:IDENTITY_ENDPOINT = 'http://127.0.0.1:40342/msi/token'
                $env:IDENTITY_HEADER = 'identity-header-value-0000'
                Start-TestRun -AccessToken $null -ClientId $clientId
                Set-TestResponses @((New-TestResponse -Json @{ access_token = $graphToken; expires_on = '4102444800'; resource = 'https://graph.microsoft.com' }))
                (Get-RunbookAccessToken -Resource Graph) | Should Be $graphToken
                $request = Get-TestRequest 0
                $request.Method | Should Be 'GET'
                $request.Uri | Should Be ('http://127.0.0.1:40342/msi/token?resource=https%3A%2F%2Fgraph.microsoft.com&client_id=' + $clientId)
                $request.Headers['X-IDENTITY-HEADER'] | Should Be 'identity-header-value-0000'
                $request.Headers['Metadata'] | Should Be 'True'
            }
            finally {
                Remove-Item -Path Env:\IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
                Remove-Item -Path Env:\IDENTITY_HEADER -ErrorAction SilentlyContinue
            }
        }

        It 'asks for the US Government ARM resource and omits client_id for the default identity' {
            try {
                $env:IDENTITY_ENDPOINT = 'http://127.0.0.1:40342/msi/token'
                $env:IDENTITY_HEADER = 'identity-header-value-0000'
                Start-TestRun -Environment USGov -AccessToken ''
                Set-TestResponses @((New-TestResponse -Json @{ access_token = $armToken; expires_on = '4102444800' }))
                (Get-RunbookAccessToken -Resource Arm) | Should Be $armToken
                (Get-TestRequest 0).Uri | Should Be 'http://127.0.0.1:40342/msi/token?resource=https%3A%2F%2Fmanagement.usgovcloudapi.net%2F'
            }
            finally {
                Remove-Item -Path Env:\IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
                Remove-Item -Path Env:\IDENTITY_HEADER -ErrorAction SilentlyContinue
            }
        }

        It 'caches the identity token per resource and refreshes on request' {
            try {
                $env:IDENTITY_ENDPOINT = 'http://127.0.0.1:40342/msi/token'
                $env:IDENTITY_HEADER = 'identity-header-value-0000'
                Start-TestRun -AccessToken $null -ClientId $clientId
                Set-TestResponses @(
                    (New-TestResponse -Json @{ access_token = $graphToken; expires_on = '4102444800' }),
                    (New-TestResponse -Json @{ access_token = $storageToken; expires_on = '4102444800' }),
                    (New-TestResponse -Json @{ access_token = 'refreshed-graph-token-0000'; expires_on = '4102444800' }),
                    (New-TestResponse -Json @{ organization = 'x' }))
                (Get-RunbookAccessToken -Resource Graph) | Should Be $graphToken
                (Get-RunbookAccessToken -Resource Graph) | Should Be $graphToken
                (Get-RunbookAccessToken -Resource Storage) | Should Be $storageToken
                $global:RbcRequests.Count | Should Be 2
                (Get-RunbookAccessToken -Resource Graph -ForceRefresh) | Should Be 'refreshed-graph-token-0000'
                Invoke-CloudRequest -Api Graph -Uri 'organization' | Out-Null
                $global:RbcRequests.Count | Should Be 4
                (Get-TestRequest 3).Headers['Authorization'] | Should Be 'Bearer refreshed-graph-token-0000'
                @(Get-RunLogEntries -Level Info | Where-Object { $_.Message -like 'Token for Graph*' }).Count | Should Be 1
            }
            finally {
                Remove-Item -Path Env:\IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
                Remove-Item -Path Env:\IDENTITY_HEADER -ErrorAction SilentlyContinue
            }
        }

        It 'acquires again when the cached token is about to expire' {
            try {
                $env:IDENTITY_ENDPOINT = 'http://127.0.0.1:40342/msi/token'
                $env:IDENTITY_HEADER = 'identity-header-value-0000'
                Start-TestRun -AccessToken $null
                $soon = [string][long](([DateTime]::UtcNow.AddSeconds(60) - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalSeconds)
                Set-TestResponses @(
                    (New-TestResponse -Json @{ access_token = 'short-lived-token-0000'; expires_on = $soon }),
                    (New-TestResponse -Json @{ access_token = 'fresh-token-value-0000'; expires_in = '3599' }))
                (Get-RunbookAccessToken -Resource Graph) | Should Be 'short-lived-token-0000'
                (Get-RunbookAccessToken -Resource Graph) | Should Be 'fresh-token-value-0000'
            }
            finally {
                Remove-Item -Path Env:\IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
                Remove-Item -Path Env:\IDENTITY_HEADER -ErrorAction SilentlyContinue
            }
        }

        It 'retries a failing identity endpoint, then fails with the resource and client id' {
            try {
                $env:IDENTITY_ENDPOINT = 'http://127.0.0.1:40342/msi/token'
                $env:IDENTITY_HEADER = 'identity-header-value-0000'
                Start-TestRun -AccessToken $null -ClientId $clientId
                Set-TestResponses @(
                    (New-TestResponse -Status 500 -Text 'busy'),
                    (New-TestResponse -Status 500 -Text 'busy'),
                    (New-TestResponse -Status 500 -Text 'busy'))
                { Get-RunbookAccessToken -Resource Graph } | Should Throw ('Could not get a Graph token from the Automation identity endpoint (client_id ' + $clientId + ')')
                $global:RbcRequests.Count | Should Be 3
                Assert-MockCalled Start-Sleep -Exactly 2 -Scope It
            }
            finally {
                Remove-Item -Path Env:\IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
                Remove-Item -Path Env:\IDENTITY_HEADER -ErrorAction SilentlyContinue
            }
        }

        It 'fails when the identity endpoint returns no access_token' {
            try {
                $env:IDENTITY_ENDPOINT = 'http://127.0.0.1:40342/msi/token'
                $env:IDENTITY_HEADER = 'identity-header-value-0000'
                Start-TestRun -AccessToken $null
                Set-TestResponses @((New-TestResponse -Json @{ token_type = 'Bearer' }))
                { Get-RunbookAccessToken -Resource Arm } | Should Throw 'returned no access_token for Arm'
            }
            finally {
                Remove-Item -Path Env:\IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
                Remove-Item -Path Env:\IDENTITY_HEADER -ErrorAction SilentlyContinue
            }
        }

        It 'prefers the identity endpoint over Az.Accounts' {
            try {
                $env:IDENTITY_ENDPOINT = 'http://127.0.0.1:40342/msi/token'
                $env:IDENTITY_HEADER = 'identity-header-value-0000'
                Mock Test-AzAccountsAvailable { return $true }
                Mock Get-AzAccessToken { throw 'Az.Accounts should not be used' }
                Start-TestRun -AccessToken $null
                Set-TestResponses @((New-TestResponse -Json @{ access_token = $graphToken; expires_on = '4102444800' }))
                (Get-RunbookAccessToken -Resource Graph) | Should Be $graphToken
                Assert-MockCalled Get-AzAccessToken -Exactly 0 -Scope It
            }
            finally {
                Remove-Item -Path Env:\IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
                Remove-Item -Path Env:\IDENTITY_HEADER -ErrorAction SilentlyContinue
            }
        }

        It 'falls back to Az.Accounts, connecting with the managed identity in the right cloud' {
            Mock Test-AzAccountsAvailable { return $true }
            Mock Get-AzContext { return $null }
            Mock Connect-AzAccount { return $null }
            Mock Get-AzAccessToken {
                return [PSCustomObject]@{
                    Token     = (ConvertTo-SecureString -String 'az-accounts-token-0000' -AsPlainText -Force)
                    ExpiresOn = [DateTimeOffset]::UtcNow.AddHours(1)
                }
            }
            Start-TestRun -Environment USGov -AccessToken $null -ClientId $clientId
            (Get-RunbookAccessToken -Resource Arm) | Should Be 'az-accounts-token-0000'
            (Get-RunbookAccessToken -Resource Arm) | Should Be 'az-accounts-token-0000'
            Assert-MockCalled Connect-AzAccount -Exactly 1 -Scope It -ParameterFilter { $Identity -and $AccountId -eq $clientId -and $Environment -eq 'AzureUSGovernment' }
            Assert-MockCalled Get-AzAccessToken -Exactly 1 -Scope It -ParameterFilter { $ResourceUrl -eq 'https://management.usgovcloudapi.net/' }
            Assert-MockCalled Invoke-HttpCore -Exactly 0 -Scope It
        }

        It 'uses an existing Az context without connecting again' {
            Mock Test-AzAccountsAvailable { return $true }
            Mock Get-AzContext { return [PSCustomObject]@{ Name = 'existing' } }
            Mock Connect-AzAccount { return $null }
            Mock Get-AzAccessToken { return [PSCustomObject]@{ Token = 'plain-az-token-0000'; ExpiresOn = [DateTimeOffset]::UtcNow.AddHours(1) } }
            Start-TestRun -AccessToken $null
            (Get-RunbookAccessToken -Resource Storage) | Should Be 'plain-az-token-0000'
            Assert-MockCalled Connect-AzAccount -Exactly 0 -Scope It
            Assert-MockCalled Get-AzAccessToken -Exactly 1 -Scope It -ParameterFilter { $ResourceUrl -eq 'https://storage.azure.com/' }
        }

        It 'fails when there is no credential source at all' {
            # Pester 3.4 keeps a mock made inside an It for the rest of the
            # Context, so the Az.Accounts answer is set again here.
            Mock Test-AzAccountsAvailable { return $false }
            Start-TestRun -AccessToken $null
            { Get-RunbookAccessToken -Resource Graph } | Should Throw 'No credential source'
        }
    }

    Context 'the token is never written' {
        It 'keeps supplied and acquired tokens out of every stream and every error' {
            try {
                $env:IDENTITY_ENDPOINT = 'http://127.0.0.1:40342/msi/token'
                $env:IDENTITY_HEADER = 'identity-header-value-0000'
                $echo = '{"error":{"code":"InvalidAuthenticationToken","message":"Token ' + $armToken + ' rejected. Header was Bearer ' + $armToken + ' and identity-header-value-0000"}}'
                $captured = & {
                    $VerbosePreference = 'Continue'
                    $WarningPreference = 'Continue'
                    Start-TestRun -AccessToken $null -ClientId $clientId
                    Set-TestResponses @(
                        (New-TestResponse -Json @{ access_token = $armToken; expires_on = '4102444800' }),
                        (New-TestResponse -Status 503 -Text $echo),
                        (New-TestResponse -Status 401 -Text $echo))
                    $null = Get-RunbookAccessToken -Resource Arm
                    try { Invoke-CloudRequest -Api Arm -Uri 'subscriptions' -ApiVersion '2022-12-01' | Out-Null }
                    catch { Write-RunLog -Level Error -Message $_.Exception.Message; 'THROWN: ' + $_.Exception.Message }
                } 4>&1 3>&1 2>&1
                $text = ($captured | ForEach-Object { [string]$_ }) -join "`n"
                $text | Should Match 'THROWN: Arm GET /subscriptions'
                $text | Should Match 'HTTP 401'
                $text.Contains($armToken) | Should Be $false
                $text.Contains('identity-header-value-0000') | Should Be $false
                $logText = (@(Get-RunLogEntries) | ForEach-Object { $_.Message }) -join "`n"
                $logText.Contains($armToken) | Should Be $false
                $logText | Should Match 'Token for Arm'
            }
            finally {
                Remove-Item -Path Env:\IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
                Remove-Item -Path Env:\IDENTITY_HEADER -ErrorAction SilentlyContinue
            }
        }

        It 'scrubs JWTs, bearer values, signatures, and secrets from text' {
            Start-TestRun
            $dirty = "a eyJabc.def.ghi b Bearer abc.def-123 c https://x.example.com/c/b?sv=1&sig=abc%2Bdef d ""client_secret"":""s3cr3t"" e $storageToken"
            $clean = Protect-RunbookText -Text $dirty
            $clean.Contains('eyJabc.def.ghi') | Should Be $false
            $clean.Contains('abc.def-123') | Should Be $false
            $clean.Contains('abc%2Bdef') | Should Be $false
            $clean.Contains('s3cr3t') | Should Be $false
            $clean.Contains($storageToken) | Should Be $false
            $clean | Should Match 'sv=1&sig=\[redacted\]'
        }

        It 'redacts continuation tokens and signatures from a request path' {
            ConvertTo-SafeRequestPath -Uri 'https://graph.microsoft.com/v1.0/users?$top=5&$skiptoken=abc' | Should Be '/v1.0/users?$top=5&$skiptoken=[redacted]'
            ConvertTo-SafeRequestPath -Uri 'https://acct.blob.core.windows.net/c/b?sv=2023&sig=zzz' | Should Be '/c/b?sv=2023&sig=[redacted]'
        }

        It 'does not leak the context token through Get-RunContext' {
            Start-TestRun
            $context = Get-RunContext
            ($context | Out-String).Contains($graphToken) | Should Be $false
            $context.PSObject.Properties['AccessToken'] | Should BeNullOrEmpty
            $context.RunId | Should Be $runId
        }
    }

    Context 'Invoke-CloudRequest paging, bodies, and headers' {
        It 'follows Graph @odata.nextLink and returns the combined value items' {
            Start-TestRun
            Set-TestResponses @(
                (New-TestResponse -Json @{ value = @(@{ id = 'u1' }, @{ id = 'u2' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/users?$top=2&$skiptoken=p2' }),
                (New-TestResponse -Json @{ value = @(@{ id = 'u3' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/users?$top=2&$skiptoken=p3' }),
                (New-TestResponse -Json @{ value = @(@{ id = 'u4' }, @{ id = 'u5' }) }))
            $users = @(Invoke-CloudRequest -Api Graph -Uri 'users?$top=2' -AllPages)
            $users.Count | Should Be 5
            ($users | ForEach-Object { $_.id }) -join ',' | Should Be 'u1,u2,u3,u4,u5'
            (Get-TestRequest 0).Uri | Should Be 'https://graph.microsoft.com/v1.0/users?$top=2'
            (Get-TestRequest 1).Uri | Should Be 'https://graph.microsoft.com/v1.0/users?$top=2&$skiptoken=p2'
            (Get-TestRequest 2).Uri | Should Be 'https://graph.microsoft.com/v1.0/users?$top=2&$skiptoken=p3'
        }

        It 'returns one item as a one-element array inside @()' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json @{ value = @(@{ id = 'only' }) }))
            $items = @(Invoke-CloudRequest -Api Graph -Uri 'groups' -AllPages)
            $items.Count | Should Be 1
            $items[0].id | Should Be 'only'
        }

        It 'returns nothing for an empty value array' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Text '{"value":[]}'))
            @(Invoke-CloudRequest -Api Graph -Uri 'groups' -AllPages).Count | Should Be 0
        }

        It 'follows ARM nextLink as given' {
            Start-TestRun
            $next = "https://management.azure.com/subscriptions?api-version=2022-12-01&%24skiptoken=abc"
            Set-TestResponses @(
                (New-TestResponse -Json @{ value = @(@{ subscriptionId = $subscriptionA }); nextLink = $next }),
                (New-TestResponse -Json @{ value = @(@{ subscriptionId = $subscriptionB }); nextLink = $null }))
            $subs = @(Invoke-CloudRequest -Api Arm -Uri 'subscriptions' -ApiVersion '2022-12-01' -AllPages)
            $subs.Count | Should Be 2
            (Get-TestRequest 0).Uri | Should Be 'https://management.azure.com/subscriptions?api-version=2022-12-01'
            (Get-TestRequest 1).Uri | Should Be $next
            (Get-TestRequest 1).Headers['Authorization'] | Should Be ('Bearer ' + $armToken)
        }

        It 'follows the @nextLink spelling the management groups list documents' {
            Start-TestRun
            Set-TestResponses @(
                (New-TestResponse -Json @{ value = @(@{ name = 'mg-a' }); '@nextLink' = 'https://management.azure.com/providers/Microsoft.Management/managementGroups?api-version=2020-05-01&$skiptoken=x' }),
                (New-TestResponse -Json @{ value = @(@{ name = 'mg-b' }) }))
            @(Invoke-CloudRequest -Api Arm -Uri 'providers/Microsoft.Management/managementGroups' -ApiVersion '2020-05-01' -AllPages).Count | Should Be 2
        }

        It 'refuses a next link on another host' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json @{ value = @(@{ id = 'a' }); '@odata.nextLink' = 'https://attacker.example.com/v1.0/users?$skiptoken=x' }))
            { Invoke-CloudRequest -Api Graph -Uri 'users' -AllPages } | Should Throw 'Refusing to send a Graph token'
            $global:RbcRequests.Count | Should Be 1
        }

        It 'stops when a next link repeats' {
            Start-TestRun
            $loop = 'https://graph.microsoft.com/v1.0/users?$skiptoken=same'
            Set-TestResponses @(
                (New-TestResponse -Json @{ value = @(@{ id = 'a' }); '@odata.nextLink' = $loop }),
                (New-TestResponse -Json @{ value = @(@{ id = 'b' }); '@odata.nextLink' = $loop }))
            { Invoke-CloudRequest -Api Graph -Uri 'users' -AllPages } | Should Throw 'already returned'
        }

        It 'stops at MaxPages' {
            Start-TestRun
            Set-TestResponses @(
                (New-TestResponse -Json @{ value = @(@{ id = 'a' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/users?$skiptoken=2' }),
                (New-TestResponse -Json @{ value = @(@{ id = 'b' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/users?$skiptoken=3' }))
            { Invoke-CloudRequest -Api Graph -Uri 'users' -AllPages -MaxPages 2 } | Should Throw 'more than 2 pages'
        }

        It 'rejects -AllPages with a write method' {
            Start-TestRun
            { Invoke-CloudRequest -Api Graph -Method POST -Uri 'users' -AllPages } | Should Throw 'only valid with GET'
        }

        It 'returns a single object without -AllPages, even when it has a value property' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json @{ value = @(@{ id = 'a' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/users?$skiptoken=2' }))
            $page = Invoke-CloudRequest -Api Graph -Uri 'users'
            @($page.value).Count | Should Be 1
            $global:RbcRequests.Count | Should Be 1
        }

        It 'serialises a hashtable body as JSON and passes a string body through' {
            Start-TestRun -DryRun $false
            Set-TestResponses @((New-TestResponse -Status 204), (New-TestResponse -Status 204))
            $r = Invoke-CloudRequest -Api Graph -Method PATCH -Uri 'users/u1' -Body @{ accountEnabled = $false; tags = @('one') }
            $r | Should BeNullOrEmpty
            $sent = Get-TestRequest 0
            $sent.Method | Should Be 'PATCH'
            $sent.ContentType | Should Be 'application/json; charset=utf-8'
            $parsed = ConvertFrom-Json -InputObject ([string]$sent.Body)
            $parsed.accountEnabled | Should Be $false
            @($parsed.tags).Count | Should Be 1
            Invoke-CloudRequest -Api Graph -Method POST -Uri 'groups/g/members/$ref' -Body '{"@odata.id":"x"}' | Out-Null
            (Get-TestRequest 1).Body | Should Be '{"@odata.id":"x"}'
            (Get-TestRequest 1).Uri | Should Be 'https://graph.microsoft.com/v1.0/groups/g/members/$ref'
        }

        It 'sends GET without a body or content type' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json @{ id = 'a' }))
            Invoke-CloudRequest -Api Graph -Uri 'me' | Out-Null
            (Get-TestRequest 0).Body | Should BeNullOrEmpty
            (Get-TestRequest 0).ContentType | Should BeNullOrEmpty
        }

        It 'adds extra headers but never lets them replace Authorization' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Text '42'))
            $count = Invoke-CloudRequest -Api Graph -Uri 'users/$count' -Headers @{ ConsistencyLevel = 'eventual'; Authorization = 'Bearer spoofed' }
            $count | Should Be '42'
            $sent = Get-TestRequest 0
            $sent.Headers['ConsistencyLevel'] | Should Be 'eventual'
            $sent.Headers['Authorization'] | Should Be ('Bearer ' + $graphToken)
            $sent.Headers['Accept'] | Should Be 'application/json'
        }
    }

    Context 'retries and errors' {
        It 'retries 429 and honours Retry-After' {
            Start-TestRun
            Set-TestResponses @(
                (New-TestResponse -Status 429 -Headers @{ 'Retry-After' = '7' }),
                (New-TestResponse -Json @{ id = 'ok' }))
            (Invoke-CloudRequest -Api Graph -Uri 'organization').id | Should Be 'ok'
            $global:RbcRequests.Count | Should Be 2
            Assert-MockCalled Start-Sleep -Exactly 1 -Scope It -ParameterFilter { $Seconds -eq 7 }
            (Get-RunLogCount -Level Warn) | Should Be 1
        }

        It 'caps a long Retry-After at 60 seconds' {
            Start-TestRun
            Set-TestResponses @(
                (New-TestResponse -Status 429 -Headers @{ 'Retry-After' = '120' }),
                (New-TestResponse -Json @{ id = 'ok' }))
            Invoke-CloudRequest -Api Arm -Uri 'subscriptions' -ApiVersion '2022-12-01' | Out-Null
            Assert-MockCalled Start-Sleep -Exactly 1 -Scope It -ParameterFilter { $Seconds -eq 60 }
        }

        It 'backs off exponentially on 5xx without Retry-After' {
            Start-TestRun
            Set-TestResponses @(
                (New-TestResponse -Status 503 -Text 'unavailable'),
                (New-TestResponse -Status 502 -Text 'bad gateway'),
                (New-TestResponse -Json @{ id = 'ok' }))
            Invoke-CloudRequest -Api Graph -Uri 'organization' | Out-Null
            Assert-MockCalled Start-Sleep -Exactly 1 -Scope It -ParameterFilter { $Seconds -eq 2 }
            Assert-MockCalled Start-Sleep -Exactly 1 -Scope It -ParameterFilter { $Seconds -eq 4 }
        }

        It 'gives up after MaxAttempts and reports the status' {
            Start-TestRun
            Set-TestResponses @(
                (New-TestResponse -Status 503 -Text 'unavailable'),
                (New-TestResponse -Status 503 -Text 'unavailable'),
                (New-TestResponse -Status 503 -Text 'unavailable'))
            $caught = $null
            try { Invoke-CloudRequest -Api Graph -Uri 'organization' -MaxAttempts 3 } catch { $caught = $_ }
            $caught | Should Not BeNullOrEmpty
            $caught.Exception.Message | Should Match 'failed with HTTP 503 after 3 attempt\(s\)'
            (Get-CloudErrorStatus -ErrorRecord $caught) | Should Be 503
            $global:RbcRequests.Count | Should Be 3
            Assert-MockCalled Start-Sleep -Exactly 2 -Scope It
        }

        It 'does not retry 403 and carries method, path, status, and the service message' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Status 403 -Json @{ error = @{ code = 'Authorization_RequestDenied'; message = 'Insufficient privileges to complete the operation.' } }))
            $caught = $null
            try { Invoke-CloudRequest -Api Graph -Uri "groups/$groupId/members" } catch { $caught = $_ }
            $caught.Exception.Message | Should Be "Graph GET /v1.0/groups/$groupId/members failed with HTTP 403 after 1 attempt(s): Authorization_RequestDenied: Insufficient privileges to complete the operation."
            $caught.Exception.Data['HttpStatus'] | Should Be 403
            $caught.Exception.Data['Method'] | Should Be 'GET'
            $caught.Exception.Data['Path'] | Should Be "/v1.0/groups/$groupId/members"
            $caught.Exception.Data['ErrorCode'] | Should Be 'Authorization_RequestDenied'
            $global:RbcRequests.Count | Should Be 1
            Assert-MockCalled Start-Sleep -Exactly 0 -Scope It
        }

        It 'does not retry other 4xx either' {
            Start-TestRun
            foreach ($status in @(400, 401, 404, 409)) {
                Set-TestResponses @((New-TestResponse -Status $status -Text ''))
                $caught = $null
                try { Invoke-CloudRequest -Api Arm -Method DELETE -Uri "subscriptions/$subscriptionA/resourceGroups/rg-x" -ApiVersion '2021-04-01' } catch { $caught = $_ }
                (Get-CloudErrorStatus -ErrorRecord $caught) | Should Be $status
                $caught.Exception.Message | Should Match '\(no body\)'
                $global:RbcRequests.Count | Should Be 1
            }
            Assert-MockCalled Start-Sleep -Exactly 0 -Scope It
        }

        It 'retries a GET that got no response' {
            Start-TestRun
            Set-TestResponses @(
                { throw 'The operation has timed out.' },
                (New-TestResponse -Json @{ id = 'ok' }))
            (Invoke-CloudRequest -Api Graph -Uri 'organization').id | Should Be 'ok'
            Assert-MockCalled Start-Sleep -Exactly 1 -Scope It
        }

        It 'does not repeat a POST that got no response' {
            Start-TestRun -DryRun $false
            Set-TestResponses @({ throw 'The operation has timed out.' }, (New-TestResponse -Status 202))
            $caught = $null
            try { Invoke-CloudRequest -Api Graph -Method POST -Uri 'users/x/sendMail' -Body @{ a = 1 } } catch { $caught = $_ }
            $caught.Exception.Message | Should Match 'failed without an HTTP response after 1 attempt\(s\): The operation has timed out'
            $caught.Exception.Message | Should Match 'POST is not repeated automatically .* may already have been applied'
            $caught.Exception.Data['MayHaveBeenApplied'] | Should Be $true
            (Get-CloudErrorStatus -ErrorRecord $caught) | Should Be 0
            $global:RbcRequests.Count | Should Be 1
            Assert-MockCalled Start-Sleep -Exactly 0 -Scope It
        }

        It 'does not repeat a POST answered with any 5xx' {
            Start-TestRun -DryRun $false
            foreach ($status in @(500, 502, 503, 504)) {
                Set-TestResponses @(
                    (New-TestResponse -Status $status -Json @{ error = @{ code = 'ServiceError'; message = 'Try later.' } }),
                    (New-TestResponse -Status 202))
                $caught = $null
                try { Invoke-CloudRequest -Api Graph -Method POST -Uri 'roleManagement/directory/roleEligibilityScheduleRequests' -Body @{ action = 'adminExtend' } } catch { $caught = $_ }
                $caught | Should Not BeNullOrEmpty
                (Get-CloudErrorStatus -ErrorRecord $caught) | Should Be $status
                $caught.Exception.Message | Should Match ('failed with HTTP {0} after 1 attempt\(s\): ServiceError: Try later\. POST is not repeated automatically' -f $status)
                $caught.Exception.Data['MayHaveBeenApplied'] | Should Be $true
                $caught.Exception.Data['Attempts'] | Should Be 1
                $global:RbcRequests.Count | Should Be 1
            }
            Assert-MockCalled Start-Sleep -Exactly 0 -Scope It
        }

        It 'does not repeat a PATCH answered 503 or left without a response' {
            Start-TestRun -DryRun $false
            Set-TestResponses @((New-TestResponse -Status 503 -Headers @{ 'Retry-After' = '1' }), (New-TestResponse -Status 200))
            $caught = $null
            try { Invoke-CloudRequest -Api Arm -Method PATCH -Uri "subscriptions/$subscriptionA/providers/Microsoft.Authorization/roleManagementPolicies/p1" -ApiVersion '2020-10-01' -Body @{ properties = @{} } } catch { $caught = $_ }
            (Get-CloudErrorStatus -ErrorRecord $caught) | Should Be 503
            $caught.Exception.Message | Should Match 'PATCH is not repeated automatically'
            $global:RbcRequests.Count | Should Be 1

            Set-TestResponses @({ throw 'The underlying connection was closed.' }, (New-TestResponse -Status 204))
            $caught = $null
            try { Invoke-CloudRequest -Api Graph -Method PATCH -Uri 'users/u1' -Body @{ accountEnabled = $false } } catch { $caught = $_ }
            (Get-CloudErrorStatus -ErrorRecord $caught) | Should Be 0
            $caught.Exception.Data['MayHaveBeenApplied'] | Should Be $true
            $global:RbcRequests.Count | Should Be 1
            Assert-MockCalled Start-Sleep -Exactly 0 -Scope It
        }

        It 'retries a POST and a PATCH answered 429, honouring Retry-After' {
            Start-TestRun -DryRun $false
            Set-TestResponses @(
                (New-TestResponse -Status 429 -Headers @{ 'Retry-After' = '7' } -Json @{ error = @{ code = 'TooManyRequests' } }),
                (New-TestResponse -Status 201 -Json @{ id = 'created' }))
            (Invoke-CloudRequest -Api Graph -Method POST -Uri 'groups' -Body @{ displayName = 'x' }).id | Should Be 'created'
            $global:RbcRequests.Count | Should Be 2
            Assert-MockCalled Start-Sleep -Exactly 1 -Scope It -ParameterFilter { $Seconds -eq 7 }

            Set-TestResponses @(
                (New-TestResponse -Status 429 -Headers @{ 'Retry-After' = '3' }),
                (New-TestResponse -Status 429),
                (New-TestResponse -Status 204))
            Invoke-CloudRequest -Api Graph -Method PATCH -Uri 'users/u1' -Body @{ accountEnabled = $false } | Out-Null
            $global:RbcRequests.Count | Should Be 3
            Assert-MockCalled Start-Sleep -Exactly 1 -Scope It -ParameterFilter { $Seconds -eq 3 }
            Assert-MockCalled Start-Sleep -Exactly 1 -Scope It -ParameterFilter { $Seconds -eq 4 }
        }

        It 'retries POST and PATCH after a 5xx or a lost response only with -RetryNonIdempotent' {
            Start-TestRun -DryRun $false
            Set-TestResponses @((New-TestResponse -Status 503), (New-TestResponse -Status 502), (New-TestResponse -Json @{ id = 'ok' }))
            (Invoke-CloudRequest -Api Graph -Method POST -Uri 'x/action' -Body @{ a = 1 } -RetryNonIdempotent).id | Should Be 'ok'
            $global:RbcRequests.Count | Should Be 3

            Set-TestResponses @({ throw 'The operation has timed out.' }, (New-TestResponse -Status 200 -Json @{ id = 'p' }))
            (Invoke-CloudRequest -Api Arm -Method PATCH -Uri 'providers/x/y' -ApiVersion '2020-10-01' -Body @{ a = 1 } -RetryNonIdempotent).id | Should Be 'p'
            $global:RbcRequests.Count | Should Be 2

            Set-TestResponses @((New-TestResponse -Status 500), (New-TestResponse -Status 500))
            $caught = $null
            try { Invoke-CloudRequest -Api Graph -Method POST -Uri 'x/action' -Body @{ a = 1 } -RetryNonIdempotent -MaxAttempts 2 } catch { $caught = $_ }
            $caught.Exception.Message | Should Match 'failed with HTTP 500 after 2 attempt\(s\)'
            $caught.Exception.Data['MayHaveBeenApplied'] | Should Be $false
            Assert-MockCalled Start-Sleep -Exactly 4 -Scope It
        }

        It 'still retries PUT, DELETE, and GET after a 5xx' {
            Start-TestRun -DryRun $false
            Set-TestResponses @((New-TestResponse -Status 503), (New-TestResponse -Status 201 -Json @{ id = 'ra' }))
            (Invoke-CloudRequest -Api Arm -Method PUT -Uri "subscriptions/$subscriptionA/providers/Microsoft.Authorization/roleAssignments/r1" -ApiVersion '2022-04-01' -Body @{ properties = @{} }).id | Should Be 'ra'
            $global:RbcRequests.Count | Should Be 2
            Set-TestResponses @((New-TestResponse -Status 500), (New-TestResponse -Status 204))
            Invoke-CloudRequest -Api Graph -Method DELETE -Uri 'groups/g/members/m/$ref' | Out-Null
            $global:RbcRequests.Count | Should Be 2
            Set-TestResponses @((New-TestResponse -Status 504), (New-TestResponse -Status 504))
            $caught = $null
            try { Invoke-CloudRequest -Api Graph -Uri 'organization' -MaxAttempts 2 } catch { $caught = $_ }
            $caught.Exception.Data['MayHaveBeenApplied'] | Should Be $false
            $caught.Exception.Message | Should Not Match 'not repeated automatically'
        }

        It 'adds no may-have-been-applied note when the caller allowed only one attempt' {
            Start-TestRun -DryRun $false
            Set-TestResponses @((New-TestResponse -Status 504 -Text '{"error":{"code":"GatewayTimeout","message":"No response in time."}}'))
            $caught = $null
            try { Invoke-CloudRequest -Api Graph -Method POST -Uri 'x/action' -Body @{ a = 1 } -MaxAttempts 1 } catch { $caught = $_ }
            $caught.Exception.Message | Should Be 'Graph POST /v1.0/x/action failed with HTTP 504 after 1 attempt(s): GatewayTimeout: No response in time.'
            $caught.Exception.Data['MayHaveBeenApplied'] | Should Be $false
        }

        It 'applies the same rules when Invoke-RunbookHttp is called directly' {
            Start-TestRun -DryRun $false
            Set-TestResponses @((New-TestResponse -Status 502), (New-TestResponse -Status 200))
            { Invoke-RunbookHttp -Api 'Graph' -Method POST -Uri 'https://graph.microsoft.com/v1.0/x' -Headers @{} -Body '{}' -ContentType 'application/json' } | Should Throw 'HTTP 502 after 1 attempt(s)'
            $global:RbcRequests.Count | Should Be 1
            Set-TestResponses @((New-TestResponse -Status 502), (New-TestResponse -Status 200))
            (Invoke-RunbookHttp -Api 'Graph' -Method POST -Uri 'https://graph.microsoft.com/v1.0/x' -Headers @{} -Body '{}' -RetryNonIdempotent).StatusCode | Should Be 200
            $global:RbcRequests.Count | Should Be 2
            (Get-TestRequest 1).ContainsKey('OutFile') | Should Be $true
            [string]::IsNullOrEmpty((Get-TestRequest 1).OutFile) | Should Be $true
        }

        It 'reads a Storage XML error body' {
            $detail = Get-ServiceErrorText -Content '<?xml version="1.0" encoding="utf-8"?><Error><Code>AuthorizationPermissionMismatch</Code><Message>This request is not authorized.</Message></Error>'
            $detail.Code | Should Be 'AuthorizationPermissionMismatch'
            $detail.Text | Should Be 'AuthorizationPermissionMismatch: This request is not authorized.'
        }

        It 'truncates a long non-JSON error body' {
            $detail = Get-ServiceErrorText -Content ('x' * 1000)
            $detail.Text.Length | Should Be 403
        }

        It 'computes retry delays' {
            Get-RetryDelaySeconds -Attempt 1 | Should Be 2
            Get-RetryDelaySeconds -Attempt 3 | Should Be 8
            Get-RetryDelaySeconds -Attempt 6 | Should Be 60
            Get-RetryDelaySeconds -Attempt 9 | Should Be 60
            Get-RetryDelaySeconds -Attempt 1 -RetryAfter '0' | Should Be 1
            Get-RetryDelaySeconds -Attempt 1 -RetryAfter ' 15 ' | Should Be 15
            $now = New-Object -TypeName DateTime -ArgumentList 2026, 9, 17, 12, 0, 0, ([DateTimeKind]::Utc)
            Get-RetryDelaySeconds -Attempt 1 -RetryAfter 'Thu, 17 Sep 2026 12:00:30 GMT' -Now $now | Should Be 30
            Get-RetryDelaySeconds -Attempt 1 -RetryAfter 'Thu, 17 Sep 2026 13:00:00 GMT' -Now $now | Should Be 60
            Get-RetryDelaySeconds -Attempt 2 -RetryAfter 'not a date' | Should Be 4
        }

        It 'reads the status from an exception or a null' {
            Get-CloudErrorStatus -ErrorRecord $null | Should Be 0
            Get-CloudErrorStatus -ErrorRecord (New-Object System.Exception 'plain') | Should Be 0
            $inner = New-CloudRequestError -Api Graph -Method GET -Uri 'https://graph.microsoft.com/v1.0/x' -StatusCode 409 -Attempts 1 -Content ''
            Get-CloudErrorStatus -ErrorRecord (New-Object System.Exception 'outer', $inner) | Should Be 409
        }
    }

    Context 'blob storage' {
        It 'puts a block blob with a bearer token and x-ms-version' {
            Start-TestRun -DryRun $false
            Set-TestResponses @((New-TestResponse -Status 201 -Headers @{ ETag = '"0x1"'; 'Last-Modified' = 'Thu, 17 Sep 2026 12:00:00 GMT' }))
            $r = Invoke-StorageRequest -Operation PutBlob -StorageAccountName 'stexampleiam' -ContainerName 'runbook-state' -BlobName 'reviews/2026 09/state.json' -Content ('{"a":"caf' + [char]0x00E9 + '"}')
            $r.ETag | Should Be '"0x1"'
            $r.StatusCode | Should Be 201
            $sent = Get-TestRequest 0
            $sent.Method | Should Be 'PUT'
            $sent.Uri | Should Be 'https://stexampleiam.blob.core.windows.net/runbook-state/reviews/2026%2009/state.json'
            $sent.Headers['x-ms-blob-type'] | Should Be 'BlockBlob'
            $sent.Headers['x-ms-version'] | Should Be '2023-11-03'
            $sent.Headers['x-ms-date'] | Should Match 'GMT$'
            $sent.Headers['Authorization'] | Should Be ('Bearer ' + $storageToken)
            $sent.ContentType | Should Be 'application/json; charset=utf-8'
            ($sent.Body -is [byte[]]) | Should Be $true
            [System.Text.Encoding]::UTF8.GetString($sent.Body) | Should Be ('{"a":"caf' + [char]0x00E9 + '"}')
        }

        It 'uses the US Government blob endpoint' {
            Start-TestRun -Environment USGov
            Set-TestResponses @((New-TestResponse -Status 200 -Text 'hello'))
            Invoke-StorageRequest -Operation GetBlob -StorageAccountName 'stexampleiam' -ContainerName 'state' -BlobName 'a.txt' | Should Be 'hello'
            (Get-TestRequest 0).Uri | Should Be 'https://stexampleiam.blob.core.usgovcloudapi.net/state/a.txt'
        }

        It 'returns null for a missing blob only when allowed' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Status 404 -Text '<Error><Code>BlobNotFound</Code><Message>The specified blob does not exist.</Message></Error>'))
            Invoke-StorageRequest -Operation GetBlob -StorageAccountName 'stexampleiam' -ContainerName 'state' -BlobName 'missing.json' -AllowNotFound | Should BeNullOrEmpty
            Set-TestResponses @((New-TestResponse -Status 404 -Text '<Error><Code>BlobNotFound</Code><Message>The specified blob does not exist.</Message></Error>'))
            { Invoke-StorageRequest -Operation GetBlob -StorageAccountName 'stexampleiam' -ContainerName 'state' -BlobName 'missing.json' } | Should Throw 'HTTP 404 after 1 attempt(s): BlobNotFound'
        }

        It 'deletes a blob and reports a missing one' {
            Start-TestRun -DryRun $false
            Set-TestResponses @((New-TestResponse -Status 202), (New-TestResponse -Status 404))
            Invoke-StorageRequest -Operation DeleteBlob -StorageAccountName 'stexampleiam' -ContainerName 'state' -BlobName 'old.json' | Should Be $true
            Invoke-StorageRequest -Operation DeleteBlob -StorageAccountName 'stexampleiam' -ContainerName 'state' -BlobName 'old.json' -AllowNotFound | Should Be $false
            (Get-TestRequest 0).Method | Should Be 'DELETE'
        }

        It 'lists blobs with a prefix across marker pages' {
            Start-TestRun
            $page1 = [string][char]0xFEFF + '<?xml version="1.0" encoding="utf-8"?><EnumerationResults ServiceEndpoint="https://stexampleiam.blob.core.windows.net/" ContainerName="state"><Prefix>reviews/</Prefix><MaxResults>2</MaxResults><Blobs><Blob><Name>reviews/a.json</Name><Properties><Last-Modified>Thu, 17 Sep 2026 12:00:00 GMT</Last-Modified><Etag>0x1</Etag><Content-Length>10</Content-Length><Content-Type>application/json</Content-Type></Properties></Blob><Blob><Name>reviews/b &amp; c.json</Name><Properties><Last-Modified>Thu, 17 Sep 2026 12:01:00 GMT</Last-Modified><Etag>0x2</Etag><Content-Length>20</Content-Length></Properties></Blob></Blobs><NextMarker>2!72!marker</NextMarker></EnumerationResults>'
            $page2 = '<?xml version="1.0" encoding="utf-8"?><EnumerationResults ContainerName="state"><Blobs><Blob><Name>reviews/d.json</Name><Properties><Content-Length>5368709120</Content-Length></Properties></Blob></Blobs><NextMarker /></EnumerationResults>'
            Set-TestResponses @((New-TestResponse -Text $page1), (New-TestResponse -Text $page2))
            $blobs = @(Invoke-StorageRequest -Operation ListBlobs -StorageAccountName 'stexampleiam' -ContainerName 'state' -Prefix 'reviews/' -MaxResults 2)
            $blobs.Count | Should Be 3
            $blobs[1].Name | Should Be 'reviews/b & c.json'
            $blobs[0].ContentLength | Should Be 10
            $blobs[2].ContentLength | Should Be 5368709120
            $blobs[0].LastModified.ToString('yyyy-MM-ddTHH:mm:ss') | Should Be '2026-09-17T12:00:00'
            $blobs[0].ContentType | Should Be 'application/json'
            (Get-TestRequest 0).Uri | Should Be 'https://stexampleiam.blob.core.windows.net/state?restype=container&comp=list&maxresults=2&prefix=reviews%2F'
            # .NET Framework leaves "!" unescaped and .NET escapes it; both are valid in a query.
            (Get-TestRequest 1).Uri | Should Be ('https://stexampleiam.blob.core.windows.net/state?restype=container&comp=list&maxresults=2&prefix=reviews%2F&marker=' + [Uri]::EscapeDataString('2!72!marker'))
        }

        It 'returns nothing for an empty container' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Text '<?xml version="1.0" encoding="utf-8"?><EnumerationResults><Blobs /><NextMarker /></EnumerationResults>'))
            @(Invoke-StorageRequest -Operation ListBlobs -StorageAccountName 'stexampleiam' -ContainerName 'state').Count | Should Be 0
        }

        It 'retries storage throttling' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Status 503 -Headers @{ 'Retry-After' = '3' }), (New-TestResponse -Text 'ok'))
            Invoke-StorageRequest -Operation GetBlob -StorageAccountName 'stexampleiam' -ContainerName 'state' -BlobName 'a' | Should Be 'ok'
            Assert-MockCalled Start-Sleep -Exactly 1 -Scope It -ParameterFilter { $Seconds -eq 3 }
        }

        It 'validates names and requires a blob name' {
            Start-TestRun
            { Invoke-StorageRequest -Operation GetBlob -StorageAccountName 'Bad_Name' -ContainerName 'state' -BlobName 'a' } | Should Throw
            { Invoke-StorageRequest -Operation GetBlob -StorageAccountName 'stexampleiam' -ContainerName 'Bad--Name' -BlobName 'a' } | Should Throw
            { Invoke-StorageRequest -Operation PutBlob -StorageAccountName 'stexampleiam' -ContainerName 'state' } | Should Throw 'needs -BlobName'
            { Invoke-StorageRequest -Operation GetBlobToFile -StorageAccountName 'stexampleiam' -ContainerName 'state' -BlobName '  ' -OutFile (Join-Path -Path $TestDrive -ChildPath 'x.bin') } | Should Throw 'needs -BlobName'
        }

        It 'refuses an unsafe blob name for every operation before a token or a request' {
            # No supplied token, no identity endpoint, no Az.Accounts: reaching
            # token acquisition would fail with "No credential source" instead.
            Start-TestRun -AccessToken $null
            Set-TestResponses @()
            $target = Join-Path -Path $TestDrive -ChildPath 'refused.bin'
            $cases = @(
                @{ Name = '/leading'; Reason = 'empty path segment' },
                @{ Name = 'trailing/'; Reason = 'empty path segment' },
                @{ Name = 'double//slash'; Reason = 'empty path segment' },
                @{ Name = '.'; Reason = '"." or ".." path segment' },
                @{ Name = '..'; Reason = '"." or ".." path segment' },
                @{ Name = './a.json'; Reason = '"." or ".." path segment' },
                @{ Name = 'reviews/../secrets.json'; Reason = '"." or ".." path segment' },
                @{ Name = 'reviews/2026./state.json'; Reason = 'a path segment ends with a dot' },
                @{ Name = 'report.'; Reason = 'a path segment ends with a dot' },
                @{ Name = 'reviews\state.json'; Reason = 'backslash' },
                @{ Name = ('tab' + [char]9 + 'name'); Reason = 'control character' },
                @{ Name = ('c1' + [char]0x0085 + 'name'); Reason = 'control character' },
                @{ Name = ('x' * 1025); Reason = 'longer than 1024 characters' },
                @{ Name = ((@('s') * 255) -join '/'); Reason = 'more than 254 path segments' }
            )
            foreach ($case in $cases) {
                foreach ($operation in @('PutBlob', 'GetBlob', 'GetBlobToFile', 'DeleteBlob')) {
                    $request = @{ Operation = $operation; StorageAccountName = 'stexampleiam'; ContainerName = 'state'; BlobName = $case.Name; Content = 'x' }
                    if ($operation -eq 'GetBlobToFile') { $request.OutFile = $target; $request.Remove('Content') }
                    $message = ''
                    try { Invoke-StorageRequest @request | Out-Null } catch { $message = $_.Exception.Message }
                    $message.StartsWith('Refusing blob name "') | Should Be $true
                    $message.Contains($case.Reason) | Should Be $true
                    $message.Contains([string][char]9) | Should Be $false
                }
            }
            Assert-MockCalled Invoke-HttpCore -Exactly 0 -Scope It
            (Test-Path -LiteralPath $target) | Should Be $false
        }

        It 'accepts unusual but valid blob names and addresses exactly that blob' {
            Start-TestRun
            $names = @(
                'a b/c#d?e.json',
                ('caf' + [char]0x00E9 + '/100%.txt'),
                "x+y&z=1;(2)!~'*.json",
                '.hidden/v1.0/file.json',
                'reviews/..data/state.json',
                'a/%2E%2E/b',
                ' leading space/x'
            )
            foreach ($name in $names) {
                Set-TestResponses @((New-TestResponse -Text 'ok'))
                Invoke-StorageRequest -Operation GetBlob -StorageAccountName 'stexampleiam' -ContainerName 'state' -BlobName $name | Should Be 'ok'
                $sent = [Uri](Get-TestRequest 0).Uri
                $sent.Host | Should Be 'stexampleiam.blob.core.windows.net'
                [Uri]::UnescapeDataString($sent.AbsolutePath) | Should Be ('/state/' + $name)
                $sent.Query | Should Be ''
            }
        }

        It 'refuses a built URI that would reach a different blob' {
            { Assert-StorageRequestUri -Uri 'https://stexampleiam.blob.core.windows.net/state/a/../b' -ContainerName 'state' -BlobName 'a/../b' } | Should Throw 'Refusing a storage request'
            { Assert-StorageRequestUri -Uri 'https://stexampleiam.blob.core.windows.net/state/a%3Fb' -ContainerName 'state' -BlobName 'a?b' } | Should Not Throw
            { Assert-StorageRequestUri -Uri 'https://stexampleiam.blob.core.windows.net/other/a' -ContainerName 'state' -BlobName 'a' } | Should Throw 'Refusing a storage request'
            { Assert-StorageRequestUri -Uri 'not a uri' -ContainerName 'state' -BlobName 'a' } | Should Throw 'Refusing a storage request'
            if ($PSVersionTable.PSEdition -ne 'Core') {
                # .NET Framework drops a segment's trailing dots when it parses a URI.
                { Assert-StorageRequestUri -Uri 'https://stexampleiam.blob.core.windows.net/state/a./b' -ContainerName 'state' -BlobName 'a./b' } | Should Throw 'Refusing a storage request'
            }
        }

        It 'downloads a blob to a file through the one HTTP seam, bytes intact' {
            Start-TestRun -Environment USGov
            $payload = [byte[]](0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF, 0xFE, 0x0A, 0x0D, 0xC3)
            $global:RbcPayload = $payload
            $target = Join-Path -Path $TestDrive -ChildPath 'downloads\new-folder\package.zip'
            Set-TestResponses @({
                    param($path)
                    [System.IO.File]::WriteAllBytes($path, $global:RbcPayload)
                    return @{ StatusCode = 200; Content = ''; Headers = @{ 'Content-MD5' = 'q1w2e3r4t5y6u7i8o9p0aa=='; ETag = '"0x8D0"'; 'Last-Modified' = 'Thu, 17 Sep 2026 02:30:00 GMT' } }
                })
            $result = Invoke-StorageRequest -Operation GetBlobToFile -StorageAccountName 'stexampleiam' -ContainerName 'runbook-backups' -BlobName 'automation/aa-example/20260917-023000Z.zip' -OutFile $target
            $result.Name | Should Be 'automation/aa-example/20260917-023000Z.zip'
            $result.Path | Should Be $target
            $result.Length | Should Be 10
            $result.ContentMd5 | Should Be 'q1w2e3r4t5y6u7i8o9p0aa=='
            $result.ETag | Should Be '"0x8D0"'
            $result.LastModified | Should Be 'Thu, 17 Sep 2026 02:30:00 GMT'
            $result.StatusCode | Should Be 200
            ([System.IO.File]::ReadAllBytes($target) -join ',') | Should Be ($payload -join ',')
            $sent = Get-TestRequest 0
            $sent.Method | Should Be 'GET'
            $sent.Uri | Should Be 'https://stexampleiam.blob.core.usgovcloudapi.net/runbook-backups/automation/aa-example/20260917-023000Z.zip'
            $sent.OutFile | Should Be $target
            $sent.Body | Should BeNullOrEmpty
            $sent.Headers['Authorization'] | Should Be ('Bearer ' + $storageToken)
            $sent.Headers['x-ms-version'] | Should Be '2023-11-03'
            $sent.Headers['x-ms-date'] | Should Match 'GMT$'
        }

        It 'returns null for a missing blob with -AllowNotFound and leaves no file' {
            Start-TestRun
            $target = Join-Path -Path $TestDrive -ChildPath 'missing.zip'
            [System.IO.File]::WriteAllText($target, 'stale content from an earlier run')
            $notFound = '<?xml version="1.0" encoding="utf-8"?><Error><Code>BlobNotFound</Code><Message>The specified blob does not exist.</Message></Error>'
            Set-TestResponses @((New-TestResponse -Status 404 -Text $notFound))
            $result = Invoke-StorageRequest -Operation GetBlobToFile -StorageAccountName 'stexampleiam' -ContainerName 'state' -BlobName 'gone.zip' -OutFile $target -AllowNotFound
            $result | Should BeNullOrEmpty
            (Test-Path -LiteralPath $target) | Should Be $false

            Set-TestResponses @((New-TestResponse -Status 404 -Text $notFound))
            $caught = $null
            try { Invoke-StorageRequest -Operation GetBlobToFile -StorageAccountName 'stexampleiam' -ContainerName 'state' -BlobName 'gone.zip' -OutFile $target } catch { $caught = $_ }
            (Get-CloudErrorStatus -ErrorRecord $caught) | Should Be 404
            $caught.Exception.Message | Should Match 'Storage GET /state/gone\.zip failed with HTTP 404 after 1 attempt\(s\): BlobNotFound'
        }

        It 'retries a throttled download and refuses a success that wrote no file' {
            Start-TestRun
            $target = Join-Path -Path $TestDrive -ChildPath 'retry.bin'
            Set-TestResponses @(
                (New-TestResponse -Status 503 -Headers @{ 'Retry-After' = '2' }),
                { param($path) [System.IO.File]::WriteAllBytes($path, [byte[]](1, 2, 3)); return @{ StatusCode = 200; Content = ''; Headers = @{} } })
            $result = Invoke-StorageRequest -Operation GetBlobToFile -StorageAccountName 'stexampleiam' -ContainerName 'state' -BlobName 'retry.bin' -OutFile $target
            $result.Length | Should Be 3
            $result.ContentMd5 | Should Be ''
            $global:RbcRequests.Count | Should Be 2
            (Get-TestRequest 1).OutFile | Should Be $target
            Assert-MockCalled Start-Sleep -Exactly 1 -Scope It -ParameterFilter { $Seconds -eq 2 }

            Remove-Item -LiteralPath $target
            Set-TestResponses @((New-TestResponse -Status 200))
            { Invoke-StorageRequest -Operation GetBlobToFile -StorageAccountName 'stexampleiam' -ContainerName 'state' -BlobName 'retry.bin' -OutFile $target } | Should Throw 'returned HTTP 200 but wrote no file'
        }

        It 'checks OutFile before any request' {
            Start-TestRun
            Set-TestResponses @()
            $base = @{ Operation = 'GetBlobToFile'; StorageAccountName = 'stexampleiam'; ContainerName = 'state'; BlobName = 'a.zip' }
            { Invoke-StorageRequest @base } | Should Throw 'needs -OutFile'
            { Invoke-StorageRequest @base -OutFile 'relative\a.zip' } | Should Throw 'is not a full path'
            { Invoke-StorageRequest @base -OutFile (Join-Path -Path $TestDrive -ChildPath 'a*.zip') } | Should Throw 'wildcard character'
            { Invoke-StorageRequest @base -OutFile (Join-Path -Path $TestDrive -ChildPath 'a[1].zip') } | Should Throw 'wildcard character'
            { Invoke-StorageRequest @base -OutFile ([string]$TestDrive) } | Should Throw 'is a folder'
            { Invoke-StorageRequest -Operation GetBlob -StorageAccountName 'stexampleiam' -ContainerName 'state' -BlobName 'a.zip' -OutFile (Join-Path -Path $TestDrive -ChildPath 'a.zip') } | Should Throw 'only valid with -Operation GetBlobToFile'
            Assert-MockCalled Invoke-HttpCore -Exactly 0 -Scope It
        }
    }

    Context 'Write-RunLog' {
        It 'writes Info and Action to the verbose stream with timestamp, level, and run id' {
            Start-TestRun
            $lines = & { $VerbosePreference = 'Continue'; Write-RunLog -Level Action -Message 'Would remove x.' } 4>&1
            $line = [string]@($lines)[0]
            $line | Should Match ('^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \[ACTION\] run=' + $runId + ' Would remove x\.$')
        }

        It 'writes nothing to the output stream' {
            Start-TestRun
            $out = Write-RunLog -Level Info -Message 'quiet'
            $out | Should BeNullOrEmpty
        }

        It 'writes Warn to the warning stream and counts it' {
            Start-TestRun
            $warnings = & { $WarningPreference = 'Continue'; Write-RunLog -Level Warn -Message 'careful' } 3>&1
            [string]@($warnings)[0] | Should Match '\[WARN\] run=.* careful$'
            Get-RunLogCount -Level Warn | Should Be 1
        }

        It 'writes Error to the error stream without stopping a Stop run' {
            Start-TestRun
            $records = & { $ErrorActionPreference = 'Stop'; Write-RunLog -Level Error -Message 'broken'; 'still running' } 2>&1
            $text = ($records | ForEach-Object { [string]$_ }) -join "`n"
            $text | Should Match '\[ERROR\] run=.* broken'
            $text | Should Match 'still running'
            Get-RunLogCount -Level Error | Should Be 1
            @(Get-RunLogEntries -Level Error)[0].Message | Should Be 'broken'
        }

        It 'starts each run with a fresh log and the given run id' {
            Start-TestRun
            Write-RunLog -Level Warn -Message 'one'
            Start-TestRun
            Get-RunLogCount -Level Warn | Should Be 0
            @(Get-RunLogEntries)[0].RunId | Should Be $runId
            @(Get-RunLogEntries)[0].Message | Should Match '^Starting Runbook.Common.Tests\. DryRun=True Environment=Global'
        }

        It 'generates a run id when none is given' {
            Initialize-RunContext -RunbookName 'x' -AccessToken $graphToken
            (Get-RunContext).RunId | Should Match '^[0-9a-f]{8}-[0-9a-f]{4}-'
        }
    }

    Context 'ConvertTo-StringList' {
        It 'parses a JSON array' {
            $r = @(ConvertTo-StringList -Value '["Group A", " Group B "]')
            $r.Count | Should Be 2
            $r[1] | Should Be 'Group B'
        }

        It 'keeps a single-element JSON array as one string' {
            $r = @(ConvertTo-StringList -Value '["only one"]')
            $r.Count | Should Be 1
            $r[0] | Should Be 'only one'
            ($r[0] -is [string]) | Should Be $true
        }

        It 'keeps a single plain value as one string' {
            $r = @(ConvertTo-StringList -Value 'iam@corp.example.com')
            $r.Count | Should Be 1
            $r[0] | Should Be 'iam@corp.example.com'
        }

        It 'splits on commas and semicolons, trims, and drops blanks' {
            $r = @(ConvertTo-StringList -Value ' a ; b,, c;')
            ($r -join '|') | Should Be 'a|b|c'
        }

        It 'returns nothing for null, empty, blank, and an empty JSON array' {
            @(ConvertTo-StringList -Value $null).Count | Should Be 0
            @(ConvertTo-StringList -Value '').Count | Should Be 0
            @(ConvertTo-StringList -Value '  ').Count | Should Be 0
            @(ConvertTo-StringList -Value ' ; , ').Count | Should Be 0
            @(ConvertTo-StringList -Value '[]').Count | Should Be 0
        }

        It 'rejects malformed JSON and names the parameter' {
            { ConvertTo-StringList -Value '["a", "b"' -Label 'GroupNames' } | Should Throw 'GroupNames looks like a JSON array but does not parse'
        }

        It 'rejects objects and nested arrays inside the JSON array' {
            { ConvertTo-StringList -Value '[{"a":1}]' -Label 'Scopes' } | Should Throw 'Scopes must be a JSON array of strings'
            { ConvertTo-StringList -Value '[["a"]]' } | Should Throw 'must be a JSON array of strings'
        }

        It 'rejects a hashtable with a clear message instead of recursing' {
            { ConvertTo-StringList -Value @{ a = 1 } -Label 'Owners' } | Should Throw 'Owners must be a string or a string array'
        }

        It 'converts JSON numbers and skips JSON nulls' {
            $r = @(ConvertTo-StringList -Value '[1, null, "x"]')
            ($r -join '|') | Should Be '1|x'
        }

        It 'unwraps a quoted JSON string' {
            ($(ConvertTo-StringList -Value '"a; b"') -join '|') | Should Be 'a|b'
        }

        It 'accepts a string array from a local call' {
            $r = @(ConvertTo-StringList -Value @('a;b', '["c"]', ''))
            ($r -join '|') | Should Be 'a|b|c'
        }

        It 'keeps commas inside JSON array elements' {
            $r = @(ConvertTo-StringList -Value '["Doe, Jane", "Roe; Rick"]')
            $r.Count | Should Be 2
            $r[0] | Should Be 'Doe, Jane'
        }

        It 'treats the semicolon form and the JSON array form alike' {
            $semicolon = @(ConvertTo-StringList -Value 'Identity Production;Shared Services;Sandbox' -Label 'AzureScopeNames')
            $json = @(ConvertTo-StringList -Value '["Identity Production","Shared Services","Sandbox"]' -Label 'AzureScopeNames')
            ($semicolon -join '|') | Should Be 'Identity Production|Shared Services|Sandbox'
            ($json -join '|') | Should Be ($semicolon -join '|')
        }

        It 'keeps a timestamp-shaped JSON element as the text that was given' {
            $canKeepText = ($PSVersionTable.PSVersion.Major -lt 6) -or (Get-Command -Name ConvertFrom-Json -CommandType Cmdlet).Parameters.ContainsKey('DateKind')
            if ($canKeepText) {
                (@(ConvertTo-StringList -Value '["2026-09-17T00:00:00Z", "x"]') -join '|') | Should Be '2026-09-17T00:00:00Z|x'
            }
        }

        It 'documents the semicolon form for schedules and the JSON form for local runs' {
            $help = (Get-Command -Name ConvertTo-StringList).ScriptBlock.Ast.GetHelpContent()
            $help.Description | Should Match 'semicolon form'
            $help.Description | Should Match 'Do not put a JSON array in a schedule parameter'
            $help.Description | Should Match 'still accepted for local runs'
        }
    }

    Context 'JSON shape on both editions' {
        It 'recognises only a parsed JSON object as an object' {
            $object = ConvertFrom-RunbookJsonText -Json '{"id":"a"}'
            $array = ConvertFrom-RunbookJsonText -Json '[{"id":"a"},{"id":"b"}]'
            $raw = ConvertFrom-Json -InputObject '[1,2]'
            Test-RunbookJsonObject -Value $object | Should Be $true
            Test-RunbookJsonObject -Value ([PSCustomObject]@{ id = 'b' }) | Should Be $true
            Test-RunbookJsonObject -Value $array | Should Be $false
            Test-RunbookJsonObject -Value $raw | Should Be $false
            Test-RunbookJsonObject -Value ([psobject]'text') | Should Be $false
            Test-RunbookJsonObject -Value @{ id = 'c' } | Should Be $false
            Test-RunbookJsonObject -Value $null | Should Be $false
            Test-RunbookJsonObject -Value 42 | Should Be $false
        }

        It 'shows why the accelerator is not used: a wrapped array passes it' {
            $wrapped = [psobject](ConvertFrom-RunbookJsonText -Json '[1,2]')
            ($wrapped -is [PSCustomObject]) | Should Be $true
            Test-RunbookJsonObject -Value $wrapped | Should Be $false
            Get-NextPageLink -Page $wrapped | Should BeNullOrEmpty
        }

        It 'returns a JSON array as one value, with one element, nested, or empty' {
            $one = ConvertFrom-RunbookJsonText -Json '["only"]'
            ($one -is [array]) | Should Be $true
            @($one).Count | Should Be 1
            $nested = ConvertFrom-RunbookJsonText -Json '[["a","b"]]'
            @($nested).Count | Should Be 1
            @(@($nested)[0]).Count | Should Be 2
            $empty = ConvertFrom-RunbookJsonText -Json '[]'
            @($empty).Count | Should Be 0
            (ConvertFrom-RunbookJsonText -Json '{"a":1}').a | Should Be 1
            { ConvertFrom-RunbookJsonText -Json '[1,' } | Should Throw
        }

        It 'does not mistake a parsed JSON array for a page object' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Text '[{"id":"a"},{"id":"b"}]'))
            $items = @(Invoke-CloudRequest -Api Graph -Uri 'x' -AllPages)
            ($items | ForEach-Object { $_.id }) -join ',' | Should Be 'a,b'
            $global:RbcRequests.Count | Should Be 1
        }

        It 'never tests for an object with the [PSCustomObject] accelerator' {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput([System.IO.File]::ReadAllText($library), [ref]$tokens, [ref]$errors)
            $typeTests = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
                        @('Is', 'IsNot', 'As') -contains [string]$node.Operator -and
                        $node.Right -is [System.Management.Automation.Language.TypeExpressionAst] -and
                        @('PSCustomObject', 'psobject', 'System.Management.Automation.PSObject') -contains $node.Right.TypeName.FullName
                    }, $true))
            (@($typeTests | ForEach-Object { $_.Extent.Text }) -join ' | ') | Should Be ''
            $exact = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
                        $node.Right -is [System.Management.Automation.Language.TypeExpressionAst] -and
                        $node.Right.TypeName.FullName -eq 'System.Management.Automation.PSCustomObject'
                    }, $true))
            $exact.Count | Should Be 1
        }
    }

    Context 'JSON array elements wrapped in PSObject' {
        # PowerShell 7 writes ConvertFrom-Json output through the pipeline, so
        # an element can arrive wrapped in a PSObject. Simulated here on any
        # edition. Pester 3.4 keeps an It-level mock for the whole Context,
        # which is why this test has a Context of its own.
        It 'still reads wrapped string elements as strings' {
            $global:RbcWrapped = @([psobject]'Group A', [psobject]'Group B')
            (@($global:RbcWrapped)[0] -is [PSCustomObject]) | Should Be $true
            Mock ConvertFrom-RunbookJsonText { return , $global:RbcWrapped }
            $r = @(ConvertTo-StringList -Value '["Group A","Group B"]' -Label 'GroupNames')
            ($r -join '|') | Should Be 'Group A|Group B'
            Assert-MockCalled ConvertFrom-RunbookJsonText -Exactly 1 -Scope It
        }
    }

    Context 'Automation string variables' {
        function Remove-TestAutomationVariableCommand {
            $guard = 0
            while ($guard -lt 5 -and (Get-Command -Name Get-AutomationVariable -CommandType Function -ErrorAction SilentlyContinue)) {
                Remove-Item -Path Function:\Get-AutomationVariable -ErrorAction SilentlyContinue
                $guard++
            }
            $global:RbcVariableValue = $null
            $global:RbcVariableCalls = New-Object System.Collections.ArrayList
        }

        function Set-TestAutomationVariableCommand {
            param([object]$Value, [switch]$Throw)
            Remove-TestAutomationVariableCommand
            $global:RbcVariableValue = $Value
            $global:RbcVariableThrow = [bool]$Throw
            # A stand-in for the sandbox's internal cmdlet.
            function global:Get-AutomationVariable {
                [CmdletBinding()]
                param([Parameter(Mandatory = $true)][string]$Name)
                [void]$global:RbcVariableCalls.Add($Name)
                if ($global:RbcVariableThrow) { throw ('Variable asset not found: ' + $Name) }
                return $global:RbcVariableValue
            }
        }

        It 'fails clearly outside the Automation sandbox' {
            Remove-TestAutomationVariableCommand
            $script:RunbookAutomationVariables = $null
            (Get-Command -Name Get-AutomationVariable -ErrorAction SilentlyContinue) | Should BeNullOrEmpty
            $message = ''
            try { Get-AutomationStringVariable -Name 'PimBaseline' } catch { $message = $_.Exception.Message }
            $message | Should Match '^Automation variable "PimBaseline" can only be read inside Azure Automation, where Get-AutomationVariable exists\.'
            $message.Contains("-LocalValues @{ 'PimBaseline' = '<value>' }") | Should Be $true
        }

        It 'reads -LocalValues, matching the name without regard to case' {
            Remove-TestAutomationVariableCommand
            $json = "{`n  ""pairs"": [ { ""scope"": ""Platform"" } ]`n}"
            Get-AutomationStringVariable -Name 'pimbaseline' -LocalValues @{ PimBaseline = $json } | Should BeExactly $json
            { Get-AutomationStringVariable -Name 'Other' -LocalValues @{ PimBaseline = $json } } | Should Throw 'Automation variable "Other" is not in the -LocalValues table.'
        }

        It 'reads the script-scope test hook, and -LocalValues wins over it' {
            Remove-TestAutomationVariableCommand
            try {
                $script:RunbookAutomationVariables = @{ Baseline = 'from the hook' }
                Start-TestRun
                Get-AutomationStringVariable -Name 'Baseline' | Should Be 'from the hook'
                Get-AutomationStringVariable -Name 'Baseline' -LocalValues @{ Baseline = 'from the caller' } | Should Be 'from the caller'
                { Get-AutomationStringVariable -Name 'Missing' } | Should Throw 'is not in the local variable table'
                $script:RunbookAutomationVariables = 'not a table'
                { Get-AutomationStringVariable -Name 'Baseline' } | Should Throw 'must be a hashtable'
            }
            finally { $script:RunbookAutomationVariables = $null }
        }

        It 'prefers the test hook over the sandbox cmdlet' {
            try {
                Set-TestAutomationVariableCommand -Value 'from the sandbox'
                $script:RunbookAutomationVariables = @{ Baseline = 'from the hook' }
                Get-AutomationStringVariable -Name 'Baseline' | Should Be 'from the hook'
                $global:RbcVariableCalls.Count | Should Be 0
            }
            finally {
                $script:RunbookAutomationVariables = $null
                Remove-TestAutomationVariableCommand
            }
        }

        It 'reads Get-AutomationVariable in the sandbox and returns the text unchanged, unlogged' {
            try {
                $stored = '["Identity Production", "Shared"]'
                Set-TestAutomationVariableCommand -Value $stored
                Start-TestRun
                Get-AutomationStringVariable -Name 'RenewalScopes' | Should BeExactly $stored
                ($global:RbcVariableCalls -join ',') | Should Be 'RenewalScopes'
                $logText = (@(Get-RunLogEntries) | ForEach-Object { $_.Message }) -join "`n"
                $logText.Contains('Identity Production') | Should Be $false
            }
            finally { Remove-TestAutomationVariableCommand }
        }

        It 'refuses a missing, unreadable, empty, or non-string variable' {
            try {
                Set-TestAutomationVariableCommand -Value $null
                { Get-AutomationStringVariable -Name 'Baseline' } | Should Throw 'Automation variable "Baseline" has no value.'
                Set-TestAutomationVariableCommand -Throw
                { Get-AutomationStringVariable -Name 'Baseline' } | Should Throw 'Automation variable "Baseline" could not be read: Variable asset not found: Baseline'
                Set-TestAutomationVariableCommand -Value '   '
                { Get-AutomationStringVariable -Name 'Baseline' } | Should Throw 'Automation variable "Baseline" is empty.'
                Get-AutomationStringVariable -Name 'Baseline' -AllowEmpty | Should BeExactly ''
                Set-TestAutomationVariableCommand -Value 42
                { Get-AutomationStringVariable -Name 'Baseline' } | Should Throw 'holds a Int32, not a string'
                Set-TestAutomationVariableCommand -Value ([PSCustomObject]@{ a = 1 })
                { Get-AutomationStringVariable -Name 'Baseline' } | Should Throw 'not a string'
            }
            finally { Remove-TestAutomationVariableCommand }
        }

        It 'registers an encrypted value for scrubbing with -Sensitive' {
            Start-TestRun
            $secret = 'sensitive-variable-value-0000'
            Get-AutomationStringVariable -Name 'Webhook' -LocalValues @{ Webhook = $secret } -Sensitive | Should Be $secret
            (Protect-RunbookText -Text ('echo ' + $secret)) | Should Be 'echo [redacted]'
        }

        It 'rejects a name Azure Automation would not accept, before reading' {
            try {
                Set-TestAutomationVariableCommand -Value 'x'
                foreach ($bad in @('', 'a/b', 'a.b', 'a:b', 'a+b', 'a%b', 'a\b', 'trailing ', ('v' * 129), ('a' + [char]10 + 'b'))) {
                    { Get-AutomationStringVariable -Name $bad } | Should Throw 'is not a valid Automation variable name'
                }
                $global:RbcVariableCalls.Count | Should Be 0
                Get-AutomationStringVariable -Name ('v' * 128) | Should Be 'x'
                Get-AutomationStringVariable -Name 'Pim Baseline-2026_v1' | Should Be 'x'
            }
            finally { Remove-TestAutomationVariableCommand }
        }

        It 'documents why structured configuration travels in a variable' {
            $help = (Get-Command -Name Get-AutomationStringVariable).ScriptBlock.Ast.GetHelpContent()
            $help.Description | Should Match 'only \[bool\],\s+\[int\], and \[string\] survive'
            $help.Description | Should Match 'may parse a value before it is bound'
            $help.Description | Should Match 'returned exactly as it was stored'
        }
    }

    Context 'HTML and mail' {
        It 'encodes HTML' {
            ConvertTo-HtmlSafe -Value 'R&D <admins> "x" it''s' | Should Be 'R&amp;D &lt;admins&gt; &quot;x&quot; it&#39;s'
            ConvertTo-HtmlSafe -Value $null | Should Be ''
        }

        It 'sends through users/{sender}/sendMail with the documented body' {
            Start-TestRun -DryRun $false
            Set-TestResponses @((New-TestResponse -Status 202))
            Send-RunbookMail -SenderMailbox 'iam-noreply@corp.example.com' -To @('a@corp.example.com; b@corp.example.com') -Cc 'c@corp.example.com' -Subject 'Weekly' -HtmlBody '<p>hi</p>'
            $sent = Get-TestRequest 0
            $sent.Method | Should Be 'POST'
            $sent.Uri | Should Be 'https://graph.microsoft.com/v1.0/users/iam-noreply%40corp.example.com/sendMail'
            $body = ConvertFrom-Json -InputObject ([string]$sent.Body)
            $body.saveToSentItems | Should Be $false
            $body.message.subject | Should Be 'Weekly'
            $body.message.body.contentType | Should Be 'HTML'
            $body.message.body.content | Should Be '<p>hi</p>'
            @($body.message.toRecipients).Count | Should Be 2
            @($body.message.toRecipients)[1].emailAddress.address | Should Be 'b@corp.example.com'
            @($body.message.ccRecipients).Count | Should Be 1
        }

        It 'sends a single recipient as a JSON array' {
            Start-TestRun -DryRun $false
            Set-TestResponses @((New-TestResponse -Status 202))
            Send-RunbookMail -SenderMailbox 'iam-noreply@corp.example.com' -To 'a@corp.example.com' -Subject 's' -HtmlBody 'b'
            [string](Get-TestRequest 0).Body | Should Match '"toRecipients":\[\{'
            [string](Get-TestRequest 0).Body | Should Not Match 'ccRecipients'
        }

        It 'sends a mail once when Graph answers 5xx or does not answer' {
            Start-TestRun -DryRun $false
            $failures = @(
                (New-TestResponse -Status 500 -Text '{"error":{"code":"InternalServerError"}}'),
                (New-TestResponse -Status 503 -Headers @{ 'Retry-After' = '2' }),
                (New-TestResponse -Status 504),
                { throw 'The operation has timed out.' })
            foreach ($failure in $failures) {
                Set-TestResponses @($failure, (New-TestResponse -Status 202), (New-TestResponse -Status 202))
                $caught = $null
                try { Send-RunbookMail -SenderMailbox 'iam-noreply@corp.example.com' -To 'a@corp.example.com' -Subject 'Digest' -HtmlBody '<p>x</p>' } catch { $caught = $_ }
                $caught | Should Not BeNullOrEmpty
                $caught.Exception.Data['MayHaveBeenApplied'] | Should Be $true
                $global:RbcRequests.Count | Should Be 1
                (Get-TestRequest 0).Uri | Should Be 'https://graph.microsoft.com/v1.0/users/iam-noreply%40corp.example.com/sendMail'
            }
            Assert-MockCalled Start-Sleep -Exactly 0 -Scope It
        }

        It 'retries a throttled mail, because Graph did not accept it' {
            Start-TestRun -DryRun $false
            Set-TestResponses @(
                (New-TestResponse -Status 429 -Headers @{ 'Retry-After' = '5' } -Json @{ error = @{ code = 'ApplicationThrottled' } }),
                (New-TestResponse -Status 202))
            Send-RunbookMail -SenderMailbox 'iam-noreply@corp.example.com' -To 'a@corp.example.com' -Subject 'Digest' -HtmlBody '<p>x</p>'
            $global:RbcRequests.Count | Should Be 2
            Assert-MockCalled Start-Sleep -Exactly 1 -Scope It -ParameterFilter { $Seconds -eq 5 }
        }

        It 'never opts sendMail into non-idempotent retries' {
            $ast = (Get-Command -Name Send-RunbookMail).ScriptBlock.Ast
            $calls = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-CloudRequest' }, $true))
            $calls.Count | Should Be 1
            $names = @($calls[0].CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
            ($names -join ',') | Should Be 'Api,Method,Uri,Body'
            $splats = @($calls[0].CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted })
            $splats.Count | Should Be 0
        }

        It 'refuses an address that is not an address, before sending' {
            Start-TestRun -DryRun $false
            Set-TestResponses @()
            { Send-RunbookMail -SenderMailbox 'iam-noreply@corp.example.com' -To 'a@corp.example.com; not-an-address' -Subject 's' -HtmlBody 'b' } | Should Throw 'not-an-address'
            { Send-RunbookMail -SenderMailbox 'iam-noreply@corp.example.com' -To ' ; ' -Subject 's' -HtmlBody 'b' } | Should Throw 'at least one To address'
            Assert-MockCalled Invoke-HttpCore -Exactly 0 -Scope It
        }
    }

    Context 'circuit breaker' {
        It 'passes at the cap' {
            { Test-CircuitBreaker -Planned 25 -Cap 25 -Label 'guest disables' } | Should Not Throw
            { Test-CircuitBreaker -Planned 0 -Cap 0 -Label 'guest disables' } | Should Not Throw
        }

        It 'trips one over the cap and says nothing was changed' {
            { Test-CircuitBreaker -Planned 26 -Cap 25 -Label 'guest disables' } | Should Throw 'Circuit breaker tripped: guest disables: 26 planned, cap is 25. Nothing was changed.'
        }

        It 'trips a zero cap on the first planned action' {
            { Test-CircuitBreaker -Planned 1 -Cap 0 -Label 'deletions' } | Should Throw 'Circuit breaker tripped'
        }

        It 'rejects a negative cap' {
            { Test-CircuitBreaker -Planned 0 -Cap -1 -Label 'x' } | Should Throw
        }
    }

    Context 'directory lookups' {
        It 'resolves a group by exact display name, escaping quotes, and caches it' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json @{ value = @(@{ id = $groupId; displayName = "O'Brien Admins" }) }))
            Resolve-GroupIdByName -DisplayName "O'Brien Admins" | Should Be $groupId
            Resolve-GroupIdByName -DisplayName "o'brien admins" | Should Be $groupId
            $global:RbcRequests.Count | Should Be 1
            $uri = (Get-TestRequest 0).Uri
            $uri | Should Match '^https://graph\.microsoft\.com/v1\.0/groups\?\$filter='
            [Uri]::UnescapeDataString($uri) | Should Match "displayName eq 'O''Brien Admins'&\`$select=id,displayName$"
        }

        It 'throws when no group has the name' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Text '{"value":[]}'))
            { Resolve-GroupIdByName -DisplayName 'Missing Group' } | Should Throw 'Group "Missing Group" was not found'
        }

        It 'throws when the name is not unique' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json @{ value = @(@{ id = '55555555-5555-5555-5555-555555555555' }, @{ id = '66666666-6666-6666-6666-666666666666' }) }))
            { Resolve-GroupIdByName -DisplayName 'Twins' } | Should Throw 'is not unique: 2 groups'
        }

        It 'resolves a guest user principal name with #EXT#' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json @{ value = @(@{ id = '77777777-7777-7777-7777-777777777777'; userPrincipalName = 'guest_partner.example.net#EXT#@corp.example.com' }) }))
            Resolve-UserIdByUpn -UserPrincipalName 'guest_partner.example.net#EXT#@corp.example.com' | Should Be '77777777-7777-7777-7777-777777777777'
            (Get-TestRequest 0).Uri | Should Match '%23EXT%23'
            (Get-TestRequest 0).Uri | Should Not Match '#'
        }

        It 'throws for an unknown user principal name' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Text '{"value":[]}'))
            { Resolve-UserIdByUpn -UserPrincipalName 'nobody@corp.example.com' } | Should Throw 'User "nobody@corp.example.com" was not found'
        }

        It 'lists transitive member ids across pages without duplicates' {
            Start-TestRun
            Set-TestResponses @(
                (New-TestResponse -Json @{ value = @(@{ id = 'm1' }, @{ id = 'm2' }); '@odata.nextLink' = "https://graph.microsoft.com/v1.0/groups/$groupId/transitiveMembers/microsoft.graph.user?`$skiptoken=2" }),
                (New-TestResponse -Json @{ value = @(@{ id = 'M1' }, @{ id = 'm3' }) }))
            $ids = @(Get-TransitiveGroupMemberIds -GroupId $groupId -MemberType User)
            ($ids -join ',') | Should Be 'm1,m2,m3'
            $first = Get-TestRequest 0
            $first.Uri | Should Be "https://graph.microsoft.com/v1.0/groups/$groupId/transitiveMembers/microsoft.graph.user?`$select=id&`$top=999&`$count=true"
            $first.Headers['ConsistencyLevel'] | Should Be 'eventual'
            (Get-TestRequest 1).Headers['ConsistencyLevel'] | Should Be 'eventual'
        }

        It 'returns a case-insensitive set on request' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json @{ value = @(@{ id = 'ABC' }) }))
            $set = Get-TransitiveGroupMemberIds -GroupId $groupId -AsHashSet
            $set.Contains('abc') | Should Be $true
            $set.Count | Should Be 1
            (Get-TestRequest 0).Uri | Should Match '/transitiveMembers\?'
        }

        It 'returns an empty result for an empty group and rejects a malformed id' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Text '{"value":[]}'))
            @(Get-TransitiveGroupMemberIds -GroupId $groupId).Count | Should Be 0
            { Get-TransitiveGroupMemberIds -GroupId '../users' } | Should Throw
        }
    }

    Context 'ARM scopes' {
        $managementGroups = @{
            value = @(
                @{ id = '/providers/Microsoft.Management/managementGroups/mg-platform'; type = 'Microsoft.Management/managementGroups'; name = 'mg-platform'; properties = @{ displayName = 'Platform'; tenantId = '99999999-9999-9999-9999-999999999999' } },
                @{ id = '/providers/Microsoft.Management/managementGroups/mg-sandbox-1'; type = 'Microsoft.Management/managementGroups'; name = 'mg-sandbox-1'; properties = @{ displayName = 'Sandbox' } },
                @{ id = '/providers/Microsoft.Management/managementGroups/mg-sandbox-2'; type = 'Microsoft.Management/managementGroups'; name = 'mg-sandbox-2'; properties = @{ displayName = 'Sandbox' } }
            )
        }
        $subscriptionList = @{
            value = @(
                @{ id = "/subscriptions/$subscriptionA"; subscriptionId = $subscriptionA; displayName = 'Identity Production'; state = 'Enabled' },
                @{ id = "/subscriptions/$subscriptionB"; subscriptionId = $subscriptionB; displayName = 'Shared'; state = 'Enabled' },
                @{ id = '/subscriptions/88888888-8888-8888-8888-888888888888'; subscriptionId = '88888888-8888-8888-8888-888888888888'; displayName = 'shared'; state = 'Disabled' }
            )
        }

        It 'resolves a management group by id' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json $managementGroups))
            Resolve-ArmScope -ManagementGroupName 'MG-PLATFORM' | Should Be '/providers/Microsoft.Management/managementGroups/mg-platform'
            (Get-TestRequest 0).Uri | Should Be 'https://management.azure.com/providers/Microsoft.Management/managementGroups?api-version=2020-05-01'
        }

        It 'resolves a management group by display name and caches it' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json $managementGroups))
            Resolve-ArmScope -ManagementGroupName 'platform' | Should Be '/providers/Microsoft.Management/managementGroups/mg-platform'
            Resolve-ArmScope -ManagementGroupName 'Platform' | Should Be '/providers/Microsoft.Management/managementGroups/mg-platform'
            $global:RbcRequests.Count | Should Be 1
        }

        It 'refuses a duplicate management group display name' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json $managementGroups))
            { Resolve-ArmScope -ManagementGroupName 'Sandbox' } | Should Throw 'is not unique (2 matches: mg-sandbox-1, mg-sandbox-2)'
        }

        It 'refuses an unknown management group' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json $managementGroups))
            { Resolve-ArmScope -ManagementGroupName 'Nowhere' } | Should Throw 'Management group "Nowhere" was not found'
        }

        It 'resolves a subscription by name through /subscriptions' {
            Start-TestRun -Environment USGov
            Set-TestResponses @((New-TestResponse -Json $subscriptionList))
            Resolve-ArmScope -SubscriptionName 'identity production' | Should Be "/subscriptions/$subscriptionA"
            (Get-TestRequest 0).Uri | Should Be 'https://management.usgovcloudapi.net/subscriptions?api-version=2022-12-01'
        }

        It 'appends a resource group' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json $subscriptionList))
            Resolve-ArmScope -SubscriptionName 'Identity Production' -ResourceGroupName 'rg-identity' | Should Be "/subscriptions/$subscriptionA/resourceGroups/rg-identity"
            { Resolve-ArmScope -SubscriptionId $subscriptionA -ResourceGroupName 'bad/name' } | Should Throw 'is not valid'
        }

        It 'refuses a duplicate subscription name, whatever the state' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json $subscriptionList))
            { Resolve-ArmScope -SubscriptionName 'Shared' } | Should Throw ('is not unique (2 matches: ' + $subscriptionB + ', 88888888-8888-8888-8888-888888888888)')
        }

        It 'refuses an unknown subscription name' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json $subscriptionList))
            { Resolve-ArmScope -SubscriptionName 'Nope' } | Should Throw 'Subscription "Nope" was not found among the 3 subscription(s)'
        }

        It 'refuses a matched subscription whose subscriptionId is empty or not a GUID, and caches nothing' {
            Start-TestRun
            $badEntries = @(
                @{ id = '/subscriptions/'; subscriptionId = ''; displayName = 'Broken'; state = 'Enabled' },
                @{ id = '/subscriptions/x'; displayName = 'Broken'; state = 'Enabled' },
                @{ id = '/subscriptions/x'; subscriptionId = $null; displayName = 'Broken'; state = 'Enabled' },
                @{ id = '/subscriptions/x'; subscriptionId = 'not-a-guid/../..'; displayName = 'Broken'; state = 'Enabled' },
                @{ id = '/subscriptions/x'; subscriptionId = ($subscriptionA + ' '); displayName = 'Broken'; state = 'Enabled' }
            )
            foreach ($entry in $badEntries) {
                Set-TestResponses @((New-TestResponse -Json @{ value = @($entry, $subscriptionList.value[0]) }))
                $message = ''
                try { Resolve-ArmScope -SubscriptionName 'Broken' -ResourceGroupName 'rg-identity' | Out-Null } catch { $message = $_.Exception.Message }
                $message | Should Match '^Subscription "Broken" has no usable subscription id: the lookup matched an entry whose subscriptionId .* is not a GUID; refusing to build a scope from it\.$'
                $message.Contains('/subscriptions/') | Should Be $false
            }
            Set-TestResponses @((New-TestResponse -Json @{ value = @(@{ subscriptionId = $subscriptionB; displayName = 'Broken' }) }))
            Resolve-ArmScope -SubscriptionName 'Broken' -ResourceGroupName 'rg-identity' | Should Be "/subscriptions/$subscriptionB/resourceGroups/rg-identity"
            $global:RbcRequests.Count | Should Be 1
        }

        It 'refuses a matched management group whose id is not a valid group id' {
            Start-TestRun
            foreach ($badName in @('', 'mg/../other', 'mg-trailing.', ('m' * 91))) {
                Set-TestResponses @((New-TestResponse -Json @{ value = @(@{ id = '/providers/Microsoft.Management/managementGroups/x'; name = $badName; properties = @{ displayName = 'Odd' } }) }))
                { Resolve-ArmScope -ManagementGroupName 'Odd' } | Should Throw 'is not a valid management group id'
            }
            Set-TestResponses @((New-TestResponse -Json @{ value = @(@{ id = '/providers/Microsoft.Management/managementGroups/x'; name = 'mg_(Odd).v2'; properties = @{ displayName = 'Odd' } }) }))
            Resolve-ArmScope -ManagementGroupName 'Odd' | Should Be '/providers/Microsoft.Management/managementGroups/mg_(Odd).v2'
        }

        It 'refuses a descendant subscription whose name is not a GUID' {
            Start-TestRun
            Set-TestResponses @(
                (New-TestResponse -Json $managementGroups),
                (New-TestResponse -Json @{ value = @(@{ id = '/subscriptions/'; type = 'Microsoft.Management/managementGroups/subscriptions'; name = ''; properties = @{ displayName = 'Nameless' } }) }))
            { Get-ManagementGroupDescendantSubscriptions -ManagementGroupName 'Platform' } | Should Throw 'listed a subscription whose name "" is not a GUID'
        }

        It 'builds a subscription scope from an id without a call' {
            Start-TestRun
            Set-TestResponses @()
            Resolve-ArmScope -SubscriptionId $subscriptionA | Should Be "/subscriptions/$subscriptionA"
            Assert-MockCalled Invoke-HttpCore -Exactly 0 -Scope It
            { Resolve-ArmScope -SubscriptionId 'not-a-guid' } | Should Throw
        }

        It 'lists the subscriptions under a management group across pages' {
            Start-TestRun
            $descendantsNext = 'https://management.azure.com/providers/Microsoft.Management/managementGroups/mg-platform/descendants?api-version=2020-05-01&$skiptoken=2'
            Set-TestResponses @(
                (New-TestResponse -Json $managementGroups),
                (New-TestResponse -Json @{
                        value    = @(
                            @{ id = '/providers/Microsoft.Management/managementGroups/mg-child'; type = 'Microsoft.Management/managementGroups'; name = 'mg-child'; properties = @{ displayName = 'Child'; parent = @{ id = '/providers/Microsoft.Management/managementGroups/mg-platform' } } },
                            @{ id = "/subscriptions/$subscriptionB"; type = 'Microsoft.Management/managementGroups/subscriptions'; name = $subscriptionB; properties = @{ displayName = 'Zeta'; parent = @{ id = '/providers/Microsoft.Management/managementGroups/mg-child' } } }
                        )
                        nextLink = $descendantsNext
                    }),
                (New-TestResponse -Json @{
                        value    = @(
                            @{ id = "/subscriptions/$subscriptionA"; type = '/subscriptions'; name = $subscriptionA; properties = @{ displayName = 'Alpha'; parent = @{ id = '/providers/Microsoft.Management/managementGroups/mg-platform' } } }
                        )
                        nextLink = $null
                    }))
            $subs = @(Get-ManagementGroupDescendantSubscriptions -ManagementGroupName 'Platform')
            $subs.Count | Should Be 2
            $subs[0].DisplayName | Should Be 'Alpha'
            $subs[0].SubscriptionId | Should Be $subscriptionA
            $subs[0].Scope | Should Be "/subscriptions/$subscriptionA"
            $subs[1].ParentId | Should Be '/providers/Microsoft.Management/managementGroups/mg-child'
            (Get-TestRequest 1).Uri | Should Be 'https://management.azure.com/providers/Microsoft.Management/managementGroups/mg-platform/descendants?api-version=2020-05-01'
            (Get-TestRequest 2).Uri | Should Be $descendantsNext
        }

        It 'returns nothing for a management group with no subscriptions' {
            Start-TestRun
            Set-TestResponses @((New-TestResponse -Json $managementGroups), (New-TestResponse -Text '{"value":[],"nextLink":null}'))
            @(Get-ManagementGroupDescendantSubscriptions -ManagementGroupName 'mg-platform').Count | Should Be 0
        }
    }

    Context 'run summary and actions' {
        It 'takes its defaults from the run context' {
            Start-TestRun -Environment USGov -DryRun $false
            $s = New-RunSummary
            $s.Runbook | Should Be 'Runbook.Common.Tests'
            $s.RunId | Should Be $runId
            $s.DryRun | Should Be $false
            $s.Environment | Should Be 'USGov'
        }

        It 'records Planned in a dry run and Done in a live run by default' {
            Start-TestRun
            $dry = New-RunSummary
            Add-RunSummaryItem -Summary $dry -Action 'Disable' -Target 'u1'
            $dry.Counts['Disable']['Planned'] | Should Be 1
            $live = New-RunSummary -DryRun $false
            Add-RunSummaryItem -Summary $live -Action 'Disable' -Target 'u1'
            $live.Counts['Disable']['Done'] | Should Be 1
        }

        It 'completes with counts, totals, failures, duration, and extra values' {
            Start-TestRun -DryRun $false
            $start = New-Object -TypeName DateTime -ArgumentList 2026, 9, 17, 6, 0, 0, ([DateTimeKind]::Utc)
            $s = New-RunSummary -StartedUtc $start
            Add-RunSummaryItem -Summary $s -Action 'RemoveMember' -Target 'u1'
            Add-RunSummaryItem -Summary $s -Action 'RemoveMember' -Target 'u2' -Outcome Failed -Detail ('Graph said no to ' + $graphToken)
            Add-RunSummaryItem -Summary $s -Action 'Notify' -Target 'owner@corp.example.com' -Outcome Skipped -Detail 'no mailbox'
            Write-RunLog -Level Warn -Message 'one warning'
            $extra = [ordered]@{ GroupsScanned = 4; RunId = 'must not replace' }
            $out = Complete-RunSummary -Summary $s -Extra $extra -CompletedUtc $start.AddSeconds(95.26)
            $out.RunId | Should Be $runId
            $out.Runbook | Should Be 'Runbook.Common.Tests'
            $out.DryRun | Should Be $false
            $out.StartedUtc | Should Be '2026-09-17T06:00:00Z'
            $out.CompletedUtc | Should Be '2026-09-17T06:01:35Z'
            $out.DurationSeconds | Should Be 95.3
            $out.Counts.RemoveMember.Done | Should Be 1
            $out.Counts.RemoveMember.Failed | Should Be 1
            $out.Counts.Notify.Skipped | Should Be 1
            $out.Done | Should Be 1
            $out.Failed | Should Be 1
            $out.Skipped | Should Be 1
            $out.Planned | Should Be 0
            $out.ItemCount | Should Be 3
            $out.FailureCount | Should Be 1
            @($out.Failures)[0].Target | Should Be 'u2'
            @($out.Failures)[0].Detail.Contains($graphToken) | Should Be $false
            $out.GroupsScanned | Should Be 4
            $out.Warnings | Should Be 2
            $out.Errors | Should Be 0
            $out.ItemsTruncated | Should Be $false
            (@($out.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') | Should Match '^RunId,Runbook,DryRun,Environment,StartedUtc,CompletedUtc,DurationSeconds,Counts,'
        }

        It 'caps the items it emits' {
            Start-TestRun
            $s = New-RunSummary
            for ($i = 1; $i -le 5; $i++) { Add-RunSummaryItem -Summary $s -Action 'Warn' -Target ('g' + $i) }
            $out = Complete-RunSummary -Summary $s -MaxItems 2
            @($out.Items).Count | Should Be 2
            $out.ItemCount | Should Be 5
            $out.ItemsTruncated | Should Be $true
            $out.Planned | Should Be 5
        }

        It 'serialises to JSON for the job output' {
            Start-TestRun
            $s = New-RunSummary
            Add-RunSummaryItem -Summary $s -Action 'Warn' -Target 'g1'
            $json = Complete-RunSummary -Summary $s | ConvertTo-Json -Depth 6 -Compress
            $json | Should Match '"Counts":\{"Warn":\{"Planned":1,"Done":0,"Failed":0,"Skipped":0\}\}'
            $json | Should Match '"DryRun":true'
        }

        It 'logs and records a dry-run action without running it' {
            Start-TestRun
            $s = New-RunSummary
            $global:RbcRan = $false
            $out = Invoke-RunbookAction -Summary $s -Action 'Delete' -Target 'u1' -Description 'delete u1' -ScriptBlock { $global:RbcRan = $true }
            $out | Should BeNullOrEmpty
            $global:RbcRan | Should Be $false
            $s.Counts['Delete']['Planned'] | Should Be 1
            @(Get-RunLogEntries -Level Action)[0].Message | Should Be 'Would delete u1.'
        }

        It 'runs a live action, discards its output, and records Done' {
            Start-TestRun -DryRun $false
            $s = New-RunSummary
            $callerValue = 'caller variable'
            $global:RbcSeen = ''
            $out = Invoke-RunbookAction -Summary $s -Action 'Delete' -Target 'u1' -Description 'delete u1' -ScriptBlock { $global:RbcSeen = $callerValue; 'noise' }
            $out | Should BeNullOrEmpty
            $global:RbcSeen | Should Be 'caller variable'
            $s.Counts['Delete']['Done'] | Should Be 1
            @(Get-RunLogEntries -Level Action)[0].Message | Should Be 'Done: delete u1.'
            Invoke-RunbookAction -Summary $s -Action 'Delete' -Target 'u2' -Description 'delete u2' -ScriptBlock { } -PassThru | Should Be 'Done'
        }

        It 'records a failed action and carries on, or stops when asked' {
            Start-TestRun -DryRun $false
            $s = New-RunSummary
            $result = Invoke-RunbookAction -Summary $s -Action 'Delete' -Target 'u1' -Description 'delete u1' -ScriptBlock { throw ('Graph DELETE failed, token ' + $graphToken) } -PassThru 2>$null
            $result | Should Be 'Failed'
            $s.Counts['Delete']['Failed'] | Should Be 1
            @($s.Failures)[0].Detail | Should Match 'Graph DELETE failed'
            @($s.Failures)[0].Detail.Contains($graphToken) | Should Be $false
            Get-RunLogCount -Level Error | Should Be 1
            { Invoke-RunbookAction -Summary $s -Action 'Delete' -Target 'u2' -Description 'delete u2' -ScriptBlock { throw 'hard stop' } -StopOnError 2>$null } | Should Throw 'hard stop'
            $s.Counts['Delete']['Failed'] | Should Be 2
        }
    }

    Context 'inline contract with modules/azure/automation-runbooks' {
        $begin = '# INLINE_LIBRARY_BEGIN'
        $end = '# INLINE_LIBRARY_END'
        $libraryText = [System.IO.File]::ReadAllText($library)
        $sampleRunbook = @'
<#
.SYNOPSIS
    Sample runbook used by Runbook.Common.Tests.ps1 to prove the inline contract.
#>
[CmdletBinding()]
param(
    [string]$Items = '',
    [int]$MaxActions = 10,
    [bool]$DryRun = $true,
    [ValidateSet('Global', 'USGov')]
    [string]$Environment = 'Global',
    [string]$ClientId = '',
    [string]$AccessToken = '',
    [string]$RunId = ([Guid]::NewGuid().ToString())
)

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'SilentlyContinue'

# INLINE_LIBRARY_BEGIN
. (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\Runbook.Common.ps1')
# INLINE_LIBRARY_END

function Invoke-SampleRun {
    Initialize-RunContext -RunbookName 'Invoke-Sample' -RunId $RunId -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken -DryRun $DryRun
    $summary = New-RunSummary
    $names = @(ConvertTo-StringList -Value $Items -Label 'Items')
    Test-CircuitBreaker -Planned $names.Count -Cap $MaxActions -Label 'sample actions'
    foreach ($name in $names) {
        Invoke-RunbookAction -Summary $summary -Action 'Touch' -Target $name -Description ('touch {0}' -f $name) -ScriptBlock { throw 'the live path is not expected in this test' }
    }
    return (Complete-RunSummary -Summary $summary -Extra @{ Endpoint = (Get-CloudEndpoints -Environment $Environment).Graph })
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-SampleRun
}
'@

        It 'keeps the library safe to inline' {
            $bytes = [System.IO.File]::ReadAllBytes($library)
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $false
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should Be 0
            $libraryText.Contains($begin) | Should Be $false
            $libraryText.Contains($end) | Should Be $false
            $libraryText.Contains([string][char]0x2013) | Should Be $false
            $libraryText.Contains([string][char]0x2014) | Should Be $false
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($libraryText, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should Be 0
            $ast.ParamBlock | Should BeNullOrEmpty
            $ast.ScriptRequirements | Should BeNullOrEmpty
            $hostOnly = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and @('PSScriptRoot', 'MyInvocation', 'PSCommandPath') -contains $node.VariablePath.UserPath }, $true))
            $hostOnly.Count | Should Be 0
        }

        It 'gives every function comment-based help' {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($libraryText, [ref]$tokens, [ref]$errors)
            $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
            $functions.Count | Should BeGreaterThan 30
            $missing = @($functions | Where-Object { $null -eq $_.GetHelpContent() -or [string]::IsNullOrWhiteSpace($_.GetHelpContent().Synopsis) } | ForEach-Object { $_.Name })
            ($missing -join ', ') | Should Be ''
        }

        It 'uses the same marker strings as the runbooks module' {
            $moduleText = [System.IO.File]::ReadAllText($runbooksModule)
            $moduleText.Contains(('library_begin = "{0}"' -f $begin)) | Should Be $true
            $moduleText.Contains(('library_end   = "{0}"' -f $end)) | Should Be $true
        }

        It 'passes the module validation: each marker exactly once in the runbook' {
            $sampleRunbook.Split([string[]]@($begin), [StringSplitOptions]::None).Count | Should Be 2
            $sampleRunbook.Split([string[]]@($end), [StringSplitOptions]::None).Count | Should Be 2
        }

        It 'runs from disk with the dot-source between the markers' {
            $runbooksDir = Join-Path -Path $TestDrive -ChildPath 'automation\runbooks'
            $libDir = Join-Path -Path $TestDrive -ChildPath 'automation\lib'
            New-Item -ItemType Directory -Path $runbooksDir -Force | Out-Null
            New-Item -ItemType Directory -Path $libDir -Force | Out-Null
            Copy-Item -Path $library -Destination (Join-Path -Path $libDir -ChildPath 'Runbook.Common.ps1')
            $samplePath = Join-Path -Path $runbooksDir -ChildPath 'Invoke-Sample.ps1'
            [System.IO.File]::WriteAllText($samplePath, $sampleRunbook, (New-Object System.Text.UTF8Encoding($false)))

            $summary = & $samplePath -Items '["one","two"]' -AccessToken 'local-sample-token-0000' -RunId $runId
            @($summary).Count | Should Be 1
            $summary.Runbook | Should Be 'Invoke-Sample'
            $summary.RunId | Should Be $runId
            $summary.DryRun | Should Be $true
            $summary.Planned | Should Be 2
            $summary.Endpoint | Should Be 'https://graph.microsoft.com'
        }

        It 'runs when assembled the way Terraform inlines library_path' {
            # main.tf: join("", [split(begin, runbook)[0], begin, "\n", file(library), "\n", end, split(end, runbook)[1]])
            $head = $sampleRunbook.Split([string[]]@($begin), [StringSplitOptions]::None)[0]
            $tail = $sampleRunbook.Split([string[]]@($end), [StringSplitOptions]::None)[1]
            $assembled = $head + $begin + "`n" + $libraryText + "`n" + $end + $tail

            $assembled.Contains('..\lib\Runbook.Common.ps1') | Should Be $false
            $assembled.Contains('function Invoke-CloudRequest') | Should Be $true
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseInput($assembled, [ref]$tokens, [ref]$errors) | Out-Null
            @($errors).Count | Should Be 0

            $published = Join-Path -Path $TestDrive -ChildPath 'published\Invoke-Sample.ps1'
            New-Item -ItemType Directory -Path (Split-Path -Parent $published) -Force | Out-Null
            [System.IO.File]::WriteAllText($published, $assembled, (New-Object System.Text.UTF8Encoding($false)))
            $summary = & $published -Items 'a;b;c' -Environment USGov -AccessToken 'published-sample-token-0000' -RunId $runId
            $summary.Runbook | Should Be 'Invoke-Sample'
            $summary.Environment | Should Be 'USGov'
            $summary.Planned | Should Be 3
            $summary.Endpoint | Should Be 'https://graph.microsoft.us'
        }

        It 'trips the breaker in the assembled runbook before any action' {
            $head = $sampleRunbook.Split([string[]]@($begin), [StringSplitOptions]::None)[0]
            $tail = $sampleRunbook.Split([string[]]@($end), [StringSplitOptions]::None)[1]
            $published = Join-Path -Path $TestDrive -ChildPath 'published\Invoke-SampleBreaker.ps1'
            New-Item -ItemType Directory -Path (Split-Path -Parent $published) -Force | Out-Null
            [System.IO.File]::WriteAllText($published, ($head + $begin + "`n" + $libraryText + "`n" + $end + $tail), (New-Object System.Text.UTF8Encoding($false)))
            { & $published -Items 'a;b;c' -MaxActions 2 -AccessToken 'published-sample-token-0000' } | Should Throw 'Circuit breaker tripped: sample actions: 3 planned, cap is 2. Nothing was changed.'
        }
    }
}

# Invoke-HttpCore is the one function the block above mocks, so it is tested
# on its own here, one level down, against a mocked Invoke-WebRequest.
Describe 'Runbook.Common Invoke-HttpCore' {
    . $library
    $VerbosePreference = 'SilentlyContinue'

    $accented = '{"name":"caf' + [char]0x00E9 + '"}'

    It 'maps a success response, decoding UTF-8 and dropping a byte order mark' {
        Mock Invoke-WebRequest {
            $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes($accented))
            $stream = New-Object -TypeName System.IO.MemoryStream -ArgumentList (, $bytes)
            return [PSCustomObject]@{ StatusCode = 200; Headers = @{ 'Retry-After' = '5'; 'Content-Type' = 'application/json' }; RawContentStream = $stream; Content = 'decoded differently' }
        }
        $r = Invoke-HttpCore -Method GET -Uri 'https://graph.microsoft.com/v1.0/me' -Headers @{ Authorization = 'Bearer test' }
        $r.StatusCode | Should Be 200
        $r.Content | Should Be $accented
        $r.Headers['retry-after'] | Should Be '5'
        Assert-MockCalled Invoke-WebRequest -Exactly 1 -Scope It -ParameterFilter { $UseBasicParsing -and $Method -eq 'GET' -and $null -eq $Body -and $Uri -eq 'https://graph.microsoft.com/v1.0/me' }
    }

    It 'sends a string body as UTF-8 bytes with the content type' {
        Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 204; Headers = @{}; Content = '' } }
        $r = Invoke-HttpCore -Method POST -Uri 'https://graph.microsoft.com/v1.0/x' -Headers @{} -Body $accented -ContentType 'application/json; charset=utf-8'
        $r.StatusCode | Should Be 204
        $r.Content | Should Be ''
        Assert-MockCalled Invoke-WebRequest -Exactly 1 -Scope It -ParameterFilter { $ContentType -eq 'application/json; charset=utf-8' -and $Body -is [byte[]] -and [System.Text.Encoding]::UTF8.GetString($Body) -eq $accented }
    }

    It 'maps an HTTP error in the Windows PowerShell shape instead of throwing' {
        Mock Invoke-WebRequest {
            $responseHeaders = New-Object System.Net.WebHeaderCollection
            $responseHeaders.Add('Retry-After', '9')
            $response = [PSCustomObject]@{ StatusCode = 429; Headers = $responseHeaders }
            $response | Add-Member -MemberType ScriptMethod -Name GetResponseStream -Value { New-Object -TypeName System.IO.MemoryStream -ArgumentList (, [System.Text.Encoding]::UTF8.GetBytes('{"error":{"code":"TooManyRequests"}}')) }
            $exception = New-Object System.Exception 'The remote server returned an error: (429).'
            $exception | Add-Member -MemberType NoteProperty -Name Response -Value $response
            throw $exception
        }
        $r = Invoke-HttpCore -Method GET -Uri 'https://management.azure.com/subscriptions?api-version=2022-12-01' -Headers @{}
        $r.StatusCode | Should Be 429
        $r.Headers['Retry-After'] | Should Be '9'
        $r.Content | Should Be '{"error":{"code":"TooManyRequests"}}'
    }

    It 'rethrows when there is no HTTP response at all' {
        Mock Invoke-WebRequest { throw (New-Object System.Net.WebException 'The remote name could not be resolved') }
        { Invoke-HttpCore -Method GET -Uri 'https://graph.microsoft.com/v1.0/me' -Headers @{} } | Should Throw 'could not be resolved'
    }

    It 'maps an HTTP error returned as a response, the PowerShell 7 shape' {
        Mock Invoke-WebRequest {
            $responseHeaders = New-Object 'System.Collections.Generic.Dictionary[string,string[]]'
            $responseHeaders.Add('Retry-After', [string[]]@('11'))
            $responseHeaders.Add('x-ms-request-id', [string[]]@('a', 'b'))
            $stream = New-Object -TypeName System.IO.MemoryStream -ArgumentList (, [System.Text.Encoding]::UTF8.GetBytes('{"error":{"code":"ServerBusy"}}'))
            return [PSCustomObject]@{ StatusCode = [System.Net.HttpStatusCode]::ServiceUnavailable; Headers = $responseHeaders; RawContentStream = $stream; Content = '' }
        }
        $r = Invoke-HttpCore -Method GET -Uri 'https://management.azure.com/subscriptions?api-version=2022-12-01' -Headers @{}
        $r.StatusCode | Should Be 503
        $r.Headers['retry-after'] | Should Be '11'
        $r.Headers['x-ms-request-id'] | Should Be 'a,b'
        $r.Content | Should Be '{"error":{"code":"ServerBusy"}}'
    }

    It 'streams a GET to OutFile without decoding, after removing an old file' {
        $target = Join-Path -Path $TestDrive -ChildPath 'core-ok.zip'
        [System.IO.File]::WriteAllText($target, 'stale')
        $global:RbcStaleSeen = $null
        Mock Invoke-WebRequest {
            $global:RbcStaleSeen = [System.IO.File]::Exists($OutFile)
            [System.IO.File]::WriteAllBytes($OutFile, [byte[]](0x50, 0x4B, 0x00, 0xFF, 0xFE))
            return [PSCustomObject]@{ StatusCode = 200; Headers = @{ 'Content-MD5' = 'abc=='; 'Content-Length' = '5' }; Content = [byte[]](0x50, 0x4B, 0x00, 0xFF, 0xFE) }
        }
        $r = Invoke-HttpCore -Method GET -Uri 'https://stexampleiam.blob.core.windows.net/state/core-ok.zip' -Headers @{ Authorization = 'Bearer test' } -OutFile $target
        $r.StatusCode | Should Be 200
        $r.Content | Should Be ''
        $r.Headers['content-md5'] | Should Be 'abc=='
        $global:RbcStaleSeen | Should Be $false
        ([System.IO.File]::ReadAllBytes($target) -join ',') | Should Be '80,75,0,255,254'
        Assert-MockCalled Invoke-WebRequest -Exactly 1 -Scope It -ParameterFilter { $OutFile -eq $target -and $PassThru -and $UseBasicParsing -and $Method -eq 'GET' -and $null -eq $Body }
    }

    It 'reads an error body a PowerShell 7 download wrote to OutFile, then removes the file' {
        $target = Join-Path -Path $TestDrive -ChildPath 'core-404.zip'
        Mock Invoke-WebRequest {
            [System.IO.File]::WriteAllBytes($OutFile, [System.Text.Encoding]::UTF8.GetBytes([string][char]0xFEFF + '<?xml version="1.0" encoding="utf-8"?><Error><Code>BlobNotFound</Code></Error>'))
            $responseHeaders = New-Object 'System.Collections.Generic.Dictionary[string,string[]]'
            $responseHeaders.Add('x-ms-error-code', [string[]]@('BlobNotFound'))
            return [PSCustomObject]@{ StatusCode = [System.Net.HttpStatusCode]::NotFound; Headers = $responseHeaders; Content = '' }
        }
        $r = Invoke-HttpCore -Method GET -Uri 'https://stexampleiam.blob.core.windows.net/state/core-404.zip' -Headers @{} -OutFile $target
        $r.StatusCode | Should Be 404
        $r.Content | Should Be '<?xml version="1.0" encoding="utf-8"?><Error><Code>BlobNotFound</Code></Error>'
        $r.Headers['x-ms-error-code'] | Should Be 'BlobNotFound'
        (Test-Path -LiteralPath $target) | Should Be $false
    }

    It 'maps a Windows PowerShell download error and leaves no file' {
        $target = Join-Path -Path $TestDrive -ChildPath 'core-403.zip'
        Mock Invoke-WebRequest {
            [System.IO.File]::WriteAllBytes($OutFile, [byte[]](1, 2))
            $responseHeaders = New-Object System.Net.WebHeaderCollection
            $responseHeaders.Add('x-ms-error-code', 'AuthorizationPermissionMismatch')
            $response = [PSCustomObject]@{ StatusCode = 403; Headers = $responseHeaders }
            $response | Add-Member -MemberType ScriptMethod -Name GetResponseStream -Value { New-Object -TypeName System.IO.MemoryStream -ArgumentList (, [System.Text.Encoding]::UTF8.GetBytes('<Error><Code>AuthorizationPermissionMismatch</Code></Error>')) }
            $exception = New-Object System.Exception 'The remote server returned an error: (403) Forbidden.'
            $exception | Add-Member -MemberType NoteProperty -Name Response -Value $response
            throw $exception
        }
        $r = Invoke-HttpCore -Method GET -Uri 'https://stexampleiam.blob.core.windows.net/state/core-403.zip' -Headers @{} -OutFile $target
        $r.StatusCode | Should Be 403
        $r.Content | Should Be '<Error><Code>AuthorizationPermissionMismatch</Code></Error>'
        $r.Headers['x-ms-error-code'] | Should Be 'AuthorizationPermissionMismatch'
        (Test-Path -LiteralPath $target) | Should Be $false
    }

    It 'removes a partial download when the connection drops, then rethrows' {
        $target = Join-Path -Path $TestDrive -ChildPath 'core-partial.zip'
        Mock Invoke-WebRequest {
            [System.IO.File]::WriteAllBytes($OutFile, [byte[]](1, 2, 3))
            throw (New-Object System.Net.WebException 'The connection was closed unexpectedly')
        }
        { Invoke-HttpCore -Method GET -Uri 'https://stexampleiam.blob.core.windows.net/state/core-partial.zip' -Headers @{} -OutFile $target } | Should Throw 'closed unexpectedly'
        (Test-Path -LiteralPath $target) | Should Be $false
    }

    It 'refuses OutFile with another method or with a body, before any request' {
        Mock Invoke-WebRequest { throw 'must not be called' }
        $target = Join-Path -Path $TestDrive -ChildPath 'core-refused.zip'
        { Invoke-HttpCore -Method POST -Uri 'https://graph.microsoft.com/v1.0/x' -Headers @{} -OutFile $target } | Should Throw 'only valid with GET, not POST'
        { Invoke-HttpCore -Method GET -Uri 'https://graph.microsoft.com/v1.0/x' -Headers @{} -Body 'x' -OutFile $target } | Should Throw 'cannot send a body'
        Assert-MockCalled Invoke-WebRequest -Exactly 0 -Scope It
    }

    It 'leaves the text path unchanged when OutFile is empty' {
        Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 200; Headers = @{}; Content = 'plain' } }
        (Invoke-HttpCore -Method GET -Uri 'https://graph.microsoft.com/v1.0/x' -Headers @{} -OutFile '').Content | Should Be 'plain'
        Assert-MockCalled Invoke-WebRequest -Exactly 1 -Scope It -ParameterFilter { [string]::IsNullOrEmpty($OutFile) -and -not $PassThru }
    }
}

Remove-Variable -Name RbcQueue, RbcRequests, RbcRan, RbcSeen, RbcPayload, RbcWrapped, RbcVariableValue, RbcVariableCalls, RbcVariableThrow, RbcStaleSeen -Scope Global -ErrorAction SilentlyContinue
