[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Start", "Stop")]
    [string]$Action,
    [Parameter(Mandatory = $true)]
    [string]$InstallDir,
    [int]$PostgresPort = 5432,
    [int]$RedisPort = 6379,
    [int]$ServerPort = 8080
)

$ErrorActionPreference = "Stop"
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$pgDir = Join-Path $InstallDir "pgsql"
$pgData = Join-Path $InstallDir "pgdata"
$redisDir = Join-Path $InstallDir "redis"
$appDir = Join-Path $InstallDir "app"
$appExe = Join-Path $appDir "sub2api.exe"
$redisExe = Join-Path $redisDir "redis-server.exe"
$redisPidFile = Join-Path $redisDir "redis.pid"

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

function Get-ProcessAtPath([string]$Name, [string]$ExecutablePath) {
    $target = [System.IO.Path]::GetFullPath($ExecutablePath)
    return @(Get-Process -Name $Name -ErrorAction SilentlyContinue | Where-Object {
        $candidate = $null
        try { $candidate = $_.Path } catch { }
        $candidate -and ([System.IO.Path]::GetFullPath($candidate) -ieq $target)
    })
}

function Stop-ProcessAtPath([string]$Name, [string]$ExecutablePath) {
    Get-ProcessAtPath $Name $ExecutablePath | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Assert-PortFree([string]$Name, [int]$Port) {
    if (Test-PortInUse $Port) {
        throw "$Name 端口 $Port 已被其他进程占用；为避免接入或停止另一套部署，本脚本拒绝继续。"
    }
}

if ($Action -eq "Start") {
    $required = @(
        (Join-Path $pgDir "bin\pg_ctl.exe"),
        (Join-Path $pgDir "bin\pg_isready.exe"),
        $redisExe,
        (Join-Path $redisDir "redis-cli.exe"),
        $appExe,
        (Join-Path $appDir "zoneinfo.zip"),
        (Join-Path $appDir "data\config.yaml")
    )
    foreach ($file in $required) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "安装不完整，缺少：$file"
        }
    }

    Write-Host "[1/3] Redis"
    $ownedRedis = $false
    if (Test-Path -LiteralPath $redisPidFile -PathType Leaf) {
        $pidText = ([System.IO.File]::ReadAllText($redisPidFile)).Trim()
        if ($pidText -match '^\d+$') {
            try {
                $process = Get-Process -Id ([int]$pidText) -ErrorAction Stop
                $ownedRedis = ([System.IO.Path]::GetFullPath($process.Path) -ieq [System.IO.Path]::GetFullPath($redisExe))
            } catch { }
        }
    }
    if ($ownedRedis) {
        Write-Host "  本安装目录的 Redis 已运行。"
    } else {
        Assert-PortFree "Redis" $RedisPort
        $redisLog = Join-Path $redisDir "redis.log"
        $arguments = "--port $RedisPort --bind 127.0.0.1 --save 900 1 --save 300 10 --logfile `"$redisLog`" --dir `"$redisDir`" --pidfile `"$redisPidFile`""
        $redisProcess = Start-Process -FilePath $redisExe -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $ready = $false
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 1
            $ping = & (Join-Path $redisDir "redis-cli.exe") -h 127.0.0.1 -p $RedisPort ping 2>&1
            if ($ping -eq "PONG") { $ready = $true; break }
            if ($redisProcess.HasExited) { break }
        }
        if (-not $ready) { throw "Redis 启动失败。" }
    }

    Write-Host "[2/3] PostgreSQL"
    $pgCtl = Join-Path $pgDir "bin\pg_ctl.exe"
    & $pgCtl -D $pgData status | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  本安装目录的 PostgreSQL 已运行。"
    } else {
        Assert-PortFree "PostgreSQL" $PostgresPort
        & $pgCtl -D $pgData -l (Join-Path $pgData "pg.log") start -o "-p $PostgresPort" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "PostgreSQL 启动失败。" }
        $ready = $false
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 1
            & (Join-Path $pgDir "bin\pg_isready.exe") -h 127.0.0.1 -p $PostgresPort | Out-Null
            if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        }
        if (-not $ready) { throw "PostgreSQL 未就绪。" }
    }

    Write-Host "[3/3] Sub2API"
    if ((Get-ProcessAtPath "sub2api" $appExe).Count -gt 0) {
        Write-Host "  本安装目录的 Sub2API 已运行。"
    } else {
        Assert-PortFree "Sub2API" $ServerPort
        $env:ZONEINFO = Join-Path $appDir "zoneinfo.zip"
        $env:DATA_DIR = Join-Path $appDir "data"
        $env:SERVER_HOST = "127.0.0.1"
        $env:SERVER_PORT = [string]$ServerPort
        Start-Process -FilePath $appExe -WorkingDirectory $appDir -WindowStyle Hidden | Out-Null
    }

    Write-Host "Web UI: http://127.0.0.1:$ServerPort"
    Write-Host "API:    http://127.0.0.1:$ServerPort/v1"
    exit 0
}

Write-Host "[1/3] stopping this Sub2API installation"
if (Test-Path -LiteralPath $appExe -PathType Leaf) {
    Stop-ProcessAtPath "sub2api" $appExe
}

Write-Host "[2/3] stopping this PostgreSQL data directory"
$pgCtl = Join-Path $pgDir "bin\pg_ctl.exe"
if (Test-Path -LiteralPath $pgCtl -PathType Leaf) {
    & $pgCtl -D $pgData stop -m fast | Out-Null
}

Write-Host "[3/3] stopping this Redis process"
if (Test-Path -LiteralPath $redisPidFile -PathType Leaf) {
    $pidText = ([System.IO.File]::ReadAllText($redisPidFile)).Trim()
    if ($pidText -match '^\d+$') {
        try {
            $process = Get-Process -Id ([int]$pidText) -ErrorAction Stop
            if ([System.IO.Path]::GetFullPath($process.Path) -ieq [System.IO.Path]::GetFullPath($redisExe)) {
                Stop-Process -Id $process.Id -Force
            } else {
                Write-Warning "redis.pid 指向其他程序，未停止。"
            }
        } catch { }
    }
} else {
    Write-Warning "没有 redis.pid；为避免误停另一套部署，未按端口发送 shutdown。"
}
