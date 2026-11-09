@echo off
rem Builds ApisK0Launcher.dll (RED4ext plugin) with the Visual Studio Build Tools.
rem Needs the RED4ext SDK headers in deps\RED4ext.SDK:
rem   git clone --depth 1 https://github.com/WopsS/RED4ext.SDK.git deps\RED4ext.SDK
rem and nlohmann/json (single header) in deps\nlohmann\json.hpp:
rem   curl -L -o deps\nlohmann\json.hpp https://github.com/nlohmann/json/releases/download/v3.11.3/json.hpp
rem and miniaudio (single header, public domain or MIT-0) in deps\miniaudio\miniaudio.h:
rem   curl -L -o deps\miniaudio\miniaudio.h https://raw.githubusercontent.com/mackron/miniaudio/0.11.21/miniaudio.h
rem and onnxruntime 1.20.1 (MIT; Piper's runtime, loaded at run time) in deps\onnxruntime:
rem   https://github.com/microsoft/onnxruntime/releases/download/v1.20.1/onnxruntime-win-x64-1.20.1.zip, extracted and
rem   its folder renamed to deps\onnxruntime (out\ gets a copy of lib\onnxruntime.dll)
rem and espeak-ng and whisper.cpp built with build_deps.bat.
setlocal
cd /d "%~dp0"
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq delims=" %%i in (`call "%VSWHERE%" -latest -products * -property installationPath`) do set "VS=%%i"
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
if not exist out mkdir out
set "ESPEAK=deps\build\espeak-ng\src"
set "WHISPER=deps\build\whisper.cpp"
cl /nologo /LD /std:c++20 /EHsc /O2 /MT /W4 /utf-8 /DWIN32_LEAN_AND_MEAN /DNOMINMAX /D_CRT_SECURE_NO_WARNINGS ^
   /I deps\RED4ext.SDK\include /I deps /I deps\espeak-ng\src\include /I deps\onnxruntime\include ^
   /I deps\whisper.cpp\include /I deps\whisper.cpp\ggml\include ^
   ApisK0Launcher.cpp NativeBridge.cpp GameFiles.cpp Log.cpp ^
   Brain.cpp Memory.cpp Providers.cpp Http.cpp Paths.cpp Text.cpp World.cpp Barks.cpp Voice.cpp Ears.cpp Dsp.cpp ^
   Piper.cpp MiniAudio.cpp ^
   /Foout\ /Feout\ApisK0Launcher.dll /link /NOLOGO ^
   %ESPEAK%\libespeak-ng\espeak-ng.lib %ESPEAK%\ucd-tools\ucd.lib %ESPEAK%\speechPlayer\speechPlayer.lib ^
   %WHISPER%\src\whisper.lib %WHISPER%\ggml\src\ggml.lib %WHISPER%\ggml\src\ggml-base.lib ^
   %WHISPER%\ggml\src\ggml-cpu.lib advapi32.lib || exit /b 1
copy /y deps\onnxruntime\lib\onnxruntime.dll out\ >nul || exit /b 1
echo Built out\ApisK0Launcher.dll (with out\onnxruntime.dll)
