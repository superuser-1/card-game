@echo off
REM Double-click to open the GIF -> Godot cosmetic converter UI.
REM Prefers pythonw / pyw so no console window sticks around.
setlocal
set "SCRIPT=%~dp0gif_to_cosmetic.py"

where pythonw >nul 2>&1 && ( start "" pythonw "%SCRIPT%" & goto :done )
where pyw     >nul 2>&1 && ( start "" pyw "%SCRIPT%"     & goto :done )
where python  >nul 2>&1 && ( start "" python "%SCRIPT%"  & goto :done )
where py      >nul 2>&1 && ( start "" py "%SCRIPT%"      & goto :done )

echo Python 3 was not found on your PATH.
echo Install it from https://www.python.org/downloads/ (tick "Add python.exe to PATH"),
echo then double-click this file again.
pause

:done
endlocal
