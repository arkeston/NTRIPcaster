#!/bin/bash
# NTRIP Caster DockerDeployment script v2.1.8
# Full deployment solution supporting development, testing, production environment

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration variables
IMAGE_NAME="ntrip-caster"
IMAGE_TAG="2.1.8"
CONTAINER_NAME="ntrip-caster"
NETWORK_NAME="ntrip-network"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVIRONMENT="development"
PROFILES=""
COMPOSE_FILES="-f docker-compose.yml"

# Function definition
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "${PURPLE}[DEBUG]${NC} $1"
    fi
}

log_success() {
    echo -e "${CYAN}[SUCCESS]${NC} $1"
}

# Show banner
show_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
    ██████╗ ██████╗ ████████╗██╗  ██╗
    ╚════██╗██╔══██╗╚══██╔══╝██║ ██╔╝
     █████╔╝██████╔╝   ██║   █████╔╝ 
    ██╔═══╝ ██╔══██╗   ██║   ██╔═██╗ 
    ███████╗██║  ██║   ██║   ██║  ██╗
    ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝
EOF
    echo -e "${NC}"
    echo -e "${GREEN}    NTRIP Caster Docker Deployment script v2.1.8${NC}"
    echo -e "${BLUE}    Environment: ${ENVIRONMENT} | Profile: ${COMPOSE_FILES}${NC}"
    echo
}

# Resolve command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --env|--environment)
                ENVIRONMENT="$2"
                shift 2
                ;;
            --profile)
                PROFILES="--profile $2 $PROFILES"
                shift 2
                ;;
            --debug)
                DEBUG="true"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                break
                ;;
        esac
    done
    
    # Based on environment settingscomposeFiles
    case "$ENVIRONMENT" in
        "production"|"prod")
            COMPOSE_FILES="-f docker-compose.yml -f docker-compose.prod.yml"
            ENVIRONMENT="production"
            ;;
        "development"|"dev")
            COMPOSE_FILES="-f docker-compose.yml -f docker-compose.override.yml"
            ENVIRONMENT="development"
            ;;
        "testing"|"test")
            COMPOSE_FILES="-f docker-compose.yml"
            ENVIRONMENT="testing"
            ;;
        *)
            log_warn "Unknown environment: $ENVIRONMENT, using default development environment"
            ENVIRONMENT="development"
            COMPOSE_FILES="-f docker-compose.yml -f docker-compose.override.yml"
            ;;
    esac
    
    log_debug "Environment: $ENVIRONMENT"
    log_debug "ComposeFiles: $COMPOSE_FILES"
    log_debug "Profiles: $PROFILES"
}

# CheckDockerIs it installed?
check_docker() {
    log_step "CheckDockerEnvironment..."
    
    if ! command -v docker &> /dev/null; then
        log_error "Dockeris not installed, please install it firstDocker"
        echo "Install command:"
        echo "  Ubuntu/Debian: curl -fsSL https://get.docker.com | sh"
        echo "  CentOS/RHEL: curl -fsSL https://get.docker.com | sh"
        echo "  macOS: brew install docker"
        echo "  Windows: DownloadDocker Desktop"
        exit 1
    fi
    
    # CheckDocker Compose (Priority usedocker composePlugin)
    if docker compose version &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
        log_debug "UseDocker ComposePlugin"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
        log_debug "Use standalonedocker-compose"
    else
        log_error "Docker Composeis not installed, please install it firstDocker Compose"
        echo "Install command:"
        echo "  Plug-in method: docker plugin install docker/compose"
        echo "  Standalone installation: sudo curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o /usr/local/bin/docker-compose"
        echo "           sudo chmod +x /usr/local/bin/docker-compose"
        exit 1
    fi
    
    # CheckDockerWhether the daemon is running
    if ! docker info &> /dev/null; then
        log_error "DockerThe daemon is not running, please startDockerServices"
        echo "Start command:"
        echo "  systemd: sudo systemctl start docker"
        echo "  macOS/Windows: StartDocker Desktop"
        exit 1
    fi
    
    # Show version information
    local docker_version=$(docker --version | cut -d' ' -f3 | cut -d',' -f1)
    local compose_version=$($DOCKER_COMPOSE_CMD version --short 2>/dev/null || echo "unknown")
    
    log_info "DockerEnvironmental inspection passed"
    log_debug "DockerVersion: $docker_version"
    log_debug "ComposeVersion: $compose_version"
}

# Create necessary directories
create_directories() {
    log_step "Create the necessary directory structure..."
    
    # Base Directory
    local dirs=(
        "data"
        "logs"
        "config"
        "secrets"
        "nginx/conf.d"
        "nginx/ssl"
        "nginx/logs"
        "redis"
        "monitoring/prometheus/rules"
        "monitoring/grafana/provisioning/datasources"
        "monitoring/grafana/provisioning/dashboards"
        "monitoring/grafana/dashboards"
        "backup"
    )
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log_debug "Create directory:$dir"
        fi
    done
    
    # Set directory permissions
    chmod 755 data logs config
    chmod 700 secrets
    
    # Copy profile
    if [[ ! -f "config/config.ini" && -f "config.ini" ]]; then
        cp config.ini config/config.ini
        log_info "Profile copied to config/config.ini"
    fi
    
    # Create an environment profile
    if [[ ! -f ".env.${ENVIRONMENT}" ]]; then
        create_env_file
    fi
    
    log_success "Directory structure creation completed"
}

# Create an environment profile
create_env_file() {
    log_step "Create an environment profile..."
    
    cat > ".env.${ENVIRONMENT}" << EOF
# ${ENVIRONMENT} Environment configuration
COMPOSE_PROJECT_NAME=ntrip-${ENVIRONMENT}
COMPOSE_FILE=${COMPOSE_FILES// /,}
ENVIRONMENT=${ENVIRONMENT}

# App Configuration
NTRIP_HOST=0.0.0.0
NTRIP_PORT=2101
WEB_HOST=0.0.0.0
WEB_PORT=5757

# Log configuration
LOG_LEVEL=INFO
LOG_FORMAT=json

# Database configuration
DATABASE_PATH=/app/data/2rtk.db

# Time zone configuration
TZ=Asia/Shanghai
EOF
    
    log_info "Environment profile created: .env.${ENVIRONMENT}"
}

# CreateNginxConfiguration
create_nginx_config() {
    log_step "CreateNginxConfiguration..."
    
    cat > nginx/nginx.conf << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    
    access_log /var/log/nginx/access.log main;
    
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        image/svg+xml;
    
    include /etc/nginx/conf.d/*.conf;
}
EOF

    cat > nginx/conf.d/ntrip.conf << 'EOF'
server {
    listen 80;
    server_name _;
    
    # Safety header
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
    
    # Web Admin Interface
    location / {
        proxy_pass http://ntrip-caster:5757;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocketSupport
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }
    
    # Health Check
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}

# NTRIPService proxy (optional)
stream {
    upstream ntrip_backend {
        server ntrip-caster:2101;
    }
    
    server {
        listen 2101;
        proxy_pass ntrip_backend;
        proxy_timeout 1s;
        proxy_responses 1;
        error_log /var/log/nginx/ntrip.log;
    }
}
EOF

    log_info "NginxConfiguration creation complete"
}

# Create monitoring configuration
create_monitoring_config() {
    log_step "Create monitoring configuration..."
    
    cat > monitoring/prometheus.yml << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  # - "first_rules.yml"
  # - "second_rules.yml"

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
  
  - job_name: 'ntrip-caster'
    static_configs:
      - targets: ['ntrip-caster:5757']
    metrics_path: '/metrics'
    scrape_interval: 30s
EOF

    mkdir -p monitoring/grafana/provisioning/datasources
    cat > monitoring/grafana/provisioning/datasources/prometheus.yml << 'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF

    log_info "Monitoring configuration creation completed"
}

# Build an image
build_image() {
    log_step "BuildDockerMirror..."
    
    if [ -f "Dockerfile" ]; then
        docker build -t $IMAGE_NAME:$IMAGE_TAG .
        docker tag $IMAGE_NAME:$IMAGE_TAG $IMAGE_NAME:latest
        log_success "Mirror build complete: $IMAGE_NAME:$IMAGE_TAG"
    else
        log_info "not foundDockerfile, usingdocker-composeBuild..."
        $DOCKER_COMPOSE_CMD $COMPOSE_FILES build
        log_success "Mirror build complete"
    fi
}

# Start the service
start_services() {
    log_step "Start the service..."
    
    # Basic Services
    $DOCKER_COMPOSE_CMD $COMPOSE_FILES $PROFILES up -d ntrip-caster
    
    # Waiting for service to start
    log_info "Waiting for service to start..."
    sleep 10
    
    # Check service status
    if $DOCKER_COMPOSE_CMD $COMPOSE_FILES ps | grep -q "Up"; then
        log_info "NTRIP CasterService started successfully"
        check_health
    else
        log_error "Service start failed"
        $DOCKER_COMPOSE_CMD $COMPOSE_FILES logs ntrip-caster
        exit 1
    fi
}

# Start full service (incl.Nginxand monitoring)
start_full_services() {
    log_step "Start the full service stack..."
    
    $DOCKER_COMPOSE_CMD $COMPOSE_FILES --profile nginx --profile monitoring up -d
    
    # Waiting for service to start
    log_info "Waiting for service to start..."
    sleep 15
    
    check_health
    show_info
    log_success "Full service stack startup complete"
}

# Stop the service
stop_services() {
    log_step "Stop the service..."
    
    $DOCKER_COMPOSE_CMD $COMPOSE_FILES $PROFILES down
    
    log_success "Service stopped"
}

# Clean up resources
clean_resources() {
    log_step "CleanupDockerResources..."
    
    # Stopping and deleting containers
    $DOCKER_COMPOSE_CMD $COMPOSE_FILES down -v --remove-orphans
    
    # Delete Mirror
    docker rmi $IMAGE_NAME:$IMAGE_TAG $IMAGE_NAME:latest 2>/dev/null || true
    
    # Clean up unused resources
    docker system prune -f
    docker volume prune -f
    
    log_success "Resource cleanup complete"
}

# View Log
view_logs() {
    $DOCKER_COMPOSE_CMD $COMPOSE_FILES logs -f ntrip-caster
}

# Check status
view_status() {
    echo "=== Docker ComposeStatus ==="
    $DOCKER_COMPOSE_CMD $COMPOSE_FILES ps
    echo
    echo "=== Container Resource Usage ==="
    docker stats --no-stream
    echo
    echo "=== Service Health Status ==="
    if docker ps --format "table {{.Names}}\t{{.Status}}" | grep -q "ntrip-caster.*Up"; then
        if $DOCKER_COMPOSE_CMD $COMPOSE_FILES exec -T ntrip-caster curl -f http://localhost:5757/ >/dev/null 2>&1; then
            echo "✓ Web Service OK"
        else
            echo "✗ WebService exception"
        fi
    else
        echo "✗ NTRIP CasterService is not running"
    fi
}

# Show help
show_help() {
    echo "NTRIP Caster DockerDeployment script v2.1.8"
    echo
    echo "Usage: $0 [Options] [Command] [Parameters]"
    echo
    echo "Options:"
    echo "  --env, --environment ENV  Designated environment (development|testing|production)"
    echo "  --profile PROFILE         Enable specifiedcompose profile"
    echo "  --debug                   Enable debug mode"
    echo "  --help, -h               Show help"
    echo
    echo "Command:"
    echo "  build     - BuildDockerMirror"
    echo "  start     - Start basic services"
    echo "  full      - Start full service (incl.Nginxand monitoring)"
    echo "  stop      - Stop the service"
    echo "  restart   - Restart the service"
    echo "  logs      - View Log"
    echo "  status    - Check status"
    echo "  health    - Check service health"
    echo "  info      - Show service information"
    echo "  backup    - Backup data"
    echo "  restore   - Recover data (The backup path needs to be specified)"
    echo "  update    - Update service"
    echo "  clean     - Clean up resources"
    echo "  help      - Show help"
    echo
    echo "Example:"
    echo "  $0 --env production build && $0 start    # Production build and launch"
    echo "  $0 --profile nginx --profile monitoring full  # Start the full service stack"
    echo "  $0 --debug logs                          # Debug Mode View Log"
    echo "  $0 backup                                # Backup data"
    echo "  $0 restore ./backup/20231201_120000     # Recover data"
    echo
    echo "Environmental description:"
    echo "  development - Development environment, including debugging tools"
    echo "  testing     - Test environment, basic configuration"
    echo "  production  - Production environment, optimized configuration"
}

# Check service health
check_health() {
    log_info "Check service health..."
    
    local services=("ntrip-caster" "ntrip-nginx" "ntrip-prometheus" "ntrip-grafana")
    local healthy=true
    
    for service in "${services[@]}"; do
        if $DOCKER_COMPOSE_CMD $COMPOSE_FILES $PROFILES ps --format "table {{.Service}}\t{{.Status}}" | grep -q "$service.*healthy"; then
            log_success "✓ $service: Health"
        elif $DOCKER_COMPOSE_CMD $COMPOSE_FILES $PROFILES ps --format "table {{.Service}}\t{{.Status}}" | grep -q "$service.*Up"; then
            log_warn "⚠ $service: Running but failed health check"
            healthy=false
        else
            log_error "✗ $service: Not running"
            healthy=false
        fi
    done
    
    if [ "$healthy" = true ]; then
        log_success "All services are up and running"
    else
        log_warn "Some services have problems, please check the logs"
    fi
}

# Show service information
show_info() {
    log_info "NTRIP Caster Service Information:"
    echo
    echo "${BLUE}Environment:${NC} $ENVIRONMENT"
    echo "${BLUE}Profile:${NC} $COMPOSE_FILES"
    echo "${BLUE}Project name:${NC} ${CONTAINER_NAME}"
    echo
    echo "${BLUE}Service endpoint:${NC}"
    echo "  • NTRIP Caster: http://localhost:2101"
    echo "  • WebInterface: http://localhost:5757"
    echo "  • Prometheus: http://localhost:9090"
    echo "  • Grafana: http://localhost:3000"
    if [ "$ENVIRONMENT" = "development" ]; then
        echo "  • Adminer: http://localhost:8081"
        echo "  • Dozzle: http://localhost:8082"
        echo "  • cAdvisor: http://localhost:8083"
    fi
    echo
    
    if $DOCKER_COMPOSE_CMD $COMPOSE_FILES ps >/dev/null 2>&1; then
        echo "${BLUE}Service Status:${NC}"
        $DOCKER_COMPOSE_CMD $COMPOSE_FILES ps
    fi
}

# Backup data
backup_data() {
    log_info "Backup data..."
    
    local backup_dir="./backup/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    # Backup profile
    log_info "Backup profile..."
    cp -r config/ "$backup_dir/" 2>/dev/null || true
    cp -r nginx/ "$backup_dir/" 2>/dev/null || true
    cp -r monitoring/ "$backup_dir/" 2>/dev/null || true
    cp .env.* "$backup_dir/" 2>/dev/null || true
    
    # Backup data volumes
    log_info "Backup data volumes..."
    if docker volume ls | grep -q "ntrip.*data"; then
        docker run --rm -v "ntrip-data:/data" -v "$(pwd)/$backup_dir:/backup" alpine tar czf /backup/ntrip-data.tar.gz -C /data .
    fi
    
    if docker volume ls | grep -q "prometheus.*data"; then
        docker run --rm -v "prometheus-data:/data" -v "$(pwd)/$backup_dir:/backup" alpine tar czf /backup/prometheus-data.tar.gz -C /data .
    fi
    
    if docker volume ls | grep -q "grafana.*data"; then
        docker run --rm -v "grafana-data:/data" -v "$(pwd)/$backup_dir:/backup" alpine tar czf /backup/grafana-data.tar.gz -C /data .
    fi
    
    log_success "Backup complete: $backup_dir"
}

# Recover data
restore_data() {
    local backup_path="$1"
    
    if [ -z "$backup_path" ] || [ ! -d "$backup_path" ]; then
        log_error "Please specify a valid backup directory path"
        exit 1
    fi
    
    log_info "From $backup_path Recover data..."
    
    # Stop the service
    $DOCKER_COMPOSE_CMD $COMPOSE_FILES down
    
    # Restore profile
    if [ -d "$backup_path/config" ]; then
        log_info "Restore profile..."
        cp -r "$backup_path/config/" ./ 2>/dev/null || true
    fi
    
    # Recover data volumes
    if [ -f "$backup_path/ntrip-data.tar.gz" ]; then
        log_info "RecoveryNTRIPData..."
        docker run --rm -v "ntrip-data:/data" -v "$(realpath $backup_path):/backup" alpine tar xzf /backup/ntrip-data.tar.gz -C /data
    fi
    
    if [ -f "$backup_path/prometheus-data.tar.gz" ]; then
        log_info "RecoveryPrometheusData..."
        docker run --rm -v "prometheus-data:/data" -v "$(realpath $backup_path):/backup" alpine tar xzf /backup/prometheus-data.tar.gz -C /data
    fi
    
    if [ -f "$backup_path/grafana-data.tar.gz" ]; then
        log_info "RecoveryGrafanaData..."
        docker run --rm -v "grafana-data:/data" -v "$(realpath $backup_path):/backup" alpine tar xzf /backup/grafana-data.tar.gz -C /data
    fi
    
    log_success "Data recovery complete"
}

# Update service
update_services() {
    log_info "Update service..."
    
    # Pull the latest image
    log_info "Pull the latest image..."
    $DOCKER_COMPOSE_CMD $COMPOSE_FILES pull
    
    # Rebuild local image
    log_info "Rebuild local image..."
    $DOCKER_COMPOSE_CMD $COMPOSE_FILES build --no-cache
    
    # Restart the service
    log_info "Restart the service..."
    $DOCKER_COMPOSE_CMD $COMPOSE_FILES up -d
    
    # Clean up old images
    log_info "Purge unused mirrors..."
    docker image prune -f
    
    log_success "Service update complete"
}

# Main function
main() {
    show_banner
    parse_args "$@"
    
    case "$1" in
        build)
            check_docker
            create_directories
            create_nginx_config
            create_monitoring_config
            build_image
            ;;
        start)
            check_docker
            create_directories
            start_services
            ;;
        full)
            check_docker
            create_directories
            create_nginx_config
            create_monitoring_config
            start_full_services
            ;;
        stop)
            check_docker
            stop_services
            ;;
        restart)
            check_docker
            stop_services
            sleep 2
            start_services
            ;;
        logs)
            check_docker
            view_logs
            ;;
        status)
            check_docker
            view_status
            ;;
        health)
            check_docker
            check_health
            ;;
        info)
            show_info
            ;;
        backup)
            check_docker
            backup_data
            ;;
        restore)
            check_docker
            restore_data "$2"
            ;;
        update)
            check_docker
            update_services
            ;;
        clean)
            check_docker
            clean_resources
            ;;
        help|--help|-h)
            show_help
            ;;
        "")
            log_info "Start Automated Deployment..."
            check_docker
            create_directories
            create_nginx_config
            create_monitoring_config
            build_image
            start_services
            
            echo
            echo "==========================================="
            echo "    NTRIP Caster DockerDeployment complete"
            echo "==========================================="
            echo
            echo "Service address:"
            echo "  - NTRIPServices: $(hostname -I | awk '{print $1}'):2101"
            echo "  - WebManagement: http://$(hostname -I | awk '{print $1}'):5757"
            echo
            echo "Administrative Commands:"
            echo "  - Check status: $0 status"
            echo "  - View Log: $0 logs"
            echo "  - Stop the service: $0 stop"
            echo "  - Restart the service: $0 restart"
            echo
            ;;
        *)
            log_error "Unknown command: $1"
            show_help
            exit 1
            ;;
    esac
}

# Execute main function
main "$@"