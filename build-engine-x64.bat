@echo off
setlocal

cd /d "%~dp0"
set LOGFILE=%~dp0build-engine-x64.log
set VCXPROJ_ENGINE=build-win-x86_64\livecode\engine\development.vcxproj
set VCXPROJ_BROWSER=build-win-x86_64\livecode\libbrowser\libbrowser.vcxproj
set VCXPROJ_DBMYSQL=build-win-x86_64\livecode\revdb\dbmysql.vcxproj
set VCXPROJ_LCB_MODULES=build-win-x86_64\livecode\engine\engine_lcb_modules.vcxproj
set VCXPROJ_LIBFFI=build-win-x86_64\livecode\thirdparty\libffi\libffi.vcxproj
set VCXPROJ_LIBFOUNDATION=build-win-x86_64\livecode\libfoundation\libFoundation.vcxproj
set VCXPROJ_LIBSCRIPT=build-win-x86_64\livecode\libscript\libScript.vcxproj
set VCXPROJ_STANDALONE=build-win-x86_64\livecode\engine\standalone.vcxproj
set VCXPROJ_KERNEL=build-win-x86_64\livecode\engine\kernel.vcxproj
set VCXPROJ_KERNEL_STANDALONE=build-win-x86_64\livecode\engine\kernel-standalone.vcxproj
set VCXPROJ_KERNEL_DEVELOPMENT=build-win-x86_64\livecode\engine\kernel-development.vcxproj
set VCXPROJ_SECURITY_COMMUNITY=build-win-x86_64\livecode\engine\security-community.vcxproj
set VCXPROJ_LIBXML=build-win-x86_64\livecode\thirdparty\libxml\libxml.vcxproj
set VCXPROJ_LIBXSLT=build-win-x86_64\livecode\thirdparty\libxslt\libxslt.vcxproj
set VCXPROJ_REVXML=build-win-x86_64\livecode\revxml\external-revxml.vcxproj
set VCXPROJ_REVXML_SERVER=build-win-x86_64\livecode\revxml\external-revxml-server.vcxproj
set VCXPROJ_REVZIP_SERVER=build-win-x86_64\livecode\revzip\external-revzip-server.vcxproj
set VCXPROJ_REVBROWSER=build-win-x86_64\livecode\revbrowser\external-revbrowser.vcxproj

:: ----------------------------------------------------------
:: MySQL 9.6.0 prerequisite check
:: The engine links against libmysql.lib (MySQL 9.6.0).
:: Run setup-mysql-win.bat once after: scoop install mysql
:: ----------------------------------------------------------
set "DEBUG_MYSQL_LIB=build-win-x86_64\livecode\Debug\lib\libmysql.lib"
if not exist "%DEBUG_MYSQL_LIB%" (
    echo.
    echo NOTE: %DEBUG_MYSQL_LIB% not found.
    echo Running setup-mysql-win.bat to copy MySQL 9.6.0 libs from Scoop...
    echo.
    call setup-mysql-win.bat
    if errorlevel 1 (
        echo.
        echo MySQL setup failed. Install MySQL via Scoop first:
        echo   scoop install mysql
        echo Then re-run this script.
        exit /b 1
    )
    echo.
)

:: ----------------------------------------------------------
:: PostgreSQL 18 prerequisite check
:: The engine links against libpq.lib (PostgreSQL 18).
:: Run setup-pgsql-win.bat once after: scoop install postgresql
:: ----------------------------------------------------------
set "DEBUG_PG_LIB=build-win-x86_64\livecode\Debug\lib\libpq.lib"
if not exist "%DEBUG_PG_LIB%" (
    echo.
    echo NOTE: %DEBUG_PG_LIB% not found.
    echo Running setup-pgsql-win.bat to copy PostgreSQL 18 libs from Scoop...
    echo.
    call setup-pgsql-win.bat
    if errorlevel 1 (
        echo.
        echo PostgreSQL setup failed. Install PostgreSQL via Scoop first:
        echo   scoop install postgresql
        echo Then re-run this script.
        exit /b 1
    )
    echo.
)

:: ----------------------------------------------------------
:: Locate MSBuild via a temp PS1 file (avoids cmd mishandling of
:: parentheses inside %ProgramFiles(x86)% in inline commands)
:: ----------------------------------------------------------
set "FIND_PS1=%TEMP%\hxt_find_msbuild.ps1"
echo $pf = [System.Environment]::GetEnvironmentVariable('ProgramFiles(x86)')> "%FIND_PS1%"
echo $vs = "$pf\Microsoft Visual Studio\Installer\vswhere.exe">> "%FIND_PS1%"
echo if (Test-Path $vs) { ^& $vs -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' ^| Select-Object -First 1 }>> "%FIND_PS1%"
for /f "tokens=*" %%i in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%FIND_PS1%"') do set "MSBUILD=%%i"
del "%FIND_PS1%" 2>nul
if not defined MSBUILD (
    echo ERROR: MSBuild.exe not found. Install Visual Studio 2019 Build Tools with C++ workload.
    exit /b 1
)
echo Using MSBuild: %MSBUILD%

echo Build started: %DATE% %TIME%
echo Build started: %DATE% %TIME% > "%LOGFILE%"
echo. >> "%LOGFILE%"

:: ----------------------------------------------------------
:: Build libExternal.lib — required by dbmysql and other DB drivers.
:: On the developer's machine this is a leftover from a previous build;
:: on a clean CI checkout it must be compiled first.
:: ----------------------------------------------------------
echo Building libExternal ...
echo Building libExternal ... >> "%LOGFILE%"
set "VCXPROJ_LIBEXTERNAL=build-win-x86_64\livecode\libexternal\libExternal.vcxproj"
"%MSBUILD%" %VCXPROJ_LIBEXTERNAL% /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo >> "%LOGFILE%" 2>&1
if errorlevel 1 (
    echo.
    echo LIBEXTERNAL BUILD FAILED. Errors:
    findstr /i " error " "%LOGFILE%"
    echo Full log: %LOGFILE%
    exit /b 1
)
echo libExternal OK.

echo.
echo Building libbrowser (WebView2 fix) ...
echo Building libbrowser (WebView2 fix) ... >> "%LOGFILE%"
"%MSBUILD%" %VCXPROJ_BROWSER% /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo >> "%LOGFILE%" 2>&1
if errorlevel 1 (
    echo.
    echo LIBBROWSER BUILD FAILED. Errors:
    findstr /i " error " "%LOGFILE%"
    echo Full log: %LOGFILE%
    exit /b 1
)
echo libbrowser OK.

echo.
echo Building dbmysql (MySQL 9.6.0 database driver) ...
echo Building dbmysql ... >> "%LOGFILE%"
"%MSBUILD%" %VCXPROJ_DBMYSQL% /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo >> "%LOGFILE%" 2>&1
if errorlevel 1 (
    echo.
    echo DBMYSQL BUILD FAILED. Errors:
    findstr /i " error " "%LOGFILE%"
    echo Full log: %LOGFILE%
    exit /b 1
)
echo dbmysql OK.

echo.
:: ----------------------------------------------------------
:: Build libffi (x64 must use include_win64 so FFI_DEFAULT_ABI = FFI_WIN64 = 1,
:: matching what libffi.lib expects; using include_win32 gave FFI_MS_CDECL = 5
:: which caused ffi_prep_cif to return FFI_BAD_ABI and throw "unexpected libffi failure").
:: ----------------------------------------------------------
echo Building libffi ...
echo Building libffi ... >> "%LOGFILE%"
set "LIBFFI_LOG=%~dp0build-libffi.log"
"%MSBUILD%" %VCXPROJ_LIBFFI% /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo > "%LIBFFI_LOG%" 2>&1
set LIBFFI_ERR=%ERRORLEVEL%
type "%LIBFFI_LOG%"
type "%LIBFFI_LOG%" >> "%LOGFILE%"
if %LIBFFI_ERR% NEQ 0 (
    echo.
    echo LIBFFI BUILD FAILED. See %LIBFFI_LOG% for details.
    exit /b 1
)
echo libffi OK.

echo.
:: /t:Rebuild is required here — MSBuild does not detect include-path changes
:: in incremental builds, so foundation-handler.obj and foundation-typeinfo.obj
:: would keep the stale FFI_DEFAULT_ABI=5 value (from include_win32) baked in.
:: Rebuild guarantees they are compiled with include_win64 → FFI_DEFAULT_ABI=1.
:: ----------------------------------------------------------
:: Generate icudata-minimal.cpp (shared_intermediate/src/icudata-minimal.cpp).
::
:: dependency chain:
::   minimal_icu_data.vcxproj
::     → runs icupkg (from prebuilt ICU) on icudt58l.dat to produce
::       shared_intermediate/data/icudata-minimal.dat
::   encode_minimal_icu_data.vcxproj
::     → runs util/encode_data.py on the .dat file to produce
::       shared_intermediate/src/icudata-minimal.cpp
::
:: libFoundation.vcxproj compiles icudata-minimal.cpp, so this must run
:: before the libFoundation build.
:: ----------------------------------------------------------
:: Step 1: minimal_icu_data — runs icupkg on the bundled ICU dat file to
:: produce icudata-minimal.dat.  Built with BuildProjectReferences=false to
:: avoid chaining into fetch.vcxproj → fetch-win.vcxproj, which would abort
:: because prebuilt/lib/win32/icudt.lib is not in the repo.  The ICU
:: binaries (icupkg.exe) are already present in prebuilt/unpacked/icu/.
echo Generating icudata-minimal.dat (minimal_icu_data) ...
echo Generating icudata-minimal.dat ... >> "%LOGFILE%"
set "VCXPROJ_MINICU=build-win-x86_64\livecode\prebuilt\minimal_icu_data.vcxproj"
set "MINICU_LOG=%~dp0build-minimal-icu.log"
"%MSBUILD%" %VCXPROJ_MINICU% /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo > "%MINICU_LOG%" 2>&1
set MINICU_ERR=%ERRORLEVEL%
type "%MINICU_LOG%"
type "%MINICU_LOG%" >> "%LOGFILE%"
if %MINICU_ERR% NEQ 0 (
    echo.
    echo MINIMAL_ICU_DATA FAILED. See %MINICU_LOG% for details.
    exit /b 1
)
echo minimal_icu_data OK.

echo.
:: Step 2: encode_minimal_icu_data — runs util/encode_data.py on the .dat
:: file to produce icudata-minimal.cpp.
echo Generating icudata-minimal.cpp (encode_minimal_icu_data) ...
echo Generating icudata-minimal.cpp ... >> "%LOGFILE%"
set "VCXPROJ_ICU=build-win-x86_64\livecode\prebuilt\encode_minimal_icu_data.vcxproj"
set "ICU_LOG=%~dp0build-encode-icu.log"
"%MSBUILD%" %VCXPROJ_ICU% /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo > "%ICU_LOG%" 2>&1
set ICU_ERR=%ERRORLEVEL%
type "%ICU_LOG%"
type "%ICU_LOG%" >> "%LOGFILE%"
if %ICU_ERR% NEQ 0 (
    echo.
    echo ENCODE_MINIMAL_ICU_DATA FAILED. See %ICU_LOG% for details.
    exit /b 1
)
echo encode_minimal_icu_data OK.

echo.
echo Building libFoundation (FFI closure fix: x64 now uses include_win64 headers) ...
echo Building libFoundation ... >> "%LOGFILE%"
set "FOUND_LOG=%~dp0build-libfoundation.log"
"%MSBUILD%" %VCXPROJ_LIBFOUNDATION% /t:Rebuild /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo > "%FOUND_LOG%" 2>&1
set FOUND_ERR=%ERRORLEVEL%
type "%FOUND_LOG%"
type "%FOUND_LOG%" >> "%LOGFILE%"
if %FOUND_ERR% NEQ 0 (
    echo.
    echo LIBFOUNDATION BUILD FAILED. See %FOUND_LOG% for details.
    exit /b 1
)
echo libFoundation OK.

echo.
echo Building libScript ...
echo Building libScript ... >> "%LOGFILE%"
set "SCRIPT_LOG=%~dp0build-libscript.log"
"%MSBUILD%" %VCXPROJ_LIBSCRIPT% /t:Rebuild /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo > "%SCRIPT_LOG%" 2>&1
set SCRIPT_ERR=%ERRORLEVEL%
type "%SCRIPT_LOG%"
type "%SCRIPT_LOG%" >> "%LOGFILE%"
if %SCRIPT_ERR% NEQ 0 (
    echo.
    echo LIBSCRIPT BUILD FAILED. See %SCRIPT_LOG% for details.
    exit /b 1
)
echo libScript OK.

echo.
:: ----------------------------------------------------------
:: Build LCB engine modules (compiles engine/src/browser.lcb et al.
:: via lc-compile; produces engine_lcb_modules.cpp and .lci files).
:: Must run before the engine so any .lcb changes are picked up.
:: ----------------------------------------------------------
echo Building LCB engine modules ...
echo Building LCB engine modules ... >> "%LOGFILE%"
"%MSBUILD%" %VCXPROJ_LCB_MODULES% /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo >> "%LOGFILE%" 2>&1
if errorlevel 1 (
    echo.
    echo LCB MODULES BUILD FAILED. See %LOGFILE% for details.
    exit /b 1
)
echo LCB modules OK.

echo.
:: ----------------------------------------------------------
:: Generate startupstack.cpp (shared_intermediate/src/startupstack.cpp).
::
:: dependency chain:
::   descriptify_environment_stack.vcxproj
::     → runs server-community.exe (committed bootstrap binary) to produce
::       shared_intermediate/src/environment_descriptified.livecode
::   encode_environment_stack.vcxproj
::     → runs util/compress_data.py on the .livecode file to produce
::       shared_intermediate/src/startupstack.cpp
::
:: development.vcxproj compiles startupstack.cpp, so this must run before
:: the engine build.  On the developer's machine the file is a leftover from
:: a previous build; on a clean CI checkout it does not exist.
::
:: We build encode_environment_stack with BuildProjectReferences=true so
:: MSBuild automatically chains descriptify_environment_stack first.
:: ----------------------------------------------------------
:: Step 1: descriptify_environment_stack — runs the committed server-community.exe
:: to produce environment_descriptified.livecode.
:: Built with BuildProjectReferences=false to avoid chaining into host-server →
:: server → libicu → fetch → fetch-win, which aborts because prebuilt/lib/win32/
:: icudt.lib is not in the repo.  server-community.exe is already committed.
echo Generating environment_descriptified.livecode (descriptify_environment_stack) ...
echo Generating environment_descriptified.livecode ... >> "%LOGFILE%"
set "VCXPROJ_DESCRIPTIFY=build-win-x86_64\livecode\engine\descriptify_environment_stack.vcxproj"
set "DESCRIPTIFY_LOG=%~dp0build-descriptify-stack.log"
"%MSBUILD%" %VCXPROJ_DESCRIPTIFY% /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo > "%DESCRIPTIFY_LOG%" 2>&1
set DESCRIPTIFY_ERR=%ERRORLEVEL%
type "%DESCRIPTIFY_LOG%"
type "%DESCRIPTIFY_LOG%" >> "%LOGFILE%"
if %DESCRIPTIFY_ERR% NEQ 0 (
    echo.
    echo DESCRIPTIFY_ENVIRONMENT_STACK FAILED. See %DESCRIPTIFY_LOG% for details.
    exit /b 1
)
echo descriptify_environment_stack OK.

echo.
:: Step 2: encode_environment_stack — runs util/compress_data.py on the
:: .livecode file to produce startupstack.cpp.
echo Generating startupstack.cpp (encode_environment_stack) ...
echo Generating startupstack.cpp ... >> "%LOGFILE%"
set "VCXPROJ_ENCODE=build-win-x86_64\livecode\engine\encode_environment_stack.vcxproj"
set "ENCODE_LOG=%~dp0build-encode-stack.log"
"%MSBUILD%" %VCXPROJ_ENCODE% /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo > "%ENCODE_LOG%" 2>&1
set ENCODE_ERR=%ERRORLEVEL%
type "%ENCODE_LOG%"
type "%ENCODE_LOG%" >> "%LOGFILE%"
if %ENCODE_ERR% NEQ 0 (
    echo.
    echo ENCODE_ENVIRONMENT_STACK FAILED. See %ENCODE_LOG% for details.
    exit /b 1
)
echo encode_environment_stack OK.

echo.
:: ----------------------------------------------------------
:: Build security-community.lib (stacksecurity.cpp — sets
:: license_class and deploy_targets for community builds).
:: Must be explicit because development.vcxproj uses
:: BuildProjectReferences=false.
:: ----------------------------------------------------------
echo Building security-community ...
echo Building security-community ... >> "%LOGFILE%"
set "SECCOM_LOG=%~dp0build-security-community.log"
"%MSBUILD%" %VCXPROJ_SECURITY_COMMUNITY% /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo > "%SECCOM_LOG%" 2>&1
set SECCOM_ERR=%ERRORLEVEL%
type "%SECCOM_LOG%"
type "%SECCOM_LOG%" >> "%LOGFILE%"
if %SECCOM_ERR% NEQ 0 (
    echo.
    echo SECURITY-COMMUNITY BUILD FAILED. See %SECCOM_LOG% for details.
    exit /b 1
)
echo security-community OK.

echo.
:: ----------------------------------------------------------
:: Build kernel.lib — the main engine object library (~300 source files).
::
:: Root cause of previous winnt.h(24176) C2059 failures (now fixed):
::   sysdefs.h defined #define None 0 which collided with the
::   IMAGE_POLICY_ENTRY.None union member added in Windows SDK 26100.
::   Fixed in engine\src\w32prefix.h: #undef None before <windows.h>,
::   #define None 0 restored after.  All engine files can now compile.
::
:: /p:OutDir="..\Debug\" overrides the standalone output directory so
:: kernel.lib lands in build-win-x86_64\livecode\Debug\lib\kernel.lib —
:: the same path that development.vcxproj links against.  Without this,
:: a standalone kernel.vcxproj build puts the lib under engine\Debug\lib\
:: which development.vcxproj never finds.
:: ----------------------------------------------------------
echo Building kernel ...
echo Building kernel ... >> "%LOGFILE%"
set "KERNEL_LOG=%~dp0build-kernel.log"
:: OutDir quoting note:
::   The C runtime's CommandLineToArgvW treats \" as an escaped quote, so
::   "/p:OutDir=..\Debug\" would consume the rest of the command line.
::   Fix: use an absolute path and end with \\ inside the quotes — the C
::   runtime converts \\" to one literal \ followed by the closing quote.
set "KERNEL_OUTDIR=%~dp0build-win-x86_64\livecode\Debug"
"%MSBUILD%" %VCXPROJ_KERNEL% /p:Configuration=Debug /p:Platform=x64 "/p:OutDir=%KERNEL_OUTDIR%\\" /p:BuildProjectReferences=false /v:minimal /nologo > "%KERNEL_LOG%" 2>&1
set KERNEL_ERR=%ERRORLEVEL%
type "%KERNEL_LOG%"
type "%KERNEL_LOG%" >> "%LOGFILE%"
if %KERNEL_ERR% NEQ 0 (
    echo.
    echo KERNEL BUILD FAILED. See %KERNEL_LOG% for details.
    exit /b 1
)
echo kernel OK.

echo.
:: ----------------------------------------------------------
:: Patch kernel.lib with printer base class (MCPrinter) and Windows
:: subclass (MCWindowsPrinter).
::
:: kernel.vcxproj compiles printer.cpp, w32printer.cpp, and
:: customprinter.cpp, but the winnt.h SDK conflict historically prevented
:: w32printer.cpp from compiling correctly inside vcxproj.  compile-printer.bat
:: compiles all three with the correct flags and patches the resulting objects
:: into kernel.lib so the linker can always resolve all MCPrinter:: symbols.
::
:: This must run AFTER the kernel build (so kernel.lib exists) and BEFORE
:: the engine link step (so the symbols are present when needed).
:: ----------------------------------------------------------
echo Patching kernel.lib with printer objects ...
echo Patching kernel.lib with printer objects ... >> "%LOGFILE%"
set "PRINTER_LOG=%~dp0compile-printer.log"
call "%~dp0compile-printer.bat" Debug >> "%LOGFILE%" 2>&1
if errorlevel 1 (
    echo.
    echo PRINTER PATCH FAILED. See %PRINTER_LOG% for details.
    exit /b 1
)
echo Printer patch OK.

echo.
:: ----------------------------------------------------------
:: Build kernel-development.lib — contains the bulk of engine
:: source files (deploy.cpp, license.cpp, etc.).  Must be built
:: explicitly because development.vcxproj uses
:: BuildProjectReferences=false and will fail with LNK1181 if
:: this lib is missing or stale.
:: ----------------------------------------------------------
echo Building kernel-development ...
echo Building kernel-development ... >> "%LOGFILE%"
set "KDEV_LOG=%~dp0build-kernel-development.log"
"%MSBUILD%" %VCXPROJ_KERNEL_DEVELOPMENT% /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo > "%KDEV_LOG%" 2>&1
set KDEV_ERR=%ERRORLEVEL%
type "%KDEV_LOG%"
type "%KDEV_LOG%" >> "%LOGFILE%"
if %KDEV_ERR% NEQ 0 (
    echo.
    echo KERNEL-DEVELOPMENT BUILD FAILED. See %KDEV_LOG% for details.
    exit /b 1
)
echo kernel-development OK.

echo.
:: ----------------------------------------------------------
:: Build libxml2 and libxslt BEFORE the engine — development.vcxproj
:: links libxml.lib and libxslt.lib directly, so they must exist on
:: disk before the link step runs.  revxml (a DLL loaded at runtime)
:: is built after standalone-community.exe.
:: ----------------------------------------------------------
echo Building libxml2 (2.15.3) ...
echo Building libxml2 ... >> "%LOGFILE%"
"%MSBUILD%" %VCXPROJ_LIBXML% /t:Rebuild /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo >> "%LOGFILE%" 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: libxml2 build failed. See %LOGFILE%
    exit /b 1
)
echo libxml2 OK.

echo Building libxslt ...
echo Building libxslt ... >> "%LOGFILE%"
"%MSBUILD%" %VCXPROJ_LIBXSLT% /t:Rebuild /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo >> "%LOGFILE%" 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: libxslt build failed. See %LOGFILE%
    exit /b 1
)
echo libxslt OK.

echo.
echo Building engine ...

set "EXE=build-win-x86_64\livecode\Debug\HyperXTalk.exe"
set "ENGINE_LOG=%~dp0build-engine-step.log"
set "LINK_TLOG=build-win-x86_64\livecode\engine\Debug\x64\obj\development\development.tlog\link.write.1.tlog"

:: If the exe is missing, delete the linker tlog so MSBuild is forced
:: to rerun the link step even when no source files changed.
if not exist "%EXE%" (
    if exist "%LINK_TLOG%" (
        del /F /Q "%LINK_TLOG%"
        echo Cleared linker tlog to force relink.
    )
)

"%MSBUILD%" %VCXPROJ_ENGINE% /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo > "%ENGINE_LOG%" 2>&1
set BUILD_ERR=%ERRORLEVEL%

:: Show the engine build output (errors and warnings) on the console.
type "%ENGINE_LOG%"
type "%ENGINE_LOG%" >> "%LOGFILE%"

if %BUILD_ERR% NEQ 0 (
    echo.
    echo ENGINE BUILD FAILED.
    exit /b 1
)

if not exist "%EXE%" (
    echo.
    echo ENGINE BUILD FAILED - HyperXTalk.exe was not produced.
    exit /b 1
)

echo Engine built: %EXE%

echo.
:: ----------------------------------------------------------
:: Build kernel-standalone.lib for x64.
:: The pre-built lib shipped as x86; we must compile it for x64 so that
:: standalone-community.exe can link against it.  Only the two mode source
:: files (mode_standalone.cpp, lextable.cpp) are compiled here — the
:: winnt.h SDK conflict does NOT affect these files.
:: BuildProjectReferences=false: encode_version and perfect are already
:: present from the engine build; no need to rebuild them.
:: ----------------------------------------------------------
echo Building kernel-standalone (x64 mode library) ...
echo Building kernel-standalone ... >> "%LOGFILE%"
set "KSTD_LOG=%~dp0build-kernel-standalone.log"
"%MSBUILD%" %VCXPROJ_KERNEL_STANDALONE% /t:Rebuild /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo > "%KSTD_LOG%" 2>&1
set KSTD_ERR=%ERRORLEVEL%
type "%KSTD_LOG%"
type "%KSTD_LOG%" >> "%LOGFILE%"
if %KSTD_ERR% NEQ 0 (
    echo.
    echo KERNEL-STANDALONE BUILD FAILED. See %KSTD_LOG% for details.
    exit /b 1
)
echo kernel-standalone OK.

echo.
:: ----------------------------------------------------------
:: Build standalone-community.exe (required by the standalone builder).
:: The IDE's revSBEnginePath resolves to standalone-community.exe when
:: editionType is "community" (or falls back to it for community builds).
:: ----------------------------------------------------------
echo Building standalone-community.exe ...
echo Building standalone-community.exe ... >> "%LOGFILE%"
set "STANDALONE_LOG=%~dp0build-standalone.log"
set "STANDALONE_EXE=build-win-x86_64\livecode\Debug\standalone-community.exe"
:: BuildProjectReferences=false: kernel-standalone.lib, security-community.lib and
:: kernel.lib are already pre-built; we just link against them without rebuilding
:: (rebuilding them triggers winnt.h SDK conflicts in those older vcxprojs).
"%MSBUILD%" %VCXPROJ_STANDALONE% /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo > "%STANDALONE_LOG%" 2>&1
set STANDALONE_ERR=%ERRORLEVEL%
type "%STANDALONE_LOG%" >> "%LOGFILE%"
if %STANDALONE_ERR% NEQ 0 goto standalone_failed
echo standalone-community.exe OK.
goto standalone_done
:standalone_failed
echo.
:: Write filtered errors to a small file for easy inspection.
set "STANDALONE_ERRORS=%~dp0build-standalone-errors.log"
findstr /v /r "LNK4099\|LNK4075" "%STANDALONE_LOG%" > "%STANDALONE_ERRORS%"
echo STANDALONE BUILD FAILED. Filtered errors (excluding LNK4099/LNK4075 noise):
type "%STANDALONE_ERRORS%"
if not exist "%STANDALONE_EXE%" (
    echo ERROR: standalone-community.exe is missing and could not be built.
    exit /b 1
)
echo WARNING: Using existing standalone-community.exe from a previous build.
:standalone_done

echo.
:: ----------------------------------------------------------
:: Build revxml (IDE XML external).
:: libxml.lib / libxslt.lib were already built before the engine above.
:: revxml.dll is loaded at runtime by the IDE — it does not need to
:: exist before the engine links.
:: ----------------------------------------------------------
echo Building revxml (IDE XML external) ...
echo Building revxml ... >> "%LOGFILE%"
"%MSBUILD%" %VCXPROJ_REVXML% /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo >> "%LOGFILE%" 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: revxml build failed. See %LOGFILE%
    exit /b 1
)
echo revxml OK.

echo.
:: server-revxml.dll and server-revzip.dll are built in Release by
:: build-release-x64.bat (after Release libxml2/libxslt/libzip are ready)
:: so they use the Release CRT matching server-community.exe.

echo.
echo Building revbrowser (Debug — used as fallback by build-release-x64.bat) ...
echo Building revbrowser (Debug) ... >> "%LOGFILE%"
set "REVBROWSER_LOG=%~dp0build-revbrowser.log"
"%MSBUILD%" %VCXPROJ_REVBROWSER% /p:Configuration=Debug /p:Platform=x64 /p:BuildProjectReferences=false /v:minimal /nologo > "%REVBROWSER_LOG%" 2>&1
set REVBROWSER_ERR=%ERRORLEVEL%
type "%REVBROWSER_LOG%"
type "%REVBROWSER_LOG%" >> "%LOGFILE%"
if %REVBROWSER_ERR% NEQ 0 (
    echo WARNING: revbrowser Debug build failed -- Release step will also fail.
) else (
    echo revbrowser Debug OK.
)

echo.
:: ----------------------------------------------------------
:: Recompile browser widget (browser.lcb → module.lcm).
:: We invoke lc-compile.exe directly rather than going through
:: server-community.exe + extension-utils.livecodescript, which
:: is unreliable in a plain cmd environment.
:: Only the browser widget is compiled here — it is the only LCB
:: file changed for the navigation-event fix.
:: ----------------------------------------------------------
echo.
echo Compiling browser widget (browser.lcb) ...
echo Compiling browser widget ... >> "%LOGFILE%"
set "LC_COMPILE=build-win-x86_64\livecode\Debug\lc-compile.exe"
set "LCI_DIR=build-win-x86_64\livecode\Debug\modules\lci"
set "BROWSER_PKG=build-win-x86_64\livecode\Debug\packaged_extensions\com.livecode.widget.browser"

:: Ensure widgetutils.lci is in the LCI dir — it is not generated by
:: engine_lcb_modules but is needed by browser.lcb at compile time.
set "WIDGETUTILS_LCI=extensions\modules\widget-utils\com.livecode.library.widgetutils.lci"
if exist "%WIDGETUTILS_LCI%" (
    copy /Y "%WIDGETUTILS_LCI%" "%LCI_DIR%\com.livecode.library.widgetutils.lci" > nul
)
set "BROWSER_LCB=extensions\widgets\browser\browser.lcb"

if not exist "%LC_COMPILE%" (
    echo ERROR: lc-compile.exe not found. Build the engine first.
    exit /b 1
)

:: Create the packaged extension directory and seed it with the manifest
:: if it doesn't already exist (first CI run, clean checkout).
if not exist "%BROWSER_PKG%" mkdir "%BROWSER_PKG%"
if not exist "%BROWSER_PKG%\manifest.xml" (
    copy /Y "extensions\widgets\browser\manifest.xml" "%BROWSER_PKG%\manifest.xml" > nul
)

:: Delete the old module to force a clean output.
if exist "%BROWSER_PKG%\module.lcm" del /F /Q "%BROWSER_PKG%\module.lcm"

set "LCOMPILE_LOG=%~dp0build-browser-widget.log"
"%LC_COMPILE%" --modulepath "%BROWSER_PKG%" --modulepath "%LCI_DIR%" --manifest "%BROWSER_PKG%\manifest.xml" --output "%BROWSER_PKG%\module.lcm" "%BROWSER_LCB%" > "%LCOMPILE_LOG%" 2>&1
set LC_ERR=%ERRORLEVEL%
type "%LCOMPILE_LOG%"
type "%LCOMPILE_LOG%" >> "%LOGFILE%"
if %LC_ERR% NEQ 0 (
    echo.
    echo BROWSER WIDGET COMPILE FAILED. Full output above / in %LCOMPILE_LOG%
    exit /b 1
)
if not exist "%BROWSER_PKG%\module.lcm" (
    echo.
    echo BROWSER WIDGET COMPILE FAILED - module.lcm was not produced.
    exit /b 1
)
:: Sync the updated source into the packaged extension folder.
copy /Y "%BROWSER_LCB%" "%BROWSER_PKG%\browser.lcb" > nul
echo Browser widget OK.

echo.
echo Build completed: %DATE% %TIME%
echo Build completed: %DATE% %TIME% >> "%LOGFILE%"
echo Full log: %LOGFILE%