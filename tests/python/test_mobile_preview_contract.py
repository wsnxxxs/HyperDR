"""Mobile preview layout contracts that CSS and the stage controller share."""
from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SHELL = (REPO_ROOT / "apps" / "panel" / "web" / "css" / "shell.css").read_text(
    encoding="utf-8")
COMPONENTS = (
    REPO_ROOT / "apps" / "panel" / "web" / "css" / "components.css"
).read_text(encoding="utf-8")
TOKENS = (REPO_ROOT / "apps" / "panel" / "web" / "css" / "tokens.css").read_text(
    encoding="utf-8")
STAGE = (
    REPO_ROOT / "apps" / "panel" / "web" / "js" / "preview" / "stage.js"
).read_text(encoding="utf-8")
MAIN = (REPO_ROOT / "apps" / "panel" / "web" / "js" / "main.js").read_text(
    encoding="utf-8")
INDEX = (REPO_ROOT / "apps" / "panel" / "web" / "index.html").read_text(
    encoding="utf-8")
CONTROLS = (
    REPO_ROOT / "apps" / "panel" / "web" / "js" / "settings" / "controls.js"
).read_text(encoding="utf-8")
RUNNER = (
    REPO_ROOT / "apps" / "panel" / "web" / "js" / "run" / "runner.js"
).read_text(encoding="utf-8")
MEDIA = (REPO_ROOT / "apps" / "panel" / "web" / "js" / "core" / "media.js").read_text(
    encoding="utf-8")

#: Everything below the marker is inside `@media (width < 860px)`.
MOBILE_CSS = COMPONENTS[COMPONENTS.index("/* -- small screens"):]


class MobilePreviewContractTest(unittest.TestCase):
    def test_gradient_tokens_keep_light_dark_at_color_stops(self):
        self.assertNotIn("light-dark(linear-gradient", TOKENS)
        self.assertIn("--accent-gradient: linear-gradient", TOKENS)
        self.assertIn("--hdr-gradient:    linear-gradient", TOKENS)

    def test_settings_and_conversion_wait_for_a_successful_preview(self):
        self.assertIn('store.watchAny(["file", "previewReady"]', MAIN)
        self.assertIn("!state.file || !state.previewReady", RUNNER)
        self.assertIn("previewReady: false", STAGE)
        self.assertIn("previewReady: true", STAGE)
        self.assertIn("const PREVIEW_RELOAD_DELAY_MS = 240;", STAGE)

    def test_mobile_layout_has_no_fixed_preview_row_or_block_size_containment(self):
        self.assertIn("grid-template-rows: auto auto auto auto;", SHELL)
        self.assertIn("grid-template-rows: minmax(0, 1fr);", SHELL)
        self.assertIn("container-type: inline-size;", SHELL)
        self.assertIn("--stage-gutter: 0;", SHELL)

    def test_loaded_mobile_preview_is_driven_by_image_aspect_ratio(self):
        self.assertIn("aspect-ratio: var(--stage-aspect);", COMPONENTS)
        self.assertIn("max-height: 60dvh;", COMPONENTS)
        self.assertIn('stage.style.setProperty(\n      "--stage-aspect"', STAGE)
        mobile_branch = STAGE.index("if (mobileLayout.matches || expanded)")
        desktop_width_write = STAGE.index('stage.style.width = `${width}px`')
        self.assertLess(mobile_branch, desktop_width_write)
        between = STAGE[mobile_branch:desktop_width_write]
        self.assertIn('stage.style.removeProperty("width")', between)
        self.assertIn('stage.style.removeProperty("height")', between)

    def test_effect_canvases_fill_and_clip_to_the_rounded_frame(self):
        canvas_rule = COMPONENTS.split(".stage-frame canvas {", 1)[1].split("}", 1)[0]
        self.assertIn("border-radius: inherit;", canvas_rule)
        for role in ("canvas-hdr", "canvas-sdr"):
            selector = f'.stage-frame canvas[data-role="{role}"]'
            rule = COMPONENTS.split(selector, 1)[1].split("}", 1)[0]
            self.assertIn("width: 100%;", rule)
            self.assertIn("height: 100%;", rule)

    def test_resize_observer_does_not_write_mobile_pixel_dimensions(self):
        self.assertIn(
            "if (!mobileLayout.matches && !expanded) fitStageToImage();",
            STAGE,
        )

    def test_expanded_preview_has_css_fallback_and_tier_upgrade(self):
        self.assertIn(".stage-viewport.is-expanded", COMPONENTS)
        self.assertIn("position: fixed;", COMPONENTS)
        self.assertIn('typeof viewport.requestFullscreen === "function"', STAGE)
        self.assertIn("wanted > image.previewRequestEdge", STAGE)
        self.assertIn("const PREVIEW_TIERS = [960, 1280, 2048];", STAGE)

    def test_zoom_and_view_mode_controls_are_removed(self):
        self.assertNotIn('data-role="zoom-controls"', INDEX)
        self.assertNotIn('data-role="view-mode"', INDEX)

    def test_empty_state_is_one_centred_card_in_normal_flow(self):
        # The invitation is a bounded card centred in the drop area, not a
        # dashed rectangle drawn around the full height of the window with an
        # icon absolutely positioned at its midpoint.
        self.assertIn('<div class="stage-empty-card">', INDEX)
        empty_rule = COMPONENTS.split(".stage-empty {", 1)[1].split("}", 1)[0]
        self.assertIn("display: flex", empty_rule)
        self.assertIn("align-items: center", empty_rule)
        self.assertIn("justify-content: center", empty_rule)
        card_rule = COMPONENTS.split(chr(10) + ".stage-empty-card {", 1)[1].split("}", 1)[0]
        self.assertNotIn("position: absolute", card_rule)
        self.assertIn("width: min(", card_rule)
        # Everything inside the card is in flow, so nothing can overlap.
        for selector in (".stage-support {", ".stage-progress {",
                         ".stage-privacy {", ".stage-empty-mark {"):
            rule = COMPONENTS.split(selector, 1)[1].split("}", 1)[0]
            self.assertNotIn("position: absolute", rule)

    def test_empty_state_offers_a_real_button(self):
        # An icon the user has to guess is a button is not an affordance.
        self.assertIn('class="button button--primary stage-select"', INDEX)
        self.assertIn(">选择图片</button>", INDEX)

    def test_empty_card_sizes_the_stage_on_a_phone(self):
        # A fixed 210-260px box would clip the card.
        self.assertIn(".stage:not(.has-image) { height: auto; }", MOBILE_CSS)
        self.assertIn("position: static", MOBILE_CSS.split(".stage-empty {", 1)[1].split("}", 1)[0])

    def test_closing_help_preserves_mouse_hover_mask(self):
        self.assertIn("trigger.maskMouseHovered = true;", CONTROLS)
        self.assertIn("trigger.maskMouseHovered = false;", CONTROLS)
        self.assertIn("open || button.maskMouseHovered === true", CONTROLS)

    def test_mode_toggle_takes_its_own_row_rather_than_the_heading(self):
        # `.segmented button` makes every mode switch a 44px touch target, so
        # the toggle cannot share the group's baseline-aligned heading row.
        self.assertIn(".segmented button { min-height: 44px; }", MOBILE_CSS)
        self.assertIn(".group-head { flex-wrap: wrap; }", MOBILE_CSS)
        toggle = MOBILE_CSS.split(".optimize-toggle {", 1)[1].split("}", 1)[0]
        self.assertIn("display: flex", toggle)
        self.assertIn("flex-basis: 100%", toggle)
        # A height here would opt the toggle back out of the 44px target.
        self.assertNotIn("height", toggle)
        buttons = MOBILE_CSS.split(".optimize-toggle button {", 1)[1].split("}", 1)[0]
        self.assertIn("flex: 1", buttons)

    def test_viewport_queries_are_defined_once_and_match_the_stylesheet(self):
        self.assertIn('matchMedia("(width < 860px)")', MEDIA)
        self.assertIn("@media (width < 860px)", COMPONENTS)
        self.assertIn("@media (width < 860px)", SHELL)
        for source in (STAGE,):
            self.assertIn('from "../core/media.js"', source)
            self.assertNotIn("width: 859px", source)
            self.assertNotIn("min-width: 641px", source)

    def test_result_delivery_is_a_download_on_every_platform(self):
        self.assertIn('data-role="download"', INDEX)
        self.assertNotIn('data-role="export"', INDEX)
        self.assertIn('const download = role("download")', RUNNER)
        self.assertNotIn("outputSelectionId", RUNNER)


if __name__ == "__main__":
    unittest.main()
