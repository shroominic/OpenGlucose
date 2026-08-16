param(
  [Parameter(Mandatory = $true)]
  [string]$ReleaseDirectory,

  [Parameter(Mandatory = $true)]
  [string]$OutputDirectory,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$')]
  [string]$VersionRecord,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[0-9a-f]{40}$')]
  [string]$SourceCommit,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^(?:refs/tags/v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)|ci:[0-9a-f]{40})$')]
  [string]$SourceRef
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-File {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Required Windows bundle file is missing: $Path"
  }
}

function Require-Directory {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "Required Windows bundle directory is missing: $Path"
  }
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$releasePath = (Resolve-Path -LiteralPath $ReleaseDirectory).Path
$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)
$stagePath = Join-Path $outputPath 'OpenGlucose'
$safeVersion = $VersionRecord.Replace('+', '-')
$archiveName = "openglucose-$safeVersion-windows-x64-preview.zip"
$archivePath = Join-Path $outputPath $archiveName
$checksumPath = "$archivePath.sha256"

Require-File (Join-Path $releasePath 'OpenGlucose.exe')
Require-File (Join-Path $releasePath 'flutter_windows.dll')
Require-File (Join-Path $releasePath 'flutter_blue_plus_winrt_plugin.dll')
Require-File (Join-Path $releasePath 'msvcp140.dll')
Require-File (Join-Path $releasePath 'vcruntime140.dll')
Require-Directory (Join-Path $releasePath 'data\flutter_assets')
Require-File (Join-Path $releasePath 'data\flutter_assets\NOTICES.Z')

foreach ($path in @($stagePath, $archivePath, $checksumPath)) {
  if (Test-Path -LiteralPath $path) {
    throw "Refusing to replace existing package output: $path"
  }
}

New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
New-Item -ItemType Directory -Path $stagePath | Out-Null
Copy-Item -Path (Join-Path $releasePath '*') -Destination $stagePath -Recurse
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'LICENSE') -Destination $stagePath
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'NOTICE.md') -Destination $stagePath
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'docs\windows-preview.md') -Destination (Join-Path $stagePath 'README-WINDOWS-PREVIEW.md')

$buildInfo = @(
  'OpenGlucose Windows preview'
  "App version: $VersionRecord"
  "Source commit: $SourceCommit"
  "Source ref: $SourceRef"
  'Physical Windows/AiDEX verification: not yet recorded'
  'Distribution status: unsigned preview; not an approved production release'
)
Set-Content -LiteralPath (Join-Path $stagePath 'BUILD-INFO.txt') -Value $buildInfo -Encoding utf8NoBOM

$forbiddenFiles = Get-ChildItem -LiteralPath $stagePath -Recurse -File | Where-Object {
  $_.Extension -match '^\.(pfx|p12|pem|key|jks|keystore|mobileprovision)$'
}
if ($forbiddenFiles) {
  throw 'The staged package contains credential or signing-material file types.'
}

Compress-Archive -LiteralPath $stagePath -DestinationPath $archivePath -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $checksumPath -Value "$hash  $archiveName" -Encoding ascii

if ($env:GITHUB_OUTPUT) {
  "archive=$archivePath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "checksum=$checksumPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "sha256=$hash" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

Write-Output "Created $archivePath"
Write-Output "SHA-256 $hash"
