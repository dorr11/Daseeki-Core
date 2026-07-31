@echo off
REM Run the Daseeki-Core headless self-test harness under real Lua 5.1.
REM Reuses the interpreter vendored with the Nexus harness (no second copy).
REM Usage: run-selftests.cmd [CORE_DIR]
setlocal
set HERE=%~dp0
set LUA=%HERE%..\..\nexus-test-harness\lua51\lua5.1.exe
if not exist "%LUA%" set LUA=%HERE%..\lua51\lua5.1.exe
if not exist "%LUA%" (
  echo ERROR: lua5.1.exe not found. Expected at %HERE%..\..\nexus-test-harness\lua51\
  exit /b 2
)
set CORE=%~1
if "%CORE%"=="" set CORE=%HERE%..
"%LUA%" "%HERE%harness.lua" "%CORE%"
exit /b %ERRORLEVEL%
