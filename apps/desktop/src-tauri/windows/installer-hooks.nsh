; Stop the shell first so its Job Object can release the Python process tree.
; Older builds can leave a sidecar running after the shell has already exited.
!macro HYPERDR_STOP_PROCESSES
  !insertmacro CheckIfAppIsRunning "${MAINBINARYNAME}.exe" "${PRODUCTNAME}"
  !insertmacro CheckIfAppIsRunning "hyperdr-panel.exe" "${PRODUCTNAME} background service"
!macroend

!macro NSIS_HOOK_PREINSTALL
  !insertmacro HYPERDR_STOP_PROCESSES
  ; Rebuilds can share a version number; replace both executables in that case.
  SetOverwrite on
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  !insertmacro HYPERDR_STOP_PROCESSES
!macroend
