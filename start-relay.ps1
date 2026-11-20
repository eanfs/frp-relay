#Requires -Version 5.1

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$tomlPath = Join-Path $Root "frpc.toml"
$metaPath = Join-Path $Root "relay-meta.json"
$statePath = Join-Path $Root "relay-state.json"
$runtimePath = Join-Path $Root "frpc.runtime.toml"
$infoPath = Join-Path $Root "connection-info.txt"
$frpcPath = Join-Path $Root "frpc.exe"

if (-not (Test-Path $frpcPath)) {
    Write-Host "frpc.exe 不存在，请先运行 download-frpc.ps1 或从其他机器拷贝。" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $tomlPath)) {
    Write-Host "frpc.toml 不存在，请先运行 setup-relay.cmd。" -ForegroundColor Red
    exit 1
}

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

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $enc)
}

$text = [IO.File]::ReadAllText($tomlPath)
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
$internalHost = ""
$sshPort = 22
$stcpBindPort = 60022
$proxyName = ""
if ($meta) {
    $sshUser = $meta.sshUser
    $internalHost = $meta.internalHost
    $sshPort = $meta.sshPort
    if ($meta.stcpBindPort) { $stcpBindPort = $meta.stcpBindPort }
    $proxyName = $meta.proxyName
}

$lastPort = 0
if (Test-Path $statePath) {
    try {
        $state = ConvertFrom-Json ([IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8))
        if ($state.lastPort) { $lastPort = [int]$state.lastPort }
    } catch { }
}

$pair = "${user}:${pass}"
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
$headers = @{ Authorization = "Basic $b64" }
$statusUri = "http://127.0.0.1:${adminPort}/api/status"

function New-RandomPort {
    param([int]$AvoidPort)
    do {
        $p = Get-Random -Minimum 50000 -Maximum 60000
    } while ($p -eq $AvoidPort)
    return $p
}

function Write-RuntimeConfig {
    param([int]$Port)
    $re = [regex]'(?m)^\s*remotePort\s*=\s*\d+'
    $runtime = $re.Replace($text, "remotePort = $Port", 1)
    if ($runtime -notmatch "(?m)^remotePort = ${Port}\s*$") {
        throw "无法在 frpc.toml 中写入 remotePort"
    }
    Write-Utf8NoBom $runtimePath $runtime
}

function Get-TcpProxyStatus {
    try {
        $resp = Invoke-RestMethod -Uri $statusUri -Headers $headers -TimeoutSec 2
    } catch {
        return $null
    }
    $proxies = @($resp.tcp)
    if ($proxies.Count -eq 0) { return $null }
    $chosen = $proxies | Where-Object {
        $_.name -eq $proxyName -or $_.name -like "*.$proxyName"
    } | Select-Object -First 1
    if (-not $chosen) { $chosen = $proxies[0] }
    return $chosen
}

function Write-ConnectionInfo {
    param([string]$RemoteAddr)
    $m = [regex]::Match($RemoteAddr, ':(\d+)$')
    if (-not $m.Success) {
        throw "无法解析远程端口: $RemoteAddr"
    }
    $port = $m.Groups[1].Value
    $info = @"
frp 中转启动信息
====================
frps 控制地址 : ${serverAddr}
公网 SSH      : ${RemoteAddr}
TCP 连接命令  : ssh -p ${port} ${sshUser}@${serverAddr}
转发目标      : ${sshUser}@${internalHost}:${sshPort}
STCP 备用     : 在环境B运行 visitor\start-visitor.cmd 后执行
                ssh -p ${stcpBindPort} ${sshUser}@127.0.0.1
====================
"@
    Write-Host ""
    Write-Host $info -ForegroundColor Cyan
    Write-Utf8NoBom $infoPath $info
}

$maxAttempts = 5
$child = $null
try {
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $port = New-RandomPort $lastPort
        $lastPort = $port
        $state = [ordered]@{ lastPort = $port }
        Write-Utf8NoBom $statePath ($state | ConvertTo-Json)
        Write-RuntimeConfig $port

        Write-Host "第 ${attempt} 次尝试，随机端口: ${port}" -ForegroundColor Yellow
        $child = Start-Process -FilePath $frpcPath -ArgumentList @("-c", "frpc.runtime.toml") `
            -WorkingDirectory $Root -NoNewWindow -PassThru

        $deadline = (Get-Date).AddSeconds(20)
        $running = $false
        $portErr = $false
        $startErr = $false
        $remoteAddr = $null
        while ((Get-Date) -lt $deadline) {
            if ($child.HasExited) { break }
            $p = Get-TcpProxyStatus
            if ($p) {
                if ($p.status -eq "running" -and $p.remote_addr) {
                    $running = $true
                    $remoteAddr = $p.remote_addr
                    break
                }
                if ($p.status -eq "start error") {
                    if ($p.err -match '(?i)port') {
                        $portErr = $true
                    } else {
                        Write-Host "代理启动错误: $($p.err)" -ForegroundColor Red
                        $startErr = $true
                    }
                    break
                }
            }
            Start-Sleep -Milliseconds 500
        }

        if ($running) {
            if (-not $remoteAddr) { $remoteAddr = "${serverAddr}:${port}" }
            Write-ConnectionInfo $remoteAddr
            Write-Host "frpc 正在运行，按 Ctrl+C 停止。" -ForegroundColor Green
            Wait-Process -Id $child.Id
            Write-Host "frpc 已退出，退出码 $($child.ExitCode)。" -ForegroundColor Yellow
            exit 0
        }

        if ($portErr) {
            Write-Host "端口 ${port} 已被占用，自动重试。" -ForegroundColor Yellow
            Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $child.Id -Timeout 5 -ErrorAction SilentlyContinue
            $child = $null
            continue
        }

        if ($child.HasExited) {
            Write-Host "frpc 已退出，退出码 $($child.ExitCode)；请检查上方日志。" -ForegroundColor Red
            exit 1
        }

        if ($startErr) {
            Write-Host "frpc 仍在运行；修复内网服务后可能自动恢复。按 Ctrl+C 停止。" -ForegroundColor Yellow
            Wait-Process -Id $child.Id
            Write-Host "frpc 已退出，退出码 $($child.ExitCode)。" -ForegroundColor Yellow
            exit 0
        }

        Write-Host "等待代理启动超时；frpc 仍在运行，请查看上方日志。" -ForegroundColor Yellow
        Wait-Process -Id $child.Id
        Write-Host "frpc 已退出，退出码 $($child.ExitCode)。" -ForegroundColor Yellow
        exit 0
    }

    Write-Host "连续 ${maxAttempts} 次随机端口都不可用，请稍后重试。" -ForegroundColor Red
    exit 1
} finally {
    if ($child -and -not $child.HasExited) {
        Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
    }
}
