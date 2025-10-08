using namespace System.Collections.Generic

<#
.SYNOPSIS
    AdGuard Home API Wrapper Class for PowerShell
.DESCRIPTION
    A comprehensive PowerShell class wrapper for the AdGuard Home REST API (v0.107)
    Based on the official AdGuard Home OpenAPI specification
.NOTES
    Author: Generated from OpenAPI spec
    Version: 0.107
#>

class AdGuardHomeAPI {
    # Connection Properties
    [string]$BaseUrl
    [string]$Username
    [string]$Password
    [hashtable]$Headers
    [bool]$SkipCertificateCheck = $false
    
    # Constructor with basic auth (string password)
    AdGuardHomeAPI([string]$baseUrl, [string]$username, [string]$password) {
        $this.BaseUrl = $baseUrl.TrimEnd('/')
        $this.Username = $username
        $this.Password = $password
        $this.InitializeHeaders()
    }
    
    # Constructor with basic auth (secure string password)
    AdGuardHomeAPI([string]$baseUrl, [string]$username, [securestring]$securePassword) {
        $this.BaseUrl = $baseUrl.TrimEnd('/')
        $this.Username = $username
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        $this.Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $this.InitializeHeaders()
    }
    
    # Constructor with URL only (for already authenticated sessions or manual header setup)
    AdGuardHomeAPI([string]$baseUrl) {
        $this.BaseUrl = $baseUrl.TrimEnd('/')
        $this.InitializeHeaders()
    }
    
    # Static method to create instance from environment token (like AGHOME_TOKEN)
    static [AdGuardHomeAPI] FromToken([string]$baseUrl, [string]$token) {
        $instance = [AdGuardHomeAPI]::new($baseUrl)
        $instance.Headers['Authorization'] = "Basic $token"
        return $instance
    }
    
    # Static method to create instance from environment variable
    static [AdGuardHomeAPI] FromEnvironment([string]$baseUrl, [string]$envVarName = "AGHOME_TOKEN") {
        $token = [Environment]::GetEnvironmentVariable($envVarName)
        if (-not $token) {
            throw "Environment variable '$envVarName' not set"
        }
        return [AdGuardHomeAPI]::FromToken($baseUrl, $token)
    }
    
    # Initialize headers with basic auth
    hidden [void] InitializeHeaders() {
        $this.Headers = @{
            'Content-Type' = 'application/json'
            'Accept'       = 'application/json'
        }
        
        if ($this.Username -and $this.Password) {
            $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($this.Username):$($this.Password)"))
            $this.Headers['Authorization'] = "Basic $base64AuthInfo"
        }
    }
    
    # Generic HTTP request method
    hidden [object] InvokeRequest([string]$method, [string]$endpoint, [object]$body = $null, [hashtable]$queryParams = $null) {
        $uri = "$($this.BaseUrl)/control$endpoint"
        
        # Add query parameters
        if ($queryParams -and $queryParams.Count -gt 0) {
            $queryString = ($queryParams.GetEnumerator() | ForEach-Object {
                    "$($_.Key)=$([System.Web.HttpUtility]::UrlEncode($_.Value))"
                }) -join '&'
            $uri += "?$queryString"
        }
        
        $params = @{
            Uri     = $uri
            Method  = $method
            Headers = $this.Headers
        }
        
        if ($body) {
            $params['Body'] = ($body | ConvertTo-Json -Depth 10 -Compress)
        }
        
        if ($this.SkipCertificateCheck) {
            $params['SkipCertificateCheck'] = $true
        }
        
        try {
            $response = Invoke-RestMethod @params
            return $response
        }
        catch {
            Write-Error "API Request Failed: $($_.Exception.Message)"
            throw
        }
    }
    
    # ============================================================================
    # GLOBAL / SERVER OPERATIONS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Get DNS server current status and general settings
    #>
    [object] GetStatus() {
        return $this.InvokeRequest('GET', '/status')
    }
    
    <#
    .SYNOPSIS
        Get general DNS parameters
    #>
    [object] GetDnsInfo() {
        return $this.InvokeRequest('GET', '/dns_info')
    }
    
    <#
    .SYNOPSIS
        Set general DNS parameters
    #>
    [object] SetDnsConfig([object]$config) {
        return $this.InvokeRequest('POST', '/dns_config', $config)
    }
    
    <#
    .SYNOPSIS
        Set protection state and duration
    #>
    [object] SetProtection([bool]$enabled, [int]$duration = 0) {
        $body = @{
            enabled = $enabled
        }
        if ($duration -gt 0) {
            $body['duration'] = $duration
        }
        return $this.InvokeRequest('POST', '/protection', $body)
    }
    
    <#
    .SYNOPSIS
        Clear DNS cache
    #>
    [object] ClearCache() {
        return $this.InvokeRequest('POST', '/cache_clear')
    }
    
    <#
    .SYNOPSIS
        Test upstream DNS configuration
    #>
    [object] TestUpstreamDNS([object]$upstreamsConfig) {
        return $this.InvokeRequest('POST', '/test_upstream_dns', $upstreamsConfig)
    }
    
    <#
    .SYNOPSIS
        Get information about the latest available version of AdGuard Home
    #>
    [object] GetVersionInfo([bool]$recheckNow = $false) {
        $body = @{
            recheck_now = $recheckNow
        }
        return $this.InvokeRequest('POST', '/version.json', $body)
    }
    
    <#
    .SYNOPSIS
        Begin auto-upgrade procedure
    #>
    [object] BeginUpdate() {
        return $this.InvokeRequest('POST', '/update')
    }
    
    # ============================================================================
    # QUERY LOG OPERATIONS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Get DNS server query log
    #>
    [object] GetQueryLog([string]$olderThan = $null, [int]$offset = 0, [int]$limit = 0, [string]$search = $null, [string]$responseStatus = $null) {
        $queryParams = @{}
        
        if ($olderThan) { $queryParams['older_than'] = $olderThan }
        if ($offset -gt 0) { $queryParams['offset'] = $offset }
        if ($limit -gt 0) { $queryParams['limit'] = $limit }
        if ($search) { $queryParams['search'] = $search }
        if ($responseStatus) { $queryParams['response_status'] = $responseStatus }
        
        return $this.InvokeRequest('GET', '/querylog', $null, $queryParams)
    }
    
    <#
    .SYNOPSIS
        Clear query log
    #>
    [object] ClearQueryLog() {
        return $this.InvokeRequest('POST', '/querylog_clear')
    }
    
    <#
    .SYNOPSIS
        Get query log configuration
    #>
    [object] GetQueryLogConfig() {
        return $this.InvokeRequest('GET', '/querylog/config')
    }
    
    <#
    .SYNOPSIS
        Set query log configuration
    #>
    [object] SetQueryLogConfig([object]$config) {
        return $this.InvokeRequest('PUT', '/querylog/config/update', $config)
    }
    
    # ============================================================================
    # STATISTICS OPERATIONS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Get DNS server statistics
    #>
    [object] GetStats() {
        return $this.InvokeRequest('GET', '/stats')
    }
    
    <#
    .SYNOPSIS
        Reset all statistics to zeroes
    #>
    [object] ResetStats() {
        return $this.InvokeRequest('POST', '/stats_reset')
    }
    
    <#
    .SYNOPSIS
        Get statistics configuration
    #>
    [object] GetStatsConfig() {
        return $this.InvokeRequest('GET', '/stats/config')
    }
    
    <#
    .SYNOPSIS
        Set statistics configuration
    #>
    [object] SetStatsConfig([object]$config) {
        return $this.InvokeRequest('PUT', '/stats/config/update', $config)
    }
    
    # ============================================================================
    # TLS OPERATIONS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Get TLS configuration and status
    #>
    [object] GetTlsStatus() {
        return $this.InvokeRequest('GET', '/tls/status')
    }
    
    <#
    .SYNOPSIS
        Update TLS configuration
    #>
    [object] ConfigureTls([object]$tlsConfig) {
        return $this.InvokeRequest('POST', '/tls/configure', $tlsConfig)
    }
    
    <#
    .SYNOPSIS
        Validate TLS configuration
    #>
    [object] ValidateTls([object]$tlsConfig) {
        return $this.InvokeRequest('POST', '/tls/validate', $tlsConfig)
    }
    
    # ============================================================================
    # DHCP OPERATIONS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Get current DHCP settings and status
    #>
    [object] GetDhcpStatus() {
        return $this.InvokeRequest('GET', '/dhcp/status')
    }
    
    <#
    .SYNOPSIS
        Get available network interfaces
    #>
    [object] GetDhcpInterfaces() {
        return $this.InvokeRequest('GET', '/dhcp/interfaces')
    }
    
    <#
    .SYNOPSIS
        Set DHCP server configuration
    #>
    [object] SetDhcpConfig([object]$config) {
        return $this.InvokeRequest('POST', '/dhcp/set_config', $config)
    }
    
    <#
    .SYNOPSIS
        Search for active DHCP server on the network
    #>
    [object] FindActiveDhcp([string]$interface) {
        return $this.InvokeRequest('POST', '/dhcp/find_active_dhcp', @{ interface = $interface })
    }
    
    <#
    .SYNOPSIS
        Add a DHCP static lease
    #>
    [object] AddDhcpStaticLease([object]$lease) {
        return $this.InvokeRequest('POST', '/dhcp/add_static_lease', $lease)
    }
    
    <#
    .SYNOPSIS
        Remove a DHCP static lease
    #>
    [object] RemoveDhcpStaticLease([object]$lease) {
        return $this.InvokeRequest('POST', '/dhcp/remove_static_lease', $lease)
    }
    
    <#
    .SYNOPSIS
        Update a DHCP static lease
    #>
    [object] UpdateDhcpStaticLease([object]$lease) {
        return $this.InvokeRequest('POST', '/dhcp/update_static_lease', $lease)
    }
    
    <#
    .SYNOPSIS
        Reset DHCP configuration
    #>
    [object] ResetDhcp() {
        return $this.InvokeRequest('POST', '/dhcp/reset')
    }
    
    <#
    .SYNOPSIS
        Reset DHCP leases
    #>
    [object] ResetDhcpLeases() {
        return $this.InvokeRequest('POST', '/dhcp/reset_leases')
    }
    
    # ============================================================================
    # FILTERING OPERATIONS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Get filtering parameters and filter lists
    #>
    [object] GetFilteringStatus() {
        return $this.InvokeRequest('GET', '/filtering/status')
    }
    
    <#
    .SYNOPSIS
        Set filtering parameters
    #>
    [object] SetFilteringConfig([object]$config) {
        return $this.InvokeRequest('POST', '/filtering/config', $config)
    }
    
    <#
    .SYNOPSIS
        Add filter URL or file path
    #>
    [object] AddFilterUrl([string]$name, [string]$url, [bool]$whitelist = $false) {
        $body = @{
            name      = $name
            url       = $url
            whitelist = $whitelist
        }
        return $this.InvokeRequest('POST', '/filtering/add_url', $body)
    }
    
    <#
    .SYNOPSIS
        Remove filter URL
    #>
    [object] RemoveFilterUrl([string]$url, [bool]$whitelist = $false) {
        $body = @{
            url       = $url
            whitelist = $whitelist
        }
        return $this.InvokeRequest('POST', '/filtering/remove_url', $body)
    }
    
    <#
    .SYNOPSIS
        Set URL parameters for a filter
    #>
    [object] SetFilterUrl([object]$filterData) {
        return $this.InvokeRequest('POST', '/filtering/set_url', $filterData)
    }
    
    <#
    .SYNOPSIS
        Refresh filter lists from URLs
    #>
    [object] RefreshFilters([bool]$whitelist = $false) {
        $body = @{
            whitelist = $whitelist
        }
        return $this.InvokeRequest('POST', '/filtering/refresh', $body)
    }
    
    <#
    .SYNOPSIS
        Set user-defined filter rules
    #>
    [object] SetFilterRules([string[]]$rules) {
        $body = @{
            rules = $rules
        }
        return $this.InvokeRequest('POST', '/filtering/set_rules', $body)
    }
    
    <#
    .SYNOPSIS
        Check if hostname is filtered
    #>
    [object] CheckHost([string]$name, [string]$client = $null, [string]$qtype = $null) {
        $queryParams = @{
            name = $name
        }
        if ($client) { $queryParams['client'] = $client }
        if ($qtype) { $queryParams['qtype'] = $qtype }
        
        return $this.InvokeRequest('GET', '/filtering/check_host', $null, $queryParams)
    }
    
    # ============================================================================
    # SAFE BROWSING OPERATIONS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Enable safe browsing
    #>
    [object] EnableSafeBrowsing() {
        return $this.InvokeRequest('POST', '/safebrowsing/enable')
    }
    
    <#
    .SYNOPSIS
        Disable safe browsing
    #>
    [object] DisableSafeBrowsing() {
        return $this.InvokeRequest('POST', '/safebrowsing/disable')
    }
    
    <#
    .SYNOPSIS
        Get safe browsing status
    #>
    [object] GetSafeBrowsingStatus() {
        return $this.InvokeRequest('GET', '/safebrowsing/status')
    }
    
    # ============================================================================
    # PARENTAL CONTROL OPERATIONS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Enable parental filtering
    #>
    [object] EnableParental() {
        return $this.InvokeRequest('POST', '/parental/enable')
    }
    
    <#
    .SYNOPSIS
        Disable parental filtering
    #>
    [object] DisableParental() {
        return $this.InvokeRequest('POST', '/parental/disable')
    }
    
    <#
    .SYNOPSIS
        Get parental filtering status
    #>
    [object] GetParentalStatus() {
        return $this.InvokeRequest('GET', '/parental/status')
    }
    
    # ============================================================================
    # SAFE SEARCH OPERATIONS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Update safe search settings
    #>
    [object] SetSafeSearchSettings([object]$config) {
        return $this.InvokeRequest('PUT', '/safesearch/settings', $config)
    }
    
    <#
    .SYNOPSIS
        Get safe search status
    #>
    [object] GetSafeSearchStatus() {
        return $this.InvokeRequest('GET', '/safesearch/status')
    }
    
    # ============================================================================
    # CLIENT OPERATIONS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Get information about configured clients
    #>
    [object] GetClients() {
        return $this.InvokeRequest('GET', '/clients')
    }
    
    <#
    .SYNOPSIS
        Add a new client
    #>
    [object] AddClient([object]$client) {
        return $this.InvokeRequest('POST', '/clients/add', $client)
    }
    
    <#
    .SYNOPSIS
        Delete a client
    #>
    [object] DeleteClient([string]$name) {
        $body = @{
            name = $name
        }
        return $this.InvokeRequest('POST', '/clients/delete', $body)
    }
    
    <#
    .SYNOPSIS
        Update client information
    #>
    [object] UpdateClient([string]$name, [object]$data) {
        $body = @{
            name = $name
            data = $data
        }
        return $this.InvokeRequest('POST', '/clients/update', $body)
    }
    
    <#
    .SYNOPSIS
        Search for clients by IP addresses, CIDRs, MAC addresses, or ClientIDs
    #>
    [object] SearchClients([object[]]$clients) {
        $body = @{
            clients = $clients
        }
        return $this.InvokeRequest('POST', '/clients/search', $body)
    }
    
    # ============================================================================
    # ACCESS CONTROL OPERATIONS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Get access list (allowed/disallowed clients, blocked hosts)
    #>
    [object] GetAccessList() {
        return $this.InvokeRequest('GET', '/access/list')
    }
    
    <#
    .SYNOPSIS
        Set access list
    #>
    [object] SetAccessList([object]$accessList) {
        return $this.InvokeRequest('POST', '/access/set', $accessList)
    }
    
    # ============================================================================
    # BLOCKED SERVICES OPERATIONS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Get all available services to block
    #>
    [object] GetAllBlockedServices() {
        return $this.InvokeRequest('GET', '/blocked_services/all')
    }
    
    <#
    .SYNOPSIS
        Get blocked services schedule
    #>
    [object] GetBlockedServicesSchedule() {
        return $this.InvokeRequest('GET', '/blocked_services/get')
    }
    
    <#
    .SYNOPSIS
        Update blocked services schedule
    #>
    [object] UpdateBlockedServicesSchedule([object]$schedule) {
        return $this.InvokeRequest('PUT', '/blocked_services/update', $schedule)
    }
    
    # ============================================================================
    # REWRITE RULES OPERATIONS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Get list of DNS rewrite rules
    #>
    [object] GetRewriteList() {
        return $this.InvokeRequest('GET', '/rewrite/list')
    }
    
    <#
    .SYNOPSIS
        Add a new DNS rewrite rule
    #>
    [object] AddRewriteRule([string]$domain, [string]$answer) {
        $body = @{
            domain = $domain
            answer = $answer
        }
        return $this.InvokeRequest('POST', '/rewrite/add', $body)
    }
    
    <#
    .SYNOPSIS
        Delete a DNS rewrite rule
    #>
    [object] DeleteRewriteRule([string]$domain, [string]$answer) {
        $body = @{
            domain = $domain
            answer = $answer
        }
        return $this.InvokeRequest('POST', '/rewrite/delete', $body)
    }
    
    <#
    .SYNOPSIS
        Update a DNS rewrite rule
    #>
    [object] UpdateRewriteRule([object]$target, [object]$update) {
        $body = @{
            target = $target
            update = $update
        }
        return $this.InvokeRequest('PUT', '/rewrite/update', $body)
    }
    
    <#
    .SYNOPSIS
        Remove duplicate DNS rewrite rules (keeping first occurrence)
    #>
    [hashtable] DeduplicateRewrites() {
        $rewrites = $this.GetRewriteList()
        
        if (-not $rewrites -or $rewrites.Count -eq 0) {
            return @{
                Removed = 0
                Kept    = 0
            }
        }
        
        $seen = @{}
        $duplicates = @()
        $keptCount = 0
        
        foreach ($rewrite in $rewrites) {
            $key = "$($rewrite.domain)|$($rewrite.answer)"
            
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $keptCount++
            }
            else {
                # Mark as duplicate for removal
                $duplicates += $rewrite
            }
        }
        
        # Remove duplicates
        $removedCount = 0
        foreach ($duplicate in $duplicates) {
            try {
                $this.DeleteRewriteRule($duplicate.domain, $duplicate.answer)
                Write-Verbose "Removed duplicate: $($duplicate.domain) -> $($duplicate.answer)"
                $removedCount++
                Start-Sleep -Milliseconds 100
            }
            catch {
                Write-Warning "Failed to remove duplicate: $($duplicate.domain) -> $($duplicate.answer): $_"
            }
        }
        
        return @{
            Removed = $removedCount
            Kept    = $keptCount
        }
    }
    
    # ============================================================================
    # INSTALLATION OPERATIONS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Get network interfaces information for installation
    #>
    [object] GetInstallAddresses() {
        return $this.InvokeRequest('GET', '/install/get_addresses')
    }
    
    <#
    .SYNOPSIS
        Check installation configuration
    #>
    [object] CheckInstallConfig([object]$config) {
        return $this.InvokeRequest('POST', '/install/check_config', $config)
    }
    
    <#
    .SYNOPSIS
        Apply initial configuration
    #>
    [object] InstallConfigure([object]$config) {
        return $this.InvokeRequest('POST', '/install/configure', $config)
    }
    
    # ============================================================================
    # AUTHENTICATION OPERATIONS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Perform administrator login
    #>
    [object] Login([string]$name, [string]$password) {
        $body = @{
            name     = $name
            password = $password
        }
        return $this.InvokeRequest('POST', '/login', $body)
    }
    
    <#
    .SYNOPSIS
        Perform administrator login (with SecureString password)
    #>
    [object] Login([string]$name, [securestring]$securePassword) {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        
        $body = @{
            name     = $name
            password = $plainPassword
        }
        return $this.InvokeRequest('POST', '/login', $body)
    }
    
    <#
    .SYNOPSIS
        Perform administrator logout
    #>
    [object] Logout() {
        return $this.InvokeRequest('GET', '/logout')
    }
    
    # ============================================================================
    # PROFILE OPERATIONS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Get current user profile information
    #>
    [object] GetProfile() {
        return $this.InvokeRequest('GET', '/profile')
    }
    
    <#
    .SYNOPSIS
        Update current user profile
    #>
    [object] UpdateProfile([object]$profileInfo) {
        return $this.InvokeRequest('PUT', '/profile/update', $profileInfo)
    }
    
    # ============================================================================
    # MOBILE CONFIG OPERATIONS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Get DNS over HTTPS .mobileconfig for Apple devices
    #>
    [string] GetMobileConfigDoH([string]$hostname, [string]$clientId = $null) {
        $queryParams = @{
            host = $hostname
        }
        if ($clientId) { $queryParams['client_id'] = $clientId }
        
        $uri = "$($this.BaseUrl)/control/apple/doh.mobileconfig"
        $queryString = ($queryParams.GetEnumerator() | ForEach-Object {
                "$($_.Key)=$([System.Web.HttpUtility]::UrlEncode($_.Value))"
            }) -join '&'
        $uri += "?$queryString"
        
        return $uri
    }
    
    <#
    .SYNOPSIS
        Get DNS over TLS .mobileconfig for Apple devices
    #>
    [string] GetMobileConfigDoT([string]$hostname, [string]$clientId = $null) {
        $queryParams = @{
            host = $hostname
        }
        if ($clientId) { $queryParams['client_id'] = $clientId }
        
        $uri = "$($this.BaseUrl)/control/apple/dot.mobileconfig"
        $queryString = ($queryParams.GetEnumerator() | ForEach-Object {
                "$($_.Key)=$([System.Web.HttpUtility]::UrlEncode($_.Value))"
            }) -join '&'
        $uri += "?$queryString"
        
        return $uri
    }
    
    # ============================================================================
    # HELPER METHODS
    # ============================================================================
    
    <#
    .SYNOPSIS
        Enable protection (convenience method)
    #>
    [object] EnableProtection() {
        return $this.SetProtection($true)
    }
    
    <#
    .SYNOPSIS
        Disable protection (convenience method)
    #>
    [object] DisableProtection([int]$duration = 0) {
        return $this.SetProtection($false, $duration)
    }
    
    <#
    .SYNOPSIS
        Get protection status
    #>
    [bool] IsProtectionEnabled() {
        $status = $this.GetStatus()
        return $status.protection_enabled
    }
    
    <#
    .SYNOPSIS
        Get DNS server running status
    #>
    [bool] IsRunning() {
        $status = $this.GetStatus()
        return $status.running
    }
    
    <#
    .SYNOPSIS
        Get current version
    #>
    [string] GetVersion() {
        $status = $this.GetStatus()
        return $status.version
    }
    
    <#
    .SYNOPSIS
        Test if API is accessible
    #>
    [bool] TestConnection() {
        try {
            $null = $this.GetStatus()
            return $true
        }
        catch {
            return $false
        }
    }
    
    <#
    .SYNOPSIS
        Export all current settings to a hashtable
    #>
    [hashtable] ExportSettings() {
        return @{
            Status             = $this.GetStatus()
            DnsInfo            = $this.GetDnsInfo()
            FilteringStatus    = $this.GetFilteringStatus()
            QueryLogConfig     = $this.GetQueryLogConfig()
            StatsConfig        = $this.GetStatsConfig()
            TlsStatus          = $this.GetTlsStatus()
            Clients            = $this.GetClients()
            AccessList         = $this.GetAccessList()
            BlockedServices    = $this.GetBlockedServicesSchedule()
            RewriteRules       = $this.GetRewriteList()
            SafeSearchStatus   = $this.GetSafeSearchStatus()
            SafeBrowsingStatus = $this.GetSafeBrowsingStatus()
            ParentalStatus     = $this.GetParentalStatus()
        }
    }
}

# Export the class
Export-ModuleMember -Function * -Alias *

<#
.EXAMPLE
    # Basic usage with authentication
    $ag = [AdGuardHomeAPI]::new("http://192.168.1.1:3000", "admin", "password")
    
    # Check connection
    $ag.TestConnection()
    
    # Get status
    $status = $ag.GetStatus()
    
    # Enable protection
    $ag.EnableProtection()
    
    # Get query log
    $log = $ag.GetQueryLog()
    
    # Add filter
    $ag.AddFilterUrl("My Filter", "https://example.com/filter.txt")
    
    # Add client
    $client = @{
        name = "MyDevice"
        ids = @("192.168.1.100")
        use_global_settings = $true
    }
    $ag.AddClient($client)
    
    # Add DNS rewrite rule
    $ag.AddRewriteRule("example.com", "127.0.0.1")
    
    # Export all settings
    $settings = $ag.ExportSettings()
    $settings | ConvertTo-Json -Depth 10 | Out-File "aghome-settings.json"

.EXAMPLE
    # Using environment token (like hosts-push.ps1)
    $env:AGHOME_TOKEN = "YWRtaW46cGFzc3dvcmQ="  # base64 of "admin:password"
    
    # Create instance from environment variable
    $ag = [AdGuardHomeAPI]::FromEnvironment("https://192.168.2.4:3003")
    
    # Or specify custom environment variable name
    $ag = [AdGuardHomeAPI]::FromEnvironment("https://192.168.2.4:3003", "MY_AGH_TOKEN")
    
    # Or use token directly
    $token = "YWRtaW46cGFzc3dvcmQ="
    $ag = [AdGuardHomeAPI]::FromToken("https://192.168.2.4:3003", $token)
    
    # Now use API as normal
    $rewrites = $ag.GetRewriteList()
    
.EXAMPLE
    # Generate token from username/password for environment variable
    $username = "admin"
    $password = "password"
    $token = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${username}:${password}"))
    Write-Host "Set environment variable: `$env:AGHOME_TOKEN = '$token'"
    
    # Or set it directly
    $env:AGHOME_TOKEN = $token

.EXAMPLE
    # Advanced usage - manage blocked services with schedule
    $ag = [AdGuardHomeAPI]::new("http://adguard.local", "admin", "secret")
    
    # Get available services
    $services = $ag.GetAllBlockedServices()
    
    # Block services with schedule
    $schedule = @{
        ids = @("youtube", "facebook", "tiktok")
        schedule = @{
            time_zone = "Local"
            mon = @{ start = 32400000; end = 61200000 }  # 9 AM to 5 PM
            tue = @{ start = 32400000; end = 61200000 }
            wed = @{ start = 32400000; end = 61200000 }
            thu = @{ start = 32400000; end = 61200000 }
            fri = @{ start = 32400000; end = 61200000 }
        }
    }
    $ag.UpdateBlockedServicesSchedule($schedule)

.EXAMPLE
    # DHCP operations
    $ag = [AdGuardHomeAPI]::new("http://192.168.1.1:3000", "admin", "password")
    
    # Get DHCP status
    $dhcp = $ag.GetDhcpStatus()
    
    # Add static lease
    $lease = @{
        mac = "00:11:22:33:44:55"
        ip = "192.168.1.100"
        hostname = "mydevice"
    }
    $ag.AddDhcpStaticLease($lease)

.EXAMPLE
    # Statistics and query log
    $ag = [AdGuardHomeAPI]::new("http://192.168.1.1:3000", "admin", "password")
    
    # Get statistics
    $stats = $ag.GetStats()
    Write-Host "Total queries: $($stats.num_dns_queries)"
    Write-Host "Blocked: $($stats.num_blocked_filtering)"
    
    # Search query log for specific domain
    $queries = $ag.GetQueryLog($null, 0, 100, "google.com", $null)
    
    # Clear old data
    $ag.ClearQueryLog()
    $ag.ResetStats()
#>
