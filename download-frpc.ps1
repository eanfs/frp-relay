#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Version = "0.72.0",
    [string]$Destination = $PSScriptRoot,
    [string]$Sha256 = "5197c1b69564089cdc229fc1260a0e25db1e722b1b7db45fe1542c3c43edf9ae"
)

$ErrorActionPreference = "Stop"
$url = "https://github.com/fatedier/frp/releases/download/v${Version}/frp_${Version}_windows_amd64.zip"
$tmp = Join-Path $env:TEMP ("frpc-" + [guid]::NewGuid().ToString("N") + ".zip")
$extract = Join-Path $env:TEMP ("frpc-" + [guid]::NewGuid().ToString("N"))

try {
    Write-Host "下载 $url"
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
    $hash = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $Sha256.ToLower()) {
        throw "SHA256 校验失败：实际 $hash，期望 $Sha256"
    }
    Expand-Archive -Path $tmp -DestinationPath $extract -Force
    $exe = Get-ChildItem -Path $extract -Recurse -Filter "frpc.exe" | Select-Object -First 1
    if (-not $exe) {
        throw "压缩包中未找到 frpc.exe"
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $target = Join-Path $Destination "frpc.exe"
    Copy-Item $exe.FullName $target -Force
    Unblock-File $target -ErrorAction SilentlyContinue
    Write-Host "已安装到 $target" -ForegroundColor Green
} finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
}
