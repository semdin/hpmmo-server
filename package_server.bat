@echo off
title Package PotterMetin Dedicated Server
echo ========================================================
echo Packaging PotterMetin dedicated server files...
echo ========================================================

tar -czf pottermetin_server.tar.gz --exclude=".git" --exclude=".godot/editor" --exclude="*.bat" *

echo.
echo [SUCCESS] Archive created: pottermetin_server.tar.gz
echo.
echo To send this to your VPS (IP: 213.250.145.75):
echo   scp pottermetin_server.tar.gz root@213.250.145.75:~/
echo.
echo Then on your VPS, run:
echo   bash ~/pottermetin/game/update_server.sh
echo ========================================================
pause
