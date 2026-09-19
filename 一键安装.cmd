@echo off
chcp 65001 >nul
title CampusNet Auto Login Setup
echo.
echo  ====================================================
echo    CampusNet Auto Login - Setup Wizard
echo  ====================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CampusNetSetup.ps1"
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (
  echo  [OK] Install finished successfully.
) else (
  echo  [FAILED] Exit code = %RC%
  echo  Please read the messages above.
)
echo.
pause
