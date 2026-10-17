@echo off
rem ===========================================================================
rem  Build LocalSend PC MSI installer (unpackaged build, no code signing needed)
rem
rem  Prereqs:
rem    - .NET 8 SDK
rem    - WiX v5 tool:  dotnet tool install --tool-path build\tools-wix5 wix --version 5.0.2
rem      (WiX v7 requires accepting the OSMF fee EULA, so we pin v5)
rem
rem  Usage: double-click, or run from any directory.
rem ===========================================================================
setlocal
cd /d "%~dp0.."

set WIX=build\tools-wix5\wix.exe
set APP=PcDemo\PcDemo\PcDemo.csproj
set OUT=build\out
set PORTABLE=%OUT%\portable
set MSI=%OUT%\KuaiChuan-1.2.1.0-x64.msi

if not exist "%WIX%" (
  echo [ERROR] WiX not found: %WIX%
  echo         dotnet tool install --tool-path build\tools-wix5 wix --version 5.0.2
  exit /b 1
)

echo [1/2] publish unpackaged build ^(self-contained, no MSIX^)...
dotnet publish "%APP%" -c Release -r win-x64 --self-contained true -p:Platform=x64 ^
  -p:WindowsPackageType=None -p:WindowsAppSDKSelfContained=true -p:PublishTrimmed=false ^
  -p:GenerateAppxPackageOnBuild=false -o "%PORTABLE%"
if errorlevel 1 goto :err

if not exist "%PORTABLE%\PcDemo.pri" (
  echo [ERROR] PcDemo.pri missing - XAML resources would fail to load at runtime.
  goto :err
)

echo [2/2] building MSI...
"%WIX%" build installer\LocalSendPC.wxs -arch x64 -loc installer\zh-CN.wxl -culture zh-CN -d SourceDir="%CD%\%PORTABLE%" -o "%MSI%"
if errorlevel 1 goto :err

echo.
echo Done: %MSI%
exit /b 0

:err
echo.
echo BUILD FAILED
exit /b 1
