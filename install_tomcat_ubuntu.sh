#!/bin/bash
# ==============================================================================
# Tomcat 10.1 installer for Ubuntu EC2 (20.04 / 22.04 / 24.04)
# - Installs OpenJDK 17, creates a tomcat user, installs latest Tomcat 10.1
# - Creates a systemd service enabled at boot (survives EC2 stop/start/reboot)
#
# Usage:
#   sudo bash install_tomcat_ubuntu.sh
#
# Optional (enables Manager / Host Manager GUI, reachable from any IP):
#   sudo ADMIN_USER=admin ADMIN_PASS='YourStrongPass' bash install_tomcat_ubuntu.sh
#
# Can also be pasted into EC2 "User data" (runs as root at first boot).
# ==============================================================================
set -euo pipefail

TOMCAT_MAJOR=10
TOMCAT_HOME=/opt/tomcat
TOMCAT_USER=tomcat
ADMIN_USER="${ADMIN_USER:-}"
ADMIN_PASS="${ADMIN_PASS:-}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"; exit 1
fi

log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

# 1. Packages ------------------------------------------------------------------
log "Installing Java 17 and tools"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y openjdk-17-jdk-headless curl tar ca-certificates

JAVA_BIN="$(readlink -f "$(command -v java)")"
JAVA_HOME_DIR="$(dirname "$(dirname "$JAVA_BIN")")"
echo "JAVA_HOME = $JAVA_HOME_DIR"

# 2. Find latest Tomcat 10.1.x -------------------------------------------------
log "Detecting latest Tomcat ${TOMCAT_MAJOR}.1 release"
BASE_URL="https://dlcdn.apache.org/tomcat/tomcat-${TOMCAT_MAJOR}"
VER="$(curl -fsSL "$BASE_URL/" | grep -oP "v${TOMCAT_MAJOR}\.1\.[0-9]+" | sed 's/^v//' | sort -V | tail -1 || true)"
if [[ -z "$VER" ]]; then
  echo "Could not auto-detect version; falling back to archive.apache.org"
  VER="10.1.34"
  BASE_URL="https://archive.apache.org/dist/tomcat/tomcat-${TOMCAT_MAJOR}"
fi
echo "Tomcat version: $VER"

# 3. User + download -----------------------------------------------------------
log "Creating tomcat user"
id "$TOMCAT_USER" &>/dev/null || useradd -r -m -U -d "$TOMCAT_HOME" -s /usr/sbin/nologin "$TOMCAT_USER"

log "Downloading and verifying Tomcat $VER"
cd /tmp
TARBALL="apache-tomcat-${VER}.tar.gz"
curl -fSL -o "$TARBALL" "${BASE_URL}/v${VER}/bin/${TARBALL}"
curl -fSL -o "${TARBALL}.sha512" "${BASE_URL}/v${VER}/bin/${TARBALL}.sha512"
sha512sum -c "${TARBALL}.sha512"

# 4. Install (stop old instance first if re-running) ---------------------------
systemctl stop tomcat 2>/dev/null || true
log "Installing to $TOMCAT_HOME"
mkdir -p "$TOMCAT_HOME"
# keep existing webapps/conf on re-run by backing up
if [[ -d "$TOMCAT_HOME/webapps" ]]; then
  cp -a "$TOMCAT_HOME" "${TOMCAT_HOME}.bak.$(date +%s)"
fi
tar -xzf "$TARBALL" -C "$TOMCAT_HOME" --strip-components=1
rm -f "$TARBALL" "${TARBALL}.sha512"
chown -R "$TOMCAT_USER:$TOMCAT_USER" "$TOMCAT_HOME"
chmod +x "$TOMCAT_HOME"/bin/*.sh

# 5. Optional Manager / Host Manager -------------------------------------------
if [[ -n "$ADMIN_PASS" ]]; then
  log "Configuring Manager and Host Manager users"
  sed -i '/<\/tomcat-users>/i \
  <role rolename="manager-gui"/>\n  <role rolename="admin-gui"/>\n  <user username="'"$ADMIN_USER"'" password="'"$ADMIN_PASS"'" roles="manager-gui,admin-gui"/>' \
    "$TOMCAT_HOME/conf/tomcat-users.xml"
  # allow access from any IP (restrict with the security group!)
  for f in manager host-manager; do
    sed -i 's#allow="[^"]*"#allow=".*"#' \
      "$TOMCAT_HOME/webapps/$f/META-INF/context.xml"
  done
fi

# 6. systemd service (enabled at boot) -----------------------------------------
log "Creating systemd service"
cat > /etc/systemd/system/tomcat.service <<EOF
[Unit]
Description=Apache Tomcat ${VER}
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=${TOMCAT_USER}
Group=${TOMCAT_USER}
Environment="JAVA_HOME=${JAVA_HOME_DIR}"
Environment="CATALINA_HOME=${TOMCAT_HOME}"
Environment="CATALINA_BASE=${TOMCAT_HOME}"
Environment="CATALINA_PID=${TOMCAT_HOME}/temp/tomcat.pid"
Environment="CATALINA_OPTS=-Xms256M -Xmx512M -server"
ExecStart=${TOMCAT_HOME}/bin/startup.sh
ExecStop=${TOMCAT_HOME}/bin/shutdown.sh
SuccessExitStatus=143
Restart=on-failure
RestartSec=10
UMask=0007

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tomcat
systemctl restart tomcat

# 7. Verify ---------------------------------------------------------------------
log "Waiting for Tomcat to come up"
for i in {1..30}; do
  if curl -fs -o /dev/null http://localhost:8080; then
    echo "Tomcat is UP"; break
  fi
  sleep 2
done

TOKEN="$(curl -fs -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)"
PUBIP="$(curl -fs -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4 || echo '<EC2-public-IP>')"

echo
echo "-------------------------------------------------------------"
echo " Tomcat ${VER} installed and enabled at boot"
echo " URL:     http://${PUBIP}:8080   (open TCP 8080 in the security group)"
echo " Status:  systemctl status tomcat"
echo " Logs:    tail -f ${TOMCAT_HOME}/logs/catalina.out"
echo " Webapps: ${TOMCAT_HOME}/webapps"
[[ -n "$ADMIN_PASS" ]] && echo " Manager: http://${PUBIP}:8080/manager  (user: ${ADMIN_USER})"
echo "-------------------------------------------------------------"
