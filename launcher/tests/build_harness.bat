@echo off
rem Builds the test programs: tests\out\harness.exe (the native bridge outside the game, see harness.cpp) and
rem tests\out\dsp_wav.exe (the voice effects on a WAV, see dsp_wav.cpp).
setlocal
cd /d "%~dp0.."
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq delims=" %%i in (`call "%VSWHERE%" -latest -products * -property installationPath`) do set "VS=%%i"
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
if not exist tests\out mkdir tests\out
cl /nologo /std:c++20 /EHsc /O2 /MT /W4 /utf-8 /DWIN32_LEAN_AND_MEAN /DNOMINMAX /D_CRT_SECURE_NO_WARNINGS ^
   /I deps tests\harness.cpp NativeBridge.cpp GameFiles.cpp Log.cpp ^
   Brain.cpp Memory.cpp Providers.cpp Http.cpp Paths.cpp Text.cpp World.cpp Barks.cpp Voice.cpp Ears.cpp Dsp.cpp MiniAudio.cpp ^
   /Fotests\out\ /Fetests\out\harness.exe /link /NOLOGO winhttp.lib || exit /b 1
rem dsp_wav.exe: the machine voice and effects on a WAV (see dsp_wav.cpp).
cl /nologo /std:c++20 /EHsc /O2 /MT /W4 /utf-8 /DNOMINMAX tests\dsp_wav.cpp Dsp.cpp ^
   /Fotests\out\ /Fetests\out\dsp_wav.exe /link /NOLOGO || exit /b 1
rem ears_test.exe: speech recognition on a WAV and the name fixes (see ears_test.cpp).
cl /nologo /std:c++20 /EHsc /O2 /MT /W4 /utf-8 /DWIN32_LEAN_AND_MEAN /DNOMINMAX /D_CRT_SECURE_NO_WARNINGS ^
   /I deps tests\ears_test.cpp Ears.cpp Voice.cpp Dsp.cpp Providers.cpp Http.cpp Text.cpp Log.cpp Paths.cpp ^
   MiniAudio.cpp /Fotests\out\ /Fetests\out\ears_test.exe /link /NOLOGO winhttp.lib || exit /b 1
echo Built tests\out\harness.exe, dsp_wav.exe and ears_test.exe
