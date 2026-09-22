---
phase: quick-260922-fa5
plan: 01
subsystem: website
tags: [seo, og-image, social-sharing, vercel]
dependency-graph:
  requires: []
  provides: [website/og-en.png, website/assets/og/og-en.html, en-og-meta]
  affects: [website/en/**/*.html]
tech-stack:
  added: []
  patterns: ["Chrome headless HTML->PNG render for OG card generation", "surgical git index staging via hash-object + update-index to isolate meta-only edits from unrelated pending diffs"]
key-files:
  created:
    - website/assets/og/og-en.html
    - website/og-en.png
  modified:
    - website/en/index.html
    - website/en/livret-v2.html
    - website/en/privacy.html
    - website/en/license.html
    - website/en/legal-notice.html
    - website/en/guides/mac-predictive-text-like-iphone.html
    - website/en/guides/local-llm-writing-assistant.html
    - website/en/guides/autocomplete-every-mac-app.html
    - website/en/guides/translate-while-typing-mac.html
    - website/en/guides/copilot-for-writing.html
    - website/en/guides/offline-ai-writing-mac.html
    - website/en/guides/professional-email-tone-mac.html
    - website/en/compare/cotypist-alternatives.html
decisions:
  - "Rendered og-en.png by using og.png itself as a full-bleed background layer (identical frame+silhouette guaranteed), then covering only the French text block with a solid paper-colored rectangle before painting the English copy — chosen over redrawing frame+silhouette from scratch for maximum fidelity."
  - "Title font-size reduced from an initial 150px to 128px so 'Souffleuse' (same word in both languages) fits inside the frame without clipping (150px overflowed past the inner right frame line)."
  - "On the 8 EN guide/compare pages, replaced the French-captioned portrait promo JPG (og:image) with og-en.png, since a 1080x1350 French-captioned portrait crops badly in summary_large_image and carries the wrong language for an EN page."
  - "Scoped all substitutions strictly to og:image / twitter:image meta lines (per task instructions), deliberately leaving JSON-LD 'image' fields and in-article <img> tags untouched, even though the plan's own broad verify grep pattern also matches those (see Deviations)."
metrics:
  duration: "~40 min"
  completed: "2026-09-22"
---

# Quick Task 260922-fa5: English OG image for souffleuse.app/en/* Summary

Rendered an English Open Graph card (`website/og-en.png`, 1200x630, pixel-matched to `og.png`'s frame/silhouette/typography) from a new regenerable HTML template, pointed all 13 English pages' `og:image`/`twitter:image` at it (including swapping out French-captioned promo JPGs on 8 guide pages), committed the change as a single 15-file commit via surgical git-index staging, and deployed it live to souffleuse.app.

## What was built

1. **`website/assets/og/og-en.html`** — a self-contained, regenerable Chrome-headless template. It loads `../../og.png` as a full-bleed 1200x630 background (guaranteeing an identical double-frame and silhouette), paints a solid `#f3ead9` rectangle over the French text block (x 490–1165, y 100–598 — inside the inner frame, right of the silhouette's hand at x≈459), then lays the English copy on top using the site's self-hosted Bodoni Moda / Spectral fonts at matching sizes/positions/colors. The file's header comment documents the exact regeneration command.
2. **`website/og-en.png`** — rendered via Chrome headless at device-scale 1, optimized with `pngquant` + `oxipng` (141 KB → 47.7 KB, well under the 300 KB budget).
3. **Meta updates on 13 EN pages** — `og:image` (and `twitter:image` where declared) now point to `https://souffleuse.app/og-en.png`. The 11 pages that lacked `og:image:width/height/alt` now have them (1200x630 + English alt text). FR pages (`website/*.html`, `website/guides/*.html`, `website/livret-v2.html`) were left untouched — still reference `og.png`.

## Visual comparison (og.png vs og-en.png)

Read both PNGs side by side with the Read tool after rendering and again after pngquant/oxipng optimization. Result: **passed**.
- Double thin ink frame intact on all four sides, identical to og.png.
- Silhouette (woman blowing a kiss) pixel-identical — it comes from the same og.png base layer.
- No residual French glyphs anywhere.
- Fonts loaded correctly: "Souffleuse" renders in Bodoni Moda italic with the distinctive `ff`/`ss` ligature look, not a Times/serif fallback.
- Kicker "WRITING AID FOR MAC" in Spectral small-caps, rouge `#8c2b21`, same letter-spacing feel as the French "AIDE À L'ÉCRITURE POUR MAC".
- Title "Souffleuse" (same word in both languages) had to be reduced from 150px to 128px font-size to avoid clipping past the inner frame — the longer English word width forced this vs. the original 150px French rendering.
- Tagline correctly wraps on two explicit lines ("The right word," / "whispered from the wings.") without touching the frame.
- Footer line "100% on your Mac. Nothing leaves." matches position/style of the French footer.
- Optimization (pngquant quality 80-98 + oxipng) did not introduce visible banding or artifacts — re-verified visually after compression.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - blocking] Title font-size overflow on first render**
- **Found during:** Task 1, step 5 (mandatory visual check)
- **Issue:** Initial `font-size: 150px` for `.title` (matching the French card's apparent size) caused "Souffleuse" to clip past the inner right frame line in the English render.
- **Fix:** Reduced to `128px` and adjusted `top` from 205px to 215px to keep the baseline visually aligned with the French original.
- **Files modified:** `website/assets/og/og-en.html`
- **Commit:** `f0c1483`

**2. [Rule 1 - bug] Transform script initially over-matched og.png occurrences**
- **Found during:** Task 2, first script run
- **Issue:** The first version of the surgical-staging Python script replaced *every* occurrence of `https://souffleuse.app/og.png` in the text, including the JSON-LD `"image"` field in `website/en/index.html` (unrelated to `og:image`/`twitter:image` meta). This tripped the script's own assertion ("staged diff must only contain og:image/twitter:image lines") and aborted before touching any other file.
- **Fix:** Reverted the one file's working-tree write (`git checkout -- website/en/index.html`, safe since that file carried no unrelated pending edits) and rewrote the substitution regex to match only `<meta property="og:image" ...>` / `<meta name="twitter:image" ...>` lines, not the raw URL string anywhere in the document. Reran cleanly across all 13 files.
- **Files affected:** transform script only (scratchpad, not committed); `website/en/index.html` working tree was momentarily touched and restored before any other file was processed.
- **Commit:** n/a (caught pre-commit, in scratchpad tooling)

### Notable scope clarification (not a fix, documented for the record)

The plan's `<task 2><verify><automated>` command includes a broad check: `! grep -rl 'souffleuse.app/og.png\|promo/souffleuse-en-action' website/en`. This also matches two occurrence types that are **out of the task's stated scope** (the task's own `<action>` text says twice: "These are only og:image and twitter:image lines"):
- The JSON-LD `Article`/`WebPage` schema `"image"` field (8 files: `index.html` + 7 guides/compare pages) — still points at `og.png` / the promo JPGs.
- In-article `<img src="/promo/souffleuse-en-action/web/...-720.jpg">` tags (2 files: `mac-predictive-text-like-iphone.html`, `cotypist-alternatives.html`) — these are real inline photos displayed in the article body, unrelated to social-share cards; overwriting them would have replaced a real 720px-wide content photo with the 1200x630 OG card in the wrong context.

Given the explicit scope statement in the task's own action text and the `<done>` criteria (which only mentions `og:image`/`twitter:image`), the surgical script was kept scoped to meta lines only, and this literal grep check in `<verify>` was treated as over-broad rather than authoritative. All meta-line requirements in `<done>` are satisfied (verified individually below). This is flagged here rather than silently deviating.

### Auth gates

None.

## Self-Check

- `website/assets/og/og-en.html` — FOUND
- `website/og-en.png` — FOUND, 1200x630, 47753 bytes
- Commit `f0c1483` — FOUND (`git log --oneline` confirms)
- Live `https://souffleuse.app/og-en.png` — 200, `image/png`, md5 identical to committed file (`9c420a7675722b56671743de87ce1da2`)
- Live `/en/` — `og:image` and `twitter:image` both `og-en.png`
- Live `/index.html` (FR home; `/` now 307-redirects to `/en/` due to an unrelated already-live commit `ac14d44`) — `og:image` still `og.png`, unchanged

## Self-Check: PASSED

## Deploy status

**Done — verified live.**

Pre-deploy safety check (per plan Task 3 step 2) confirmed the unrelated uncommitted working-tree changes (Souffleuse app sources, `licensed.py`, `appcast.xml`, deleted/added guide pages, Vercel Insights script snippets, Studio-license copy edits, `sitemap.xml`, Remotion components) were **already live** before this deploy:
- `appcast.xml` on disk vs. live: identical (`diff -q` reported no difference).
- `/en/privacy.html` live already served `_vercel/insights/script.js` (count 1).
- `https://souffleuse.app/guides/alternative-cotypist-sans-abonnement.html` (new, untracked guide) already returned 200 live.

So `vercel --prod` from `website/` published nothing beyond this task's 15-file commit that wasn't already live. Deploy proceeded.

Post-deploy live verification, all passed:
- `curl https://souffleuse.app/en/` → `og:image` and `twitter:image` = `https://souffleuse.app/og-en.png` (with width/height/alt present).
- `curl -I https://souffleuse.app/og-en.png` → `200`, `content-type: image/png`, 1200x630, md5 identical to the committed file.
- `curl https://souffleuse.app/en/guides/offline-ai-writing-mac.html` → `og:image` = `og-en.png` (note: the extension-less path `/en/guides/offline-ai-writing-mac` 404s; `cleanUrls` is not enabled for this route — used the `.html` path instead, consistent with how other EN guide links are referenced on the site).
- `curl https://souffleuse.app/index.html` (FR home content; `/` redirects to `/en/`, an already-live unrelated routing change) → `og:image` still `https://souffleuse.app/og.png`, unchanged.
- `data-version` count on `/index.html` and `/en/`: 4 (not 3 as CLAUDE.md's "recette rapide" note states — this is a pre-existing drift from an earlier unrelated commit, not caused by this task; noted but not fixed, out of scope).

## Threat Flags

None. This task introduces no new network endpoints, auth paths, or trust-boundary changes — it adds a static, first-party image and edits existing meta tags.
