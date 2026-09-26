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
