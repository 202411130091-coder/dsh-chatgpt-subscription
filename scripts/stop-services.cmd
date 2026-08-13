@echo off
rem Usage: stop-services.cmd [install-dir] [pg-port] [redis-port]
set "ROOT=%~1"
if not defined ROOT set "ROOT=%~dp0..\runtime"
set "PGPORT=%~2"
if not defined PGPORT set "PGPORT=5432"
set "REDISPORT=%~3"
if not defined REDISPORT set "REDISPORT=6379"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0services.ps1" -Action Stop -InstallDir "%ROOT%" -PostgresPort %PGPORT% -RedisPort %REDISPORT%
exit /b %ERRORLEVEL%
