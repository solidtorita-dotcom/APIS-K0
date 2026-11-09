@echo off
rem Builds the test programs: tests\out\harness.exe (the native bridge outside the game, see harness.cpp),
rem tests\out\dsp_wav.exe (the voice effects on a WAV, see dsp_wav.cpp) and tests\out\ears_test.exe (speech
rem recognition on a WAV, see ears_test.cpp). Same dependencies as build.bat.
setlocal
cd /d "%~dp0.."
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq delims=" %%i in (`call "%VSWHERE%" -latest -products * -property installationPath`) do set "VS=%%i"
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
if not exist tests\out mkdir tests\out
set "ESPEAK=deps\build\espeak-ng\src"
set "FLAGS=/nologo /std:c++20 /EHsc /O2 /MT /W4 /utf-8 /DWIN32_LEAN_AND_MEAN /DNOMINMAX /D_CRT_SECURE_NO_WARNINGS"
set "WHISPER=deps\build\whisper.cpp"
set "INCLUDES=/I deps /I deps\espeak-ng\src\include /I deps\onnxruntime\include /I deps\whisper.cpp\include /I deps\whisper.cpp\ggml\include"
set "LIBS=winhttp.lib advapi32.lib %ESPEAK%\libespeak-ng\espeak-ng.lib %ESPEAK%\ucd-tools\ucd.lib %ESPEAK%\speechPlayer\speechPlayer.lib"
set "LIBS=%LIBS% %WHISPER%\src\whisper.lib %WHISPER%\ggml\src\ggml.lib %WHISPER%\ggml\src\ggml-base.lib %WHISPER%\ggml\src\ggml-cpu.lib"
cl %FLAGS% %INCLUDES% tests\harness.cpp NativeBridge.cpp GameFiles.cpp Log.cpp ^
   Brain.cpp Memory.cpp Providers.cpp Http.cpp Paths.cpp Text.cpp World.cpp Barks.cpp Voice.cpp Ears.cpp Dsp.cpp ^
   Piper.cpp MiniAudio.cpp /Fotests\out\ /Fetests\out\harness.exe /link /NOLOGO %LIBS% || exit /b 1
rem dsp_wav.exe: the machine voice and effects on a WAV (see dsp_wav.cpp).
cl %FLAGS% tests\dsp_wav.cpp Dsp.cpp /Fotests\out\ /Fetests\out\dsp_wav.exe /link /NOLOGO || exit /b 1
rem ears_test.exe: speech recognition on a WAV and the name fixes (see ears_test.cpp).
cl %FLAGS% %INCLUDES% tests\ears_test.cpp Ears.cpp Voice.cpp Dsp.cpp Piper.cpp Providers.cpp Http.cpp Text.cpp ^
   Log.cpp Paths.cpp MiniAudio.cpp /Fotests\out\ /Fetests\out\ears_test.exe /link /NOLOGO %LIBS% || exit /b 1
rem piper_wav.exe: native Piper on one text (see piper_wav.cpp).
cl %FLAGS% %INCLUDES% tests\piper_wav.cpp Piper.cpp Http.cpp Text.cpp Log.cpp ^
   /Fotests\out\ /Fetests\out\piper_wav.exe /link /NOLOGO %LIBS% || exit /b 1
copy /y deps\onnxruntime\lib\onnxruntime.dll tests\out\ >nul || exit /b 1
echo Built tests\out\harness.exe, dsp_wav.exe and ears_test.exe
