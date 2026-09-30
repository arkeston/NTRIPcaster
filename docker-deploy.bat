@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

REM NTRIP Caster Docker Deployment script (Batch Version)
REM Used in Windows Management in an environment NTRIP Caster 's Docker Container

REM Project Configuration
set "PROJECT_NAME=ntrip-caster"
set "SCRIPT_DIR=%~dp0"
set "ENV_FILE=%SCRIPT_DIR%.env"

REM Color definitions (Windows 10+ Support ANSI Color)
set "RED=[31m"
set "GREEN=[32m"
set "YELLOW=[33m"
set "BLUE=[34m"
set "PURPLE=[35m"
set "CYAN=[36m"
set "NC=[0m"

REM Enable ANSI Color support
reg add HKCU\Console /v VirtualTerminalLevel /t REG_DWORD /d 1 /f >nul 2>&1

REM Get command parameters
set "COMMAND=%1"
if "%COMMAND%"=="" set "COMMAND=help"

REM Log function
:log_info
echo %BLUE%[INFO]%NC% %~1
goto :eof

:log_success
echo %GREEN%[SUCCESS]%NC% %~1
goto :eof

:log_warning
echo %YELLOW%[WARNING]%NC% %~1
goto :eof

:log_error
echo %RED%[ERROR]%NC% %~1
goto :eof

:log_step
echo %PURPLE%[STEP]%NC% %~1
goto :eof

REM Show banner
:show_banner
echo %CYAN%
echo ╔══════════════════════════════════════════════════════════════╗
echo ║                    NTRIP Caster Deployment script                    ║
echo ║                      Batch Version                              ║
echo ╚══════════════════════════════════════════════════════════════╝
echo %NC%
goto :eof

REM Check Docker Environment
:check_docker
call :log_step "Check Docker Environment..."

REM Check Docker
docker --version >nul 2>&1
if errorlevel 1 (
    call :log_error "Docker is not installed, please install it first Docker Desktop"
    echo Download address: https://www.docker.com/products/docker-desktop
    exit /b 1
)

REM Check Docker Compose
docker compose version >nul 2>&1
if errorlevel 1 (
    docker-compose --version >nul 2>&1
    if errorlevel 1 (
        call :log_error "Docker Compose Not installed"
        exit /b 1
    ) else (
        set "DOCKER_COMPOSE_CMD=docker-compose"
    )
) else (
    set "DOCKER_COMPOSE_CMD=docker compose"
)

REM Check Docker Service Status
docker info >nul 2>&1
if errorlevel 1 (
    call :log_error "Docker Service is not running, please start Docker Desktop"
    exit /b 1
)

call :log_success "Docker Environmental inspection completed"
goto :eof

REM Load environment variables
:load_env
if exist "%ENV_FILE%" (
    for /f "usebackq tokens=1,2 delims==" %%a in ("%ENV_FILE%") do (
        if not "%%a"=="" if not "%%a:~0,1"=="#" (
            set "%%a=%%b"
        )
    )
    call :log_info "Environment variables loaded"
) else (
    call :log_warning ".env File does not exist, use default configuration"
)
goto :eof

REM Build Docker Compose Command
:build_compose_cmd
if "%ENVIRONMENT%"=="" set "ENVIRONMENT=development"
if "%PROFILES%"=="" set "PROFILES=dev"

set "COMPOSE_FILES=-f docker-compose.yml"

if "%ENVIRONMENT%"=="production" (
    set "COMPOSE_FILES=%COMPOSE_FILES% -f docker-compose.prod.yml"
) else (
    set "COMPOSE_FILES=%COMPOSE_FILES% -f docker-compose.override.yml"
)

set "PROFILE_ARGS="
for %%p in (%PROFILES:,= %) do (
    set "PROFILE_ARGS=!PROFILE_ARGS! --profile %%p"
)

set "FULL_COMPOSE_CMD=%DOCKER_COMPOSE_CMD% %COMPOSE_FILES% %PROFILE_ARGS%"
goto :eof

REM Execution Docker Compose Command
:run_compose
call :build_compose_cmd
set "FULL_CMD=%FULL_COMPOSE_CMD% %*"
call :log_info "Execute the command: %FULL_CMD%"
%FULL_CMD%
goto :eof

REM Create required directories
:create_directories
call :log_step "Create required directories..."

set "DIRS=data logs secrets nginx\logs redis monitoring\prometheus\rules monitoring\grafana\provisioning\datasources monitoring\grafana\provisioning\dashboards monitoring\grafana\dashboards backup"

for %%d in (%DIRS%) do (
    if not exist "%%d" (
        mkdir "%%d" 2>nul
        call :log_info "Create directory:%%d"
    )
)

call :log_success "Catalog creation complete"
goto :eof

REM Health Check
:health_check
call :log_step "Perform health checks..."

if exist "healthcheck.py" (
    python healthcheck.py
) else (
    call :log_warning "Health check script does not exist, skipping check"
)
goto :eof

REM Show service information
:show_info
call :log_step "Service Information:"

REM Get NativeIP
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /c:"IPv4"') do (
    for /f "tokens=1" %%b in ("%%a") do (
        set "LOCAL_IP=%%b"
        goto :ip_found
    )
)
set "LOCAL_IP=localhost"

:ip_found
echo.
echo 📡 NTRIP Caster Services:
echo    - NTRIP Port: ntrip://%LOCAL_IP%:2101
echo    - Web Admin Interface: http://%LOCAL_IP%:5757

echo %PROFILES% | findstr /c:"monitoring" >nul
if not errorlevel 1 (
    echo.
    echo 📊 Monitoring services:
    echo    - Prometheus: http://%LOCAL_IP%:9090
    echo    - Grafana: http://%LOCAL_IP%:3000 ^(admin/admin123^)
)

if "%ENVIRONMENT%"=="development" (
    echo.
    echo 🛠️ Development tools:
    echo    - Adminer ^(Database management^): http://%LOCAL_IP%:8081
    echo    - Dozzle ^(Log view^): http://%LOCAL_IP%:8082
    echo    - cAdvisor ^(Container monitoring^): http://%LOCAL_IP%:8083
)

echo.
goto :eof

REM Show help
:show_help
echo.
echo NTRIP Caster Docker Deployment script ^(Batch Version^)
echo.
echo Usage: docker-deploy.bat ^<Command^> [Options]
echo.
echo Basic commands:
echo   up              Start the service
echo   down            Stop the service
echo   restart         Restart the service
echo   status          View service status
echo   logs            View service logs
echo   build           Build an image
echo   pull            Pull image
echo   clean           Clean up resources
echo.
echo Administrative Commands:
echo   health          Health Check
echo   info            Show service information
echo   backup          Backup data
echo   create_dirs     Create required directories
echo.
echo Environment variables:
echo   ENVIRONMENT     Deployment environment ^(development^|production^)
echo   PROFILES        Service Profiles ^(dev^|prod^|monitoring^|full^)
echo.
echo Example:
echo   docker-deploy.bat up -d
echo   set ENVIRONMENT=production ^&^& docker-deploy.bat up
echo   set PROFILES=monitoring ^&^& docker-deploy.bat restart
echo.
goto :eof

REM Main function
:main
call :show_banner

REM Check if it is in the correct directory
if not exist "docker-compose.yml" (
    call :log_error "Please refer to the NTRIP Caster Run this script under the project root"
    pause
    exit /b 1
)

REM Check Docker Environment
call :check_docker
if errorlevel 1 exit /b 1

REM Load environment variables
call :load_env

REM Execute the command
if "%COMMAND%"=="help" goto :show_help
if "%COMMAND%"=="check" (
    call :log_success "Docker Environmental inspection completed"
    goto :end
)
if "%COMMAND%"=="create_dirs" (
    call :create_directories
    goto :end
)
if "%COMMAND%"=="up" (
    call :log_step "Start the service..."
    call :run_compose up %2 %3 %4 %5 %6 %7 %8 %9
    if not errorlevel 1 (
        timeout /t 5 /nobreak >nul
        call :health_check
        call :show_info
    )
    goto :end
)
if "%COMMAND%"=="down" (
    call :log_step "Stop the service..."
    call :run_compose down %2 %3 %4 %5 %6 %7 %8 %9
    goto :end
)
if "%COMMAND%"=="restart" (
    call :log_step "Restart the service..."
    call :run_compose restart %2 %3 %4 %5 %6 %7 %8 %9
    timeout /t 5 /nobreak >nul
    call :health_check
    goto :end
)
if "%COMMAND%"=="status" (
    call :run_compose ps
    goto :end
)
if "%COMMAND%"=="logs" (
    call :run_compose logs %2 %3 %4 %5 %6 %7 %8 %9
    goto :end
)
if "%COMMAND%"=="build" (
    call :log_step "Build an image..."
    call :run_compose build %2 %3 %4 %5 %6 %7 %8 %9
    goto :end
)
if "%COMMAND%"=="pull" (
    call :log_step "Pull image..."
    call :run_compose pull %2 %3 %4 %5 %6 %7 %8 %9
    goto :end
)
if "%COMMAND%"=="clean" (
    call :log_step "Clean up resources..."
    call :run_compose down --volumes --remove-orphans
    docker system prune -f
    goto :end
)
if "%COMMAND%"=="health" (
    call :health_check
    goto :end
)
if "%COMMAND%"=="info" (
    call :show_info
    goto :end
)
if "%COMMAND%"=="backup" (
    call :log_step "Backup data..."
    if not exist "backup" mkdir "backup"
    for /f "tokens=2 delims==" %%a in ('wmic OS Get localdatetime /value') do set "dt=%%a"
    set "timestamp=!dt:~0,8!_!dt:~8,6!"
    if exist "data" (
        powershell -Command "Compress-Archive -Path 'data' -DestinationPath 'backup\ntrip_backup_!timestamp!.zip' -Force"
        call :log_success "Data backup completed: backup\ntrip_backup_!timestamp!.zip"
    ) else (
        call :log_warning "Data directory does not exist"
    )
    goto :end
)

REM Unknown command
call :log_error "Unknown command: %COMMAND%"
call :show_help

:end
goto :eof

REM Script portal
call :main %*