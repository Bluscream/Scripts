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

# Get all local IP addresses (IPv4 and IPv6)
get_local_ips() {
    local ipv4s=()
    local ipv6s=()
    
    # Try different methods to get local IPs
    if command -v ip >/dev/null 2>&1; then
        # Modern Linux systems - IPv4
        while IFS= read -r ip; do
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$ip" != "127.0.0.1" ]] && [[ "$ip" != "169.254."* ]]; then
                ipv4s+=("$ip")
            fi
        done < <(ip -4 addr show | grep -oP 'inet \K\S+' | cut -d'/' -f1)
        
        # Modern Linux systems - IPv6
        while IFS= read -r ip; do
            if [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$ip" != "::1" ]] && [[ "$ip" != "fe80:"* ]]; then
                ipv6s+=("$ip")
            fi
        done < <(ip -6 addr show | grep -oP 'inet6 \K\S+' | cut -d'/' -f1)
    elif command -v ifconfig >/dev/null 2>&1; then
        # Traditional Unix systems - IPv4
        while IFS= read -r ip; do
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$ip" != "127.0.0.1" ]] && [[ "$ip" != "169.254."* ]]; then
                ipv4s+=("$ip")
            fi
        done < <(ifconfig | grep -oP 'inet \K\S+' | cut -d' ' -f1)
        
        # Traditional Unix systems - IPv6
        while IFS= read -r ip; do
            if [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$ip" != "::1" ]] && [[ "$ip" != "fe80:"* ]]; then
                ipv6s+=("$ip")
            fi
        done < <(ifconfig | grep -oP 'inet6 \K\S+' | cut -d' ' -f1)
    fi
    
    # If no IPs found, use hostname
    if [[ ${#ipv4s[@]} -eq 0 ]]; then
        ipv4s=("$HOSTNAME")
    fi
    
    # Return comma-separated lists
    printf '%s|%s' "$(IFS=,; echo "${ipv4s[*]}")" "$(IFS=,; echo "${ipv6s[*]}")"
}

IP_INFO=$(get_local_ips)
HOSTNAME_IPV4=$(echo "$IP_INFO" | cut -d'|' -f1)
HOSTNAME_IPV6=$(echo "$IP_INFO" | cut -d'|' -f2)

LOGFILE="${TMPDIR:-/tmp}/discovery.log"

# Helper function to write to both stdout and log file
write_discovery_line() {
    local line="$1"
    echo "$line" >> "$LOGFILE"
    echo "$line"
}

# Cache for connection results to avoid duplicate tests
declare -A connection_cache

# Optimized function to test TCP connectivity with caching
test_tcp_port() {
    local host="$1"
    local port="$2"
    local cache_key="${host}:${port}"
    
    # Check cache first
    if [[ -n "${connection_cache[$cache_key]}" ]]; then
        echo "${connection_cache[$cache_key]}"
        return
    fi
    
    # Test connection with timeout (reduced from 1.5s to 0.5s)
    local result
    if timeout 0.5 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
        result="success"
    else
        result="refused"
    fi
    
    # Cache the result
    connection_cache[$cache_key]="$result"
    echo "$result"
}

# Optimized function to test HTTP/HTTPS with caching
test_http_protocol() {
    local host="$1"
    local port="$2"
    local cache_key="http_${host}:${port}"
    
    # Check cache first
    if [[ -n "${connection_cache[$cache_key]}" ]]; then
        echo "${connection_cache[$cache_key]}"
        return
    fi
    
    local result=""
    
    # Test HTTP with curl (faster than wget)
    if command -v curl >/dev/null 2>&1; then
        if curl -s -m 1 "http://$host:$port/" >/dev/null 2>&1; then
            result="HTTP"
        elif curl -s -m 1 -k "https://$host:$port/" >/dev/null 2>&1; then
            result="HTTPS"
        fi
    else
        # Fallback to wget
        if wget -q --timeout=1 --tries=1 "http://$host:$port/" -O /dev/null 2>/dev/null; then
            result="HTTP"
        elif wget -q --timeout=1 --tries=1 --no-check-certificate "https://$host:$port/" -O /dev/null 2>/dev/null; then
            result="HTTPS"
        fi
    fi
    
    # Cache the result
    connection_cache[$cache_key]="$result"
    echo "$result"
}

# Optimized function to write service output with connection testing
write_service_output_optimized() {
    local service_name="$1"
    local protocol="$2"
    local port="$3"
    local source="$4"
    
    # Only test TCP connections (skip UDP)
    if [[ "$protocol" == "TCP" ]]; then
        local tcp_result
        tcp_result=$(test_tcp_port "127.0.0.1" "$port")
        
        if [[ "$tcp_result" == "success" ]]; then
            local http_protocol
            http_protocol=$(test_http_protocol "127.0.0.1" "$port")
            if [[ -n "$http_protocol" ]]; then
                protocol="$http_protocol"
            fi
        fi
        
        write_service_output "$service_name" "$protocol" "$port" "$tcp_result" "0" "$source"
    else
        write_service_output "$service_name" "$protocol" "$port" "Listening" "0" "$source"
    fi
}

# Function to write output in required format
write_service_output() {
    local service_name="$1"
    local protocol="$2"
    local port="$3"
    local status="$4"
    local ping="$5"
    local source="$6"
    write_discovery_line "$hostname;$service_name;$protocol;$port;$status;$ping;$source"
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

write_discovery_line "# Service Discovery Results"
write_discovery_line "# Generated at $(date)"
write_discovery_line "# hostname;$HOSTNAME_IPV4;$HOSTNAME_IPV6"
write_discovery_line ""
write_discovery_line "# service name;protocol;port;status;ping ms;source"

# Method 1: lsof (most comprehensive) - Only listening servers
if [[ "$VERBOSE" == "true" ]]; then
    write_discovery_line "Scanning with lsof (listening servers only)..."
fi

if command -v lsof >/dev/null 2>&1; then
    # TCP connections - only LISTENING state
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
                write_service_output_optimized "$process_name" "TCP" "$port" "lsof"
            fi
        fi
    done
    
    # UDP connections - only listening servers
    lsof -iUDP -sUDP:IDLE -n -P 2>/dev/null | tail -n +2 | while read -r line; do
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
                write_service_output_optimized "$process_name" "UDP" "$port" "lsof"
            fi
        fi
    done
fi

# Method 2: ss (modern alternative to netstat) - Only listening servers
if [[ "$VERBOSE" == "true" ]]; then
    write_discovery_line "Scanning with ss (listening servers only)..."
fi

if command -v ss >/dev/null 2>&1; then
    # TCP connections - only LISTEN state
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
                    write_service_output_optimized "$process_name" "TCP" "$port" "ss"
                fi
            fi
        fi
    done
fi

# Method 3: netstat (fallback) - Only listening servers
if [[ "$VERBOSE" == "true" ]]; then
    write_discovery_line "Scanning with netstat (listening servers only)..."
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
                write_service_output_optimized "$process_name" "TCP" "$port" "netstat"
            fi
        fi
    done
fi

# Method 4: Docker containers - Only exposed ports (server ports)
if [[ "$INCLUDE_DOCKER" == "true" ]]; then
    if [[ "$VERBOSE" == "true" ]]; then
        write_discovery_line "Scanning Docker containers (exposed server ports only)..."
    fi
    
    if command -v docker >/dev/null 2>&1; then
        docker ps --format "table {{.Names}}\t{{.Ports}}" 2>/dev/null | tail -n +2 | while read -r line; do
            if [[ $line =~ ([^[:space:]]+)[[:space:]]+(.+) ]]; then
                container_name="${BASH_REMATCH[1]}"
                ports="${BASH_REMATCH[2]}"
                
                # Parse port mappings like "0.0.0.0:8080->80/tcp" (only exposed server ports)
                while [[ $ports =~ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)->([0-9]+)/([[:alpha:]]+) ]]; do
                    host_port="${BASH_REMATCH[2]}"
                    protocol="${BASH_REMATCH[4]}"
                    write_service_output_optimized "Docker-$container_name" "${protocol^^}" "$host_port" "docker"
                    # Remove the matched part to find more ports
                    ports="${ports#*${BASH_REMATCH[0]}}"
                done
            fi
        done
    fi
fi

# Method 5: systemd services - Only services that are actually listening
if [[ "$INCLUDE_SYSTEMD" == "true" ]]; then
    if [[ "$VERBOSE" == "true" ]]; then
        write_discovery_line "Scanning systemd services (listening servers only)..."
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
                                write_service_output_optimized "$service_name" "TCP" "$port" "systemd"
                            fi
                        done
                    fi
                fi
            fi
        done
    fi
fi

# Method 6: Check for Kubernetes services (if kubectl is available) - Only NodePort/LoadBalancer services
if [[ "$VERBOSE" == "true" ]]; then
    write_discovery_line "Scanning Kubernetes services (NodePort/LoadBalancer only)..."
fi

if command -v kubectl >/dev/null 2>&1; then
    kubectl get services --all-namespaces --no-headers 2>/dev/null | while read -r line; do
        if [[ $line =~ ([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
            namespace="${BASH_REMATCH[1]}"
            service_name="${BASH_REMATCH[2]}"
            service_type="${BASH_REMATCH[3]}"
            ports="${BASH_REMATCH[5]}"
            
            # Only include NodePort and LoadBalancer services (actual server ports)
            if [[ "$service_type" == "NodePort" || "$service_type" == "LoadBalancer" ]]; then
                # Parse port mappings like "80:30000/TCP"
                if [[ $ports =~ ([0-9]+):([0-9]+)/([[:alpha:]]+) ]]; then
                    node_port="${BASH_REMATCH[2]}"
                    protocol="${BASH_REMATCH[3]}"
                    write_service_output_optimized "K8s-$namespace-$service_name" "${protocol^^}" "$node_port" "kubernetes"
                fi
            fi
        fi
    done
fi

if [[ "$VERBOSE" == "true" ]]; then
    write_discovery_line ""
    write_discovery_line "# Scan completed at $(date)"
fi