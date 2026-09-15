@echo off
start "" powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Display-Tuner.ps1" %*
