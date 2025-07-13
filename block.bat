@echo off
schtasks /Change /ENABLE /tn "\blu\elevated\Block Shutdown"
schtasks /run /tn "\blu\elevated\Block Shutdown"
schtasks /Change /ENABLE /tn "\blu\elevated\Block Shutdown 2"
schtasks /run /tn "\blu\elevated\Block Shutdown 2"

:loop
shutdown /a
timeout /t 1 >nul
goto loop




