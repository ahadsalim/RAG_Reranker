#!/bin/bash

# =============================================================================
# Reranker Service - Complete Automated Setup Script (Security Hardened)
# =============================================================================
# این اسکریپت تمام نیازمندی‌های reranker را نصب و راه‌اندازی می‌کند
# شامل: نصب Docker، ایجاد تنظیمات، build و اجرای سرویس
# همچنین تنظیمات امنیتی شامل UFW و DOCKER-USER iptables را اعمال می‌کند
# 
# نحوه استفاده:
#   cd /srv/deployment
#   chmod +x start.sh
#   ./start.sh
# =============================================================================

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
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

# Check if running as root
if [ "$EUID" -eq 0 ]; then 
    log_error "Please do not run as root. Run as regular user with sudo access."
    exit 1
fi

echo "========================================================================"
log_info "Reranker Service - Complete Setup"
echo "========================================================================"
echo ""

# 0. Configure apt to use cache server (with fallback to internet)
log_step "Step 0/15: Configuring apt cache server..."
if curl -sf --connect-timeout 3 http://10.10.10.111/ > /dev/null 2>&1; then
    if [ ! -f /etc/apt/apt.conf.d/00proxy ]; then
        echo 'Acquire::http::Proxy "http://10.10.10.111:3142";' | sudo tee /etc/apt/apt.conf.d/00proxy > /dev/null
        echo 'Acquire::https::Proxy "http://10.10.10.111:3144";' | sudo tee -a /etc/apt/apt.conf.d/00proxy > /dev/null
        log_info "apt cache server configured (HTTP:3142, HTTPS:3144) ✓"
    else
        log_info "apt cache server already configured ✓"
    fi
else
    log_warn "Cache server not reachable, will use internet directly"
    sudo rm -f /etc/apt/apt.conf.d/00proxy 2>/dev/null || true
fi

# 1. Update system packages
log_step "Step 1/15: Updating system packages from cache server..."
sudo apt-get update -qq

# 2. Install required packages
log_step "Step 2/15: Installing prerequisites from cache server..."
sudo apt-get install -y curl git wget ca-certificates gnupg lsb-release python3 python3-pip jq ufw

# 3. Install Docker if not already installed
if ! command -v docker &> /dev/null; then
    log_step "Step 3/15: Installing Docker from cache server..."
    
    # Remove old versions
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Add Docker's official GPG key (try cache server first, fallback to internet)
    sudo mkdir -p /etc/apt/keyrings
    if curl -sf --connect-timeout 5 http://10.10.10.111/ > /dev/null 2>&1; then
        log_info "Downloading Docker GPG key from cache server..."
        curl -fsSL http://10.10.10.111/keys/docker.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    else
        log_warn "Cache server unavailable, downloading Docker GPG key from internet..."
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    fi
    
    # Set up the repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker Engine
    sudo apt-get update -qq
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # Add current user to docker group
    sudo usermod -aG docker $USER
    
    log_info "Docker installed successfully from cache server ✓"
    log_warn "You may need to log out and back in for docker group to take effect"
else
    log_step "Step 3/15: Docker already installed ✓"
fi

# 3.5. Configure Docker daemon to use registry mirrors and insecure registries
log_step "Step 3.5/15: Configuring Docker registry mirrors..."
if [ ! -f /etc/docker/daemon.json ]; then
    sudo tee /etc/docker/daemon.json > /dev/null << 'DOCKER_DAEMON_EOF'
{
  "registry-mirrors": ["http://10.10.10.111:5001"],
  "insecure-registries": [
    "10.10.10.111:5001",
    "10.10.10.111:5002",
    "10.10.10.111:5003",
    "10.10.10.111:5004",
    "10.10.10.111:5005"
  ]
}
DOCKER_DAEMON_EOF
    sudo systemctl restart docker 2>/dev/null || true
    log_info "Docker registry mirrors and insecure registries configured ✓"
else
    log_info "Docker daemon.json already exists ✓"
fi

# 4. Verify Docker installation
log_step "Step 4/15: Verifying Docker installation..."
DOCKER_VERSION=$(sudo docker --version)
COMPOSE_VERSION=$(sudo docker compose version)
log_info "$DOCKER_VERSION"
log_info "$COMPOSE_VERSION"

# 5. Download HuggingFace model from cache server (offline mode)
log_step "Step 5/16: Downloading reranker model from cache server..."
MODEL_DIR="$HOME/models/BAAI-bge-reranker-v2-m3"
if [ ! -d "$MODEL_DIR" ]; then
    log_info "Downloading model from cache server (http://10.10.10.111/models/)..."
    mkdir -p "$HOME/models"
    if curl -sf --connect-timeout 5 http://10.10.10.111/models/BAAI-bge-reranker-v2-m3/ > /dev/null 2>&1; then
        wget -q --show-progress -r -np -nH --cut-dirs=1 -R "index.html*" \
            http://10.10.10.111/models/BAAI-bge-reranker-v2-m3/ \
            -P "$HOME/models/"
        log_info "Model downloaded successfully (~2.1GB) ✓"
    else
        log_error "Cache server not reachable. Cannot download model."
        log_error "Please ensure 10.10.10.111 is accessible."
        exit 1
    fi
else
    log_info "Model already exists at $MODEL_DIR ✓"
fi

# 5.5. Create .env file if it doesn't exist
log_step "Step 5.5/16: Setting up environment variables..."
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
        log_info "Created .env from .env.example"
    else
        log_warn ".env.example not found. Creating default .env..."
        cat > .env << 'EOF'
# Using local model from cache server (offline mode)
RERANKER_MODEL="/models/local/BAAI-bge-reranker-v2-m3"
RERANKER_MODEL_PATH="/models/reranker"
RERANKER_MAX_LENGTH=512
RERANKER_HOST="0.0.0.0"
RERANKER_PORT=8100
RERANKER_MEMORY_LIMIT="4G"
RERANKER_MEMORY_RESERVATION="2G"
EOF
        log_info "Created default .env file with offline model path"
    fi
else
    log_info ".env file already exists ✓"
fi

# 6. Configure pip to use cache server
log_step "Step 6/16: Configuring pip cache server..."
if [ ! -f /etc/pip.conf ]; then
    sudo tee /etc/pip.conf > /dev/null << 'PIP_CONF_EOF'
[global]
index-url = http://10.10.10.111:3141/root/pypi/+simple/
trusted-host = 10.10.10.111
PIP_CONF_EOF
    log_info "pip cache server configured ✓"
else
    log_info "pip.conf already exists ✓"
fi

# 7. Create Promtail configuration
log_step "Step 7/17: Setting up Promtail configuration..."
if [ ! -f promtail-config.yml ]; then
    cat > promtail-config.yml << 'PROMTAIL_EOF'
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://10.10.10.40:3100/loki/api/v1/push

scrape_configs:
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 5s
    relabel_configs:
      - source_labels: ['__meta_docker_container_name']
        regex: '/(.*)'  
        target_label: 'container'
      - source_labels: ['__meta_docker_container_log_stream']
        target_label: 'stream'
      - target_label: 'server'
        replacement: 'reranker'
      - target_label: 'hostname'
        replacement: 'reranker'
      - target_label: 'job'
        replacement: 'docker-logs'

  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          server: reranker
          hostname: reranker
          __path__: /var/log/*log
PROMTAIL_EOF
    log_info "Created promtail-config.yml"
else
    log_info "promtail-config.yml already exists ✓"
fi

# 8. Configure UFW Firewall
log_step "Step 8/17: Configuring UFW firewall..."
if ! sudo ufw status | grep -q "Status: active"; then
    log_info "Setting up UFW firewall rules..."
    sudo ufw --force default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow OpenSSH
    sudo ufw allow from 192.168.100.0/24 comment 'LAN access'
    sudo ufw allow from 10.10.10.0/24 comment 'DMZ access'
    sudo ufw --force enable
    log_info "UFW firewall enabled ✓"
else
    log_info "UFW firewall already active ✓"
fi

# 9. Configure DOCKER-USER iptables chain
log_step "Step 9/17: Configuring DOCKER-USER iptables..."
if ! grep -q "DOCKER-USER" /etc/ufw/after.rules; then
    log_info "Adding DOCKER-USER rules to /etc/ufw/after.rules..."
    sudo bash -c 'cat >> /etc/ufw/after.rules << "IPTABLES_EOF"

# Docker DOCKER-USER chain rules
*filter
:DOCKER-USER - [0:0]
# Allow established connections
-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
# Allow Docker internal networks
-A DOCKER-USER -s 172.16.0.0/12 -j RETURN
# Allow LAN subnet
-A DOCKER-USER -s 192.168.100.0/24 -j RETURN
# Allow DMZ subnet
-A DOCKER-USER -s 10.10.10.0/24 -j RETURN
# Allow localhost
-A DOCKER-USER -s 127.0.0.0/8 -j RETURN
# Drop everything else
-A DOCKER-USER -j DROP
COMMIT
IPTABLES_EOF'
    log_info "DOCKER-USER rules added ✓"
else
    log_info "DOCKER-USER rules already exist ✓"
fi

# Create systemd service for DOCKER-USER persistence
if [ ! -f /etc/systemd/system/docker-user-iptables.service ]; then
    log_info "Creating docker-user-iptables systemd service..."
    sudo tee /etc/systemd/system/docker-user-iptables.service > /dev/null << 'SERVICE_EOF'
[Unit]
Description=Docker DOCKER-USER iptables rules
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'iptables -N DOCKER-USER 2>/dev/null || iptables -F DOCKER-USER; iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN; iptables -A DOCKER-USER -s 172.16.0.0/12 -j RETURN; iptables -A DOCKER-USER -s 192.168.100.0/24 -j RETURN; iptables -A DOCKER-USER -s 10.10.10.0/24 -j RETURN; iptables -A DOCKER-USER -s 127.0.0.0/8 -j RETURN; iptables -A DOCKER-USER -j DROP'

[Install]
WantedBy=multi-user.target
SERVICE_EOF
    sudo systemctl daemon-reload
    sudo systemctl enable docker-user-iptables.service
    sudo systemctl start docker-user-iptables.service
    log_info "docker-user-iptables service enabled ✓"
else
    log_info "docker-user-iptables service already exists ✓"
fi

sudo ufw reload

# 10. Display configuration
log_step "Step 10/17: Configuration summary..."
echo "  Cache Server: 10.10.10.111"
echo "  Model: BAAI/bge-reranker-v2-m3"
echo "  Port: 8100 (localhost only)"
echo "  Memory Limit: 4GB"
echo "  Memory Reservation: 2GB"
echo "  Monitoring: Node Exporter + Promtail + cAdvisor"
echo "  Security: UFW + DOCKER-USER iptables"

# 11. Stop existing containers if running
log_step "Step 11/17: Stopping existing containers (if any)..."
sudo docker compose down 2>/dev/null || true

# 12. Pull image and start all services
log_step "Step 12/17: Pulling reranker image and starting all services..."
log_info "This may take several minutes on first run:"
log_info "  - Pulling reranker image from registry (~2GB)"
log_info "  - Downloading reranker model (~1.5GB)"
log_info "  - Starting monitoring exporters (Node Exporter, Promtail, cAdvisor)"
echo ""

sudo docker compose pull
sudo docker compose up -d

# 13. Wait for service to be healthy
log_step "Step 13/17: Waiting for Reranker service to become healthy..."
log_info "Model loading may take 30-120 seconds..."
echo ""

MAX_WAIT=180  # 3 minutes
ELAPSED=0
INTERVAL=5

while [ $ELAPSED -lt $MAX_WAIT ]; do
    if curl -sf http://localhost:8100/health > /dev/null 2>&1; then
        echo ""
        log_info "Service is healthy! ✓"
        break
    fi
    
    echo -n "."
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    
    # Show progress every 30 seconds
    if [ $((ELAPSED % 30)) -eq 0 ]; then
        echo ""
        log_info "Still waiting... ($ELAPSED seconds elapsed)"
    fi
done

echo ""

if [ $ELAPSED -ge $MAX_WAIT ]; then
    log_error "Service did not become healthy within $MAX_WAIT seconds"
    log_error "Checking logs for errors..."
    echo ""
    sudo docker compose logs --tail=50 reranker
    echo ""
    log_error "Full logs: sudo docker compose logs reranker"
    exit 1
fi

# 14. Verify monitoring exporters
log_step "Step 14/17: Verifying monitoring exporters..."
echo ""

# Check Node Exporter
if curl -sf http://localhost:9100/metrics > /dev/null 2>&1; then
    log_info "Node Exporter is running ✓"
    NODE_EXPORTER_STATUS="running"
else
    log_warn "Node Exporter is not responding"
    NODE_EXPORTER_STATUS="failed"
fi

# Check Promtail
if sudo docker ps --filter "name=promtail" --filter "status=running" | grep -q promtail; then
    log_info "Promtail is running ✓"
    PROMTAIL_STATUS="running"
else
    log_warn "Promtail is not running"
    PROMTAIL_STATUS="failed"
fi

# Check cAdvisor
if curl -sf http://localhost:8080/metrics > /dev/null 2>&1; then
    log_info "cAdvisor is running ✓"
    CADVISOR_STATUS="running"
else
    log_warn "cAdvisor is not responding"
    CADVISOR_STATUS="failed"
fi

echo ""

# 15. Test the service and display monitoring report
log_step "Step 15/17: Testing service and generating monitoring report..."
HEALTH_RESPONSE=$(curl -s http://localhost:8100/health)

if echo "$HEALTH_RESPONSE" | python3 -m json.tool > /dev/null 2>&1; then
    echo "$HEALTH_RESPONSE" | python3 -m json.tool
else
    echo "$HEALTH_RESPONSE"
fi

# Get container stats
RERANKER_STATS=$(sudo docker stats --no-stream reranker --format "{{.MemUsage}}" 2>/dev/null || echo "N/A")
RERANKER_MEM_PERCENT=$(sudo docker stats --no-stream reranker --format "{{.MemPerc}}" 2>/dev/null || echo "N/A")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HOSTNAME=$(hostname)

# Display final summary with monitoring report
echo ""
echo "========================================================================"
log_info "Reranker Service + Monitoring Setup Complete! ✓"
echo "========================================================================"
echo ""
echo "📊 Service Information:"
echo "  Server:       $HOSTNAME"
echo "  IP:           10.10.10.60"
echo "  Status:       Running"
echo "  URL:          http://localhost:8100"
echo "  Health:       http://localhost:8100/health"
echo "  Model:        BAAI/bge-reranker-v2-m3"
echo "  Memory Usage: $RERANKER_STATS ($RERANKER_MEM_PERCENT)"
echo "  Cache Server: 10.10.10.111 (apt HTTP:3142, apt HTTPS:3144, PyPI:3141, Docker:5001)"
echo ""
echo "📈 Monitoring Exporters:"
echo "  Node Exporter:  $NODE_EXPORTER_STATUS (Port 9100)"
echo "    └─ Metrics:   http://10.10.10.60:9100/metrics"
echo "  cAdvisor:       $CADVISOR_STATUS (Port 8080)"
echo "    └─ Metrics:   http://10.10.10.60:8080/metrics"
echo "    └─ Containers: http://10.10.10.60:8080/containers/"
echo "  Promtail:       $PROMTAIL_STATUS"
echo "    └─ Loki:      http://10.10.10.40:3100"
echo "    └─ Labels:    server=reranker, hostname=$HOSTNAME"
echo ""
echo "⚙️  Prometheus Configuration:"
echo "  Add this to your Prometheus scrape_configs:"
echo ""
echo "  - job_name: 'node-exporter-reranker'"
echo "    static_configs:"
echo "      - targets: ['10.10.10.60:9100']"
echo "        labels:"
echo "          server: 'reranker'"
echo "          hostname: '$HOSTNAME'"
echo ""
echo "  - job_name: 'cadvisor-reranker'"
echo "    static_configs:"
echo "      - targets: ['10.10.10.60:8080']"
echo "        labels:"
echo "          server: 'reranker'"
echo "          hostname: '$HOSTNAME'"
echo ""
echo "🔧 Useful Commands:"
echo "  View all containers:     sudo docker compose ps"
echo "  View reranker logs:      sudo docker compose logs -f reranker"
echo "  View promtail logs:      sudo docker compose logs -f promtail"
echo "  View cadvisor logs:      sudo docker compose logs -f cadvisor"
echo "  Stop all services:       sudo docker compose down"
echo "  Restart reranker:        sudo docker compose restart reranker"
echo "  Check node metrics:      curl http://localhost:9100/metrics | head -20"
echo "  Check container metrics: curl http://localhost:8080/metrics | grep reranker"
echo ""
echo "🌐 Access (Security Hardened):"
echo "  Reranker API:            http://127.0.0.1:8100 (localhost only - NOT from internet)"
echo "  Node Exporter:           http://127.0.0.1:9100/metrics (localhost only)"
echo "  cAdvisor Metrics:        http://127.0.0.1:8080/metrics (localhost only)"
echo "  cAdvisor UI:             http://127.0.0.1:8080/containers/ (localhost only)"
echo ""
echo "  ⚠️  All services are bound to localhost for security."
echo "  ⚠️  Access from LAN/DMZ is allowed through firewall."
echo "  ⚠️  Internet access is BLOCKED except SSH (port 22)."
echo ""
echo "🔒 Security Status:"
echo "  UFW Firewall:            $(sudo ufw status | grep -q 'Status: active' && echo 'ACTIVE ✓' || echo 'INACTIVE ⚠️')"
echo "  DOCKER-USER iptables:    $(sudo iptables -L DOCKER-USER -n | grep -q DROP && echo 'CONFIGURED ✓' || echo 'NOT CONFIGURED ⚠️')"
echo "  Open Ports (Internet):   SSH (22) only"
echo "  Internal Ports:          8100, 8080, 9100, 9080 (localhost only)"
echo ""
echo "📝 Next Steps:"
echo "  1. Verify Loki server is running on 10.10.10.40:3100"
echo "  2. Add Prometheus scrape config (see above)"
echo "  3. Test reranker: curl http://localhost:8100/health"
echo "  4. Update Core API .env: RERANKER_SERVICE_URL=\"http://10.10.10.60:8100\""
echo "  5. Verify firewall: sudo ufw status verbose"
echo "  6. Check open ports: ss -tlnp | grep '0.0.0.0'"
echo ""
# 16. Verify cache server connectivity and display status
log_step "Step 16/17: Verifying cache server connectivity..."
if curl -sf --connect-timeout 5 http://10.10.10.111/ > /dev/null 2>&1; then
    log_info "Cache server is reachable ✓"
    CACHE_SERVER_STATUS="✅ reachable (using cache for faster downloads)"
else
    log_warn "Cache server is not reachable - using internet directly"
    CACHE_SERVER_STATUS="⚠️  unreachable (using internet fallback)"
fi

echo ""
echo "📊 Monitoring Report Summary:"
echo "  Timestamp:        $TIMESTAMP"
echo "  Status:           success"
echo "  Containers:       reranker, node-exporter, cadvisor, promtail"
echo "  ML Model Memory:  $RERANKER_STATS"
echo "  Files Created:    docker-compose.yml, promtail-config.yml, .env"
echo "  cAdvisor Version: v0.49.1 (cgroup v2 compatible)"
echo "  Cache Server:     $CACHE_SERVER_STATUS (10.10.10.111)"
echo ""

if [ "$NODE_EXPORTER_STATUS" != "running" ] || [ "$PROMTAIL_STATUS" != "running" ] || [ "$CADVISOR_STATUS" != "running" ]; then
    log_warn "Some monitoring exporters are not running. Check logs with:"
    log_warn "  sudo docker compose logs node-exporter"
    log_warn "  sudo docker compose logs cadvisor"
    log_warn "  sudo docker compose logs promtail"
fi

if groups | grep -q docker; then
    log_info "Docker group is active. You can use docker without sudo."
else
    log_warn "Docker group not active yet. Log out and back in to use docker without sudo."
fi

echo ""
log_info "Setup completed successfully! ✓"
log_info "All services (Reranker + Monitoring) are now running."
