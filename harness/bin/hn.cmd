@echo off
rem Windows wrapper: run hn.sh with Git Bash (for shells without bash, e.g. PowerShell / cmd)
setlocal
set "HN_BASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%HN_BASH%" set "HN_BASH=bash"
"%HN_BASH%" "%~dp0hn.sh" %*
exit /b %ERRORLEVEL%
