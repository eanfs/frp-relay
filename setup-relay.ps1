#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ServerAddr = "frps.example.com",
    [int]$ServerPort = 7000,
    [string]$Token = "",
    [string]$InternalHost = "",
    [int]$SshPort = 22,
    [string]$SshUser = "",
    [int]$StcpBindPort = 60022,
    [string]$ProxyUser = "relay",
    [string]$ProxyName = "ssh-gw",
    [string]$StcpSecret = "",
    [string]$AdminPassword = "",
    [switch]$SkipConnectivityCheck
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot

function Read-SecretText {
    param([string]$Prompt)
    $sec = Read-Host -AsSecureString $Prompt
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function New-RandomHex {
    param([int]$ByteCount)
    $buf = New-Object byte[] $ByteCount
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($buf)
    } finally {
        $rng.Dispose()
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $buf) {
        [void]$sb.Append($b.ToString("x2"))
    }
    return $sb.ToString()
}

function ConvertTo-TomlString {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return $Value.Replace('\', '\\').Replace('"', '\"')
}

function Test-TcpPort {
    param(
        [string]$ComputerName,
        [int]$Port,
        [int]$TimeoutMs = 4000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            try {
                $client.EndConnect($iar)
                return $true
            } catch {
                return $false
            }
        }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Render-Template {
    param(
        [string]$TemplatePath,
        [hashtable]$Values
    )
    $text = [IO.File]::ReadAllText($TemplatePath)
    foreach ($key in $Values.Keys) {
        $text = $text.Replace("{{" + $key + "}}", [string]$Values[$key])
    }
    return $text
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $enc)
}

if ([string]::IsNullOrWhiteSpace($Token) -and $env:FRP_TOKEN) {
    $Token = $env:FRP_TOKEN
}
if ([string]::IsNullOrWhiteSpace($Token)) {
    $Token = Read-SecretText "请输入 frps auth.token"
}
if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "token 不能为空"
}

if ([string]::IsNullOrWhiteSpace($InternalHost)) {
    Write-Host "本机 IPv4 地址（供确认内网网段）："
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' } |
        ForEach-Object { Write-Host ("  {0}  {1}" -f $_.IPAddress, $_.InterfaceAlias) }
    $InternalHost = Read-Host "请输入内网服务器 IP"
}
if ([string]::IsNullOrWhiteSpace($InternalHost)) {
    throw "内网服务器 IP 不能为空"
}

if ([string]::IsNullOrWhiteSpace($SshUser)) {
    $SshUser = Read-Host "请输入内网 SSH 用户（直接回车默认 root）"
    if ([string]::IsNullOrWhiteSpace($SshUser)) {
        $SshUser = "root"
    }
}

if ([string]::IsNullOrWhiteSpace($ProxyUser)) {
    $ProxyUser = "relay"
}
if ([string]::IsNullOrWhiteSpace($ProxyName)) {
    $ProxyName = "ssh-gw"
}
if ([string]::IsNullOrWhiteSpace($StcpSecret)) {
    $StcpSecret = New-RandomHex 24
}
if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
    $AdminPassword = New-RandomHex 16
}

if ($StcpBindPort -lt 1 -or $StcpBindPort -gt 65535) {
    throw "STCP 本地端口无效: $StcpBindPort"
}

if (-not $SkipConnectivityCheck) {
    Write-Host "检查 frps ${ServerAddr}:${ServerPort} ..."
    if (-not (Test-TcpPort $ServerAddr $ServerPort)) {
        throw "无法连接 frps ${ServerAddr}:${ServerPort}，请检查网络、端口和 token 配置。"
    }
    Write-Host "检查内网服务器 ${InternalHost}:${SshPort} ..."
    if (-not (Test-TcpPort $InternalHost $SshPort)) {
        Write-Warning "无法连接内网 SSH ${InternalHost}:${SshPort}；请确认 IP、端口、sshd 和内网防火墙。配置仍会继续生成。"
    }
}

$frpcPath = Join-Path $Root "frpc.exe"
if (-not (Test-Path $frpcPath)) {
    Write-Warning "当前目录没有 frpc.exe；请先运行 download-frpc.ps1 或从其他机器拷贝。"
}

$templateDir = Join-Path $Root "templates"
$templatePath = Join-Path $templateDir "frpc.toml.tpl"
$visitorTemplatePath = Join-Path $templateDir "visitor.toml.tpl"
if (-not (Test-Path $templatePath)) { throw "缺少模板: $templatePath" }
if (-not (Test-Path $visitorTemplatePath)) { throw "缺少模板: $visitorTemplatePath" }

$values = @{
    SERVER_ADDR    = ConvertTo-TomlString $ServerAddr
    SERVER_PORT    = $ServerPort
    TOKEN          = ConvertTo-TomlString $Token
    INTERNAL_HOST  = ConvertTo-TomlString $InternalHost
    SSH_PORT       = $SshPort
    STCP_BIND_PORT = $StcpBindPort
    PROXY_USER     = ConvertTo-TomlString $ProxyUser
    PROXY_NAME     = ConvertTo-TomlString $ProxyName
    STCP_SECRET    = ConvertTo-TomlString $StcpSecret
    ADMIN_PASSWORD = ConvertTo-TomlString $AdminPassword
}

$frpcToml = Join-Path $Root "frpc.toml"
Write-Utf8NoBom $frpcToml (Render-Template $templatePath $values)

$visitorDir = Join-Path $Root "visitor"
if (-not (Test-Path $visitorDir)) {
    New-Item -ItemType Directory -Path $visitorDir | Out-Null
}
$visitorToml = Join-Path $visitorDir "visitor.toml"
Write-Utf8NoBom $visitorToml (Render-Template $visitorTemplatePath $values)

if (Test-Path $frpcPath) {
    try {
        Copy-Item $frpcPath (Join-Path $visitorDir "frpc.exe") -Force
    } catch {
        Write-Warning "复制 frpc.exe 到 visitor 目录失败（可能正在运行）：$($_.Exception.Message)"
    }
}

$meta = [ordered]@{
    serverAddr   = $ServerAddr
    serverPort   = $ServerPort
    sshUser      = $SshUser
    internalHost = $InternalHost
    sshPort      = $SshPort
    stcpBindPort = $StcpBindPort
    proxyUser    = $ProxyUser
    proxyName    = $ProxyName
}
Write-Utf8NoBom (Join-Path $Root "relay-meta.json") ($meta | ConvertTo-Json)

$info = @"
frp 中转启动信息
====================
frps 控制地址 : ${ServerAddr}:${ServerPort}
公网 SSH      : 启动后随机选择一个未使用端口（每次不同）
TCP 连接命令  : 运行 start-relay.cmd 后查看窗口，或运行 status.cmd
转发目标      : ${SshUser}@${InternalHost}:${SshPort}
STCP 备用     : 在环境B运行 visitor\start-visitor.cmd 后执行
                ssh -p ${StcpBindPort} ${SshUser}@127.0.0.1
====================
"@
Write-Utf8NoBom (Join-Path $Root "connection-info.txt") $info

$visitorInfo = @"
STCP 连接方式
====================
1. 先运行本目录下的 start-visitor.cmd
2. 再执行: ssh -p ${StcpBindPort} ${SshUser}@127.0.0.1
====================
"@
Write-Utf8NoBom (Join-Path $visitorDir "connection-info.txt") $visitorInfo

Write-Host ""
Write-Host "配置已生成：" -ForegroundColor Green
Write-Host "  $frpcToml"
Write-Host "  $visitorToml"
Write-Host "  $(Join-Path $Root 'connection-info.txt')"
Write-Host "  $(Join-Path $Root 'relay-meta.json')"
Write-Host ""
Write-Host "公网 TCP 端口：每次启动随机选择（占用会自动重试）" -ForegroundColor Cyan
Write-Host "启动后查看 start-relay.cmd 窗口，或运行 status.cmd 获取当前 ssh 命令"
Write-Host ""
Write-Host "下一步：双击 start-relay.cmd" -ForegroundColor Yellow
