# Parametric EQ replaces graphic EQ as a single engine

The existing 10-band graphic EQ (BiquadEQNode) uses hardcoded center frequencies and a fixed Q. Rather than adding a separate parametric EQ alongside it, we replace the graphic EQ with a parametric engine (up to 20 bands, Peak/Low Shelf/High Shelf) and offer the graphic EQ as a UI mode that maps 10 fixed-frequency sliders to parametric bands internally.

## Considered Options

- **Coexist**: keep both graphic and parametric as separate DSPNodes. Doubles maintenance, confuses users about which is active, two code paths through the same biquad math.
- **Replace**: one parametric engine, graphic EQ is a UI skin. Existing presets (EQPresets.json) become arrays of ParametricBand values. The engine is strictly a superset.

## Consequences

- The `BiquadEQNode` is rewritten as `ParametricEQNode` with variable bands, each carrying type/frequency/Q/gain.
- AutoEQ text format import is supported, enabling 5000+ headphone correction profiles out of the box.
- User presets are stored as JSON files in `~/Library/Application Support/PurePlay/EQPresets/`, factory presets remain in `Resources/`.
- UI is hybrid: draggable nodes on the frequency response curve + a detail panel for exact numeric entry.
- No open-source macOS player currently offers parametric EQ — this becomes a differentiator.
