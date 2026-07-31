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
STAGE = (
    REPO_ROOT / "apps" / "panel" / "web" / "js" / "preview" / "stage.js"
).read_text(encoding="utf-8")
INDEX = (REPO_ROOT / "apps" / "panel" / "web" / "index.html").read_text(
    encoding="utf-8")
CONTROLS = (
    REPO_ROOT / "apps" / "panel" / "web" / "js" / "settings" / "controls.js"
).read_text(encoding="utf-8")


class MobilePreviewContractTest(unittest.TestCase):
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

    def test_empty_state_keeps_select_centered_and_meta_in_normal_flow(self):
        self.assertIn('<span class="stage-empty-meta">', INDEX)
        self.assertIn(".stage-empty-meta {", COMPONENTS)
        self.assertIn("top: calc(50% + var(--stage-select-half)", COMPONENTS)
        support_rule = COMPONENTS.split(".stage-support {", 1)[1].split("}", 1)[0]
        progress_rule = COMPONENTS.split(".stage-progress {", 1)[1].split("}", 1)[0]
        self.assertNotIn("position: absolute", support_rule)
        self.assertNotIn("position: absolute", progress_rule)

    def test_closing_help_preserves_mouse_hover_mask(self):
        self.assertIn("trigger.maskMouseHovered = true;", CONTROLS)
        self.assertIn("trigger.maskMouseHovered = false;", CONTROLS)
        self.assertIn("open || button.maskMouseHovered === true", CONTROLS)


if __name__ == "__main__":
    unittest.main()
