@echo off
title CampusNet Auto Login - Setup

rem ---------------------------------------------------------------------
rem  Detect "double-clicked from inside the .zip archive".
rem  Windows then unpacks to a temp folder whose path contains ".zip",
rem  and that folder is cleaned up afterwards - so the companion files
rem  (CampusNetSetup.ps1 etc.) are gone by the time PowerShell starts.
rem  Keep this file pure ASCII: cmd.exe decodes it with the system ANSI
rem  code page, which differs between machines and mangles CJK text.
rem ---------------------------------------------------------------------
set "HERE=%~dp0"
echo %HERE%|findstr /I /C:".zip" >nul
if not errorlevel 1 goto NeedExtract
echo %HERE%|findstr /I /C:"\AppData\Local\Temp\" >nul
if not errorlevel 1 goto NeedExtract

if not exist "%HERE%CampusNetSetup.ps1" goto MissingFile

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%CampusNetSetup.ps1"
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
  echo  [DONE] Setup finished.
) else (
  echo  [FAILED] exit code = %RC%
)
echo.
pause
exit /b %RC%

:NeedExtract
echo.
echo  ====================================================
echo   EXTRACT THE ZIP FIRST
echo  ====================================================
echo.
echo   You launched this file from inside the .zip archive.
echo   Windows only unpacks it to a temporary folder, which is
echo   cleaned up - so the installer cannot find its files.
echo.
echo   Please do this instead:
echo.
echo     1. Locate   campus-net.zip
echo     2. Right-click it  -^>  Extract All...
echo     3. Open the extracted folder
echo     4. Double-click the setup file there
echo.
echo   Never double-click files inside a .zip archive.
echo.
pause
exit /b 1

:MissingFile
echo.
echo  ====================================================
echo   INSTALLER FILES NOT FOUND
echo  ====================================================
echo.
echo   CampusNetSetup.ps1 was not found next to this file.
echo   Make sure you extracted the WHOLE archive, not one file.
echo.
pause
exit /b 2