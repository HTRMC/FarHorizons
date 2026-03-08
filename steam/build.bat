@echo off
setlocal

cd /d "%~dp0.."

echo Building Windows...
zig build -Doptimize=ReleaseFast --prefix build/windows
if %errorlevel% neq 0 exit /b %errorlevel%

echo Building Linux...
zig build "-Dtarget=x86_64-linux-gnu.2.38" -Doptimize=ReleaseFast --prefix build/linux
if %errorlevel% neq 0 exit /b %errorlevel%

echo.
echo Builds staged:
echo   build\windows\bin\
echo   build\linux\bin\
echo.
echo Upload with:
echo   steamcmd +login ^<username^> +run_app_build "%~dp0app_build.vdf" +quit
