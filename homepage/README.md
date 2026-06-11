# Turbokod homepage (magazine-ad take)

A single static page styled after an early-1990s glossy magazine
advertisement — serif body in justified columns, a hero "product
photograph," a clip-out order coupon, and a reader-service line — the way
Borland, Lotus, and TI sold software in print.

This is an alternative to the sibling `homepage/` directory (which renders the
DOS Turbo Vision GUI in the browser). Pick whichever you prefer for Pages.

No build step — plain HTML + CSS.

## Files

- `index.html` — the page (self-contained, CSS inlined)
- `fonts/TurbokodVGA.woff2` — the IBM VGA 8x16 bitmap font (used only for the
  terminal block and the wordmark). Generated from the CC BY-SA BDF in
  `farsil/ibmfonts`; see `../homepage/tools/bdf2woff.py`.
- `img/` — screenshots (copied from the repo root / `docs/screenshots/`)
- `.nojekyll` — tell GitHub Pages to serve assets verbatim (no Jekyll pass)

## Publishing via GitHub Pages

Settings → Pages → Build and deployment:

- **Source:** Deploy from a branch
- **Branch:** `main`, folder `/homepage2`

## Local preview

```sh
cd homepage2 && python3 -m http.server 8000   # then open http://localhost:8000
```
