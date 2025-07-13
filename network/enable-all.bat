@echo off
setlocal enabledelayedexpansion

DISM /Online /Add-Capability /CapabilityName:WMIC

set excludedAdapters=("Bluetooth Network Connection", "vEthernet (Default Switch)")

for /f "tokens=*" %%a in ('wmic nic where "AdapterTypeID='0'" get Name ^| findstr /r /v "^$"') do (
    for %%x in %excludedAdapters% do (
        if "%%a"=="%%x" (
            echo Excluding adapter: %%a
            goto :continue
        )
    )
    echo Enabling adapter: %%a
    netsh interface set interface "%%a" adminstate=enable
    timeout /t 2 >nul
)

echo Complete - Press any key to exit
pause >nul