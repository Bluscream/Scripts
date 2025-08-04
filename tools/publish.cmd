@echo off
powershell -ExecutionPolicy Bypass -Command "build.ps1 -Publish -Git -Github -Docker -Ghcr -Repo \"youtube-music-api-proxy\"" 