@echo off
rem Builds the third-party libraries of the native bridge's local options (phase 5) into deps\build\, with the static
rem runtime (/MT) like ApisK0Launcher.dll. Run once after getting the sources:
rem   espeak-ng (GPL-3.0), phonemes for Piper, pinned to a commit with espeak_TextToPhonemesWithTerminator:
rem     git clone https://github.com/espeak-ng/espeak-ng.git deps\espeak-ng
rem     git -C deps\espeak-ng checkout 6b96deb
rem It also compiles espeak-ng-data (deps\build\espeak-ng\espeak-ng-data), which must come from the same version.
rem   whisper.cpp (MIT), local speech recognition, CPU only (no GPU: the AMD driver hangs), AVX2, no OpenMP:
rem     git clone --depth 1 --branch v1.9.5 https://github.com/ggml-org/whisper.cpp.git deps\whisper.cpp
setlocal
cd /d "%~dp0"
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq delims=" %%i in (`call "%VSWHERE%" -latest -products * -property installationPath`) do set "VS=%%i"
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
set "CMAKE=%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
set "NINJA=%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"
set COMMON=-G Ninja -DCMAKE_MAKE_PROGRAM="%NINJA%" -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_DEFAULT_CMP0091=NEW ^
  -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded

"%CMAKE%" -S deps\espeak-ng -B deps\build\espeak-ng %COMMON% -DBUILD_SHARED_LIBS=OFF -DENABLE_TESTS=OFF ^
  -DUSE_MBROLA=OFF -DUSE_LIBSONIC=OFF -DUSE_LIBPCAUDIO=OFF -DUSE_ASYNC=OFF -DUSE_KLATT=OFF -DUSE_SPEECHPLAYER=OFF ^
  || exit /b 1
"%CMAKE%" --build deps\build\espeak-ng || exit /b 1
echo Built deps\build\espeak-ng

"%CMAKE%" -S deps\whisper.cpp -B deps\build\whisper.cpp %COMMON% -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF ^
  -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_SERVER=OFF -DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON ^
  -DGGML_F16C=ON -DGGML_OPENMP=OFF || exit /b 1
"%CMAKE%" --build deps\build\whisper.cpp || exit /b 1
echo Built deps\build\whisper.cpp
