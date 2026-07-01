# EQ Panel layout: curve dominant, band region fixed-height

The Equalizer window (EQPanel) was rewritten on 2026-06-30 along with its two child views (ParametricEQEditor, EQBandTableView). The rewrite left the parametric curve editor without a bottom or height constraint — its size was implicit through a chain involving the headphone label and the band table's `>= 160` minimum, which collapsed under certain layout passes. The headphone label sat in its own row between the curve and the table with no clear owner, and the four content blocks (toolbar / curve / headphone row / table) competed for visual priority. This ADR sets a stable structural rule for the window.

## Considered Options

- **Equal split (curve and table side-by-side or 50/50 vertical)**: gives both views space but reduces curve drag precision below ~370pt width and leaves the window without a primary visual anchor.
- **Foldable band table (curve fills, table is a collapsible drawer)**: maximizes curve area but hides the precise-entry workflow behind a disclosure button; increases interaction cost for the band table's existing audience.
- **Inspector mode (curve fills, selected band opens a side inspector)**: requires reworking selection state in ParametricEQEditor and adding a new view; the band table already serves the "see all bands at once" purpose that an inspector would not.
- **Curve dominant + fixed-height band region**: curve absorbs remaining vertical space, band region (preamp toolbar + table) has a fixed 180pt height holding ~5 visible rows. The window's minSize is raised so the curve is never starved.

## Decision

**Curve dominant + fixed-height band region**, with these structural rules:

- **Toolbar (~50pt)**: title, on/off switch, preset menu, Import, Save, Reset, then a spring, then the current-headphone chip (hidden when empty) floated right. The headphone label no longer occupies its own row.
- **Curve editor**: absorbs all remaining vertical space between toolbar and band region; its `bottomAnchor` is constrained to the band region's top minus 8pt. No fixed height, no multiplier.
- **Band region (180pt fixed)**: a preamp toolbar row (32pt: preamp label / slider / numeric field, spring, +/− buttons) sitting directly on top of the band table (no separator). Table shows ~5 rows at 24pt row height.
- **Band table columns**: Type 110 / Freq 130 / Q 80 / Gain 130 / Enable 60. The previous `#` column is removed — parametric bands are an unordered set, the index has no decision value.
- **Window minSize**: raised from 700×460 to 700×520. The default size (780×520) stays. Below 520pt, the curve would compress below ~210pt and lose drag precision.
- **Spacing**: 16pt content insets (left/right/bottom), 8pt between toolbar and curve, 8pt between curve and band region, no visual divider between curve and band region (the preamp toolbar's typography is divider enough).

## Consequences

- The implicit "headphone label sized the curve" layout chain is removed; the curve's height is deterministic from the band region's fixed height.
- The band region's 32 + 22 + 5×24 + padding = ~174pt budget is just enough for 5 visible rows; users with more bands scroll. Visible-row count is a deliberate constraint, not an oversight.
- The headphone chip occupies zero space when no AutoEQ preset is loaded, so non-AutoEQ users see a clean toolbar.
- Internal drawing of ParametricEQEditor (grid density, node visuals, filter-type legend) is explicitly **out of scope** for this layout decision and tracked separately in `docs/issues/E*`.
- Two stale build artifacts (`EQCurveEditor.swift.o`, `ParametricBandDetailPanel.swift.o`) reference deleted source files from the pre-rewrite UI; they will disappear on the next clean build and need no action here.
