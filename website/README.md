# Localabs marketing site

Static HTML / CSS / JS landing page for Localabs, designed in the
style of Claude.ai (warm cream background, dark charcoal text,
coral accent, Source Serif headings + Inter body, generous
whitespace).

## Run locally

No build step — open `index.html` directly, or serve the folder:

```bash
cd website
python3 -m http.server 8000
# then visit http://localhost:8000
```

## File map

- `index.html` — page structure + copy
- `styles.css` — design tokens at the top under `:root`; rebrand
  by retuning those CSS variables (`--accent`, `--bg`, etc.)
- `script.js` — header elevation on scroll + single-open FAQ
  accordion. The HTML works fine without JS.

## Adding real screenshots

Each placeholder lives in a `<div class="screenshot-placeholder
phone-screen">…</div>` block, wrapped in a `<div class="phone-frame">`
that gives it the iPhone-style bezel. To drop in a real screenshot:

1. Save the screenshot as a PNG inside `website/img/` (create the
   folder if it doesn't exist).
2. Replace the placeholder block:

   ```html
   <!-- before -->
   <div class="phone-frame">
       <div class="screenshot-placeholder phone-screen">
           <span class="placeholder-label">SCREENSHOT</span>
           <span class="placeholder-detail">Multi-page document scanner</span>
       </div>
   </div>

   <!-- after -->
   <div class="phone-frame">
       <img src="img/scanner.png" alt="Multi-page document scanner" class="phone-screen-image">
   </div>
   ```

3. Add this rule once to `styles.css` so the image fills the phone screen:

   ```css
   .phone-screen-image {
       width: 100%;
       height: 100%;
       object-fit: cover;
       border-radius: 34px;
       display: block;
   }
   ```

Screenshots that fit the 9:19.5 iPhone aspect ratio look best — any
recent iPhone simulator export will work directly.

## Where each placeholder lives

| Section | Placeholder copy | What to drop in |
| --- | --- | --- |
| Hero | "Dashboard with patient summary, doctor questions, and translated sections" | Dashboard / live translation view |
| How it works · 01 | "Multi-page document scanner" | VNDocumentCamera UI mid-scan |
| How it works · 02 | "Translated 5-section dashboard" | DashboardView with all five cards filled in |
| How it works · 03 | "Follow-up chat with lasso highlight" | DocumentViewerView with selection + chat sheet |
| Privacy | "Profile tab — on-device AI engine status, model picker" | ProfileView showing the AI engine card |
| Trends | "Trends tab with Apple-Health-style bar + line charts" | TrendsView with metric cards visible |

## Notes on the design

- All colors and spacing are token-driven via CSS custom properties
  at `:root`. Retune those to rebrand without touching individual
  rules.
- Headings use Source Serif 4 (a Tiempos-adjacent open Google
  font); body uses Inter. Loaded once via Google Fonts.
- The mobile breakpoint at 980px collapses the two-column hero +
  step rows into a single column. The feature grid drops to one
  column at 640px.
- The header gets a hairline border + faint shadow only after
  scroll (handled in `script.js`).
