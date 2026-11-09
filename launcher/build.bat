@echo off
rem Builds ApisK0Launcher.dll (RED4ext plugin) with the Visual Studio Build Tools.
rem Needs the RED4ext SDK headers in deps\RED4ext.SDK:
rem   git clone --depth 1 https://github.com/WopsS/RED4ext.SDK.git deps\RED4ext.SDK
setlocal
cd /d "%~dp0"
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq delims=" %%i in (`call "%VSWHERE%" -latest -products * -property installationPath`) do set "VS=%%i"
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
if not exist out mkdir out
cl /nologo /LD /std:c++20 /EHsc /O2 /MT /W4 /utf-8 /DWIN32_LEAN_AND_MEAN /DNOMINMAX ^
   /I deps\RED4ext.SDK\include ApisK0Launcher.cpp /Foout\ /Feout\ApisK0Launcher.dll /link /NOLOGO || exit /b 1
echo Built out\ApisK0Launcher.dll
