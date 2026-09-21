#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""hyperdr GUI launcher.

Starts a tiny local web server for a control panel over the real hyperdr
converter. The server prints its URL; opening a browser is left to the caller.
The basic panel uses the standard library; phone certificate generation uses
cryptography (bundled in desktop releases).

Usage:
    python hyperdr_gui.py

One photograph at a time: upload it, tune it while watching a live HDR preview,
convert it, export it. Batch conversion is what the command line is for.

The implementation lives in the ``hyperdr_panel`` package next to this file:
    app         - local editor and desktop-shell entry point
    config      - shared paths and platform flags
    schema      - the converter's settings vocabulary, from schema/settings.json
    formats     - which files are images, by extension and leading bytes
    digest      - one content identity shared by upload, preview and model
    command     - panel controls -> a HyperDR command line (the only builder)
    executable  - finding the built converter
    session     - one image in, one result out, and their expiry
    color_lut   - session-owned immutable LUT files used by preview and export
    lut_library - the reusable local LUT library sessions copy from
    renditions  - immutable exports, published atomically on success
    export_target - the desktop save folder, and copies out of the workspace
    job         - the running conversion and the log the browser polls
    native_preview - validated linear-P3 float preview packets and their cache
    preview_worker - the resident preview process whose decodes outlive a slider
    model       - native embedded gain-model capability and packet adapter
    concurrency - process admission control shared by preview, model, and curve
    workbench   - shared photo, phone upload handoff and preview frame
    api         - the HTTP endpoints, as plain testable functions
    security    - tokens, login throttling, response headers
    handler     - HTTP request handling and routing
    server      - ports, TLS, addresses, startup
The browser front-end lives in ``web/``. Its UI schema is an adapter for labels,
widgets and request mapping; converter vocabulary validation comes from the
generated ``schema/settings.json`` consumed by the Python backend.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from hyperdr_panel import main  # noqa: E402

if __name__ == "__main__":
    main(sys.argv)
