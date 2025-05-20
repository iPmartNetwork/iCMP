#!/usr/bin/env bash

# ───────────── Colors and UI Elements ─────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
NC='\033[0m'
SEP="${CYAN}────────────────────────────────────────────${NC}"

# ───────────── Logo and Menu ─────────────
show_logo() {
  clear
  echo -e "${BLUE}"
  echo "╔════════════════════════════════════════╗"
  echo "║        ICMP Tunnel Manager v1.0       ║"
  echo "╚════════════════════════════════════════╝"
  echo -e "${NC}"
}

show_menu() {
  show_logo
  echo -e "${CYAN}Please select an action:${NC}"
  echo -e "${YELLOW}1)${NC} Install as Local (Client)"
  echo -e "${YELLOW}2)${NC} Install as Foreign (Server)"
  echo -e "${YELLOW}3)${NC} Start Tunnel Service"
  echo -e "${YELLOW}4)${NC} Stop Tunnel Service"
  echo -e "${YELLOW}5)${NC} Service Status"
  echo -e "${YELLOW}6)${NC} Show Tunnel Logs"
  echo -e "${YELLOW}7)${NC} Uninstall Everything"
  echo -e "${YELLOW}0)${NC} Exit"
  echo -e "$SEP"
}

# ───────────── Paths and Service Names ─────────────
WORKDIR="/opt/icmp-tunnel"
BIN="$WORKDIR/icmptunnel"
CLIENT_SCRIPT="$WORKDIR/manage-tunnel.sh"
SERVER_SCRIPT="$WORKDIR/manage-server.sh"
SERVICE_CLIENT="icmp-tunnel"
SERVICE_SERVER="icmp-tunnel-server"

# ───────────── Install Prerequisites ─────────────
install_prereq() {
  echo -e "${CYAN}Installing dependencies...${NC}"
  apt update && apt install -y make gcc git curl iptables iptables-persistent
}

# ───────────── Install as Local (Client) ─────────────
install_local() {
  install_prereq
  mkdir -p "$WORKDIR"
  echo -e "${YELLOW}Enter FOREIGN (server) IP address:${NC} "
  read -r FOREIGN_SERVER_IP

  # Clone and build icmptunnel
  if [ ! -f "$BIN" ]; then
    git clone https://github.com/jamesbarlow/icmptunnel "$WORKDIR"
    make -C "$WORKDIR"
  fi

  # Client tunnel management script
  cat <<EOF > "$CLIENT_SCRIPT"
#!/usr/bin/env bash
FOREIGN_SERVER_IP="$FOREIGN_SERVER_IP"
ICMPTUNNEL_BIN="$BIN"
LOCAL_TUN_IP="10.0.0.2"
REMOTE_TUN_IP="10.0.0.1"
LOCAL_GATEWAY_FILE="$WORKDIR/local-gateway.txt"

startTunnel() {
  echo "[\$(date)] Starting tunnel to \$FOREIGN_SERVER_IP..."
  \$ICMPTUNNEL_BIN "\$FOREIGN_SERVER_IP" &
  TUN_PID=\$!
  # Give icmptunnel a moment to start and potentially create tun0
  sleep 3 # Increased from 2

  # Wait for tun0 to appear
  for i in {1..5}; do # Try for 5 seconds
    if ip link show tun0 &>/dev/null; then
      echo "[\$(date)] tun0 device found."
      ip addr add "\$LOCAL_TUN_IP/24" dev tun0 2>/dev/null
      ip link set up dev tun0
      sleep 1 # Allow interface to settle

      ip route del default via "\$REMOTE_TUN_IP" dev tun0 2>/dev/null
      ip route del default 2>/dev/null # Clear any other default route

      ip route add default via "\$REMOTE_TUN_IP" dev tun0
      if ip route | grep -q "default via \$REMOTE_TUN_IP dev tun0"; then
        echo "[\$(date)] Tunnel to \$FOREIGN_SERVER_IP established. Routes set."
        return 0 # Success
      else
        echo "[\$(date)] Error: Failed to set default route via \$REMOTE_TUN_IP."
        if ip link show tun0 &>/dev/null; then
            ip link set dev tun0 down 2>/dev/null
        fi
        kill \$TUN_PID 2>/dev/null # Kill the icmptunnel process we started
        return 1 # Failure
      fi
    fi
    if ! ps -p \$TUN_PID > /dev/null; then
        echo "[\$(date)] ICMP tunnel process (PID \$TUN_PID) died before tun0 appeared."
        return 1 # Failure, icmptunnel process died
    fi
    echo "[\$(date)] Waiting for tun0... attempt \$i/5"
    sleep 1
  done

  echo "[\$(date)] Error: tun0 device did not appear after waiting."
  if ps -p \$TUN_PID > /dev/null; then
      echo "[\$(date)] Killing lingering icmptunnel process (PID \$TUN_PID)."
      kill \$TUN_PID 2>/dev/null
  fi
  return 1 # Failure
}

stopTunnel() {
  echo "[\$(date)] Stopping tunnel..."
  # More specific pkill: pkill -SIGTERM -f "\$ICMPTUNNEL_BIN \"\$FOREIGN_SERVER_IP\""
  # Using the existing pkill for now, assuming it's specific enough for this setup.
  # If multiple icmptunnel instances run, this might need refinement (e.g. using PID files or more specific pgrep).
  pkill -SIGTERM -f "\$ICMPTUNNEL_BIN \"\$FOREIGN_SERVER_IP\""
  sleep 1

  if ip link show tun0 &>/dev/null; then
    echo "[\$(date)] Bringing down tun0."
    ip link set dev tun0 down 2>/dev/null
  fi

  echo "[\$(date)] Restoring routes..."
  ip route del default via "\$REMOTE_TUN_IP" dev tun0 2>/dev/null
  ip route del default 2>/dev/null
  if [ -f "\$LOCAL_GATEWAY_FILE" ]; then
    ORIG_GW=\$(cat "\$LOCAL_GATEWAY_FILE")
    echo "[\$(date)] Restoring original default gateway \$ORIG_GW."
    ip route add default via "\$ORIG_GW" 2>/dev/null
  else
    echo "[\$(date)] Original gateway file not found. Cannot restore."
  fi
  echo "[\$(date)] Tunnel stopped."
}

MUST_TERMINATE=0
trap "echo '[\$(date)] Received termination signal.'; MUST_TERMINATE=1; stopTunnel; echo '[\$(date)] Exiting.'; exit 0" INT TERM

# Save original gateway if not already saved
if [ ! -f "\$LOCAL_GATEWAY_FILE" ]; then
  ip route | grep "^default" | awk '{print \$3}' > "\$LOCAL_GATEWAY_FILE"
  echo "[\$(date)] Original gateway saved to \$LOCAL_GATEWAY_FILE."
fi

stopTunnel # Initial stop to ensure clean state

# Try to start the tunnel initially.
if ! startTunnel; then
  echo "[\$(date)] Initial tunnel start failed. Will retry in loop."
fi

# Main monitoring and restart loop
while [ "\$MUST_TERMINATE" = 0 ]; do
  # Check connectivity using the tun0 interface
  # Note: ICMP itself doesn't use ports like TCP/UDP. The :8080 in the curl command below
  # is for a health check. It verifies connectivity to a service expected to be listening
  # on \$REMOTE_TUN_IP (the server's tunnel IP) at port 8080, through the tunnel.
  if curl -s -m 5 --interface tun0 "\$REMOTE_TUN_IP:8080" >/dev/null 2>&1; then
    # echo "[\$(date)] Connectivity OK via tun0." # Uncomment for verbose logging
    sleep 15 # Check less frequently if connection is stable
  else
    echo "[\$(date)] Connectivity check failed or tunnel not fully up. Attempting restart..."
    stopTunnel
    echo "[\$(date)] Waiting 5 seconds before attempting to restart tunnel..."
    sleep 5
    if ! startTunnel; then
      echo "[\$(date)] Failed to restart tunnel. Waiting 30 seconds before next attempt."
      sleep 30 # Longer wait if startTunnel itself fails
    else
      echo "[\$(date)] Tunnel restarted successfully. Waiting 15 seconds before next check."
      sleep 15 # Wait a bit after successful restart before checking again
    fi
  fi
done
EOF
  chmod +x "$CLIENT_SCRIPT"

  # Create systemd service for client
  cat <<EOF > /etc/systemd/system/$SERVICE_CLIENT.service
[Unit]
Description=ICMP Tunnel (Client)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/env bash $CLIENT_SCRIPT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  # Networking configuration
  sysctl -w net.ipv4.ip_forward=1
  sysctl -w net.ipv4.icmp_echo_ignore_all=1
  DEFAULT_IF=`ip route show default | awk '{print $5}'`
  iptables -t nat -A POSTROUTING -o $DEFAULT_IF -j MASQUERADE 2>/dev/null
  iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null
  iptables-save > /etc/iptables/rules.v4
  systemctl enable netfilter-persistent

  # Start the tunnel service
  systemctl daemon-reload
  systemctl enable $SERVICE_CLIENT
  systemctl restart $SERVICE_CLIENT

  echo -e "${GREEN}Client installed and tunnel started!${NC}"
}

# ───────────── Install as Foreign (Server) ─────────────
install_foreign() {
  install_prereq
  mkdir -p "$WORKDIR"
  if [ ! -f "$BIN" ]; then
    git clone https://github.com/jamesbarlow/icmptunnel "$WORKDIR"
    make -C "$WORKDIR"
  fi

  # Server tunnel management script
  cat <<EOF > "$SERVER_SCRIPT"
#!/usr/bin/env bash
ICMPTUNNEL_BIN="$BIN"
TUN_IP="10.0.0.1"
startServer() {
  \$ICMPTUNNEL_BIN -s &
  sleep 2
  ip addr add "\$TUN_IP/24" dev tun0 2>/dev/null
  ip link set up dev tun0
}
stopServer() {
  pkill -SIGTERM -f "\$ICMPTUNNEL_BIN"
}
MUST_TERMINATE=0
trap "MUST_TERMINATE=1; stopServer; exit 0" INT TERM
stopServer
startServer
while [ "\$MUST_TERMINATE" = 0 ]; do sleep 10; done
EOF
  chmod +x "$SERVER_SCRIPT"

  # Create systemd service for server
  cat <<EOF > /etc/systemd/system/$SERVICE_SERVER.service
[Unit]
Description=ICMP Tunnel (Server)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/env bash $SERVER_SCRIPT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  sysctl -w net.ipv4.ip_forward=1
  sysctl -w net.ipv4.icmp_echo_ignore_all=1
  DEFAULT_IF=`ip route show default | awk '{print $5}'`
  iptables -t nat -A POSTROUTING -o $DEFAULT_IF -j MASQUERADE 2>/dev/null
  iptables-save > /etc/iptables/rules.v4
  systemctl enable netfilter-persistent

  systemctl daemon-reload
  systemctl enable $SERVICE_SERVER
  systemctl restart $SERVICE_SERVER

  echo -e "${GREEN}Foreign server installed and tunnel started!${NC}"
}

# ───────────── Service Controls ─────────────
start_tunnel() {
  systemctl restart $SERVICE_CLIENT 2>/dev/null || systemctl restart $SERVICE_SERVER
  echo -e "${GREEN}Tunnel service started.${NC}"
}

stop_tunnel() {
  systemctl stop $SERVICE_CLIENT 2>/dev/null || systemctl stop $SERVICE_SERVER
  echo -e "${RED}Tunnel service stopped.${NC}"
}

status_tunnel() {
  systemctl status $SERVICE_CLIENT --no-pager 2>/dev/null || systemctl status $SERVICE_SERVER --no-pager
}

show_logs() {
  journalctl -u $SERVICE_CLIENT -u $SERVICE_SERVER -n 50 --no-pager
}

uninstall_all() {
  echo -e "${RED}Are you sure you want to remove everything? [y/N]${NC}"
  read -r ANSW
  if [[ "$ANSW" == "y" || "$ANSW" == "Y" ]]; then
    systemctl stop $SERVICE_CLIENT 2>/dev/null
    systemctl stop $SERVICE_SERVER 2>/dev/null
    systemctl disable $SERVICE_CLIENT 2>/dev/null
    systemctl disable $SERVICE_SERVER 2>/dev/null
    rm -f /etc/systemd/system/$SERVICE_CLIENT.service
    rm -f /etc/systemd/system/$SERVICE_SERVER.service
    systemctl daemon-reload
    rm -rf "$WORKDIR"
    echo -e "${GREEN}All ICMP Tunnel components removed.${NC}"
  else
    echo -e "${YELLOW}Uninstall canceled.${NC}"
  fi
}

# ───────────── Main Menu ─────────────
while true; do
  show_menu
  read -p "Enter your choice: " CH
  case "$CH" in
    1) install_local; read -n 1 -s -r -p "Press any key to continue...";;
    2) install_foreign; read -n 1 -s -r -p "Press any key to continue...";;
    3) start_tunnel; read -n 1 -s -r -p "Press any key to continue...";;
    4) stop_tunnel; read -n 1 -s -r -p "Press any key to continue...";;
    5) status_tunnel; read -n 1 -s -r -p "Press any key to continue...";;
    6) show_logs; read -n 1 -s -r -p "Press any key to continue...";;
    7) uninstall_all; read -n 1 -s -r -p "Press any key to continue...";;
    0) echo -e "${MAGENTA}Goodbye!${NC}"; exit 0;;
    *) echo -e "${RED}Invalid option!${NC}"; sleep 1;;
  esac
done
