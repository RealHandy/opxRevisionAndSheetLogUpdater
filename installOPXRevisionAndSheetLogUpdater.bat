@ECHO OFF
SETLOCAL
SET "sourcedir=S:\OPX_StuffFOLDERS\SoftwareDev\Revit\opxRevisionAndSheetLogUpdater\release"
SET "destdir=C:\ProgramData\Autodesk\Revit\Macros\2014\Revit\AppHookup\opxRevisionAndSheetLogUpdater\Source\opxRevisionAndSheetLogUpdater"
MD "%destdir%" 2>NUL
FOR /f "tokens=1-4delims=." %%a IN (
 'dir /b /a-d "%sourcedir%\*.*" '
 ) DO (
  COPY "%sourcedir%\%%a.%%b.%%c.%%d" "%destdir%\"
)
GOTO :EOF