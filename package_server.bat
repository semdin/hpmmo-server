@echo off
title Package HPMMO Dedicated Server
echo ========================================================
echo Packaging HPMMO dedicated server files...
echo ========================================================

tar -czf hpmmo_server.tar.gz --exclude=".git" --exclude=".godot/editor" --exclude="*.bat" *

echo.
echo [SUCCESS] Archive created: hpmmo_server.tar.gz
echo.
echo To send this to your VPS (IP: 213.250.145.75):
echo   scp hpmmo_server.tar.gz root@213.250.145.75:~/
echo.
echo Then on your VPS, run:
echo   bash ~/hpmmo/game/update_server.sh
echo ========================================================
pause
