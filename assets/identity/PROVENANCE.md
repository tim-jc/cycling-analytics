# Past the Grid identity provenance

Cycling Analytics adopted this local identity layer from the canonical
`pastthegrid-site` repository at revision:

```text
9b0c33ef6036f2e86cf3d8dcfde73141256120fb
```

Adopted on 10 November 2026 for Navigation Instrument Slice 1.

- `symbol-dark.svg` is an exact local copy of
  `pastthegrid-site/assets/symbol-dark.svg`.
- `favicon.svg` is an exact local copy of
  `pastthegrid-site/assets/favicon.svg`.
- `favicon.png` is a local 64-pixel raster rendering of that canonical SVG for
  browsers that do not display SVG favicons reliably.
- `tokens.css` preserves the canonical Navigation Instrument colours,
  typography and spacing values from `pastthegrid-site/assets/identity.css`.
  Token names are prefixed with `--ptg-` to avoid collisions with Bootstrap,
  Flexdashboard and htmlwidgets.

The canonical design guidance remains
`pastthegrid-site/docs/visual-identity.md`. Cycling Analytics owns its
Flexdashboard-specific integration.
