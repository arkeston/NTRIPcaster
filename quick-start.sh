#!/bin/bash

# NTRIP Caster Quick Launch Script
# For rapid deployment and management NTRIP Caster Services

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Project Configuration
PROJECT_NAME="ntrip-caster"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

# Log function
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${PURPLE}[STEP]${NC} $1"
}

# Show banner
show_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    NTRIP Caster Quick Start                    ║"
    echo "║                     Docker Containerized deployment                       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Check dependencies
check_dependencies() {
    log_step "Check system dependencies..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed, please install it first Docker"
        echo "Installation instructions: https://docs.docker.com/get-docker/"
        exit 1
    fi
    
    # Check Docker Compose
    if ! docker compose version &> /dev/null && ! command -v docker-compose &> /dev/null; then
        log_error "Docker Compose is not installed, please install it first Docker Compose"
        echo "Installation instructions: https://docs.docker.com/compose/install/"
        exit 1
    fi
    
    # Check Docker Service Status
    if ! docker info &> /dev/null; then
        log_error "Docker Service is not running, please start Docker Services"
        exit 1
    fi
    
    log_success "System Dependency Check Complete"
}

# Initialization environment
init_environment() {
    log_step "Initialize environment configuration..."
    
    # Create .env Files
    if [[ ! -f "$ENV_FILE" ]]; then
        if [[ -f "$ENV_EXAMPLE" ]]; then
            cp "$ENV_EXAMPLE" "$ENV_FILE"
            log_success "Created .env Profile"
        else
            log_error ".env.example File does not exist"
            exit 1
        fi
    else
        log_info ".env file already exists, skipping creation"
    fi
    
    # Create required directories
    log_info "Create required directories..."
    ./docker-deploy.sh create_directories
    
    log_success "Environment initialization complete"
}

# Select deployment mode
select_deployment_mode() {
    echo
    log_step "Select deployment mode:"
    echo "1) Development mode (development) - Includes development tools and debugging features"
    echo "2) Production mode (production) - Optimize performance, core services only"
    echo "3) Full Mode (full) - Includes all services and monitoring"
    echo "4) Minimal mode (minimal) - Only NTRIP Caster Core Services"
    echo
    
    while true; do
        read -p "Please select a deployment mode [1-4]: " choice
        case $choice in
            1)
                ENVIRONMENT="development"
                PROFILES="dev,monitoring"
                break
                ;;
            2)
                ENVIRONMENT="production"
                PROFILES="prod,monitoring"
                break
                ;;
            3)
                ENVIRONMENT="production"
                PROFILES="full"
                break
                ;;
            4)
                ENVIRONMENT="production"
                PROFILES="minimal"
                break
                ;;
            *)
                log_warning "Invalid selection, please enter 1-4"
                ;;
        esac
    done
    
    # Updates .env Files
    sed -i "s/^ENVIRONMENT=.*/ENVIRONMENT=$ENVIRONMENT/" "$ENV_FILE"
    
    log_success "Selected $ENVIRONMENT mode, profile: $PROFILES"
}

# Build and launch services
deploy_services() {
    log_step "Build and launch services..."
    
    # Pull the latest image
    log_info "Pull Docker Mirror..."
    ENVIRONMENT="$ENVIRONMENT" PROFILES="$PROFILES" ./docker-deploy.sh pull
    
    # Build a custom image
    log_info "Build application image..."
    ENVIRONMENT="$ENVIRONMENT" PROFILES="$PROFILES" ./docker-deploy.sh build
    
    # Start the service
    log_info "Start the service..."
    ENVIRONMENT="$ENVIRONMENT" PROFILES="$PROFILES" ./docker-deploy.sh up -d
    
    # Waiting for service to start
    log_info "Waiting for service to start..."
    sleep 10
    
    # Health Check
    log_info "Perform health checks..."
    ENVIRONMENT="$ENVIRONMENT" PROFILES="$PROFILES" ./docker-deploy.sh health
    
    log_success "Service deployment complete"
}

# Show service information
show_service_info() {
    log_step "Service Information:"
    
    # Show service status
    ENVIRONMENT="$ENVIRONMENT" PROFILES="$PROFILES" ./docker-deploy.sh status
    
    echo
    log_step "Service endpoint:"
    
    # Get NativeIP
    LOCAL_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
    
    echo "📡 NTRIP Caster Services:"
    echo "   - NTRIP Port: ntrip://$LOCAL_IP:2101"
    echo "   - Web Admin Interface: http://$LOCAL_IP:5757"
    
    if [[ "$PROFILES" == *"monitoring"* ]] || [[ "$PROFILES" == *"full"* ]]; then
        echo
        echo "📊 Monitoring services:"
        echo "   - Prometheus: http://$LOCAL_IP:9090"
        echo "   - Grafana: http://$LOCAL_IP:3000 (admin/admin123)"
    fi
    
    if [[ "$ENVIRONMENT" == "development" ]]; then
        echo
        echo "🛠️ Development tools:"
        echo "   - Adminer (Database management): http://$LOCAL_IP:8081"
        echo "   - Dozzle (Log view): http://$LOCAL_IP:8082"
        echo "   - cAdvisor (Container monitoring): http://$LOCAL_IP:8083"
    fi
    
    if [[ -f "$ENV_FILE" ]]; then
        NGINX_PORT=$(grep "^NGINX_HTTP_PORT=" "$ENV_FILE" | cut -d'=' -f2 || echo "80")
        if [[ "$NGINX_PORT" != "80" ]]; then
            echo
            echo "🌐 Nginx Proxy:"
            echo "   - HTTP: http://$LOCAL_IP:$NGINX_PORT"
        fi
    fi
    
    echo
    log_success "Deployment complete!Please use the above endpoint to access the service"
}

# Show management commands
show_management_commands() {
    echo
    log_step "Common Admin Commands:"
    echo "View Log:     ./docker-deploy.sh logs"
    echo "Check status:     ./docker-deploy.sh status"
    echo "Restart the service:     ./docker-deploy.sh restart"
    echo "Stop the service:     ./docker-deploy.sh down"
    echo "Clean up resources:     ./docker-deploy.sh clean"
    echo "Health Check:     ./docker-deploy.sh health"
    echo "Backup data:     ./docker-deploy.sh backup"
    echo "Update service:     ./docker-deploy.sh update"
    echo
    echo "Use Makefile (Recommended):"
    echo "make up          # Start the service"
    echo "make down        # Stop the service"
    echo "make logs        # View Log"
    echo "make status      # Check status"
    echo "make health      # Health Check"
    echo "make clean       # Clean up resources"
}

# Main function
main() {
    show_banner
    
    # Check if it is in the correct directory
    if [[ ! -f "docker-compose.yml" ]]; then
        log_error "Please refer to the NTRIP Caster Run this script under the project root"
        exit 1
    fi
    
    # Check dependencies
    check_dependencies
    
    # Initialization environment
    init_environment
    
    # Select deployment mode
    select_deployment_mode
    
    # Confirm Deployment
    echo
    read -p "Confirm start of deployment? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Deployment cancelled"
        exit 0
    fi
    
    # Deployment Services
    deploy_services
    
    # Show service information
    show_service_info
    
    # Show management commands
    show_management_commands
    
    echo
    log_success "🎉 NTRIP Caster Quick start complete!"
}

# Script portal
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi