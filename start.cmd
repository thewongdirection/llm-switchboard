@echo off
title LLM Switchboard
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" %*
if errorlevel 1 pause
