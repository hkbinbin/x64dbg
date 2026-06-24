@echo off
setlocal
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
    echo [build.bat] vcvars64.bat failed
    exit /b 1
)
set "PATH=C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%"
set "SRC=C:\Users\theoou\Desktop\Reverse_tools\x64dbg"
set "BUILD=C:\Users\theoou\Desktop\Reverse_tools\x64dbg\build64"

if "%1"=="" goto all
if /i "%1"=="configure" goto configure
if /i "%1"=="build" goto build
if /i "%1"=="all" goto all
goto usage

:configure
echo === [build.bat] cmake configure (Ninja, downloads Qt5.12.12 ~110MB on first run) ===
cmake -S "%SRC%" -B "%BUILD%" -G "Ninja" -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl
exit /b %errorlevel%

:build
echo === [build.bat] cmake build (Ninja Release) ===
cmake --build "%BUILD%"
exit /b %errorlevel%

:all
call "%~f0" configure
if errorlevel 1 exit /b 1
call "%~f0" build
exit /b %errorlevel%

:usage
echo Usage: build.bat [configure^|build^|all]
exit /b 1
