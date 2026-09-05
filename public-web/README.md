# InferenceBar — public website

This is the static marketing site for InferenceBar (project homepage /
`https://inferencebar.kladhest.se`). It is plain HTML/CSS/JS served through
`index.php` — a `.php` extension so it works as the directory index on a
host whose web server expects one, but there is no PHP in it and no build
step; any PHP-capable host (or one that simply serves the file as-is) works.

## Preview locally

```sh
cd public-web
php -S localhost:8000
```

Then open `http://localhost:8000` in a browser. (`python3 -m http.server`
also works for a quick look, since the file has no PHP to execute — it just
won't serve `.php` under its own extension the way a real host does.)

## Structure

```
public-web/
├── index.php              # the whole site (single page)
├── assets/
│   ├── css/style.css     # styles
│   ├── js/main.js        # tiny nav-toggle helper, no dependencies
│   ├── img/               # logo / favicon
│   └── screenshots/        # app screenshots used on the page
└── README.md
```

## Updating

The page is intentionally a single `index.php` with inlined SVG icons —
edit it directly. Screenshots live under `assets/screenshots/`; keep them
free of any personal file paths, usernames, or machine-specific details
before adding new ones, since this folder is published on the public site.
