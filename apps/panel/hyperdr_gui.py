#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""hyperdr GUI launcher.

Starts a tiny local web server and opens your browser for a control panel over
the real hyperdr converter. Pure Python standard library, no pip installs.

Usage:
    python hyperdr_gui.py

One photograph at a time: upload it, tune it while watching a live HDR preview,
convert it, export it. Batch conversion is what the command line is for.

The implementation lives in the ``hyperdr_panel`` package next to this file:
    app         - entry-point dispatch: the --pick subprocess, or the server
    config      - shared paths and platform flags
    schema      - the converter's settings vocabulary, from schema/settings.json
    command     - panel controls -> a HyperDR command line (the only builder)
    executable  - finding the built converter
    session     - one image in, one result out, and their expiry
    job         - the running conversion and the log the browser polls
    native_preview - validated linear-P3 float preview packets and their cache
    model       - the optional HyperDR_Model gain-map inference run
    curve       - the exporter's tone curve, fetched from the binary
    concurrency - process admission control shared by preview, model, and curve
    picker      - native tkinter folder dialog (spawned as a subprocess)
    api         - the HTTP endpoints, as plain testable functions
    security    - tokens, login throttling, response headers
    handler     - HTTP request handling and routing
    server      - ports, TLS, addresses, startup
The front-end is a single source of truth in ``web/``.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from hyperdr_panel import main  # noqa: E402

if __name__ == "__main__":
    main(sys.argv)
