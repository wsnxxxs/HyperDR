# Subview consistency

Settings, phone connection, LUT library, export and export history share an 840 × 600 desktop frame. LUT space settings and keyboard shortcuts use a 560 px wide frame with content-driven height. At widths up to 720 px, the main dialogs fill the viewport.

The shared styles align headers, close buttons, padding, surfaces and action bars. Long content scrolls independently. Primary buttons perform actions such as import or export; completion buttons close the view. Native dialogs handle Escape, focus containment and focus restoration. Backdrop dismissal requires the pointer to start and finish outside the window.

Browser checks at 1280 × 720 covered Settings, phone connection, empty LUT library, export with a loaded image, empty export history and shortcuts. Settings was checked in both themes. Settings and phone connection were checked at 390 × 844 with no horizontal overflow and visible bottom actions. Escape, backdrop dismissal and Settings focus restoration were verified. LUT space settings shares the frame but was not exercised with an imported LUT.

Validation passed:

- `node tests/js/panel_interaction_test.mjs`
- `node tests/js/phone_recovery_test.mjs`
- `python scripts/check_panel_roles.py`
- `python scripts/check_panel_i18n.py`
- `git diff --check`

The PNG files in this directory are browser captures of the implementation.

## Interaction alignment

All subviews now use the same opening and return path. Closing by a button, Escape or the backdrop restores the actual entry point. Opening phone connection from Settings preserves the category and returns there; the covered parent view stays inert and hidden. Ctrl/Cmd+, cannot close Settings underneath its child view.

Settings explains automatic saving; LUT space settings explains immediate application. Done dismisses completed settings and informational views. Export has separate Close and Cancel export actions, plus a note while work continues in the background. Phone connection can be reopened during an outstanding request without starting another request. Asynchronous operations do not focus controls in a closed view. Switching Settings categories disarms a pending reset confirmation.

Browser verification covered Settings → phone → Back/Escape → Settings, the nested keyboard shortcut, both LUT library entry points, immediate theme changes retained after Escape, reset confirmation disarming, history/shortcuts completion buttons, and narrow-screen footer visibility. A real export of the existing landscape fixture completed and appeared in history after its window was closed. `settings-interactions.png` and `phone-return.png` capture the updated controls.

Additional regression checks: `node tests/js/dialog_navigation_test.mjs`, updated `phone_recovery_test.mjs`, and `node tests/js/workflow_test.mjs` passed alongside the panel and localization checks.
