param(
    [Parameter(Mandatory=$true)][string]$FolderPath,
    [Parameter(Mandatory=$false)][bool]$Recurse = $true
)

# Define the function
function Set-FullPermissions {
    param(
        [Parameter(Mandatory=$true)][string]$FolderPath,
        [Parameter(Mandatory=$false)][bool]$Recurse = $true
    )

    begin {
        # Elevate required privileges
        try {
            $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
            
            # Check for admin rights
            if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                Write-Host "Please run this script with Administrator privileges."
                exit
            }

            # Activate necessary admin privileges
            $adjustTokenPrivileges = @"
using System;
using System.Runtime.InteropServices;

public class TokenAdjuster
{
    [DllImport("advapi32.dll", ExactSpelling=true, SetLastError=true)]
    internal static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall,
    ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);

    [DllImport("kernel32.dll", ExactSpelling=true)]
    internal static extern IntPtr GetCurrentProcess();

    [DllImport("advapi32.dll", ExactSpelling=true, SetLastError=true)]
    internal static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr phtok);

    [DllImport("advapi32.dll", SetLastError=true)]
    internal static extern bool LookupPrivilegeValue(string host, string name,
    ref long pluid);

    [StructLayout(LayoutKind.Sequential, Pack=1)]
    internal struct TokPriv1Luid
    {
        public int Count;
        public long Luid;
        public int Attr;
    }

    internal const int SE_PRIVILEGE_DISABLED = 0x00000000;
    internal const int SE_PRIVILEGE_ENABLED = 0x00000002;
    internal const int TOKEN_QUERY = 0x00000008;
    internal const int TOKEN_ADJUST_PRIVILEGES = 0x00000020;

    public static bool AddPrivilege(string privilege)
    {
        try
        {
            bool retVal;
            TokPriv1Luid tp;
            IntPtr hproc = GetCurrentProcess();
            IntPtr htok = IntPtr.Zero;
            retVal = OpenProcessToken(hproc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok);
            tp.Count = 1;
            tp.Luid = 0;
            tp.Attr = SE_PRIVILEGE_ENABLED;
            retVal = LookupPrivilegeValue(null, privilege, ref tp.Luid);
            retVal = AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
            return retVal;
        }
        catch
        {
            throw;
        }
    }

    public static bool RemovePrivilege(string privilege)
    {
        try
        {
            bool retVal;
            TokPriv1Luid tp;
            IntPtr hproc = GetCurrentProcess();
            IntPtr htok = IntPtr.Zero;
            retVal = OpenProcessToken(hproc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok);
            tp.Count = 1;
            tp.Luid = 0;
            tp.Attr = SE_PRIVILEGE_DISABLED;
            retVal = LookupPrivilegeValue(null, privilege, ref tp.Luid);
            retVal = AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
            return retVal;
        }
        catch
        {
            throw;
        }
    }
}
"@

            Add-Type $adjustTokenPrivileges
            [void][TokenAdjuster]::AddPrivilege("SeRestorePrivilege")
            [void][TokenAdjuster]::AddPrivilege("SeBackupPrivilege")
            [void][TokenAdjuster]::AddPrivilege("SeTakeOwnershipPrivilege")

        } catch {
            Write-Error "Failed to elevate privileges: $_"
            exit
        }
    }

    process {
        # Validate folder path
        if (-not (Test-Path $FolderPath)) {
            Write-Error "Folder '$FolderPath' not found."
            return
        }

        # Write-Host "Processing folder: $FolderPath"

        # Remove readonly attribute from folder
        try {
            $item = Get-Item $FolderPath
            if ($item.Attributes.HasFlag([IO.FileAttributes]::ReadOnly)) {
                $item.Attributes = $item.Attributes -bxor [IO.FileAttributes]::ReadOnly
                Write-Verbose "Removed readonly attribute from folder '$FolderPath'"
            }
        } catch {
            Write-Warning "Failed to remove readonly attribute from folder '$FolderPath': $_"
        }

        # Get current ACL
        try {
            $acl = Get-Acl $FolderPath
        } catch {
            Write-Error "Failed to get ACL for '$FolderPath': $_"
            return
        }

        # Remove existing permissions
        $users = $acl.Access | Select-Object -ExpandProperty IdentityReference
        foreach ($user in $users) {
            try {
                $acl.PurgeAccessRules($user)
            } catch {
                Write-Warning "Failed to remove permissions for '$user': $_"
            }
        }

        # Set ownership to Administrators
        $adminGroup = New-Object System.Security.Principal.NTAccount("Builtin\Administrators")
        $acl.SetOwner($adminGroup)

        # Create new permission rule for Everyone
        $everyone = New-Object System.Security.Principal.NTAccount("Everyone")
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $everyone,
            "FullControl",
            "ContainerInherit,ObjectInherit",
            "None",
            "Allow"
        )
        $acl.AddAccessRule($rule)

        # Apply ACL
        try {
            Set-Acl $FolderPath $acl
        } catch {
            Write-Error "Failed to apply new permissions: $_"
            return
        }

        # Process files and subfolders recursively
        if ($Recurse) {
            Get-ChildItem $FolderPath -Recurse | ForEach-Object {
                $itemPath = $_.FullName

                Write-Host "Processing: $itemPath"
                
                # Remove readonly attribute from files and folders
                try {
                    $item = Get-Item $itemPath
                    if ($item.Attributes.HasFlag([IO.FileAttributes]::ReadOnly)) {
                        $item.Attributes = $item.Attributes -bxor [IO.FileAttributes]::ReadOnly
                        Write-Verbose "Removed readonly attribute from '$itemPath'"
                    }
                    
                    # Process subfolders
                    if ($_.PSIsContainer) {
                        Set-FullPermissions -FolderPath $itemPath -Recurse:$Recurse
                    }
                } catch {
                    Write-Warning "Failed to process '$itemPath': $_"
                }
            }
        }
    }

    end {
        # Clean up privileges
        try {
            [void][TokenAdjuster]::RemovePrivilege("SeRestorePrivilege")
            [void][TokenAdjuster]::RemovePrivilege("SeBackupPrivilege")
            [void][TokenAdjuster]::RemovePrivilege("SeTakeOwnershipPrivilege")
        } catch {
            Write-Warning "Failed to clean up privileges: $_"
        }
    }
}

Set-FullPermissions -FolderPath $FolderPath -Recurse:$Recurse