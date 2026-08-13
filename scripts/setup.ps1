<#
.SYNOPSIS
  一键在 Windows 上部署「ChatGPT 订阅 -> DSH」本地桥：
  Sub2API + 便携 PostgreSQL + 便携 Redis（免管理员权限）。

.DESCRIPTION
  仅限个人学习、技术研究与非商业性技术交流使用。
  本方案违反 OpenAI 服务条款，有封号风险，请只用你能承受丢失的账号。
  本脚本只做「部署编排」，Sub2API 二进制从官方 Release 下载，不随本仓库分发。

  脚本会：
    1. 下载便携 PostgreSQL / Redis / Sub2API / 时区数据
    2. 初始化并启动 PostgreSQL、Redis、Sub2API
    3. 随机生成所有密钥（不会写死任何默认密码）
    4. 通过 Sub2API 管理 API 建好代理 / 分组 / API Key
    5. 生成一个「带代理」的 OAuth 授权链接，供人工步骤前的连通性确认

  注意：本脚本尽力自动化，但 OpenAI 风控、上游接口、网络环境随时会变，
  若某步失败，请以 docs/guide.zh.md 的手动步骤为准排查。

.EXAMPLE
  .\setup.ps1
  .\setup.ps1 -InstallDir D:\sub2api-test -PostgresPort 15432 -RedisPort 16379 -ServerPort 18080 `
      -ProxyPort 7897 -DownloadProxy http://127.0.0.1:7897
#>

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path (Split-Path $PSScriptRoot -Parent) "runtime"),
    [int]$PostgresPort = 5432,
    [int]$RedisPort = 6379,
    [int]$ServerPort = 8080,
    [string]$AdminEmail = "admin@example.com",
    # 回源 OpenAI 用的代理（通常是 Clash 混合端口）
    [string]$ProxyHost = "127.0.0.1",
    [int]$ProxyPort = 7897,
    [string]$ProxyProtocol = "http",   # http / https / socks5 / socks5h
    # 可选：下载阶段走代理（GitHub 慢/被墙时用），例如 http://127.0.0.1:7897
    [string]$DownloadProxy = ""
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# 版本号（失效时自行更新；发布前应再次校验下载地址与校验和）
# ---------------------------------------------------------------------------
$PG_VERSION      = "17.9"
$REDIS_VERSION   = "7.0.11"
$SUB2API_VERSION = "0.1.176"

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$DOWNLOAD = Join-Path $InstallDir "downloads"
$PG_DIR   = Join-Path $InstallDir "pgsql"
$PGDATA   = Join-Path $InstallDir "pgdata"
$REDIS    = Join-Path $InstallDir "redis"
$APP      = Join-Path $InstallDir "app"
$DATA_DIR = Join-Path $APP "data"
$SUB2API_EXE = Join-Path $APP "sub2api.exe"
$PG_PASSWORD_FILE = Join-Path $InstallDir "pgpw.txt"

$pgStarted = $false
$redisProcess = $null
$sub2apiProcess = $null
$completed = $false

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
function Write-Step([string]$Message) {
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Get-RandomHex([int]$ByteCount) {
    $bytes = New-Object byte[] $ByteCount
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Invoke-Download([string]$Url, [string]$OutFile) {
    Write-Host "  下载 $Url"
    $params = @{
        Uri             = $Url
        OutFile         = $OutFile
        UseBasicParsing = $true
    }
    if ($DownloadProxy) {
        $params.Proxy = $DownloadProxy
    }
    Invoke-WebRequest @params
}

function Test-PortInUse([int]$Port) {
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $false
    } catch [System.Net.Sockets.SocketException] {
        return $true
    } finally {
        if ($null -ne $listener) {
            try { $listener.Stop() } catch { }
        }
    }
}

function Assert-ValidPort([string]$Name, [int]$Port) {
    if ($Port -lt 1 -or $Port -gt 65535) {
        throw "$Name 必须在 1..65535，当前为 $Port。"
    }
}

function Wait-Http([string]$Uri, [int]$Attempts = 40) {
    for ($i = 0; $i -lt $Attempts; $i++) {
        Start-Sleep -Seconds 2
        try {
            $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                return $true
            }
        } catch { }
    }
    return $false
}

function Stop-Sub2APIProcesses([string]$ExecutablePath) {
    $target = [System.IO.Path]::GetFullPath($ExecutablePath)
    Get-Process -Name "sub2api" -ErrorAction SilentlyContinue | ForEach-Object {
        $candidate = $null
        try { $candidate = $_.Path } catch { }
        if ($candidate -and ([System.IO.Path]::GetFullPath($candidate) -ieq $target)) {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# 0. 前置检查
# ---------------------------------------------------------------------------
Write-Step "前置检查"
if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "需要 PowerShell 5+，当前为 $($PSVersionTable.PSVersion)。"
}

Assert-ValidPort "PostgresPort" $PostgresPort
Assert-ValidPort "RedisPort" $RedisPort
Assert-ValidPort "ServerPort" $ServerPort
Assert-ValidPort "ProxyPort" $ProxyPort

if ((@($PostgresPort, $RedisPort, $ServerPort) | Select-Object -Unique).Count -ne 3) {
    throw "PostgreSQL、Redis 与 Sub2API 必须使用三个不同端口。"
}
if (@("http", "https", "socks5", "socks5h") -notcontains $ProxyProtocol) {
    throw "ProxyProtocol 只允许 http / https / socks5 / socks5h。"
}
if ([string]::IsNullOrWhiteSpace($ProxyHost)) {
    throw "ProxyHost 不能为空。"
}

$AdminEmail = $AdminEmail.Trim()
try {
    $parsedEmail = New-Object System.Net.Mail.MailAddress($AdminEmail)
} catch {
    throw "AdminEmail 不是合法邮箱格式。"
}
if ($parsedEmail.Address -ne $AdminEmail) {
    throw "AdminEmail 必须是纯邮箱地址，不能包含显示名称。"
}

$driveRoot = [System.IO.Path]::GetPathRoot($InstallDir).TrimEnd("\")
if ($InstallDir.TrimEnd("\") -ieq $driveRoot) {
    throw "InstallDir 不能是磁盘根目录。"
}
if (Test-Path -LiteralPath $InstallDir) {
    $existingItem = Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction Stop | Select-Object -First 1
    if ($null -ne $existingItem) {
        throw "安装目录不是空目录：$InstallDir。为避免覆盖真实部署，请改用新的空目录。"
    }
}

$ports = @(
    @{ Name = "PostgreSQL"; Port = $PostgresPort },
    @{ Name = "Redis"; Port = $RedisPort },
    @{ Name = "Sub2API"; Port = $ServerPort }
)
foreach ($entry in $ports) {
    if (Test-PortInUse $entry.Port) {
        throw "$($entry.Name) 端口 $($entry.Port) 已被占用。请改用对应端口参数，绝不要复用现有部署端口。"
    }
}

# Windows PowerShell 5.1 的旧默认 TLS 可能无法访问 GitHub。
[System.Net.ServicePointManager]::SecurityProtocol = `
    [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

try {
    # -----------------------------------------------------------------------
    # 1. 目录、下载与解压
    # -----------------------------------------------------------------------
    Write-Step "创建目录并下载组件"
    New-Item -ItemType Directory -Force -Path $InstallDir, $DOWNLOAD, $DATA_DIR | Out-Null

    Invoke-Download "https://get.enterprisedb.com/postgresql/postgresql-$PG_VERSION-1-windows-x64-binaries.zip" (Join-Path $DOWNLOAD "pg.zip")
    Invoke-Download "https://github.com/zkteco-home/redis-windows/releases/download/$REDIS_VERSION/redis-$REDIS_VERSION-windows.zip" (Join-Path $DOWNLOAD "redis.zip")
    Invoke-Download "https://github.com/Wei-Shaw/sub2api/releases/download/v$SUB2API_VERSION/sub2api_${SUB2API_VERSION}_windows_amd64.zip" (Join-Path $DOWNLOAD "sub2api.zip")
    Invoke-Download "https://raw.githubusercontent.com/golang/go/master/lib/time/zoneinfo.zip" (Join-Path $APP "zoneinfo.zip")

    Write-Host "  解压中..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $DOWNLOAD "pg.zip"), $InstallDir)
    Expand-Archive -Path (Join-Path $DOWNLOAD "redis.zip") -DestinationPath $REDIS -Force
    Expand-Archive -Path (Join-Path $DOWNLOAD "sub2api.zip") -DestinationPath $APP -Force

    $requiredFiles = @(
        (Join-Path $PG_DIR "bin\initdb.exe"),
        (Join-Path $PG_DIR "bin\pg_ctl.exe"),
        (Join-Path $REDIS "redis-server.exe"),
        $SUB2API_EXE,
        (Join-Path $APP "zoneinfo.zip")
    )
    foreach ($requiredFile in $requiredFiles) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "组件解压后缺少预期文件：$requiredFile"
        }
    }

    # -----------------------------------------------------------------------
    # 2. 随机密钥
    # -----------------------------------------------------------------------
    Write-Step "生成随机密钥"
    $pgPass = Get-RandomHex 16
    $adminPass = Get-RandomHex 12

    # -----------------------------------------------------------------------
    # 3. PostgreSQL
    # -----------------------------------------------------------------------
    Write-Step "初始化并启动 PostgreSQL"
    Write-Utf8NoBom $PG_PASSWORD_FILE $pgPass
    try {
        $initdb = Join-Path $PG_DIR "bin\initdb.exe"
        $initArgs = @(
            "-D", $PGDATA,
            "-U", "postgres",
            "-A", "scram-sha-256",
            "--pwfile=$PG_PASSWORD_FILE",
            "-E", "UTF8",
            "--locale=C"
        )
        & $initdb @initArgs | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "initdb 失败，退出码 $LASTEXITCODE。"
        }
    } finally {
        Remove-Item -LiteralPath $PG_PASSWORD_FILE -Force -ErrorAction SilentlyContinue
    }

    $pgCtl = Join-Path $PG_DIR "bin\pg_ctl.exe"
    & $pgCtl -D $PGDATA -l (Join-Path $PGDATA "pg.log") start -o "-p $PostgresPort" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "PostgreSQL 启动失败，退出码 $LASTEXITCODE。"
    }
    $pgStarted = $true

    $pgReady = $false
    $pgIsReady = Join-Path $PG_DIR "bin\pg_isready.exe"
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        & $pgIsReady -h 127.0.0.1 -p $PostgresPort | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $pgReady = $true
            break
        }
    }
    if (-not $pgReady) {
        throw "PostgreSQL 未在端口 $PostgresPort 就绪。"
    }

    $env:PGPASSWORD = $pgPass
    try {
        & (Join-Path $PG_DIR "bin\createdb.exe") -h 127.0.0.1 -p $PostgresPort -U postgres sub2api
        if ($LASTEXITCODE -ne 0) {
            throw "createdb 失败，退出码 $LASTEXITCODE。"
        }
    } finally {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    }

    # -----------------------------------------------------------------------
    # 4. Redis
    # -----------------------------------------------------------------------
    Write-Step "启动 Redis"
    $redisLog = Join-Path $REDIS "redis.log"
    $redisPid = Join-Path $REDIS "redis.pid"
    $redisArguments = "--port $RedisPort --bind 127.0.0.1 --save 900 1 --save 300 10 --logfile `"$redisLog`" --dir `"$REDIS`" --pidfile `"$redisPid`""
    $redisProcess = Start-Process -FilePath (Join-Path $REDIS "redis-server.exe") `
        -ArgumentList $redisArguments -WindowStyle Hidden -PassThru

    $redisReady = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        $ping = & (Join-Path $REDIS "redis-cli.exe") -h 127.0.0.1 -p $RedisPort ping 2>&1
        if ($ping -eq "PONG") {
            $redisReady = $true
            break
        }
        if ($redisProcess.HasExited) {
            break
        }
    }
    if (-not $redisReady) {
        throw "Redis 未在端口 $RedisPort 就绪。"
    }

    # -----------------------------------------------------------------------
    # 5. Sub2API：首次安装（setup wizard）
    # -----------------------------------------------------------------------
    Write-Step "首次启动 Sub2API（安装向导）"
    $env:DATA_DIR = $DATA_DIR
    $env:ZONEINFO = Join-Path $APP "zoneinfo.zip"
    # 首次启动尚无 config.yaml，自定义端口必须通过环境变量传入。
    $env:SERVER_HOST = "127.0.0.1"
    $env:SERVER_PORT = [string]$ServerPort

    $sub2apiProcess = Start-Process -FilePath $SUB2API_EXE `
        -WorkingDirectory $APP -WindowStyle Hidden -PassThru

    $setupStatusUri = "http://127.0.0.1:$ServerPort/setup/status"
    if (-not (Wait-Http $setupStatusUri)) {
        throw "Sub2API 安装向导未在端口 $ServerPort 就绪。"
    }

    $installBody = @{
        database = @{
            host = "127.0.0.1"; port = $PostgresPort; user = "postgres"
            password = $pgPass; dbname = "sub2api"; sslmode = "disable"
        }
        redis = @{
            host = "127.0.0.1"; port = $RedisPort; username = ""
            password = ""; db = 0; enable_tls = $false
        }
        admin = @{ email = $AdminEmail; password = $adminPass }
        server = @{ host = "127.0.0.1"; port = $ServerPort; mode = "release" }
    } | ConvertTo-Json -Depth 6

    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$ServerPort/setup/install" `
        -ContentType "application/json" -Body $installBody -TimeoutSec 300 | Out-Null

    # 向导把配置写进 DATA_DIR；强制设置 simple，而不是只在字段缺失时追加。
    $cfgPath = Join-Path $DATA_DIR "config.yaml"
    for ($i = 0; $i -lt 15 -and -not (Test-Path -LiteralPath $cfgPath); $i++) {
        Start-Sleep -Seconds 1
    }
    if (-not (Test-Path -LiteralPath $cfgPath -PathType Leaf)) {
        throw "安装向导未在 DATA_DIR 生成 config.yaml：$cfgPath"
    }

    $cfg = [System.IO.File]::ReadAllText($cfgPath)
    $runModePattern = New-Object System.Text.RegularExpressions.Regex("(?m)^[ `t]*run_mode[ `t]*:[^`r`n]*$")
    if ($runModePattern.IsMatch($cfg)) {
        $cfg = $runModePattern.Replace($cfg, "run_mode: simple", 1)
    } else {
        $cfg = "run_mode: simple`n" + $cfg
    }
    Write-Utf8NoBom $cfgPath $cfg

    # Windows 上向导的自动重启不可依赖；只停止本安装目录中的 sub2api.exe。
    Write-Step "重启 Sub2API（进入 simple 模式）"
    Stop-Sub2APIProcesses $SUB2API_EXE
    Start-Sleep -Seconds 2
    $sub2apiProcess = Start-Process -FilePath $SUB2API_EXE `
        -WorkingDirectory $APP -WindowStyle Hidden -PassThru

    $base = "http://127.0.0.1:$ServerPort"
    if (-not (Wait-Http "$base/")) {
        throw "Sub2API 正式服务未在端口 $ServerPort 就绪。"
    }

    # -----------------------------------------------------------------------
    # 6. 管理 API：登录、合规、代理、分组、密钥
    # -----------------------------------------------------------------------
    Write-Step "配置网关（代理 / 分组 / API Key）"
    $login = Invoke-RestMethod -Method Post -Uri "$base/api/v1/auth/login" `
        -ContentType "application/json" `
        -Body (@{ email = $AdminEmail; password = $adminPass } | ConvertTo-Json) `
        -TimeoutSec 30
    $token = $login.data.access_token
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "管理员登录成功响应中没有 access_token。"
    }
    $headers = @{ Authorization = "Bearer $token" }

    Invoke-RestMethod -Method Post -Uri "$base/api/v1/admin/compliance/accept" -Headers $headers `
        -ContentType "application/json" `
        -Body (@{
            phrase = "I have read, understood, and agree to the Sub2API Deployment and Operation Compliance Commitment"
            language = "en"
        } | ConvertTo-Json) -TimeoutSec 30 | Out-Null

    $proxy = Invoke-RestMethod -Method Post -Uri "$base/api/v1/admin/proxies" -Headers $headers `
        -ContentType "application/json" `
        -Body (@{ name = "local-proxy"; protocol = $ProxyProtocol; host = $ProxyHost; port = $ProxyPort } | ConvertTo-Json) `
        -TimeoutSec 30
    $proxyId = $proxy.data.id
    if ($null -eq $proxyId) {
        throw "创建代理的响应中没有代理 ID。"
    }

    $group = Invoke-RestMethod -Method Post -Uri "$base/api/v1/admin/groups" -Headers $headers `
        -ContentType "application/json" `
        -Body (@{ name = "openai"; platform = "openai"; rate_multiplier = 1.0 } | ConvertTo-Json) `
        -TimeoutSec 30
    $groupId = $group.data.id
    if ($null -eq $groupId) {
        throw "创建分组的响应中没有分组 ID。"
    }

    $key = Invoke-RestMethod -Method Post -Uri "$base/api/v1/keys" -Headers $headers `
        -ContentType "application/json" -Body (@{ name = "dsh" } | ConvertTo-Json) -TimeoutSec 30
    $apiKey = $key.data.key
    $keyId = $key.data.id
    if ([string]::IsNullOrWhiteSpace($apiKey) -or $null -eq $keyId) {
        throw "创建 DSH API Key 的响应缺少 key 或 id。"
    }

    Invoke-RestMethod -Method Put -Uri "$base/api/v1/admin/api-keys/$keyId" -Headers $headers `
        -ContentType "application/json" -Body (@{ group_id = $groupId } | ConvertTo-Json) `
        -TimeoutSec 30 | Out-Null

    # -----------------------------------------------------------------------
    # 7. 生成带代理的 OAuth 授权链接（自动化边界到这里）
    # -----------------------------------------------------------------------
    Write-Step "生成 OAuth 授权链接（带代理）"
    $oauth = Invoke-RestMethod -Method Post -Uri "$base/api/v1/admin/openai/generate-auth-url" -Headers $headers `
        -ContentType "application/json" -Body (@{ proxy_id = $proxyId } | ConvertTo-Json) -TimeoutSec 30
    $authUrl = $oauth.data.auth_url
    $oauthSessionId = $oauth.data.session_id
    if ([string]::IsNullOrWhiteSpace($authUrl) -or [string]::IsNullOrWhiteSpace($oauthSessionId)) {
        throw "OAuth 响应缺少 auth_url 或 session_id。"
    }

    # 保存本地凭据（运行时生成；仓库 .gitignore 明确排除 secrets.txt）。
    $secretsPath = Join-Path $InstallDir "secrets.txt"
    $secrets = @"
# Sub2API 本地部署凭据（仅本地保存，勿提交、勿外传）
管理员邮箱 : $AdminEmail
管理员密码 : $adminPass
DSH API Key: $apiKey
PostgreSQL : 127.0.0.1:$PostgresPort / 用户 postgres / 密码 $pgPass / 库 sub2api
Redis      : 127.0.0.1:$RedisPort
Web UI    : http://127.0.0.1:$ServerPort
"@
    Write-Utf8NoBom $secretsPath $secrets

    $completed = $true

    # -----------------------------------------------------------------------
    # 8. 输出结果（不把密码/API Key 回显到终端）
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  本地网关初始化完成。" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  Web UI : http://127.0.0.1:$ServerPort"
    Write-Host "  本地凭据已保存到: $secretsPath"
    Write-Host ""
    Write-Host "  已成功生成带代理的 OAuth 授权链接（约 30 分钟内有效）："
    Write-Host ""
    Write-Host "  $authUrl"
    Write-Host ""
    Write-Warning "脚本的可验证自动化边界到授权链接生成为止。OAuth 登录和账号绑定必须人工完成。"
    Write-Warning "为保持 session/state 连续，请在 Web UI 的“添加 OpenAI 账号”流程中重新生成并完成授权；不要把本脚本链接的回调粘进一个新建的 UI 会话。"
    Write-Host ""
    Write-Host "  完成账号绑定后，按 docs/guide.zh.md 第 4 节配置 DSH。"
    Write-Host "  若使用自定义端口，日常启动命令为："
    Write-Host "  scripts\start-services.cmd `"$InstallDir`" $PostgresPort $RedisPort $ServerPort"
    Write-Host ""
} finally {
    Remove-Item -LiteralPath $PG_PASSWORD_FILE -Force -ErrorAction SilentlyContinue
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue

    if (-not $completed) {
        Write-Warning "部署未完成；正在停止本次脚本启动的组件。不会按进程名清理其他部署。"
        if (Test-Path -LiteralPath $SUB2API_EXE) {
            Stop-Sub2APIProcesses $SUB2API_EXE
        }
        if ($null -ne $redisProcess) {
            try {
                if (-not $redisProcess.HasExited) {
                    Stop-Process -Id $redisProcess.Id -Force -ErrorAction SilentlyContinue
                }
            } catch { }
        }
        if ($pgStarted -and (Test-Path -LiteralPath (Join-Path $PG_DIR "bin\pg_ctl.exe"))) {
            & (Join-Path $PG_DIR "bin\pg_ctl.exe") -D $PGDATA stop -m fast | Out-Null
        }
    }

    Remove-Item Env:DATA_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:ZONEINFO -ErrorAction SilentlyContinue
    Remove-Item Env:SERVER_HOST -ErrorAction SilentlyContinue
    Remove-Item Env:SERVER_PORT -ErrorAction SilentlyContinue
}
