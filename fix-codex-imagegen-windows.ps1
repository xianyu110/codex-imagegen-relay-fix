[CmdletBinding()]
param(
    [string]$RelayBaseUrl
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RelayBaseUrl)) {
    $RelayBaseUrl = $env:CODEX_RELAY_BASE_URL
}
if ([string]::IsNullOrWhiteSpace($RelayBaseUrl)) {
    $RelayBaseUrl = 'https://momoai.asia/v1'
}
$RelayBaseUrl = $RelayBaseUrl.TrimEnd('/')
if ($RelayBaseUrl -match '[\r\n"]') {
    throw 'RelayBaseUrl must not contain quotes or newlines.'
}
try {
    $relayUri = [Uri]$RelayBaseUrl
    if (-not $relayUri.IsAbsoluteUri -or $relayUri.Scheme -notin @('http', 'https')) {
        throw 'invalid scheme'
    }
} catch {
    throw 'RelayBaseUrl must be an absolute http(s) URL.'
}

$codexHome = $env:CODEX_HOME
if ([string]::IsNullOrWhiteSpace($codexHome)) {
    $codexHome = Join-Path $HOME '.codex'
}
$configFile = Join-Path $codexHome 'config.toml'
$authFile = Join-Path $codexHome 'auth.json'

if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
    throw "Missing $configFile"
}
if (-not (Test-Path -LiteralPath $authFile -PathType Leaf)) {
    throw "Missing $authFile. Add OPENAI_API_KEY to auth.json locally, then rerun."
}

try {
    $auth = Get-Content -LiteralPath $authFile -Raw | ConvertFrom-Json
    $relayKey = [string]$auth.OPENAI_API_KEY
} catch {
    throw "Cannot read OPENAI_API_KEY from $authFile as JSON."
}
if ([string]::IsNullOrWhiteSpace($relayKey)) {
    throw 'OPENAI_API_KEY(auth.json)=MISSING'
}
Write-Output 'OPENAI_API_KEY(auth.json)=EXISTS'

$configText = Get-Content -LiteralPath $configFile -Raw
$providerMatch = [regex]::Match($configText, '(?m)^\s*model_provider\s*=\s*"([^"]+)"')
if (-not $providerMatch.Success) {
    throw 'model_provider is not configured.'
}
$activeProvider = $providerMatch.Groups[1].Value
$providerSection = "[model_providers.$activeProvider]"
if (-not [regex]::IsMatch($configText, "(?m)^\s*\[model_providers\.$([regex]::Escape($activeProvider))\]\s*$")) {
    throw "Missing $providerSection"
}

# Rewrite only the provider fields owned by this repair and the image feature flag.
$providerFields = @(
    "name = `"$($activeProvider.Replace('\', '\\').Replace('"', '\"'))`"",
    "base_url = `"$($RelayBaseUrl.Replace('\', '\\').Replace('"', '\"'))`"",
    'wire_api = "responses"',
    'requires_openai_auth = false',
    'env_key = "OPENAI_API_KEY"',
    'http_headers = { "x-openai-actor-authorization" = "local-relay" }'
)
$output = New-Object System.Collections.Generic.List[string]
$inProvider = $false
$inFeatures = $false
$providerSeen = $false
$featuresSeen = $false
$featureWritten = $false

foreach ($line in ($configText -split "`r?`n", -1)) {
    if ($line -match '^\s*\[') {
        if ($inProvider) {
            foreach ($field in $providerFields) { [void]$output.Add($field) }
            $inProvider = $false
        }
        if ($inFeatures -and -not $featureWritten) {
            [void]$output.Add('image_generation = true')
            $featureWritten = $true
        }
        $inFeatures = $false

        if ($line.Trim() -eq $providerSection) {
            [void]$output.Add($line)
            $inProvider = $true
            $providerSeen = $true
            continue
        }
        if ($line.Trim() -eq '[features]') {
            [void]$output.Add($line)
            $inFeatures = $true
            $featuresSeen = $true
            continue
        }
    }

    if ($inProvider -and $line -match '^\s*(name|base_url|wire_api|requires_openai_auth|env_key|http_headers|auth|experimental_bearer_token)\s*=') {
        continue
    }
    if ($inFeatures -and $line -match '^\s*image_generation\s*=') {
        continue
    }
    [void]$output.Add($line)
}
if ($inProvider) {
    foreach ($field in $providerFields) { [void]$output.Add($field) }
}
if ($inFeatures -and -not $featureWritten) {
    [void]$output.Add('image_generation = true')
    $featureWritten = $true
}
if (-not $featuresSeen) {
    [void]$output.Add('')
    [void]$output.Add('[features]')
    [void]$output.Add('image_generation = true')
}
if (-not $providerSeen) {
    throw "Provider rewrite failed for $providerSection"
}

$newConfig = ($output -join "`n").TrimEnd([char[]]"`r`n") + "`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($configFile, $newConfig, $utf8NoBom)

# User-scoped variables are inherited by newly launched desktop applications.
[Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $relayKey, 'User')
$env:OPENAI_API_KEY = $relayKey
$userRelayKey = [Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User')
if ([string]::IsNullOrWhiteSpace($userRelayKey)) {
    throw 'OPENAI_API_KEY(windows user environment)=MISSING'
}
Write-Output 'OPENAI_API_KEY(windows user environment)=EXISTS'

$providerOk = $newConfig -match '(?m)^\s*env_key\s*=\s*"OPENAI_API_KEY"' -and
    $newConfig -match '(?m)^\s*requires_openai_auth\s*=\s*false' -and
    $newConfig -match 'x-openai-actor-authorization.*local-relay' -and
    $newConfig -match '(?m)^\s*image_generation\s*=\s*true' -and
    $newConfig -notmatch '(?m)^\s*(auth|experimental_bearer_token)\s*='
if (-not $providerOk) {
    throw 'Provider configuration validation failed.'
}
Write-Output 'provider_config=OK'

function Invoke-RelayCheck {
    param(
        [ValidateSet('Get', 'Post')][string]$Method,
        [string]$Uri,
        [string]$Body
    )
    $headers = @{ Authorization = "Bearer $relayKey" }
    try {
        if ($Method -eq 'Post') {
            $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Uri -Headers $headers -ContentType 'application/json' -Body $Body
        } else {
            $response = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $Uri -Headers $headers
        }
        return @{ Status = [int]$response.StatusCode; Content = [string]$response.Content }
    } catch {
        $status = 0
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        return @{ Status = $status; Content = '' }
    }
}

$models = Invoke-RelayCheck -Method Get -Uri "$RelayBaseUrl/models"
Write-Output "models_http=$($models.Status)"
if ($models.Status -lt 200 -or $models.Status -ge 300) { throw 'Models validation failed.' }
try {
    $modelDocument = $models.Content | ConvertFrom-Json
    $modelIds = @($modelDocument.data | ForEach-Object { $_.id })
    if ($modelIds -contains 'gpt-image-2') { Write-Output 'gpt-image-2=AVAILABLE' } else { throw 'missing image model' }
    if ($modelIds -contains 'gpt-5.4') { Write-Output 'gpt-5.4=AVAILABLE' } else { throw 'missing chat model' }
} catch {
    throw 'Model list does not contain both gpt-image-2 and gpt-5.4.'
}

$body = '{"model":"gpt-5.4","input":"Reply with OK.","max_output_tokens":16}'
$responses = Invoke-RelayCheck -Method Post -Uri "$RelayBaseUrl/responses" -Body $body
Write-Output "responses_http=$($responses.Status)"
if ($responses.Status -lt 200 -or $responses.Status -ge 300) { throw 'Responses validation failed.' }

Write-Output 'image_generation_config=READY'
Write-Output 'Completely exit Codex, start it again, create a new task, and use a tool-capable chat model such as gpt-5.4.'
