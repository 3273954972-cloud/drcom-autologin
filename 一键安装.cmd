@echo off
chcp 936 >nul
title 校园网自动认证 - 安装向导
echo.
echo  ########################################################
echo  #                                                      #
echo  #        校园网自动认证   安装向导                     #
echo  #        装完以后开机自动联网, 再也不用点登录页       #
echo  #                                                      #
echo  ########################################################
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CampusNetSetup.ps1"
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (
  echo  [完成] 安装成功, 以后开机自动联网。
) else (
  echo  [未完成] 退出码 = %RC%
  echo  请把上面的提示内容发给我看看。
)
echo.
pause