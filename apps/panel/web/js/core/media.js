/* The two viewport questions the panel asks, defined once.
 *
 * They were inlined in the modules that needed them, which is how `stage.js`
 * came to treat a coarse-pointer tablet as touch while `runner.js`, holding a
 * hand-written `(min-width: 641px)`, still offered it the desktop save dialog.
 * A breakpoint that means the same thing in two files has to live in one.
 *
 * `mobileLayout` is the CSS breakpoint, spelled with the same range syntax as
 * the `@media (width < 860px)` block in components.css and shell.css so the
 * two cannot drift: the old `(max-width: 859px)` disagreed with the stylesheet
 * across the fractional pixel widths a zoomed or scaled viewport reports, and
 * the stage measures itself differently on each side of that line.
 *
 * `touchQuery` is a different question -- what is the hand doing? -- and a
 * large phone and a small tablet answer it the same way.
 */

export const mobileLayout = window.matchMedia("(width < 860px)");

export const touchQuery = window.matchMedia(
  "(max-width: 640px), (max-width: 1024px) and (hover: none) and (pointer: coarse)");
