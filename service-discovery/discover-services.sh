#!/bin/bash
# Service Discovery Script for Linux/Unix
# Discovers running services and their listening ports
# Output format: <hostname>;<service name>;<protocol>;<port>;<status>;<ping ms>;<source>

set -euo pipefail

# Configuration
INCLUDE_DOCKER=${INCLUDE_DOCKER:-true}
INCLUDE_SYSTEMD=${INCLUDE_SYSTEMD:-true}
VERBOSE=${VERBOSE:-false}

# Get hostname
HOSTNAME=$(hostname)

# Get all local IP addresses
get_local_ips() {
    local ips=()
    
    # Try different methods to get local IPs
    if command -v ip >/dev/null 2>&1; then
        # Modern Linux systems
        while IFS= read -r ip; do
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$ip" != "127.0.0.1" ]] && [[ "$ip" != "169.254."* ]]; then
                ips+=("$ip")
            fi
        done < <(ip -4 addr show | grep -oP 'inet \K\S+' | cut -d'/' -f1)
    elif command -v ifconfig >/dev/null 2>&1; then
        # Traditional Unix systems
        while IFS= read -r ip; do
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$ip" != "127.0.0.1" ]] && [[ "$ip" != "169.254."* ]]; then
                ips+=("$ip")
            fi
        done < <(ifconfig | grep -oP 'inet \K\S+' | cut -d' ' -f1)
    fi
    
    # If no IPs found, use hostname
    if [[ ${#ips[@]} -eq 0 ]]; then
        ips=("$HOSTNAME")
    fi
    
    # Return comma-separated list
    printf '%s' "$(IFS=,; echo "${ips[*]}")"
}

HOSTNAME=$(get_local_ips)
LOGFILE="${TMPDIR:-/tmp}/discovery.log"

# Helper function to write to both stdout and log file
write_discovery_line() {
    local line="$1"
    echo "$line" >> "$LOGFILE"
    echo "$line"
}

# Function to write output in required format
write_service_output() {
    local service_name="$1"
    local protocol="$2"
    local port="$3"
    local status="$4"
    local ping="$5"
    local source="$6"
    local detected_protocol="$7"
    local out_proto
    if [[ -n "$detected_protocol" ]]; then
        out_proto="$detected_protocol"
    else
        out_proto="$protocol"
    fi
    write_discovery_line "$HOSTNAME;$service_name;$out_proto;$port;$status;$ping;$source"
}

# Function to get service name from port
get_service_name_from_port() {
    local port="$1"
    local proto="${2:-tcp}"  # Optionally allow protocol, default to tcp

    # First, try /etc/services
    if [[ -r /etc/services ]]; then
        # Find the first matching service name for the port and protocol
        local svc
        svc=$(awk -v p="$port" -v proto="$proto" '
            $0 !~ /^#/ && $2 ~ "^"p"/"proto"$" { print $1; exit }
        ' /etc/services)
        if [[ -n "$svc" ]]; then
            echo "$svc"
            return
        fi
    fi

    # Fallback to common port mappings
    case "$port" in
        21) echo "FTP" ;;
        22) echo "SSH" ;;
        23) echo "Telnet" ;;
        25) echo "SMTP" ;;
        53) echo "DNS" ;;
        80) echo "HTTP" ;;
        110) echo "POP3" ;;
        143) echo "IMAP" ;;
        443) echo "HTTPS" ;;
        993) echo "IMAPS" ;;
        995) echo "POP3S" ;;
        1433) echo "MSSQL" ;;
        1521) echo "Oracle" ;;
        3306) echo "MySQL" ;;
        3389) echo "RDP" ;;
        5432) echo "PostgreSQL" ;;
        5900) echo "VNC" ;;
        6379) echo "Redis" ;;
        8080) echo "HTTP-Alt" ;;
        8443) echo "HTTPS-Alt" ;;
        9000) echo "Jenkins" ;;
        27017) echo "MongoDB" ;;
        *) echo "Unknown" ;;
    esac
}

# Function to get process name from PID
get_process_name() {
    local pid="$1"
    if [[ -f "/proc/$pid/comm" ]]; then
        cat "/proc/$pid/comm" 2>/dev/null || echo "Unknown"
    else
        echo "Unknown"
    fi
}

write_discovery_line "# Service Discovery Results for $HOSTNAME"
write_discovery_line "# Generated at $(date)"
write_discovery_line ""

# Method 1: lsof (most comprehensive)
if [[ "$VERBOSE" == "true" ]]; then
    write_discovery_line "Scanning with lsof..."
fi

if command -v lsof >/dev/null 2>&1; then
    # TCP connections
    lsof -iTCP -sTCP:LISTEN -n -P 2>/dev/null | tail -n +2 | while read -r line; do
        if [[ $line =~ ([[:space:]]+)([0-9]+)([[:space:]]+)([^[:space:]]+)([[:space:]]+)([^[:space:]]+)([[:space:]]+)([^[:space:]]+)([[:space:]]+)([^[:space:]]+:[0-9]+) ]]; then
            pid="${BASH_REMATCH[2]}"
            process_name="${BASH_REMATCH[4]}"
            address="${BASH_REMATCH[10]}"
            
            if [[ $address =~ :([0-9]+)$ ]]; then
                port="${BASH_REMATCH[1]}"
                if [[ "$process_name" == "Unknown" ]]; then
                    process_name=$(get_process_name "$pid")
                fi
                if [[ "$process_name" == "Unknown" ]]; then
                    process_name=$(get_service_name_from_port "$port")
                fi
                write_service_output "$process_name" "TCP" "$port" "Listening" "0" "lsof" ""
            fi
        fi
    done
    
    # UDP connections
    lsof -iUDP -n -P 2>/dev/null | tail -n +2 | while read -r line; do
        if [[ $line =~ ([[:space:]]+)([0-9]+)([[:space:]]+)([^[:space:]]+)([[:space:]]+)([^[:space:]]+)([[:space:]]+)([^[:space:]]+)([[:space:]]+)([^[:space:]]+:[0-9]+) ]]; then
            pid="${BASH_REMATCH[2]}"
            process_name="${BASH_REMATCH[4]}"
            address="${BASH_REMATCH[10]}"
            
            if [[ $address =~ :([0-9]+)$ ]]; then
                port="${BASH_REMATCH[1]}"
                if [[ "$process_name" == "Unknown" ]]; then
                    process_name=$(get_process_name "$pid")
                fi
                if [[ "$process_name" == "Unknown" ]]; then
                    process_name=$(get_service_name_from_port "$port")
                fi
                write_service_output "$process_name" "UDP" "$port" "Listening" "0" "lsof" ""
            fi
        fi
    done
fi

# Method 2: ss (modern alternative to netstat)
if [[ "$VERBOSE" == "true" ]]; then
    write_discovery_line "Scanning with ss..."
fi

if command -v ss >/dev/null 2>&1; then
    # TCP connections
    ss -tlnp 2>/dev/null | tail -n +2 | while read -r line; do
        if [[ $line =~ ([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
            local_address="${BASH_REMATCH[4]}"
            if [[ $local_address =~ :([0-9]+)$ ]]; then
                port="${BASH_REMATCH[1]}"
                process_info="${BASH_REMATCH[5]}"
                
                if [[ $process_info =~ pid=([0-9]+) ]]; then
                    pid="${BASH_REMATCH[1]}"
                    process_name=$(get_process_name "$pid")
                    if [[ "$process_name" == "Unknown" ]]; then
                        process_name=$(get_service_name_from_port "$port")
                    fi
                    write_service_output "$process_name" "TCP" "$port" "Listening" "0" "ss" ""
                fi
            fi
        fi
    done
fi

# Method 3: netstat (fallback)
if [[ "$VERBOSE" == "true" ]]; then
    write_discovery_line "Scanning with netstat..."
fi

if command -v netstat >/dev/null 2>&1; then
    netstat -tlnp 2>/dev/null | tail -n +2 | while read -r line; do
        if [[ $line =~ ([^[:space:]]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
            port="${BASH_REMATCH[4]}"
            process_info="${BASH_REMATCH[7]}"
            
            if [[ $process_info =~ ([0-9]+)/([^[:space:]]+) ]]; then
                pid="${BASH_REMATCH[1]}"
                process_name="${BASH_REMATCH[2]}"
                if [[ "$process_name" == "Unknown" ]]; then
                    process_name=$(get_process_name "$pid")
                fi
                if [[ "$process_name" == "Unknown" ]]; then
                    process_name=$(get_service_name_from_port "$port")
                fi
                write_service_output "$process_name" "TCP" "$port" "Listening" "0" "netstat" ""
            fi
        fi
    done
fi

# Method 4: Docker containers
if [[ "$INCLUDE_DOCKER" == "true" ]]; then
    if [[ "$VERBOSE" == "true" ]]; then
        write_discovery_line "Scanning Docker containers..."
    fi
    
    if command -v docker >/dev/null 2>&1; then
        docker ps --format "table {{.Names}}\t{{.Ports}}" 2>/dev/null | tail -n +2 | while read -r line; do
            if [[ $line =~ ([^[:space:]]+)[[:space:]]+(.+) ]]; then
                container_name="${BASH_REMATCH[1]}"
                ports="${BASH_REMATCH[2]}"
                
                # Parse port mappings like "0.0.0.0:8080->80/tcp"
                while [[ $ports =~ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)->([0-9]+)/([[:alpha:]]+) ]]; do
                    host_port="${BASH_REMATCH[2]}"
                    protocol="${BASH_REMATCH[4]}"
                    write_service_output "Docker-$container_name" "${protocol^^}" "$host_port" "Listening" "0" "docker" ""
                    # Remove the matched part to find more ports
                    ports="${ports#*${BASH_REMATCH[0]}}"
                done
            fi
        done
    fi
fi

# Method 5: systemd services
if [[ "$INCLUDE_SYSTEMD" == "true" ]]; then
    if [[ "$VERBOSE" == "true" ]]; then
        write_discovery_line "Scanning systemd services..."
    fi
    
    if command -v systemctl >/dev/null 2>&1; then
        systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | while read -r line; do
            if [[ $line =~ ([^[:space:]]+)\.service ]]; then
                service_name="${BASH_REMATCH[1]}"
                
                # Try to find if the service is listening on any port
                if command -v lsof >/dev/null 2>&1; then
                    service_pid=$(systemctl show -p MainPID "$service_name.service" --value 2>/dev/null)
                    if [[ -n "$service_pid" && "$service_pid" != "0" ]]; then
                        lsof -iTCP -sTCP:LISTEN -p "$service_pid" -n -P 2>/dev/null | tail -n +2 | while read -r lsof_line; do
                            if [[ $lsof_line =~ :([0-9]+)$ ]]; then
                                port="${BASH_REMATCH[1]}"
                                write_service_output "$service_name" "TCP" "$port" "Listening" "0" "systemd" ""
                            fi
                        done
                    fi
                fi
            fi
        done
    fi
fi

# Method 6: Check for Kubernetes services (if kubectl is available)
if [[ "$VERBOSE" == "true" ]]; then
    write_discovery_line "Scanning Kubernetes services..."
fi

if command -v kubectl >/dev/null 2>&1; then
    kubectl get services --all-namespaces --no-headers 2>/dev/null | while read -r line; do
        if [[ $line =~ ([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
            namespace="${BASH_REMATCH[1]}"
            service_name="${BASH_REMATCH[2]}"
            ports="${BASH_REMATCH[5]}"
            
            # Parse port mappings like "80:30000/TCP"
            if [[ $ports =~ ([0-9]+):([0-9]+)/([[:alpha:]]+) ]]; then
                node_port="${BASH_REMATCH[2]}"
                protocol="${BASH_REMATCH[3]}"
                write_service_output "K8s-$namespace-$service_name" "${protocol^^}" "$node_port" "Listening" "0" "kubernetes" ""
            fi
        fi
    done
fi

if [[ "$VERBOSE" == "true" ]]; then
    write_discovery_line ""
    write_discovery_line "# Scan completed at $(date)"
fi