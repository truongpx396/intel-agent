---
mode: agent
description: End-to-end workflow for creating designs with ui-ux-pro-max and syncing them to Google Stitch
---

# UI/UX → Stitch Workflow

Use this workflow when designing from scratch using self-contained HTML/Tailwind pages, guided by `ui-ux-pro-max`, then pushing to Google Stitch.

## Skills involved

| Skill | Role |
|---|---|
| `ui-ux-pro-max` | Generates local design system (`MASTER.md`) with tokens, colors, typography |
| `stitch-manage-design-system` | Uploads `DESIGN.md` and creates DS in Stitch |
| `stitch-upload-to-stitch` | Uploads `.stitch/designs/*.html` pages to Stitch |
| `stitch-extract-static-html` | ❌ Skip — only needed when extracting from a built app |
| `stitch-extract-design-md` | ❌ Skip — only needed when reverse-engineering existing code |
| `stitch-generate-design` | ❌ Skip — only for cloud-only Stitch generation (no local HTML) |
| `stitch-code-to-design` | ❌ Skip — chains extract skills, not needed in scratch HTML path |

## Single Source of Truth

| Layer | Location | What lives here |
|---|---|---|
| **Local SSOT** | `design-system/MASTER.md` | All design tokens, colors, typography, patterns |
| **Page overrides** | `design-system/pages/<page>.md` | Per-page deviations from master |
| **Stitch export** | `.stitch/DESIGN.md` | Stitch-formatted DS, uploaded to cloud |
| **HTML snapshots** | `.stitch/designs/*.html` | Self-contained pages, uploaded to Stitch |
| **Cloud mirror** | Google Stitch project | Live DS + screens for collaboration/handoff |

**Rule:** `design-system/MASTER.md` is always ground truth. `.stitch/` is the upload-ready export layer. Stitch is the downstream render target — never edit tokens in Stitch without syncing back.

**Sync direction is one-way:** local → Stitch. Stitch cannot export back to local files.

## Recommended folder structure

```
design-system/
  MASTER.md               ← LOCAL SSOT (ui-ux-pro-max output)
  pages/
    dashboard.md          ← page-level token overrides
    <page>.md
.stitch/
  DESIGN.md               ← Stitch-formatted DS export
  designs/
    dashboard.html        ← self-contained HTML, ready to upload
    admin.html
    billing.html
    <page>.html
```

## Phase 1 — Generate design system locally (ui-ux-pro-max)

```bash
python3 .claude/skills/ui-ux-pro-max/scripts/search.py \
  "<product_type> <industry> <keywords>" \
  --design-system --persist -p "<Project Name>"
# → creates design-system/MASTER.md
```

For a page-specific override:
```bash
python3 .claude/skills/ui-ux-pro-max/scripts/search.py \
  "<query>" --design-system --persist -p "<Project Name>" --page "<page-name>"
# → creates design-system/pages/<page-name>.md
```

Hierarchical retrieval rule:
1. Check `design-system/pages/<page>.md` first
2. Fall back to `design-system/MASTER.md`

## Phase 2 — Generate self-contained HTML pages

Copilot generates each page as a **self-contained HTML/Tailwind file**, guided by `design-system/MASTER.md` tokens.

Each file must:
- Use Tailwind via CDN (no build step)
- Embed the custom token config inline via `tailwind.config`
- Be fully renderable standalone in a browser

**Template structure:**
```html
<!DOCTYPE html>
<html class="dark" lang="en">
<head>
  <meta charset="utf-8"/>
  <meta content="width=device-width, initial-scale=1.0" name="viewport"/>
  <title>Page Title</title>
  <script src="https://cdn.tailwindcss.com?plugins=forms,container-queries"></script>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet"/>
  <script id="tailwind-config">
    tailwind.config = {
      darkMode: "class",
      theme: {
        extend: {
          colors: {
            /* tokens from design-system/MASTER.md */
          }
        }
      }
    }
  </script>
</head>
<body>
  <!-- page content -->
</body>
</html>
```

Save output to: `.stitch/designs/<page>.html`

## Phase 3 — Push design system to Stitch (stitch-manage-design-system)

1. Adapt `design-system/MASTER.md` → `.stitch/DESIGN.md` (Stitch-compatible format)
2. Run `create_design_system_from_design_md` MCP tool
3. Associate with your Stitch `projectId`

## Phase 4 — Upload HTML pages to Stitch (stitch-upload-to-stitch)

Upload each `.stitch/designs/<page>.html` to Stitch:

```bash
python3 .claude/skills/stitch/stitch-upload-to-stitch/scripts/upload_to_stitch.py \
  --project-id <PROJECT_ID> \
  --file-path .stitch/designs/<page>.html \
  --api-key <API_KEY> \
  --title "<Page Title>"
```

> Repeat for each page. Upload requires explicit user confirmation before running.

## Flow diagram

```
ui-ux-pro-max --design-system --persist
    │
    ▼
design-system/MASTER.md  ←── LOCAL SSOT
    │
    ├─ guides HTML generation
    │       Copilot writes self-contained HTML/Tailwind
    │       → .stitch/designs/<page>.html
    │
    └─ adapted to Stitch format
            → .stitch/DESIGN.md
            stitch-manage-design-system → Stitch DS created
            stitch-upload-to-stitch → screens pushed to Stitch
                                              ↓
                                    Google Stitch (cloud mirror)
```
