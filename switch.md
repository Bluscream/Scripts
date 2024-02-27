# Game Version Switcher Script

This PowerShell script is designed to manage game versions for a specific game executable. It allows users to switch between different versions of the game, create symbolic links to switch game versions, and provides a set of command-line arguments for customizing its behavior.

## Download
- [switch.ps1](https://github.com/Bluscream/Scripts/raw/master/switch.ps1)
- [switch.exe](https://github.com/Bluscream/Scripts/raw/master/switch.exe)

Source is available [here](https://github.com/Bluscream/Scripts/blob/master/switch.ps1)

## Overview

The script is designed to work with a game executable, typically named `iw4x.exe`, but this can be customized through the `-gameExe` parameter. It supports switching between different versions of the game by manipulating symbolic links. The script can automatically kill the game process if it's running when attempting to switch versions, and it can also start the game after switching versions if requested.

## Command Line Arguments

| Argument | Default Value | Description |
|----------|---------------|-------------|
| `-version` | `""` | Specifies the version to switch to. If not provided, the script will prompt the user to select a version. |
| `-switch` | `$true` | Determines whether the script will attempt to switch versions. If set to `$false`, the script will not switch versions but will still perform other actions like listing versions or killing the game process. |
| `-force` | `$false` | If set to `$true`, the script will force switching to the specified version even if it's already the current version. |
| `-killGame` | `$false` | If set to `$true`, the script will automatically kill the game process if it's running before attempting to switch versions. |
| `-ignoreRunning` | `$false` | If set to `$true`, the script will ignore whether the game is currently running and proceed with version switching. |
| `-startGame` | `$false` | If set to `$true`, the script will start the game executable after successfully switching versions. |
| `-gameExe` | `"iw4x.exe"` | Specifies the name of the game executable. This is used to identify the game process and to construct the path for starting the game. |
| `-gameArgs` | `"-disable-notifies -unprotect-dvars -multiplayer -scriptablehttp -console -nointro +set logfile  0"` | Specifies additional command-line arguments to pass to the game executable when starting it. |
| `-basePath` | `(Get-Location).Path` | Specifies the base path where the game versions and symbolic links are managed. |
| `-debug` | `$false` | If set to `$true`, the script will output additional debug information. |
| `-help` | N/A | Displays detailed help information about the script. |

## Usage

To use the script, you can call it from the command line and provide any of the above command-line arguments. For example, to switch to a specific version of the game, you could use:

```powershell
.\GameVersionSwitcher.ps1 -version "r4432"
```

To start the game after switching versions, you could use:

```powershell
.\GameVersionSwitcher.ps1 -version "r4432" -startGame
```

## Defining Versions
To define versions to choose from you can either put them in a `versions.json` file like this:

```json
{
    "version1": {
        "mainfile.dll": "mainfile_version1.dll",
        "mainfolder": "mainfolder_version1"
    },
    "version2": {
        "mainfile.dll": "mainfile_version2.dll",
        "mainfolder": "mainfolder_version2"
    }
}
```
Or you can use a `versions.ps1` file:
```ps1
$versions = @{
    "version1" = @{
        "mainfile.dll" = "mainfile_version1.dll"
        "mainfolder" = "mainfolder_version1"
    }
    "version2" = @{
        "mainfile.dll" = "mainfile_version2.dll"
        "mainfolder" = "mainfolder_version2"
    }
}
```

## Additional Information

- The script supports both JSON and PowerShell script files for defining game versions. If a `versions.json` or `versions.ps1` file exists in the base path, the script will use it to determine available game versions.
- The script can automatically detect the current version of the game based on the symbolic links it manages.
- If the `-debug` argument is used, the script will output additional debug information, which can be helpful for troubleshooting issues.

This script is a powerful tool for managing game versions, offering flexibility and control over the game's environment.
