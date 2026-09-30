# NTRIP Caster Docker Deployment script (PowerShellVersion)
# Used in Windows Management in an environment NTRIP Caster 's Docker Container

param(
    [Parameter(Position=0)]
    [string]$Command = "help",
    
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Args
)

# Set error handling
$ErrorActionPreference = "Stop"

# Project Configuration
$PROJECT_NAME = "ntrip-caster"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$ENV_FILE = Join-Path $SCRIPT_DIR ".env"
$ENV_EXAMPLE = Join-Path $SCRIPT_DIR ".env.example"

# Color definitions
$Colors = @{
    Red = "Red"
    Green = "Green"
    Yellow = "Yellow"
    Blue = "Blue"
    Magenta = "Magenta"
    Cyan = "Cyan"
    White = "White"
}

# Log function
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    switch ($Level) {
        "Info" { Write-Host "[$timestamp] [INFO] $Message" -ForegroundColor $Colors.Blue }
        "Success" { Write-Host "[$timestamp] [SUCCESS] $Message" -ForegroundColor $Colors.Green }
        "Warning" { Write-Host "[$timestamp] [WARNING] $Message" -ForegroundColor $Colors.Yellow }
        "Error" { Write-Host "[$timestamp] [ERROR] $Message" -ForegroundColor $Colors.Red }
        "Step" { Write-Host "[$timestamp] [STEP] $Message" -ForegroundColor $Colors.Magenta }
    }
}

# Show banner
function Show-Banner {
    Write-Host "" -ForegroundColor $Colors.Cyan
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor $Colors.Cyan
    Write-Host "║                    NTRIP Caster Deployment script                    ║" -ForegroundColor $Colors.Cyan
    Write-Host "║                     PowerShell Version                         ║" -ForegroundColor $Colors.Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor $Colors.Cyan
    Write-Host "" -ForegroundColor $Colors.Cyan
}

# Check Docker Environment
function Test-DockerEnvironment {
    Write-Log "Check Docker Environment..." "Step"
    
    # Check Docker
    try {
        $dockerVersion = docker --version
        Write-Log "Docker Version: $dockerVersion" "Info"
    }
    catch {
        Write-Log "Docker Not installed or not started" "Error"
        Write-Log "Please install Docker Desktop: https://www.docker.com/products/docker-desktop" "Info"
        exit 1
    }
    
    # Check Docker Compose
    try {
        $composeVersion = docker compose version
        Write-Log "Docker Compose Version: $composeVersion" "Info"
        $script:DOCKER_COMPOSE_CMD = "docker compose"
    }
    catch {
        try {
            $composeVersion = docker-compose --version
            Write-Log "Docker Compose Version: $composeVersion" "Info"
            $script:DOCKER_COMPOSE_CMD = "docker-compose"
        }
        catch {
            Write-Log "Docker Compose Not installed" "Error"
            exit 1
        }
    }
    
    # Check Docker Daemon
    try {
        docker info | Out-Null
        Write-Log "Docker The daemon is running normally" "Success"
    }
    catch {
        Write-Log "Docker The daemon is not running, please start Docker Desktop" "Error"
        exit 1
    }
}

# Load environment variables
function Import-EnvironmentVariables {
    if (Test-Path $ENV_FILE) {
        Get-Content $ENV_FILE | ForEach-Object {
            if ($_ -match '^([^#][^=]+)=(.*)$') {
                [Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
            }
        }
        Write-Log "Environment variables loaded" "Info"
    } else {
        Write-Log ".env File does not exist, use default configuration" "Warning"
    }
}

# Build Docker Compose Command
function Build-ComposeCommand {
    param([string[]]$ComposeArgs)
    
    $environment = $env:ENVIRONMENT
    if (-not $environment) { $environment = "development" }
    
    $profiles = $env:PROFILES
    if (-not $profiles) { $profiles = "dev" }
    
    $composeFiles = @("-f", "docker-compose.yml")
    
    if ($environment -eq "production") {
        $composeFiles += @("-f", "docker-compose.prod.yml")
    } else {
        $composeFiles += @("-f", "docker-compose.override.yml")
    }
    
    $profileArgs = @()
    if ($profiles) {
        $profileList = $profiles -split ","
        foreach ($profile in $profileList) {
            $profileArgs += @("--profile", $profile.Trim())
        }
    }
    
    $fullCommand = @($script:DOCKER_COMPOSE_CMD) + $composeFiles + $profileArgs + $ComposeArgs
    return $fullCommand -join " "
}

# Execution Docker Compose Command
function Invoke-ComposeCommand {
    param([string[]]$ComposeArgs)
    
    $command = Build-ComposeCommand $ComposeArgs
    Write-Log "Execute the command: $command" "Info"
    
    try {
        Invoke-Expression $command
        return $LASTEXITCODE
    }
    catch {
        Write-Log "Command execution failed: $_" "Error"
        return 1
    }
}

# Create required directories
function New-RequiredDirectories {
    Write-Log "Create required directories..." "Step"
    
    $directories = @(
        "data",
        "logs",
        "secrets",
        "nginx/logs",
        "redis",
        "monitoring/prometheus/rules",
        "monitoring/grafana/provisioning/datasources",
        "monitoring/grafana/provisioning/dashboards",
        "monitoring/grafana/dashboards",
        "backup"
    )
    
    foreach ($dir in $directories) {
        $fullPath = Join-Path $SCRIPT_DIR $dir
        if (-not (Test-Path $fullPath)) {
            New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
            Write-Log "Create directory:$dir" "Info"
        }
    }
    
    # Set permissions (Windows equivalent operations under)
    try {
        $dataPath = Join-Path $SCRIPT_DIR "data"
        $logsPath = Join-Path $SCRIPT_DIR "logs"
        
        # Ensure the current user has full control
        icacls $dataPath /grant "${env:USERNAME}:(OI)(CI)F" /T | Out-Null
        icacls $logsPath /grant "${env:USERNAME}:(OI)(CI)F" /T | Out-Null
        
        Write-Log "Directory permissions set complete" "Success"
    }
    catch {
        Write-Log "Permission setting failed without affecting usage" "Warning"
    }
}

# Create environment files
function New-EnvironmentFile {
    Write-Log "Create an environment profile..." "Step"
    
    if (-not (Test-Path $ENV_FILE)) {
        if (Test-Path $ENV_EXAMPLE) {
            Copy-Item $ENV_EXAMPLE $ENV_FILE
            Write-Log "Created .env Files" "Success"
        } else {
            Write-Log ".env.example File does not exist" "Error"
            return
        }
    }
    
    # Update environment variables
    $content = Get-Content $ENV_FILE
    $environment = $env:ENVIRONMENT
    if (-not $environment) { $environment = "development" }
    
    $content = $content -replace '^ENVIRONMENT=.*', "ENVIRONMENT=$environment"
    $content = $content -replace '^PROJECT_NAME=.*', "PROJECT_NAME=$PROJECT_NAME"
    $content = $content -replace '^TZ=.*', "TZ=Asia/Shanghai"
    
    Set-Content -Path $ENV_FILE -Value $content
    Write-Log "Environment profile update complete" "Success"
}

# Health Check
function Test-ServiceHealth {
    Write-Log "Perform health checks..." "Step"
    
    try {
        if (Test-Path "healthcheck.py") {
            python healthcheck.py
        } else {
            Write-Log "Health check script does not exist, skipping check" "Warning"
        }
    }
    catch {
        Write-Log "Health check failed:$_" "Error"
    }
}

# Show service information
function Show-ServiceInfo {
    Write-Log "Service Information:" "Step"
    
    # Get NativeIP
    $localIP = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "Ethernet*" | Select-Object -First 1).IPAddress
    if (-not $localIP) {
        $localIP = "localhost"
    }
    
    Write-Host ""
    Write-Host "📡 NTRIP Caster Services:" -ForegroundColor $Colors.Cyan
    Write-Host "   - NTRIP Port: ntrip://${localIP}:2101" -ForegroundColor $Colors.White
    Write-Host "   - Web Admin Interface: http://${localIP}:5757" -ForegroundColor $Colors.White
    
    $profiles = $env:PROFILES
    if ($profiles -and ($profiles -match "monitoring" -or $profiles -match "full")) {
        Write-Host ""
        Write-Host "📊 Monitoring services:" -ForegroundColor $Colors.Cyan
        Write-Host "   - Prometheus: http://${localIP}:9090" -ForegroundColor $Colors.White
        Write-Host "   - Grafana: http://${localIP}:3000 (admin/admin123)" -ForegroundColor $Colors.White
    }
    
    $environment = $env:ENVIRONMENT
    if ($environment -eq "development") {
        Write-Host ""
        Write-Host "🛠️ Development tools:" -ForegroundColor $Colors.Cyan
        Write-Host "   - Adminer (Database management): http://${localIP}:8081" -ForegroundColor $Colors.White
        Write-Host "   - Dozzle (Log view): http://${localIP}:8082" -ForegroundColor $Colors.White
        Write-Host "   - cAdvisor (Container monitoring): http://${localIP}:8083" -ForegroundColor $Colors.White
    }
    
    Write-Host ""
}

# Show help
function Show-Help {
    Write-Host ""
    Write-Host "NTRIP Caster Docker Deployment script (PowerShellVersion)" -ForegroundColor $Colors.Cyan
    Write-Host ""
    Write-Host "Usage: .\docker-deploy.ps1 <Command> [Options]" -ForegroundColor $Colors.White
    Write-Host ""
    Write-Host "Basic commands:" -ForegroundColor $Colors.Yellow
    Write-Host "  up              Start the service" -ForegroundColor $Colors.White
    Write-Host "  down            Stop the service" -ForegroundColor $Colors.White
    Write-Host "  restart         Restart the service" -ForegroundColor $Colors.White
    Write-Host "  status          View service status" -ForegroundColor $Colors.White
    Write-Host "  logs            View service logs" -ForegroundColor $Colors.White
    Write-Host "  build           Build an image" -ForegroundColor $Colors.White
    Write-Host "  pull            Pull image" -ForegroundColor $Colors.White
    Write-Host "  clean           Clean up resources" -ForegroundColor $Colors.White
    Write-Host ""
    Write-Host "Administrative Commands:" -ForegroundColor $Colors.Yellow
    Write-Host "  health          Health Check" -ForegroundColor $Colors.White
    Write-Host "  info            Show service information" -ForegroundColor $Colors.White
    Write-Host "  backup          Backup data" -ForegroundColor $Colors.White
    Write-Host "  restore         Recover data" -ForegroundColor $Colors.White
    Write-Host "  update          Update service" -ForegroundColor $Colors.White
    Write-Host ""
    Write-Host "Environment variables:" -ForegroundColor $Colors.Yellow
    Write-Host "  ENVIRONMENT     Deployment environment (development|production)" -ForegroundColor $Colors.White
    Write-Host "  PROFILES        Service Profiles (dev|prod|monitoring|full)" -ForegroundColor $Colors.White
    Write-Host ""
    Write-Host "Example:" -ForegroundColor $Colors.Yellow
    Write-Host "  .\docker-deploy.ps1 up -d" -ForegroundColor $Colors.White
    Write-Host "  `$env:ENVIRONMENT='production'; .\docker-deploy.ps1 up" -ForegroundColor $Colors.White
    Write-Host "  `$env:PROFILES='monitoring'; .\docker-deploy.ps1 restart" -ForegroundColor $Colors.White
    Write-Host ""
}

# Main function
function Main {
    param([string]$Command, [string[]]$Args)
    
    Show-Banner
    
    # Check if it is in the correct directory
    if (-not (Test-Path "docker-compose.yml")) {
        Write-Log "Please refer to the NTRIP Caster Run this script under the project root" "Error"
        exit 1
    }
    
    # Check Docker Environment
    Test-DockerEnvironment
    
    # Load environment variables
    Import-EnvironmentVariables
    
    switch ($Command.ToLower()) {
        "help" {
            Show-Help
        }
        "check" {
            Write-Log "Docker Environmental inspection completed" "Success"
        }
        "create_directories" {
            New-RequiredDirectories
        }
        "create_env" {
            New-EnvironmentFile
        }
        "up" {
            Write-Log "Start the service..." "Step"
            $exitCode = Invoke-ComposeCommand (@("up") + $Args)
            if ($exitCode -eq 0) {
                Start-Sleep -Seconds 5
                Test-ServiceHealth
                Show-ServiceInfo
            }
        }
        "down" {
            Write-Log "Stop the service..." "Step"
            Invoke-ComposeCommand (@("down") + $Args)
        }
        "restart" {
            Write-Log "Restart the service..." "Step"
            Invoke-ComposeCommand (@("restart") + $Args)
            Start-Sleep -Seconds 5
            Test-ServiceHealth
        }
        "status" {
            Invoke-ComposeCommand @("ps")
        }
        "logs" {
            Invoke-ComposeCommand (@("logs") + $Args)
        }
        "build" {
            Write-Log "Build an image..." "Step"
            Invoke-ComposeCommand (@("build") + $Args)
        }
        "pull" {
            Write-Log "Pull image..." "Step"
            Invoke-ComposeCommand (@("pull") + $Args)
        }
        "clean" {
            Write-Log "Clean up resources..." "Step"
            Invoke-ComposeCommand @("down", "--volumes", "--remove-orphans")
            docker system prune -f
        }
        "health" {
            Test-ServiceHealth
        }
        "info" {
            Show-ServiceInfo
        }
        "backup" {
            Write-Log "Backup data..." "Step"
            $backupDir = Join-Path $SCRIPT_DIR "backup"
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $backupFile = Join-Path $backupDir "ntrip_backup_$timestamp.zip"
            
            if (-not (Test-Path $backupDir)) {
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            }
            
            $dataDir = Join-Path $SCRIPT_DIR "data"
            if (Test-Path $dataDir) {
                Compress-Archive -Path $dataDir -DestinationPath $backupFile -Force
                Write-Log "Data backup completed: $backupFile" "Success"
            } else {
                Write-Log "Data directory does not exist" "Warning"
            }
        }
        "restore" {
            Write-Log "Recover data..." "Step"
            if ($Args.Count -gt 0) {
                $backupFile = $Args[0]
                if (Test-Path $backupFile) {
                    $dataDir = Join-Path $SCRIPT_DIR "data"
                    Expand-Archive -Path $backupFile -DestinationPath $dataDir -Force
                    Write-Log "Data recovery complete" "Success"
                } else {
                    Write-Log "Backup file does not exist: $backupFile" "Error"
                }
            } else {
                Write-Log "Please specify the backup file path" "Error"
            }
        }
        "update" {
            Write-Log "Update service..." "Step"
            Invoke-ComposeCommand @("pull")
            Invoke-ComposeCommand @("up", "-d")
            Write-Log "Service update complete" "Success"
        }
        default {
            Write-Log "Unknown command: $Command" "Error"
            Show-Help
            exit 1
        }
    }
}

# Script portal
if ($MyInvocation.InvocationName -ne '.') {
    Main $Command $Args
}