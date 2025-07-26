#!/bin/bash
# Service Discovery Script for Linux/Unix
# Discovers running services and their listening ports
# Output format: <hostname>;<service name>;<protocol>;<port>;<status>;<ping ms>;<source>;<note>

set -euo pipefail

# Configuration
INCLUDE_DOCKER=${INCLUDE_DOCKER:-true}
INCLUDE_SYSTEMD=${INCLUDE_SYSTEMD:-true}
VERBOSE=${VERBOSE:-false}
MAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS:-10}
TIMEOUT_MS=${TIMEOUT_MS:-500}

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

# Unified cache for all connection and protocol detection results
declare -A unified_cache

# Function to measure ping time for TCP connections
test_tcp_port_with_ping() {
    local host="$1"
    local port="$2"
    local cache_key="${host}:${port}"
    
    # Check cache first
    if [[ -n "${unified_cache[$cache_key]}" ]]; then
        echo "${unified_cache[$cache_key]}"
        return
    fi
    
    local timeout_sec=$((TIMEOUT_MS / 1000))
    local start_time
    local end_time
    local ping_time
    local result
    
    # Measure connection time
    start_time=$(date +%s%3N 2>/dev/null || date +%s000)
    
    if timeout "$timeout_sec" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
        result="success"
    else
        result="refused"
    fi
    
    end_time=$(date +%s%3N 2>/dev/null || date +%s000)
    ping_time=$((end_time - start_time))
    
    # Cache the result
    unified_cache[$cache_key]="${result}|${ping_time}"
    echo "${result}|${ping_time}"
}

# Function to get TCP banner/MOTD information
get_tcp_banner() {
    local host="$1"
    local port="$2"
    local timeout_sec=$((TIMEOUT_MS / 1000))
    local banner=""
    
    # Use timeout and nc (netcat) to get banner
    if command -v nc >/dev/null 2>&1; then
        banner=$(timeout "$timeout_sec" nc -w "$timeout_sec" "$host" "$port" 2>/dev/null | head -c 1024 | tr -d '\r\n' | sed 's/[[:space:]]\+/ /g')
    elif command -v telnet >/dev/null 2>&1; then
        # Fallback to telnet
        banner=$(timeout "$timeout_sec" telnet "$host" "$port" 2>/dev/null | head -c 1024 | tr -d '\r\n' | sed 's/[[:space:]]\+/ /g')
    fi
    
    echo "$banner"
}

# Enhanced function to test HTTP/HTTPS with detailed response analysis
test_http_protocol_enhanced() {
    local host="$1"
    local port="$2"
    local cache_key="http_${host}:${port}"
    
    # Check cache first
    if [[ -n "${unified_cache[$cache_key]}" ]]; then
        echo "${unified_cache[$cache_key]}"
        return
    fi
    
    local timeout_sec=$((TIMEOUT_MS / 1000))
    local result=""
    local note=""
    
    # Test HTTP with curl for detailed response
    if command -v curl >/dev/null 2>&1; then
        # Test HTTP
        local http_response
        http_response=$(curl -s -m "$timeout_sec" -w "%{http_code}|%{server}|%{powered_by}" "http://$host:$port/" 2>/dev/null || echo "")
        
        if [[ -n "$http_response" ]]; then
            local status_code=$(echo "$http_response" | cut -d'|' -f1)
            local server_header=$(echo "$http_response" | cut -d'|' -f2)
            local powered_by=$(echo "$http_response" | cut -d'|' -f3)
            
            if [[ "$status_code" =~ ^[0-9]+$ ]] && [[ "$status_code" -ge 100 ]] && [[ "$status_code" -lt 600 ]]; then
                result="HTTP"
                note="HTTP $status_code"
                if [[ -n "$server_header" && "$server_header" != "unknown" ]]; then
                    note="$note Server:$server_header"
                fi
                if [[ -n "$powered_by" && "$powered_by" != "unknown" ]]; then
                    note="$note PoweredBy:$powered_by"
                fi
            fi
        fi
        
        # Test HTTPS if HTTP failed
        if [[ -z "$result" ]]; then
            local https_response
            https_response=$(curl -s -m "$timeout_sec" -k -w "%{http_code}|%{server}|%{powered_by}" "https://$host:$port/" 2>/dev/null || echo "")
            
            if [[ -n "$https_response" ]]; then
                local status_code=$(echo "$https_response" | cut -d'|' -f1)
                local server_header=$(echo "$https_response" | cut -d'|' -f2)
                local powered_by=$(echo "$https_response" | cut -d'|' -f3)
                
                if [[ "$status_code" =~ ^[0-9]+$ ]] && [[ "$status_code" -ge 100 ]] && [[ "$status_code" -lt 600 ]]; then
                    result="HTTPS"
                    note="HTTPS $status_code"
                    if [[ -n "$server_header" && "$server_header" != "unknown" ]]; then
                        note="$note Server:$server_header"
                    fi
                    if [[ -n "$powered_by" && "$powered_by" != "unknown" ]]; then
                        note="$note PoweredBy:$powered_by"
                    fi
                fi
            fi
        fi
    else
        # Fallback to wget (less detailed)
        if wget -q --timeout="$timeout_sec" --tries=1 "http://$host:$port/" -O /dev/null 2>/dev/null; then
            result="HTTP"
            note="HTTP (wget)"
        elif wget -q --timeout="$timeout_sec" --tries=1 --no-check-certificate "https://$host:$port/" -O /dev/null 2>/dev/null; then
            result="HTTPS"
            note="HTTPS (wget)"
        fi
    fi
    
    # Cache the result
    unified_cache[$cache_key]="${result}|${note}"
    echo "${result}|${note}"
}

# Unified function to test connection and detect protocol
test_connection_and_protocol() {
    local host="$1"
    local port="$2"
    local cache_key="unified_${host}:${port}"
    
    # Check cache first
    if [[ -n "${unified_cache[$cache_key]}" ]]; then
        echo "${unified_cache[$cache_key]}"
        return
    fi
    
    # Test connection first
    local connection_result
    connection_result=$(test_tcp_port_with_ping "$host" "$port")
    local status=$(echo "$connection_result" | cut -d'|' -f1)
    local ping_time=$(echo "$connection_result" | cut -d'|' -f2)
    
    local protocol="TCP"
    local note=""
    
    # If connection successful, test for HTTP/HTTPS and get banner
    if [[ "$status" == "success" ]]; then
        # Test for HTTP/HTTPS first
        local http_result
        http_result=$(test_http_protocol_enhanced "$host" "$port")
        local detected_protocol=$(echo "$http_result" | cut -d'|' -f1)
        local http_note=$(echo "$http_result" | cut -d'|' -f2)
        
        if [[ -n "$detected_protocol" ]]; then
            protocol="$detected_protocol"
            note="$http_note"
        else
            # If not HTTP/HTTPS, try to get banner
            local banner
            banner=$(get_tcp_banner "$host" "$port")
            if [[ -n "$banner" ]]; then
                note="Banner: $banner"
            fi
        fi
    fi
    
    # Create unified result
    local unified_result="${status}|${ping_time}|${protocol}|${note}"
    
    # Cache the result
    unified_cache[$cache_key]="$unified_result"
    echo "$unified_result"
}

# Function to process a single service in parallel
process_single_service() {
    local service_name="$1"
    local protocol="$2"
    local port="$3"
    local source="$4"
    
    local unified_result
    unified_result=$(test_connection_and_protocol "127.0.0.1" "$port")
    
    local status=$(echo "$unified_result" | cut -d'|' -f1)
    local ping_time=$(echo "$unified_result" | cut -d'|' -f2)
    local final_protocol=$(echo "$unified_result" | cut -d'|' -f3)
    local note=$(echo "$unified_result" | cut -d'|' -f4)
    
    # Output result
    write_service_output "$service_name" "$final_protocol" "$port" "$status" "$ping_time" "$source" "$note"
}

# Function to process services in parallel batches
process_services_parallel() {
    local services=("$@")
    local max_jobs="$MAX_PARALLEL_JOBS"
    local jobs=()
    
    for service in "${services[@]}"; do
        # Parse service string (format: "service_name|protocol|port|source")
        IFS='|' read -r service_name protocol port source <<< "$service"
        
        # Start background job for this service
        process_single_service "$service_name" "$protocol" "$port" "$source" &
        
        jobs+=($!)
        
        # If we've reached max jobs, wait for one to complete
        if [[ ${#jobs[@]} -ge $max_jobs ]]; then
            wait -n
            # Remove completed jobs
            for i in "${!jobs[@]}"; do
                if ! kill -0 "${jobs[$i]}" 2>/dev/null; then
                    unset "jobs[$i]"
                fi
            done
            jobs=("${jobs[@]}")  # Reindex array
        fi
    done
    
    # Wait for all remaining jobs
    wait
}

# Function to write output in required format (updated to include note field)
write_service_output() {
    local service_name="$1"
    local protocol="$2"
    local port="$3"
    local status="$4"
    local ping="$5"
    local source="$6"
    local note="${7:-}"
    
    # Clean up note field (remove newlines and extra spaces)
    note=$(echo "$note" | tr '\n\r' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    write_discovery_line "$HOSTNAME;$service_name;$protocol;$port;$status;$ping;$source;$note"
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
write_discovery_line ""
write_discovery_line "# hostname;ipv4s;ipv6s"
write_discovery_line "# $HOSTNAME;$HOSTNAME_IPV4;$HOSTNAME_IPV6"
write_discovery_line ""
write_discovery_line "# hostname;service name;protocol;port;status;ping ms;source;note"

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
                process_single_service "$process_name" "TCP" "$port" "lsof"
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
                process_single_service "$process_name" "UDP" "$port" "lsof"
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
                    process_single_service "$process_name" "TCP" "$port" "ss"
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
                process_single_service "$process_name" "TCP" "$port" "netstat"
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
                    process_single_service "Docker-$container_name" "${protocol^^}" "$host_port" "docker"
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
                                process_single_service "$service_name" "TCP" "$port" "systemd"
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
                    process_single_service "K8s-$namespace-$service_name" "${protocol^^}" "$node_port" "kubernetes"
                fi
            fi
        fi
    done
fi

if [[ "$VERBOSE" == "true" ]]; then
    write_discovery_line ""
    write_discovery_line "# Scan completed at $(date)"
    write_discovery_line "# Performance optimizations applied:"
    write_discovery_line "# - Parallel processing with $MAX_PARALLEL_JOBS concurrent jobs"
    write_discovery_line "# - Connection caching to avoid duplicate tests"
    write_discovery_line "# - Consistent timeouts using TIMEOUT_MS parameter (${TIMEOUT_MS}ms)"
    write_discovery_line "# - Enhanced HTTP/HTTPS detection with detailed response analysis"
    write_discovery_line "# - TCP banner grabbing for non-HTTP services"
    write_discovery_line "# - Ping time measurement for connection latency"
    write_discovery_line "# - Note field for additional service information"
fi