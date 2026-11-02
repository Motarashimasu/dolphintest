@echo off
rem Tests the Team Battle 3-character rule in a DRAGON NET lobby on this PC: two Dolphins (a host
rem and a joiner) in a Team Battle lobby, both booting into Team Battle's character select.
rem Copy it into the game folder (next to the Dolphin and SparkingData folders) and run:
rem
rem   test_team_lobby.bat on       Player Match, the host's toggle switched ON: up to 3 per team
rem   test_team_lobby.bat off      Player Match, toggle OFF: the game's normal 5 per team
rem   test_team_lobby.bat ranked   ranked Team Battle: always on (no toggle)
rem   test_team_lobby.bat lounge   Battle Lounge Team Battle: always on (no toggle)
rem
rem What to check at character select: with the rule, after the 3rd pick the cursor goes to OK,
rem and Up / Down never reach a 4th slot; removing one makes room again. Without it, 5 as usual.
rem The host window's output shows "lobby_codes" ... "on":["Team Battle: Up To 3 Characters"]
rem when the rule is on, and "gecko_active" lists it once the game boots.
rem The second Dolphin uses SparkingData\user2 (copied from user the first time).
setlocal
cd /d "%~dp0"
set DOL=Dolphin\DolphinNoGUI.exe
set GAME=SparkingData\title\RDSPAF.rvz
set COMMON=-p win32 -v D3D --window 1280x720 --hud on --nand SparkingData\saves\netplay\RDSPAF --state-dir SparkingData\states --netplay-gecko "1=Player 1 Splitscreen Remover" --netplay-gecko "2=Player 2 Splitscreen Remover" --netplay-direct

if "%~1"=="__joiner" goto joiner

set MODE=%~1
if "%MODE%"=="" set MODE=on
if not exist "%DOL%" (echo %DOL% not found: put this file in the game folder. & pause & exit /b 1)
if not exist "%GAME%" (echo %GAME% not found: build the game copy in the launcher first. & pause & exit /b 1)
if not exist SparkingData\user2 xcopy /e /i /q SparkingData\user SparkingData\user2 >nul

set HOSTX=--mode team
set CODES=codes none
if /i "%MODE%"=="on" set CODES=codes Team Battle: Up To 3 Characters
if /i "%MODE%"=="ranked" set HOSTX=--mode team --ranked
if /i "%MODE%"=="lounge" set HOSTX=--mode team --koth
echo Mode: %MODE%    host: "%CODES%", then start

rem The joiner, in its own window (joins once the host is up).
start "Joiner (Team lobby test)" cmd /c call "%~f0" __joiner %MODE%

rem The host: its commands go in through the pipe (the rule, then start, retried until both are in).
(ping -n 12 127.0.0.1 >nul & echo %CODES% & ping -n 6 127.0.0.1 >nul & echo start & ping -n 8 127.0.0.1 >nul & echo start & ping -n 8 127.0.0.1 >nul & echo start & ping -n 99999 127.0.0.1 >nul) | %DOL% -u SparkingData\user %COMMON% --nickname Host %HOSTX% --netplay-host %GAME%
pause
exit /b 0

:joiner
set JOINX=
if /i "%~2"=="ranked" set JOINX=--ranked
if /i "%~2"=="lounge" set JOINX=--koth
ping -n 6 127.0.0.1 >nul
%DOL% -u SparkingData\user2 %COMMON% --nickname Joiner %JOINX% --netplay-join 127.0.0.1:2626 --netplay-game %GAME%
pause
exit /b 0
