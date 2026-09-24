[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("Generate", "EnableApi", "DisableApi", "Import", "All")]
    [string]$Mode = "Generate",

    [string]$RepositoryPath = "C:\Projects\opcua-asyncio",
    [string]$ReadTagsFile = "HMI_TAGS_TO_READ_OPC_UA_REAL_DATA_STRUCTURE",
    [string]$WriteTagsFile = "HMI_TAGS_TO_WRITE_OPC_UA_REAL_DATA_STRUCTURE",
    [string]$ChannelName = "HMI_Simulator",
    [string]$DeviceName = "PLC",
    [ValidateRange(1, 999)]
    [int]$DeviceId = 1,
    [ValidateSet(0, 1)]
    [int]$DeviceModel = 1,
    [uri]$ApiBaseUri = "https://127.0.0.1:57512/config/v1",
    [pscredential]$Credential,
    [string]$OutputDirectory = $PSScriptRoot,
    [switch]$TrustLocalCertificate,
    [switch]$ReplaceExistingChannel,
    [switch]$KeepApiEnabled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$settingsPath = "C:\ProgramData\Kepware\KEPServerEX\V6\settings.ini"
$settingsBackupPath = "$settingsPath.before-codex-config-api"
$configApiService = "KEPServerEXConfigAPI6"
$supportedTypes = @("Boolean", "Int16", "UInt16", "String")
$dataTypeMap = @{
    Boolean = 1
    Int16 = 4
    UInt16 = 5
    String = 0
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This operation must be run from PowerShell as Administrator."
    }
}

function Assert-LocalApiUri {
    param([uri]$Uri)

    if ($Uri.Host -notin @("127.0.0.1", "localhost", "::1")) {
        throw "ApiBaseUri must use a loopback host (127.0.0.1, localhost, or ::1)."
    }
}

function Set-ConfigurationApiState {
    param([bool]$Enabled)

    if (-not (Test-Path -LiteralPath $settingsPath)) {
        throw "Kepware settings file was not found: $settingsPath"
    }

    $desiredValue = if ($Enabled) { 1 } else { 0 }
    $verb = if ($Enabled) { "Enable" } else { "Disable" }
    if (-not $PSCmdlet.ShouldProcess($settingsPath, "$verb the Kepware Configuration API")) {
        return
    }

    Assert-Administrator
    Stop-Service -Name $configApiService -Force
    try {
        $content = Get-Content -LiteralPath $settingsPath -Raw
        if ($content -notmatch "(?ms)\[Config API Service\].*?^Enabled=\s*[01]\s*$") {
            throw "The Configuration API Enabled setting was not found in $settingsPath"
        }
        if (-not (Test-Path -LiteralPath $settingsBackupPath)) {
            Copy-Item -LiteralPath $settingsPath -Destination $settingsBackupPath
        }
        $updated = $content -replace "(?ms)(\[Config API Service\].*?^Enabled=)\s*[01]\s*$", "`${1} $desiredValue"
        Set-Content -LiteralPath $settingsPath -Value $updated -Encoding ascii
    }
    finally {
        Start-Service -Name $configApiService
    }
}

function ConvertTo-KepwareName {
    param([Parameter(Mandatory)][string]$Name)

    $converted = $Name -replace "\[(\d+)\]", "_`$1"
    $converted = $converted -replace '[\."]', "_"
    $converted = $converted.Trim()
    if ($converted.StartsWith("_")) {
        $converted = "Tag$converted"
    }
    if ([string]::IsNullOrWhiteSpace($converted)) {
        throw "A source name could not be converted to a valid Kepware name."
    }
    return $converted
}

function Read-TagExport {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$Writable
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Tag export was not found: $Path"
    }

    $result = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $Path -Encoding utf8) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $columns = $line.Split([char]9)
        if ($columns.Count -lt 7) {
            throw "$Path`:$lineNumber does not contain at least seven tab-separated columns."
        }
        if ($columns[6] -notin $supportedTypes) {
            continue
        }

        $sourcePath = $columns[3] -replace '^DataBlocksGlobal/', ""
        $identifier = $columns[2] -replace '^ns=\d+;s=', ""
        $segments = @([regex]::Matches($identifier, '"([^"]+)"(?:\[(\d+)\])?') | ForEach-Object {
            $segment = $_.Groups[1].Value
            if ($_.Groups[2].Success) {
                $segment = "$segment`_$($_.Groups[2].Value)"
            }
            ConvertTo-KepwareName -Name $segment
        })
        if ($segments.Count -lt 2) {
            throw "$Path`:$lineNumber has an invalid source path: $sourcePath"
        }

        $result.Add([pscustomobject]@{
            SourceNodeId = $columns[2]
            SourcePath = $sourcePath
            GroupPath = @($segments[0..($segments.Count - 2)])
            Name = $segments[-1]
            DataType = $columns[6]
            InitialValue = $columns[5]
            Writable = $Writable
        })
    }
    return $result
}

function New-GroupNode {
    param([Parameter(Mandatory)][string]$Name)

    return [ordered]@{
        "common.ALLTYPES_NAME" = $Name
        tag_groups = [System.Collections.Generic.List[object]]::new()
        tags = [System.Collections.Generic.List[object]]::new()
    }
}

function Add-TagToTree {
    param(
        [Parameter(Mandatory)]$RootGroups,
        [Parameter(Mandatory)]$Tag,
        [Parameter(Mandatory)][hashtable]$AddressCounters
    )

    $groups = $RootGroups
    $current = $null
    foreach ($segment in $Tag.GroupPath) {
        $current = $groups | Where-Object { $_["common.ALLTYPES_NAME"] -eq $segment } | Select-Object -First 1
        if ($null -eq $current) {
            $current = New-GroupNode -Name $segment
            $groups.Add($current)
        }
        $groups = $current.tag_groups
    }

    $prefix = switch ($Tag.DataType) {
        "Boolean" { "B" }
        "String" { "S" }
        default { "K" }
    }
    $AddressCounters[$prefix]++
    $address = "$prefix$($AddressCounters[$prefix])"
    $current.tags.Add([ordered]@{
        "common.ALLTYPES_NAME" = $Tag.Name
        "common.ALLTYPES_DESCRIPTION" = "Imported from $($Tag.SourceNodeId)"
        "servermain.TAG_ADDRESS" = $address
        "servermain.TAG_DATA_TYPE" = $dataTypeMap[$Tag.DataType]
        "servermain.TAG_READ_WRITE_ACCESS" = if ($Tag.Writable) { 1 } else { 0 }
        "servermain.TAG_SCAN_RATE_MILLISECONDS" = 100
    })
    $Tag | Add-Member -NotePropertyName KepwareAddress -NotePropertyValue $address
    $itemSegments = @($ChannelName, $DeviceName) + $Tag.GroupPath + $Tag.Name
    $Tag | Add-Member -NotePropertyName KepwareItemId -NotePropertyValue ($itemSegments -join ".")
}

function New-ProjectPayload {
    param([Parameter(Mandatory)][object[]]$Tags)

    $rootGroups = [System.Collections.Generic.List[object]]::new()
    $addressCounters = @{ B = 0; K = 0; S = 0 }
    foreach ($tag in $Tags) {
        Add-TagToTree -RootGroups $rootGroups -Tag $tag -AddressCounters $addressCounters
    }

    return [ordered]@{
        "common.ALLTYPES_NAME" = $ChannelName
        "servermain.MULTIPLE_TYPES_DEVICE_DRIVER" = "Simulator"
        devices = @(
            [ordered]@{
                "common.ALLTYPES_NAME" = $DeviceName
                "servermain.MULTIPLE_TYPES_DEVICE_DRIVER" = "Simulator"
                "servermain.DEVICE_MODEL" = $DeviceModel
                "servermain.DEVICE_ID_STRING" = "$DeviceId"
                tag_groups = $rootGroups
            }
        )
    }
}

function Get-ApiHeaders {
    if ($null -eq $Credential) {
        $script:Credential = Get-Credential -UserName "Administrator" -Message "Kepware Configuration API credentials"
    }
    $pair = "$($Credential.UserName):$($Credential.GetNetworkCredential().Password)"
    $token = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    return @{ Authorization = "Basic $token" }
}

function Invoke-KepwareApi {
    param(
        [Parameter(Mandatory)][ValidateSet("GET", "POST", "DELETE")][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body
    )

    Assert-LocalApiUri -Uri $ApiBaseUri
    $uri = [uri]::new("$($ApiBaseUri.AbsoluteUri.TrimEnd('/'))/$($Path.TrimStart('/'))")
    $parameters = @{
        Uri = $uri
        Method = $Method
        Headers = Get-ApiHeaders
        ContentType = "application/json"
    }
    if ($null -ne $Body) {
        $parameters.Body = $Body | ConvertTo-Json -Depth 100 -Compress
    }
    if ($TrustLocalCertificate) {
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            throw "TrustLocalCertificate requires PowerShell 7 or newer."
        }
        $parameters.SkipCertificateCheck = $true
    }
    return Invoke-RestMethod @parameters
}

function Export-GeneratedFiles {
    param(
        [Parameter(Mandatory)]$Payload,
        [Parameter(Mandatory)][object[]]$Tags
    )

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $payloadPath = Join-Path $OutputDirectory "kepware-project-payload.json"
    $mapPath = Join-Path $OutputDirectory "kepware-tag-map.csv"
    $Payload | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $payloadPath -Encoding utf8
    $Tags | Select-Object SourceNodeId, SourcePath, GroupPath, Name, DataType, InitialValue, Writable,
        KepwareAddress, KepwareItemId | Export-Csv -LiteralPath $mapPath -NoTypeInformation -Encoding utf8
    Write-Host "Generated $payloadPath"
    Write-Host "Generated $mapPath"
}

function Import-Project {
    param([Parameter(Mandatory)]$Payload)

    $encodedChannel = [uri]::EscapeDataString($ChannelName)
    $channelPath = "project/channels/$encodedChannel"
    $channelExists = $false
    try {
        Invoke-KepwareApi -Method GET -Path $channelPath | Out-Null
        $channelExists = $true
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 404) {
            throw
        }
    }

    if ($channelExists) {
        if (-not $ReplaceExistingChannel) {
            throw "Channel '$ChannelName' already exists. Use -ReplaceExistingChannel to replace it."
        }
        if ($PSCmdlet.ShouldProcess($ChannelName, "Delete the existing Kepware channel")) {
            Invoke-KepwareApi -Method DELETE -Path $channelPath | Out-Null
        }
    }
    if ($PSCmdlet.ShouldProcess($ChannelName, "Create the Kepware Simulator channel, device, groups, and tags")) {
        Invoke-KepwareApi -Method POST -Path "project/channels" -Body $Payload | Out-Null
    }
}

$readPath = Join-Path $RepositoryPath $ReadTagsFile
$writePath = Join-Path $RepositoryPath $WriteTagsFile
$tags = @(
    Read-TagExport -Path $readPath -Writable $false
    Read-TagExport -Path $writePath -Writable $true
)
$duplicateNames = $tags | Group-Object { "$($_.GroupPath -join '/')/$($_.Name)" } | Where-Object Count -gt 1
if ($duplicateNames) {
    throw "Duplicate Kepware tag paths were generated: $($duplicateNames.Name -join ', ')"
}
$payload = New-ProjectPayload -Tags $tags

switch ($Mode) {
    "Generate" {
        Export-GeneratedFiles -Payload $payload -Tags $tags
    }
    "EnableApi" {
        Set-ConfigurationApiState -Enabled $true
    }
    "DisableApi" {
        Set-ConfigurationApiState -Enabled $false
    }
    "Import" {
        Import-Project -Payload $payload
    }
    "All" {
        Set-ConfigurationApiState -Enabled $true
        Import-Project -Payload $payload
        if (-not $KeepApiEnabled) {
            Set-ConfigurationApiState -Enabled $false
        }
    }
}

Write-Host "Prepared $($tags.Count) scalar tags from the exported OPC UA structure."


