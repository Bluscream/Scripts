@ECHO OFF

@REM MultiMonitorTool.exe /SetMonitors "Name=SAM08AC Primary=1 BitsPerPixel=32 Width=1920 Height=1080 DisplayFlags=0 DisplayFrequency=60 DisplayOrientation=0 PositionX=0 PositionY=0" "Name=SAM08AC BitsPerPixel=32 Width=1280 Height=720 DisplayFlags=0 DisplayFrequency=50 DisplayOrientation=0 PositionX=132 PositionY=-720" "Name=MED07B8 BitsPerPixel=32 Width=1280 Height=1024 DisplayFlags=0 DisplayFrequency=75 DisplayOrientation=0 PositionX=-1280 PositionY=59" "Name=MAC0101 Primary=1 BitsPerPixel=32 Width=1920 Height=1080 DisplayFlags=0 DisplayFrequency=60 DisplayOrientation=0 PositionX=0 PositionY=0"

MultiMonitorTool.exe /SetMonitors "Name=MED07B8 BitsPerPixel=32 Width=1280 Height=1024 DisplayFlags=0 DisplayFrequency=75 DisplayOrientation=0 PositionX=-1280 PositionY=59" "Name=GSV0000 BitsPerPixel=32 Width=1920 Height=1080 DisplayFlags=0 DisplayFrequency=60 DisplayOrientation=0 PositionX=3840 PositionY=0" "Name=SAM08AC BitsPerPixel=32 Width=1280 Height=720 DisplayFlags=0 DisplayFrequency=50 DisplayOrientation=0 PositionX=132 PositionY=-720"

@REM EXIT /B

@REM MONITOR\SAM08AC\{4d36e96e-e325-11ce-bfc1-08002be10318}\0005
MultiMonitorTool.exe /SetMonitors "Name=SAM08AC Primary=1 BitsPerPixel=32 Width=1920 Height=1080 DisplayFlags=0 DisplayFrequency=60 DisplayOrientation=0 PositionX=0 PositionY=0"

@REM MONITOR\MAC0101\{4d36e96e-e325-11ce-bfc1-08002be10318}\0009
MultiMonitorTool.exe /SetMonitors "Name=MAC0101 Primary=1 BitsPerPixel=32 Width=1920 Height=1080 DisplayFlags=0 DisplayFrequency=60 DisplayOrientation=0 PositionX=0 PositionY=0"

@REM MONITOR\MED07B8\{4d36e96e-e325-11ce-bfc1-08002be10318}\0003
MultiMonitorTool.exe /SetMonitors "Name=MED07B8 Primary=0 BitsPerPixel=32 Width=1280 Height=1024 DisplayFlags=0 DisplayFrequency=75 DisplayOrientation=0 PositionX=-1280 PositionY=53"

@REM MONITOR\HJW0001\{4d36e96e-e325-11ce-bfc1-08002be10318}\0004
MultiMonitorTool.exe /SetMonitors "Name=HJW0001 Primary=0 BitsPerPixel=32 Width=1280 Height=720 DisplayFlags=0 DisplayFrequency=50 DisplayOrientation=0 PositionX=320 PositionY=-720"
MultiMonitorTool.exe /SetMonitors "Name=GSV0000 Primary=0 BitsPerPixel=32 Width=1280 Height=720 DisplayFlags=0 DisplayFrequency=50 DisplayOrientation=0 PositionX=320 PositionY=-720"

EXIT /B