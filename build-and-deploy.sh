#!/bin/bash
# NTRIP Caster Protect build and deployment scripts
# Used to build source-protectedDockerMirror and push to repository

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
IMAGE_NAME="ntripcaster"
IMAGE_TAG="2.2.0"
REGISTRY_URL="2rtk"  # Docker HubUsername/Organization name
REGISTRY_NAMESPACE=""  # Docker HubNo additional namespace required
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

log_success() {
    echo -e "${CYAN}[SUCCESS]${NC} $1"
}

# Show banner
show_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
    ███╗   ██╗████████╗██████╗ ██╗██████╗ 
    ████╗  ██║╚══██╔══╝██╔══██╗██║██╔══██╗
    ██╔██╗ ██║   ██║   ██████╔╝██║██████╔╝
    ██║╚██╗██║   ██║   ██╔══██╗██║██╔═══╝ 
    ██║ ╚████║   ██║   ██║  ██║██║██║     
    ╚═╝  ╚═══╝   ╚═╝   ╚═╝  ╚═╝╚═╝╚═╝     
EOF
    echo -e "${NC}"
    echo -e "${GREEN}    NTRIP Caster Protected Build Deployment Tool${NC}"
    echo -e "${BLUE}    Version: ${IMAGE_TAG}${NC}"
    echo
}

# Check dependencies
check_dependencies() {
    log_step "Check build dependencies..."
    
    local deps=("python3" "docker" "git")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_error "Missing dependencies: $dep"
            exit 1
        fi
    done
    
    # CheckDockerWhether to run
    if ! docker info &> /dev/null; then
        log_error "Dockeris not running or does not have permission to access"
        exit 1
    fi
    
    log_info "Dependency check passed"
}

# Build protected versions of binaries
build_protected_binary() {
    log_step "Build source-protected binaries..."
    
    cd "$SCRIPT_DIR"
    
    # Run the protection build script
    if [ -f "build_protected.py" ]; then
        python3 build_protected.py
    else
        log_error "not foundbuild_protected.pyScript"
        exit 1
    fi
    
    # Check build results
    if [ ! -d "dist_protected/ntrip-caster" ]; then
        log_error "Binary build failed"
        exit 1
    fi
    
    log_success "Binary build complete"
}

# BuildDockerMirror
build_docker_image() {
    log_step "BuildDockerMirror..."
    
    cd "$SCRIPT_DIR"
    
    # Build an image
    local full_image_name="${IMAGE_NAME}:${IMAGE_TAG}"
    
    docker build \
        -f Dockerfile \
        -t "$full_image_name" \
        -t "${IMAGE_NAME}:latest" \
        --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        --build-arg VCS_REF="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')" \
        .
    
    log_success "DockerMirror build complete: $full_image_name"
}

# Test image
test_image() {
    log_step "TestDockerMirror..."
    
    local test_container="ntrip-test-$(date +%s)"
    
    # Start test container
    docker run -d \
        --name "$test_container" \
        -p 12101:2101 \
        -p 15757:5757 \
        "${IMAGE_NAME}:${IMAGE_TAG}"
    
    # Waiting for container to start
    sleep 10
    
    # Check container status
    if docker ps | grep -q "$test_container"; then
        log_info "Container started successfully for health check..."
        
        # Waiting for health check
        local max_attempts=30
        local attempt=0
        
        while [ $attempt -lt $max_attempts ]; do
            if docker exec "$test_container" python3 /app/healthcheck.py &>/dev/null; then
                log_success "Health check passed"
                break
            fi
            
            attempt=$((attempt + 1))
            sleep 2
        done
        
        if [ $attempt -eq $max_attempts ]; then
            log_warn "The health check timed out but the container is still running"
        fi
    else
        log_error "Failed to start container"
        docker logs "$test_container"
        docker rm -f "$test_container" 2>/dev/null || true
        exit 1
    fi
    
    # Clean Test Container
    docker rm -f "$test_container" 2>/dev/null || true
    log_success "Mirror Test Complete"
}

# Push to Warehouse
push_to_registry() {
    if [ -z "$REGISTRY_URL" ]; then
        log_warn "Warehouse address not set, skipping push step"
        log_info "To push, setREGISTRY_URLandREGISTRY_NAMESPACEVariables"
        return
    fi
    
    log_step "Push image to repository..."
    
    local registry_image
    if [ -n "$REGISTRY_NAMESPACE" ]; then
        registry_image="${REGISTRY_URL}/${REGISTRY_NAMESPACE}/${IMAGE_NAME}"
    else
        registry_image="${REGISTRY_URL}/${IMAGE_NAME}"
    fi
    
    # Marking images
    docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "${registry_image}:${IMAGE_TAG}"
    docker tag "${IMAGE_NAME}:latest" "${registry_image}:latest"
    
    # Push image
    docker push "${registry_image}:${IMAGE_TAG}"
    docker push "${registry_image}:latest"
    
    log_success "Mirror push complete: ${registry_image}:${IMAGE_TAG}"
}

# Generate deployment documentation
generate_deployment_docs() {
    log_step "Generate deployment documentation..."
    
    local docs_dir="deployment_docs"
    mkdir -p "$docs_dir"
    
    # Builddocker-compose.yml
    cat > "${docs_dir}/docker-compose.yml" << EOF
# NTRIP Caster Protection Version Deployment Configuration
# How to use: docker-compose up -d

version: '3.8'

services:
  ntrip-caster:
    image: ${REGISTRY_URL:+${REGISTRY_URL}/}${REGISTRY_NAMESPACE:+${REGISTRY_NAMESPACE}/}${IMAGE_NAME}:${IMAGE_TAG}
    container_name: ntrip-caster
    hostname: ntrip-caster
    restart: unless-stopped
    ports:
      - "2101:2101"  # NTRIPService Port
      - "5757:5757"  # WebManagement Port
    volumes:
      - ntrip-data:/app/data          # Data persistence
      - ntrip-logs:/app/logs          # Log persistence
      - ntrip-config:/app/config      # Profile
      - /etc/localtime:/etc/localtime:ro  # Time zone synchronization
    environment:
      - TZ=Asia/Shanghai
      - NTRIP_CONFIG_FILE=/app/config/config.ini
    networks:
      - ntrip-network
    healthcheck:
      test: ["CMD", "python", "/app/healthcheck.py"]
      interval: 30s
      timeout: 15s
      retries: 3
      start_period: 90s
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
        compress: "true"
    security_opt:
      - no-new-privileges:true
    ulimits:
      nofile:
        soft: 65536
        hard: 65536

volumes:
  ntrip-data:
    driver: local
  ntrip-logs:
    driver: local
  ntrip-config:
    driver: local

networks:
  ntrip-network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16
EOF

    # Generate deployment scripts
    cat > "${docs_dir}/deploy.sh" << 'EOF'
#!/bin/bash
# NTRIP Caster One-click deployment scripts

set -e

echo "Start DeploymentNTRIP Caster..."

# CheckDockeranddocker-compose
if ! command -v docker &> /dev/null; then
    echo "Error: Not installedDocker"
    exit 1
fi

if ! command -v docker-compose &> /dev/null; then
    echo "Error: Not installeddocker-compose"
    exit 1
fi

# Pull the latest image
echo "Pull the latest image..."
docker-compose pull

# Start the service
echo "Start the service..."
docker-compose up -d

# Waiting for service to start
echo "Waiting for service to start..."
sleep 30

# Check service status
echo "Check service status..."
docker-compose ps

echo "Deployment complete!"
echo "NTRIPService address: http://localhost:2101"
echo "Web Admin Interface: http://localhost:5757"
echo "Default admin account: admin/admin123"
echo ""
echo "Common commands:"
echo "  View Log: docker-compose logs -f"
echo "  Stop the service: docker-compose down"
echo "  Restart the service: docker-compose restart"
EOF

    chmod +x "${docs_dir}/deploy.sh"
    
    # BuildREADME
    cat > "${docs_dir}/README.md" << EOF
# NTRIP Caster Deployment Guide

## Rapid Deployment

1. Ensure it is installedDockeranddocker-compose
2. Run the deployment script:
   \`\`\`bash
   ./deploy.sh
   \`\`\`

## Manual Deployment

1. Pull image:
   \`\`\`bash
   docker-compose pull
   \`\`\`

2. Start the service:
   \`\`\`bash
   docker-compose up -d
   \`\`\`

## Service Access

- NTRIPServices: http://localhost:2101
- Web Admin Interface: http://localhost:5757
- Default admin account: admin/admin123

## Configuration instructions

The profile is inside the container \`/app/config/config.ini\`, which can be persisted through data volumes.

## Data persistence

- Data directory: \`ntrip-data\` Volume
- Log directory: \`ntrip-logs\` Volume  
- Configuration directory: \`ntrip-config\` Volume

## Common commands

\`\`\`bash
# View service status
docker-compose ps

# View Log
docker-compose logs -f

# Restart the service
docker-compose restart

# Stop the service
docker-compose down

# Update service
docker-compose pull && docker-compose up -d
\`\`\`

## Troubleshooting

1. Check if the port is occupied
2. CheckDockerIs the service functioning properly?
3. View container logs for troubleshooting issues

EOF

    log_success "Deployment Document Generation Complete: $docs_dir/"
}

# Clean up build files
cleanup_build_files() {
    log_step "Clean up build files..."
    
    # Optional cleanup, retention of important files
    if [ -d "build_protected" ]; then
        rm -rf build_protected/work build_protected/obfuscated
    fi
    
    log_info "Build file cleanup complete"
}

# Show usage help
show_help() {
    cat << EOF
NTRIP Caster Protected Build Deployment Tool

Usage: $0 [Options]

Options:
  --registry-url URL        SettingsDockerWarehouse address
  --registry-namespace NS   Set repository namespace
  --skip-test              Skip mirror test
  --skip-push              Skip push to warehouse
  --cleanup                Clean up temporary files when build is complete
  --help, -h               Show this help

Example:
  $0 --registry-url registry.example.com --registry-namespace mycompany
  $0 --skip-test --skip-push

EOF
}

# Resolve command line arguments
parse_args() {
    SKIP_TEST=false
    SKIP_PUSH=false
    CLEANUP=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --registry-url)
                REGISTRY_URL="$2"
                shift 2
                ;;
            --registry-namespace)
                REGISTRY_NAMESPACE="$2"
                shift 2
                ;;
            --skip-test)
                SKIP_TEST=true
                shift
                ;;
            --skip-push)
                SKIP_PUSH=true
                shift
                ;;
            --cleanup)
                CLEANUP=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown parameter: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Main function
main() {
    # Parse parameters
    parse_args "$@"
    
    # Show banner
    show_banner
    
    # Show configuration information
    log_info "Build configuration:"
    echo "  Mirror Name: ${IMAGE_NAME}:${IMAGE_TAG}"
    echo "  Warehouse address: ${REGISTRY_URL:-'Not set'}"
    echo "  Namespace: ${REGISTRY_NAMESPACE:-'Not set'}"
    echo "  Skip test: ${SKIP_TEST}"
    echo "  Skip push: ${SKIP_PUSH}"
    echo
    
    try {
        # 1. Check dependencies
        check_dependencies
        
        # 2. Build protected versions of binaries
        build_protected_binary
        
        # 3. BuildDockerMirror
        build_docker_image
        
        # 4. Test image (optional)
        if [ "$SKIP_TEST" = false ]; then
            test_image
        fi
        
        # 5. Push to Warehouse (optional)
        if [ "$SKIP_PUSH" = false ]; then
            push_to_registry
        fi
        
        # 6. Generate deployment documentation
        generate_deployment_docs
        
        # 7. Clean up build files (optional)
        if [ "$CLEANUP" = true ]; then
            cleanup_build_files
        fi
        
        echo
        log_success "Build Deployment Complete!"
        echo
        log_info "Next:"
        echo "  1. View deployment documentation: deployment_docs/README.md"
        echo "  2. Use deployment scripts: cd deployment_docs && ./deploy.sh"
        if [ -n "$REGISTRY_URL" ]; then
            echo "  3. Distribute images: ${REGISTRY_URL}/${REGISTRY_NAMESPACE:+${REGISTRY_NAMESPACE}/}${IMAGE_NAME}:${IMAGE_TAG}"
        fi
        echo
        
    } catch {
        log_error "Build failed: $1"
        exit 1
    }
}

# BashError Handling Functions
try() {
    "$@"
}

catch() {
    case $? in
        0) ;; # Success, doing nothing
        *) "$@" ;; # failed, executecatchblock
    esac
}

# Script portal
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi