@echo off
rem Usage: start-services.cmd [install-dir] [pg-port] [redis-port] [web-port]
set "ROOT=%~1"
if not defined ROOT set "ROOT=%~dp0..\runtime"
set "PGPORT=%~2"
if not defined PGPORT set "PGPORT=5432"
set "REDISPORT=%~3"
if not defined REDISPORT set "REDISPORT=6379"
set "SERVERPORT=%~4"
if not defined SERVERPORT set "SERVERPORT=8080"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0services.ps1" -Action Start -InstallDir "%ROOT%" -PostgresPort %PGPORT% -RedisPort %REDISPORT% -ServerPort %SERVERPORT%
exit /b %ERRORLEVEL%
