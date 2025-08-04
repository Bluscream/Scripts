@echo off
powershell -ExecutionPolicy Bypass -Command "publish.ps1 -Git -Github -Docker -Ghcr -Repo \"youtube-music-api-proxy\"" 