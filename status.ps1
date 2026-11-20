#Requires -Version 5.1

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$tomlPath = Join-Path $Root "frpc.toml"
$metaPath = Join-Path $Root "relay-meta.json"
$infoPath = Join-Path $Root "connection-info.txt"

if (-not (Test-Path $tomlPath)) {
    Write-Host "frpc.toml 不存在，请先运行 setup-relay.cmd" -ForegroundColor Red
    exit 1
}

$text = [IO.File]::ReadAllText($tomlPath)

function Get-TomlString {
    param([string]$Text, [string]$Key)
    $pattern = '(?m)^\s*' + [regex]::Escape($Key) + '\s*=\s*"([^"]*)"'
    $m = [regex]::Match($Text, $pattern)
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-TomlNumber {
    param([string]$Text, [string]$Key)
    $pattern = '(?m)^\s*' + [regex]::Escape($Key) + '\s*=\s*(\d+)'
    $m = [regex]::Match($Text, $pattern)
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return $null
}

$user = Get-TomlString $text "webServer.user"
$pass = Get-TomlString $text "webServer.password"
$adminPort = Get-TomlNumber $text "webServer.port"
$serverAddr = Get-TomlString $text "serverAddr"
if (-not $adminPort) { $adminPort = 7400 }
if (-not $user) { $user = "relay" }

$meta = $null
if (Test-Path $metaPath) {
    $meta = ConvertFrom-Json ([IO.File]::ReadAllText($metaPath, [Text.Encoding]::UTF8))
}
$sshUser = ""
$stcpBindPort = 60022
if ($meta) {
    $sshUser = $meta.sshUser
    if ($meta.stcpBindPort) { $stcpBindPort = $meta.stcpBindPort }
}

$pair = "${user}:${pass}"
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
$headers = @{ Authorization = "Basic $b64" }
$uri = "http://127.0.0.1:${adminPort}/api/status"

try {
    $resp = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 3
} catch {
    Write-Host "frpc 未运行，或管理 API 不可达：$($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "请先双击 start-relay.cmd。" -ForegroundColor Yellow
    if (Test-Path $infoPath) {
        Write-Host ""
        Write-Host "上次启动信息（可能已过期）：" -ForegroundColor Yellow
        Write-Host ([IO.File]::ReadAllText($infoPath, [Text.Encoding]::UTF8))
    }
    exit 1
}

Write-Host "frpc 代理状态" -ForegroundColor Cyan
Write-Host "===================="
$found = $false
$tcpRemoteAddr = $null
foreach ($prop in $resp.PSObject.Properties) {
    foreach ($p in $prop.Value) {
        $found = $true
        Write-Host ("[{0}] {1}  status={2}" -f $prop.Name, $p.name, $p.status)
        if ($p.local_addr) { Write-Host ("  local : {0}" -f $p.local_addr) }
        if ($p.remote_addr) { Write-Host ("  remote: {0}" -f $p.remote_addr) }
        if ($p.err) { Write-Host ("  err   : {0}" -f $p.err) -ForegroundColor Red }
        if ($prop.Name -eq "tcp" -and $p.status -eq "running" -and $p.remote_addr) {
            $tcpRemoteAddr = $p.remote_addr
        }
    }
}
if (-not $found) {
    Write-Host "frpc 已连接，但当前没有代理。" -ForegroundColor Yellow
}

if ($tcpRemoteAddr) {
    $m = [regex]::Match($tcpRemoteAddr, ':(\d+)$')
    if ($m.Success) {
        $port = $m.Groups[1].Value
        Write-Host ""
        Write-Host "当前公网 SSH: $tcpRemoteAddr" -ForegroundColor Cyan
        if ($sshUser) {
            Write-Host "连接命令: ssh -p $port $sshUser@$serverAddr" -ForegroundColor Cyan
            Write-Host "STCP: 环境B运行 visitor\start-visitor.cmd 后 ssh -p $stcpBindPort $sshUser@127.0.0.1" -ForegroundColor Cyan
        } else {
            Write-Host "连接命令: ssh -p $port <用户>@$serverAddr" -ForegroundColor Cyan
        }
    }
} else {
    Write-Host ""
    Write-Host "TCP 代理尚未 running，端口还未分配；请查看 frpc 日志。" -ForegroundColor Yellow
}
