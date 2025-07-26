#!/bin/bash
# Service Discovery Script for Linux/Unix
# Discovers running services and their listening ports
# Output format: <hostname>;<service name>;<protocol>;<port>;<status>;<ping ms>;<source>;<note>
#
# This script always runs all available detection methods (lsof, ss, netstat) and aggregates/deduplicates results.
# Only unique service_name|protocol|port combinations are output.

set -euo pipefail

# Configuration
INCLUDE_DOCKER=${INCLUDE_DOCKER:-true}
INCLUDE_SYSTEMD=${INCLUDE_SYSTEMD:-true}
INCLUDE_WSL=${INCLUDE_WSL:-false}
VERBOSE=${VERBOSE:-true}
MAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS:-10}
TIMEOUT_MS=${TIMEOUT_MS:-500}
GLOBAL_TIMEOUT=${GLOBAL_TIMEOUT:-5}

# Get hostname
HOSTNAME=$(hostname)

# Function to get OS name and version
get_os_name_and_version() {
    local os_name=""
    local os_version=""
    
    # Try /etc/os-release first (most modern Linux systems)
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        os_name="$NAME"
        os_version="$VERSION_ID"
    # Try /etc/lsb-release (Ubuntu/Debian)
    elif [[ -f /etc/lsb-release ]]; then
        source /etc/lsb-release
        os_name="$DISTRIB_ID"
        os_version="$DISTRIB_RELEASE"
    # Try /etc/redhat-release (RHEL/CentOS)
    elif [[ -f /etc/redhat-release ]]; then
        os_name=$(cat /etc/redhat-release | cut -d' ' -f1)
        os_version=$(cat /etc/redhat-release | grep -oE '[0-9]+\.[0-9]+' | head -1)
    # Try uname as fallback
    else
        os_name=$(uname -s)
        os_version=$(uname -r)
    fi
    
    # Clean up the values
    os_name=$(echo "$os_name" | tr '[:upper:]' '[:lower:]' | sed 's/linux//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    os_version=$(echo "$os_version" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    if [[ -z "$os_name" ]]; then
        os_name="unknown"
    fi
    if [[ -z "$os_version" ]]; then
        os_version="unknown"
    fi
    
    echo "$os_name $os_version"
}

# Function to get MAC addresses
get_mac_addresses() {
    local mac_addresses=()
    
    # Try different methods to get MAC addresses
    if command -v ip >/dev/null 2>&1; then
        # Modern Linux systems
        while IFS= read -r mac; do
            if [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] && [[ "$mac" != "00:00:00:00:00:00" ]]; then
                mac_addresses+=("$mac")
            fi
        done < <(ip link show | grep -oP 'link/ether \K[0-9a-f:]+' | tr '[:lower:]' '[:upper:]')
    elif command -v ifconfig >/dev/null 2>&1; then
        # Traditional Unix systems
        while IFS= read -r mac; do
            if [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] && [[ "$mac" != "00:00:00:00:00:00" ]]; then
                mac_addresses+=("$mac")
            fi
        done < <(ifconfig | grep -oP 'ether \K[0-9a-f:]+' | tr '[:lower:]' '[:upper:]')
    fi
    
    # Return comma-separated list
    if [[ ${#mac_addresses[@]} -gt 0 ]]; then
        IFS=','; echo "${mac_addresses[*]}"
    else
        echo ""
    fi
}

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
OS_INFO=$(get_os_name_and_version)
MAC_ADDRESSES=$(get_mac_addresses)

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
    if [[ -v unified_cache[$cache_key] ]]; then
        echo "${unified_cache[$cache_key]}"
        return
    fi
    
    local timeout_sec=$GLOBAL_TIMEOUT
    local start_time
    local end_time
    local ping_time
    local result
    
    # Measure connection time
    start_time=$(date +%s%3N 2>/dev/null || date +%s000)
    if [[ "$VERBOSE" == "true" ]]; then
        echo "+ timeout $timeout_sec bash -c 'echo >/dev/tcp/$host/$port'" >&2
    fi
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

# Enhanced function to get TCP banner/MOTD information
get_tcp_banner() {
    local host="$1"
    local port="$2"
    local timeout_sec=$GLOBAL_TIMEOUT
    local banner=""
    
    if command -v nc >/dev/null 2>&1; then
        if [[ "$VERBOSE" == "true" ]]; then
            echo "+ timeout $timeout_sec nc -w $timeout_sec $host $port" >&2
        fi
        banner=$(timeout "$timeout_sec" nc -w "$timeout_sec" "$host" "$port" 2>/dev/null | head -c 1024 | tr -d '\r\n' | sed 's/[[:space:]]\+/ /g' | sed 's/,/<comma>/g')
    elif command -v telnet >/dev/null 2>&1; then
        if [[ "$VERBOSE" == "true" ]]; then
            echo "+ timeout $timeout_sec telnet $host $port" >&2
        fi
        banner=$(timeout "$timeout_sec" telnet "$host" "$port" 2>/dev/null | head -c 1024 | tr -d '\r\n' | sed 's/[[:space:]]\+/ /g' | sed 's/,/<comma>/g')
    fi
    echo "$banner"
}

# Enhanced function to test HTTP/HTTPS with detailed response analysis
test_http_protocol_enhanced() {
    local host="$1"
    local port="$2"
    local cache_key="http_${host}:${port}"
    
    # Check cache first
    if [[ -v unified_cache[$cache_key] ]]; then
        echo "${unified_cache[$cache_key]}"
        return
    fi
    
    local timeout_sec=$GLOBAL_TIMEOUT
    local result=""
    local note=""
    
    if command -v curl >/dev/null 2>&1; then
        if [[ "$VERBOSE" == "true" ]]; then
            echo "+ curl -s -m $timeout_sec -w ... http://$host:$port/" >&2
        fi
        local http_response
        http_response=$(curl -s -m "$timeout_sec" -w "%{http_code}|%{server}|%{powered_by}" "http://$host:$port/" 2>/dev/null || echo "")
        
        if [[ -n "$http_response" ]]; then
            local status_code=$(echo "$http_response" | cut -d'|' -f1)
            local server_header=$(echo "$http_response" | cut -d'|' -f2)
            local powered_by=$(echo "$http_response" | cut -d'|' -f3)
            
            if [[ "$status_code" =~ ^[0-9]+$ ]] && [[ "$status_code" -ge 100 ]] && [[ "$status_code" -lt 600 ]]; then
                result="HTTP"
                note="Status: $status_code"
                if [[ -n "$server_header" && "$server_header" != "unknown" ]]; then
                    note="$note,Server: $server_header"
                fi
                if [[ -n "$powered_by" && "$powered_by" != "unknown" ]]; then
                    note="$note,PoweredBy: $powered_by"
                fi
            fi
        fi
        
        # Test HTTPS if HTTP failed
        if [[ -z "$result" ]]; then
            if [[ "$VERBOSE" == "true" ]]; then
                echo "+ curl -s -m $timeout_sec -k -w ... https://$host:$port/" >&2
            fi
            local https_response
            https_response=$(curl -s -m "$timeout_sec" -k -w "%{http_code}|%{server}|%{powered_by}" "https://$host:$port/" 2>/dev/null || echo "")
            
            if [[ -n "$https_response" ]]; then
                local status_code=$(echo "$https_response" | cut -d'|' -f1)
                local server_header=$(echo "$https_response" | cut -d'|' -f2)
                local powered_by=$(echo "$https_response" | cut -d'|' -f3)
                
                if [[ "$status_code" =~ ^[0-9]+$ ]] && [[ "$status_code" -ge 100 ]] && [[ "$status_code" -lt 600 ]]; then
                    result="HTTPS"
                    note="Status: $status_code"
                    if [[ -n "$server_header" && "$server_header" != "unknown" ]]; then
                        note="$note,Server: $server_header"
                    fi
                    if [[ -n "$powered_by" && "$powered_by" != "unknown" ]]; then
                        note="$note,PoweredBy: $powered_by"
                    fi
                fi
            fi
        fi
    else
        if [[ "$VERBOSE" == "true" ]]; then
            echo "+ timeout $timeout_sec wget ... http://$host:$port/" >&2
        fi
        if timeout "$timeout_sec" wget -q --timeout="$timeout_sec" --tries=1 "http://$host:$port/" -O /dev/null 2>/dev/null; then
            result="HTTP"
            note="HTTP (wget)"
        elif timeout "$timeout_sec" wget -q --timeout="$timeout_sec" --tries=1 --no-check-certificate "https://$host:$port/" -O /dev/null 2>/dev/null; then
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
    if [[ -v unified_cache[$cache_key] ]]; then
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

# Function to check if WSL is available and get WSL processes
check_wsl_processes() {
    local wsl_processes=()
    
    # Check for WSL processes
    if command -v ps >/dev/null 2>&1; then
        while IFS= read -r process; do
            if [[ "$process" =~ wsl ]] || [[ "$process" =~ ubuntu ]] || [[ "$process" =~ debian ]]; then
                wsl_processes+=("$process")
            fi
        done < <(ps -eo pid,comm --no-headers 2>/dev/null | grep -E "(wsl|ubuntu|debian)" || true)
    fi
    
    echo "${wsl_processes[@]}"
}

# Aggregation: track seen services to deduplicate
# Key: service_name|protocol|port
# Value: 1 (seen)
declare -A seen_services

add_service() {
  local service_name="$1"
  local protocol="$2"
  local port="$3"
  local status="$4"
  local ping="$5"
  local source="$6"
  local note="$7"
  local key="${service_name}|${protocol}|${port}"
  
  if [[ "$VERBOSE" == "true" ]]; then
    write_discovery_line "DEBUG: add_service called - service: $service_name, protocol: $protocol, port: $port, source: $source"
  fi
  
  if [[ -z "${seen_services[$key]:-}" ]]; then
    seen_services[$key]=1
    if [[ "$VERBOSE" == "true" ]]; then
      write_discovery_line "DEBUG: Service is new, adding to output"
    fi
    write_service_output "$service_name" "$protocol" "$port" "$status" "$ping" "$source" "$note"
  else
    if [[ "$VERBOSE" == "true" ]]; then
      write_discovery_line "DEBUG: Service already seen, skipping duplicate"
    fi
  fi
}

write_discovery_line "# Service Discovery Results"
write_discovery_line "# Generated at $(date)"
write_discovery_line ""
write_discovery_line "# hostname;os;ipv4s;ipv6s;macs"
write_discovery_line "$HOSTNAME;$OS_INFO;$HOSTNAME_IPV4;$HOSTNAME_IPV6;$MAC_ADDRESSES"
write_discovery_line ""
write_discovery_line "# hostname;service name;protocol;port;status;ping ms;source;note"

# Method 1: lsof (most comprehensive) - Only listening servers
if [[ "$VERBOSE" == "true" ]]; then
    write_discovery_line "Scanning with lsof (listening servers only)..."
fi

if command -v lsof >/dev/null 2>&1; then
    if [[ "$VERBOSE" == "true" ]]; then
        write_discovery_line "DEBUG: Running lsof -nP -iTCP -sTCP:LISTEN"
        echo "+ timeout $GLOBAL_TIMEOUT lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null" >&2
    fi
    
    # TCP connections - only LISTENING state
    timeout $GLOBAL_TIMEOUT lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print}' | while read -r line; do
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: Processing lsof TCP line: $line"
        fi
        
        process_name=$(echo "$line" | awk '{print $1}')
        pid=$(echo "$line" | awk '{print $2}')
        address=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /TCP/) print $(i+1)}' | cut -d'(' -f1)
        port=$(echo "$address" | awk -F: '{print $NF}')
        
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: lsof TCP parsed - process: $process_name, pid: $pid, address: $address, port: $port"
        fi
        
        if [[ -z "$port" ]]; then 
            if [[ "$VERBOSE" == "true" ]]; then
                write_discovery_line "DEBUG: lsof TCP skipping - no port found"
            fi
            continue
        fi
        
        if [[ "$process_name" == "Unknown" ]]; then
            process_name=$(get_process_name "$pid")
            if [[ "$VERBOSE" == "true" ]]; then
                write_discovery_line "DEBUG: lsof TCP got process name from PID: $process_name"
            fi
        fi
        if [[ "$process_name" == "Unknown" ]]; then
            process_name=$(get_service_name_from_port "$port")
            if [[ "$VERBOSE" == "true" ]]; then
                write_discovery_line "DEBUG: lsof TCP got process name from port: $process_name"
            fi
        fi
        
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: lsof TCP testing connection for $process_name on port $port"
        fi
        
        unified_result=$(test_connection_and_protocol "127.0.0.1" "$port")
        status=$(echo "$unified_result" | cut -d'|' -f1)
        ping_time=$(echo "$unified_result" | cut -d'|' -f2)
        final_protocol=$(echo "$unified_result" | cut -d'|' -f3)
        note=$(echo "$unified_result" | cut -d'|' -f4)
        
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: lsof TCP result - status: $status, protocol: $final_protocol, ping: $ping_time, note: $note"
        fi
        
        add_service "$process_name" "$final_protocol" "$port" "$status" "$ping_time" "lsof" "$note"
    done
    
    if [[ "$VERBOSE" == "true" ]]; then
        write_discovery_line "DEBUG: Finished lsof TCP scanning"
        write_discovery_line "DEBUG: Running lsof -nP -iUDP -sUDP:IDLE"
        echo "+ timeout $GLOBAL_TIMEOUT lsof -nP -iUDP -sUDP:IDLE 2>/dev/null" >&2
    fi
    
    # UDP connections - only listening servers
    timeout $GLOBAL_TIMEOUT lsof -nP -iUDP -sUDP:IDLE 2>/dev/null | awk 'NR>1 {print}' | while read -r line; do
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: Processing lsof UDP line: $line"
        fi
        
        process_name=$(echo "$line" | awk '{print $1}')
        pid=$(echo "$line" | awk '{print $2}')
        address=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /UDP/) print $(i+1)}' | cut -d'(' -f1)
        port=$(echo "$address" | awk -F: '{print $NF}')
        
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: lsof UDP parsed - process: $process_name, pid: $pid, address: $address, port: $port"
        fi
        
        if [[ -z "$port" ]]; then 
            if [[ "$VERBOSE" == "true" ]]; then
                write_discovery_line "DEBUG: lsof UDP skipping - no port found"
            fi
            continue
        fi
        
        if [[ "$process_name" == "Unknown" ]]; then
            process_name=$(get_process_name "$pid")
            if [[ "$VERBOSE" == "true" ]]; then
                write_discovery_line "DEBUG: lsof UDP got process name from PID: $process_name"
            fi
        fi
        if [[ "$process_name" == "Unknown" ]]; then
            process_name=$(get_service_name_from_port "$port")
            if [[ "$VERBOSE" == "true" ]]; then
                write_discovery_line "DEBUG: lsof UDP got process name from port: $process_name"
            fi
        fi
        
        add_service "$process_name" "UDP" "$port" "" "" "lsof" ""
    done
    
    if [[ "$VERBOSE" == "true" ]]; then
        write_discovery_line "DEBUG: Finished lsof UDP scanning"
    fi
else
    if [[ "$VERBOSE" == "true" ]]; then
        write_discovery_line "DEBUG: lsof command not found"
    fi
fi

# Method 2: ss (modern alternative to netstat) - Only listening servers
if [[ "$VERBOSE" == "true" ]]; then
    write_discovery_line "Scanning with ss (listening servers only)..."
fi

if command -v ss >/dev/null 2>&1; then
    if [[ "$VERBOSE" == "true" ]]; then
        write_discovery_line "DEBUG: Running ss -tlnp"
        echo "+ timeout $GLOBAL_TIMEOUT ss -tlnp 2>/dev/null" >&2
    fi
    
    # TCP connections - only LISTEN state
    timeout $GLOBAL_TIMEOUT ss -tlnp 2>/dev/null | awk 'NR>1 {print}' | while read -r line; do
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: Processing ss TCP line: $line"
        fi
        
        local_address=$(echo "$line" | awk '{print $4}')
        port=$(echo "$local_address" | awk -F: '{print $NF}')
        process_info=$(echo "$line" | awk '{print $5}')
        process_name=$(echo "$process_info" | grep -oP 'users:\(\("([^"]+)' | head -1 | cut -d'"' -f2)
        
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: ss TCP parsed - local_address: $local_address, port: $port, process_info: $process_info, process_name: $process_name"
        fi
        
        if [[ -z "$port" ]]; then 
            if [[ "$VERBOSE" == "true" ]]; then
                write_discovery_line "DEBUG: ss TCP skipping - no port found"
            fi
            continue
        fi
        
        if [[ -z "$process_name" ]]; then
            process_name=$(get_service_name_from_port "$port")
            if [[ "$VERBOSE" == "true" ]]; then
                write_discovery_line "DEBUG: ss TCP got process name from port: $process_name"
            fi
        fi
        
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: ss TCP testing connection for $process_name on port $port"
        fi
        
        unified_result=$(test_connection_and_protocol "127.0.0.1" "$port")
        status=$(echo "$unified_result" | cut -d'|' -f1)
        ping_time=$(echo "$unified_result" | cut -d'|' -f2)
        final_protocol=$(echo "$unified_result" | cut -d'|' -f3)
        note=$(echo "$unified_result" | cut -d'|' -f4)
        
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: ss TCP result - status: $status, protocol: $final_protocol, ping: $ping_time, note: $note"
        fi
        
        add_service "$process_name" "$final_protocol" "$port" "$status" "$ping_time" "ss" "$note"
    done
    
    if [[ "$VERBOSE" == "true" ]]; then
        write_discovery_line "DEBUG: Finished ss TCP scanning"
        write_discovery_line "DEBUG: Running ss -ulnp"
        echo "+ timeout $GLOBAL_TIMEOUT ss -ulnp 2>/dev/null" >&2
    fi
    
    # UDP connections - only listening state
    timeout $GLOBAL_TIMEOUT ss -ulnp 2>/dev/null | awk 'NR>1 {print}' | while read -r line; do
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: Processing ss UDP line: $line"
        fi
        
        local_address=$(echo "$line" | awk '{print $4}')
        port=$(echo "$local_address" | awk -F: '{print $NF}')
        process_info=$(echo "$line" | awk '{print $5}')
        process_name=$(echo "$process_info" | grep -oP 'users:\(\("([^"]+)' | head -1 | cut -d'"' -f2)
        
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: ss UDP parsed - local_address: $local_address, port: $port, process_info: $process_info, process_name: $process_name"
        fi
        
        if [[ -z "$port" ]]; then 
            if [[ "$VERBOSE" == "true" ]]; then
                write_discovery_line "DEBUG: ss UDP skipping - no port found"
            fi
            continue
        fi
        
        if [[ -z "$process_name" ]]; then
            process_name=$(get_service_name_from_port "$port")
            if [[ "$VERBOSE" == "true" ]]; then
                write_discovery_line "DEBUG: ss UDP got process name from port: $process_name"
            fi
        fi
        
        add_service "$process_name" "UDP" "$port" "" "" "ss" ""
    done
    
    if [[ "$VERBOSE" == "true" ]]; then
        write_discovery_line "DEBUG: Finished ss UDP scanning"
    fi
else
    if [[ "$VERBOSE" == "true" ]]; then
        write_discovery_line "DEBUG: ss command not found"
    fi
fi

# Method 3: netstat (fallback) - Only listening servers
if [[ "$VERBOSE" == "true" ]]; then
    write_discovery_line "Scanning with netstat (listening servers only)..."
fi

if command -v netstat >/dev/null 2>&1; then
    if [[ "$VERBOSE" == "true" ]]; then
        write_discovery_line "DEBUG: Running netstat -tlnp"
        echo "+ timeout $GLOBAL_TIMEOUT netstat -tlnp 2>/dev/null" >&2
    fi
    
    netstat -tlnp 2>/dev/null | awk 'NR>2 {print}' | while read -r line; do
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: Processing netstat TCP line: $line"
        fi
        
        local_address=$(echo "$line" | awk '{print $4}')
        port=$(echo "$local_address" | awk -F: '{print $NF}')
        process_info=$(echo "$line" | awk '{print $7}')
        process_name=$(echo "$process_info" | awk -F/ '{print $2}')
        
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: netstat TCP parsed - local_address: $local_address, port: $port, process_info: $process_info, process_name: $process_name"
        fi
        
        if [[ -z "$port" ]]; then 
            if [[ "$VERBOSE" == "true" ]]; then
                write_discovery_line "DEBUG: netstat TCP skipping - no port found"
            fi
            continue
        fi
        
        if [[ -z "$process_name" || "$process_name" == "-" ]]; then
            process_name=$(get_service_name_from_port "$port")
            if [[ "$VERBOSE" == "true" ]]; then
                write_discovery_line "DEBUG: netstat TCP got process name from port: $process_name"
            fi
        fi
        
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: netstat TCP testing connection for $process_name on port $port"
        fi
        
        unified_result=$(test_connection_and_protocol "127.0.0.1" "$port")
        status=$(echo "$unified_result" | cut -d'|' -f1)
        ping_time=$(echo "$unified_result" | cut -d'|' -f2)
        final_protocol=$(echo "$unified_result" | cut -d'|' -f3)
        note=$(echo "$unified_result" | cut -d'|' -f4)
        
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: netstat TCP result - status: $status, protocol: $final_protocol, ping: $ping_time, note: $note"
        fi
        
        add_service "$process_name" "$final_protocol" "$port" "$status" "$ping_time" "netstat" "$note"
    done
    
    if [[ "$VERBOSE" == "true" ]]; then
        write_discovery_line "DEBUG: Finished netstat TCP scanning"
        write_discovery_line "DEBUG: Running netstat -ulnp"
        echo "+ timeout $GLOBAL_TIMEOUT netstat -ulnp 2>/dev/null" >&2
    fi
    
    # UDP connections
    netstat -ulnp 2>/dev/null | awk 'NR>2 {print}' | while read -r line; do
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: Processing netstat UDP line: $line"
        fi
        
        local_address=$(echo "$line" | awk '{print $4}')
        port=$(echo "$local_address" | awk -F: '{print $NF}')
        process_info=$(echo "$line" | awk '{print $7}')
        process_name=$(echo "$process_info" | awk -F/ '{print $2}')
        
        if [[ "$VERBOSE" == "true" ]]; then
            write_discovery_line "DEBUG: netstat UDP parsed - local_address: $local_address, port: $port, process_info: $process_info, process_name: $process_name"
        fi
        
        if [[ -z "$port" ]]; then 
            if [[ "$VERBOSE" == "true" ]]; then
                write_discovery_line "DEBUG: netstat UDP skipping - no port found"
            fi
            continue
        fi
        
        if [[ -z "$process_name" || "$process_name" == "-" ]]; then
            process_name=$(get_service_name_from_port "$port")
            if [[ "$VERBOSE" == "true" ]]; then
                write_discovery_line "DEBUG: netstat UDP got process name from port: $process_name"
            fi
        fi
        
        add_service "$process_name" "UDP" "$port" "" "" "netstat" ""
    done
    
    if [[ "$VERBOSE" == "true" ]]; then
        write_discovery_line "DEBUG: Finished netstat UDP scanning"
    fi
else
    if [[ "$VERBOSE" == "true" ]]; then
        write_discovery_line "DEBUG: netstat command not found"
    fi
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

# Method 6: WSL processes (if WSL is available) - Only listening servers
if [[ "$INCLUDE_WSL" == "true" ]]; then
    if [[ "$VERBOSE" == "true" ]]; then
        write_discovery_line "Scanning WSL processes (listening servers only)..."
    fi
    
    wsl_processes=$(check_wsl_processes)
    if [[ -n "$wsl_processes" ]]; then
        for process in $wsl_processes; do
            if [[ $process =~ ([0-9]+) ]]; then
                pid="${BASH_REMATCH[1]}"
                process_name=$(get_process_name "$pid")
                
                # Check if this WSL process is listening on any ports
                if command -v lsof >/dev/null 2>&1; then
                    lsof -iTCP -sTCP:LISTEN -p "$pid" -n -P 2>/dev/null | tail -n +2 | while read -r lsof_line; do
                        if [[ $lsof_line =~ :([0-9]+)$ ]]; then
                            port="${BASH_REMATCH[1]}"
                            process_single_service "WSL-$process_name" "TCP" "$port" "WSL"
                        fi
                    done
                fi
            fi
        done
    fi
fi

# Method 7: Check for Kubernetes services (if kubectl is available) - Only NodePort/LoadBalancer services
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
    write_discovery_line "# Summary:"
    write_discovery_line "# - Total unique services found: ${#seen_services[@]}"
    write_discovery_line "# - Performance optimizations applied:"
    write_discovery_line "# - Parallel processing with $MAX_PARALLEL_JOBS concurrent jobs"
    write_discovery_line "# - Connection caching to avoid duplicate tests"
    write_discovery_line "# - Consistent timeouts using TIMEOUT_MS parameter (${TIMEOUT_MS}ms)"
    write_discovery_line "# - Enhanced HTTP/HTTPS detection with detailed response analysis"
    write_discovery_line "# - TCP banner grabbing for non-HTTP services"
    write_discovery_line "# - Ping time measurement for connection latency"
    write_discovery_line "# - Note field for additional service information"
    write_discovery_line "# - OS and MAC address detection"
    write_discovery_line "# - WSL process detection"
    write_discovery_line "# - Enhanced UDP service detection"
    write_discovery_line "# - Improved error handling and verbose output"
    write_discovery_line "# - Deduplication using associative arrays"
fi