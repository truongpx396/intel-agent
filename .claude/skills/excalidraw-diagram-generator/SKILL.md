---
name: excalidraw-diagram-generator
description: 'Generate Excalidraw diagrams from natural language descriptions. Use when asked to "create a diagram", "make a flowchart", "visualize a process", "draw a system architecture", "create a mind map", or "generate an Excalidraw file". Supports flowcharts, relationship diagrams, mind maps, and system architecture diagrams. Outputs .excalidraw JSON files that can be opened directly in Excalidraw.'
---

# Excalidraw Diagram Generator

A skill for generating Excalidraw-format diagrams from natural language descriptions. This skill helps create visual representations of processes, systems, relationships, and ideas without manual drawing.

## When to Use This Skill

Use this skill when users request:

- "Create a diagram showing..."
- "Make a flowchart for..."
- "Visualize the process of..."
- "Draw the system architecture of..."
- "Generate a mind map about..."
- "Create an Excalidraw file for..."
- "Show the relationship between..."
- "Diagram the workflow of..."

**Supported diagram types:**
- 📊 **Flowcharts**: Sequential processes, workflows, decision trees
- 🔗 **Relationship Diagrams**: Entity relationships, system components, dependencies
- 🧠 **Mind Maps**: Concept hierarchies, brainstorming results, topic organization
- 🏗️ **Architecture Diagrams**: System design, module interactions, data flow
- 📈 **Data Flow Diagrams (DFD)**: Data flow visualization, data transformation processes
- 🏊 **Business Flow (Swimlane)**: Cross-functional workflows, actor-based process flows
- 📦 **Class Diagrams**: Object-oriented design, class structures and relationships
- 🔄 **Sequence Diagrams**: Object interactions over time, message flows
- 🗃️ **ER Diagrams**: Database entity relationships, data models

## Prerequisites

- Clear description of what should be visualized
- Identification of key entities, steps, or concepts
- Understanding of relationships or flow between elements

## Step-by-Step Workflow

### Step 1: Understand the Request

Analyze the user's description to determine:
1. **Diagram type** (flowchart, relationship, mind map, architecture)
2. **Key elements** (entities, steps, concepts)
3. **Relationships** (flow, connections, hierarchy)
4. **Complexity** (number of elements)

### Step 2: Choose the Appropriate Diagram Type

| User Intent | Diagram Type | Example Keywords |
|-------------|--------------|------------------|
| Process flow, steps, procedures | **Flowchart** | "workflow", "process", "steps", "procedure" |
| Connections, dependencies, associations | **Relationship Diagram** | "relationship", "connections", "dependencies", "structure" |
| Concept hierarchy, brainstorming | **Mind Map** | "mind map", "concepts", "ideas", "breakdown" |
| System design, components | **Architecture Diagram** | "architecture", "system", "components", "modules" |
| Data flow, transformation processes | **Data Flow Diagram (DFD)** | "data flow", "data processing", "data transformation" |
| Cross-functional processes, actor responsibilities | **Business Flow (Swimlane)** | "business process", "swimlane", "actors", "responsibilities" |
| Object-oriented design, class structures | **Class Diagram** | "class", "inheritance", "OOP", "object model" |
| Interaction sequences, message flows | **Sequence Diagram** | "sequence", "interaction", "messages", "timeline" |
| Database design, entity relationships | **ER Diagram** | "database", "entity", "relationship", "data model" |

### Step 3: Extract Structured Information

**For Flowcharts:**
- List of sequential steps
- Decision points (if any)
- Start and end points

**For Relationship Diagrams:**
- Entities/nodes (name + optional description)
- Relationships between entities (from → to, with label)

**For Mind Maps:**
- Central topic
- Main branches (3-6 recommended)
- Sub-topics for each branch (optional)

**For Data Flow Diagrams (DFD):**
- Data sources and destinations (external entities)
- Processes (data transformations)
- Data stores (databases, files)
- Data flows (arrows showing data movement from left-to-right or from top-left to bottom-right)
- **Important**: Do not represent process order, only data flow

**For Business Flow (Swimlane):**
- Actors/roles (departments, systems, people) - displayed as header columns
- Process lanes (vertical lanes under each actor)
- Process boxes (activities within each lane)
- Flow arrows (connecting process boxes, including cross-lane handoffs)

**For Class Diagrams:**
- Classes with names
- Attributes with visibility (+, -, #)
- Methods with visibility and parameters
- Relationships: inheritance (solid line + white triangle), implementation (dashed line + white triangle), association (solid line), dependency (dashed line), aggregation (solid line + white diamond), composition (solid line + filled diamond)
- Multiplicity notations (1, 0..1, 1..*, *)

**For Sequence Diagrams:**
- Objects/actors (arranged horizontally at top)
- Lifelines (vertical lines from each object)
- Messages (horizontal arrows between lifelines)
- Synchronous messages (solid arrow), asynchronous messages (dashed arrow)
- Return values (dashed arrows)
- Activation boxes (rectangles on lifelines during execution)
- Time flows from top to bottom

**For ER Diagrams:**
- Entities (rectangles with entity names)
- Attributes (listed inside entities)
- Primary keys (underlined or marked with PK)
- Foreign keys (marked with FK)
- Relationships (lines connecting entities)
- Cardinality: 1:1 (one-to-one), 1:N (one-to-many), N:M (many-to-many)
- Junction/associative entities for many-to-many relationships (dashed rectangles)

> ⚠️ **CRITICAL — Do NOT draw an arrow for a ubiquitous/tenant FK (avoids hairball):**
> If one column (e.g. `workspace_id`, `tenant_id`, `org_id`, `account_id`) appears as a FK on
> almost every table, drawing one arrow per table turns a hub entity into a spaghetti center —
> arrows fan out across the whole canvas and cross every other box. Instead:
> 1. **Omit** those ubiquitous-FK arrows entirely.
> 2. State the scoping once in the legend, e.g. *"All P tables carry `workspace_id` FK (tenant
>    scope) + RLS — omitted from arrows for clarity."*
> 3. Convey the grouping with **color + spatial clustering** (put all tenant-scoped tables in
>    columns near the hub), not with arrows.
> 4. Draw arrows ONLY for the **distinguishing** relationships: ownership (`owner_id`),
>    membership, parent→child within a subtree (`project_id → metrics`), and any 1:1 link.
> A clean ER diagram for a multi-tenant schema typically has **5–10 arrows**, not one per FK.

> ⚠️ **CRITICAL — Cardinality labels must be consistent and on every relationship arrow:**
> Pick ONE notation and use it for ALL arrows (don't mix `1:N` and `1..n`). Recommended:
> `1..1` (exactly one) and `1..n` (one-to-many); for N:M introduce a junction entity and label
> the two arrows `1..n` each. Place the label at the arrow's midpoint, just beside the line.
> Never leave a relationship arrow unlabeled, and never label a non-relationship (decorative) line.

> ⚠️ **CRITICAL — Entity header label must be centered (table-style boxes):**
> An ER entity box has a colored **header band** (entity name, centered) above a body of
> left-aligned fields. Build it as: (a) a colored outer rect, (b) a body-colored overlay rect
> covering everything below the header, (c) a divider line at the header's bottom edge, (d) a
> **separate centered text** for the title (`textAlign:"center"`, no `containerId`, positioned
> inside the header band), and (e) a **separate left-aligned text** for the fields. Do NOT bind
> the title with `containerId` if you also need left-aligned fields in the same box — use two
> free-floating text elements instead.

> ⚠️ **PREFER few long arrows over many — and never bus-route 3+ arrows through the same lane:**
> The top/bottom "bus" corridor is for at most ONE or two long-span arrows. Stacking three+
> arrows into the same horizontal bus lane (e.g. hub→three far entities) produces the exact
> tangle this skill is meant to prevent. If a hub needs to reach many far entities, that is the
> signal to apply the ubiquitous-FK rule above and omit those arrows.

### Step 4: Generate the Excalidraw JSON

Create the `.excalidraw` file with appropriate elements:

**Available element types:**
- `rectangle`: Boxes for entities, steps, concepts
- `ellipse`: Alternative shapes for emphasis
- `diamond`: Decision points
- `arrow`: Directional connections
- `text`: Labels and annotations

**Key properties to set:**
- **Position**: `x`, `y` coordinates
- **Size**: `width`, `height`
- **Style**: `strokeColor`, `backgroundColor`, `fillStyle`
- **Font**: `fontFamily: 5` (Excalifont - **required for all text elements**)
- **Connections**: `points` array for arrows

> ⚠️ **CRITICAL — Text inside shapes (rectangles, ellipses, diamonds):**
> Do NOT add a `text` property directly on a shape element. Excalidraw ignores it.
> Instead, create a **separate `text` element** with `containerId` pointing to the shape ID,
> and add a `boundElements: [{"type": "text", "id": "<text-id>"}]` entry on the shape.
>
> ```json
> // Shape element
> { "id": "rect1", "type": "rectangle", ..., "boundElements": [{"type": "text", "id": "txt_rect1"}] }
>
> // Paired text element (separate entry in elements array)
> {
>   "id": "txt_rect1", "type": "text",
>   "x": <shape_x + (width-text_width)/2>,
>   "y": <shape_y + (height-text_height)/2>,
>   "width": <estimated>, "height": <estimated>,
>   "containerId": "rect1",
>   "text": "Label text", "fontSize": 18, "fontFamily": 5,
>   "textAlign": "center", "verticalAlign": "middle",
>   "originalText": "Label text", "autoResize": true, "lineHeight": 1.25,
>   "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
>   "fillStyle": "solid", "strokeWidth": 2, "strokeStyle": "solid",
>   "roughness": 1, "opacity": 100, "groupIds": [], "frameId": null,
>   "index": "a0", "roundness": null, "seed": 12345, "version": 1,
>   "versionNonce": 12346, "isDeleted": false, "boundElements": null,
>   "updated": 1738195200000, "link": null, "locked": false
> }
> ```

> ⚠️ **BEST PRACTICE — Footer/legend sections use distinct colored boxes, not a single gray text blob:**
> A single free-floating text element for footer notes renders as an undifferentiated gray wall
> that is hard to scan. Instead, split each logical section into its own colored `rectangle` +
> bound `text` pair. Recommended per-section colors:
> - **Track / category items** → one distinct color each (e.g. green `#b2f2bb`, yellow `#ffec99`, blue `#a5d8ff`)
> - **Warning / important note** → pink `#ffc9c9` with red stroke `#c92a2a`
> - **Status / header row** → light gray `#dee2e6` with dark stroke `#495057`
>
> Lay sections out in a row (side-by-side) for categories, and use a full-width box for the
> warning note below. This makes the diagram self-explanatory at a glance.

> ⚠️ **CRITICAL — Arrow `points` array:**
> The **first point must always be `[0, 0]`** (relative to the arrow's `x`,`y` origin).
> All subsequent points are relative to the first. Never start with a non-zero first point.
>
> ```json
> // CORRECT
> { "x": 100, "y": 150, "width": 200, "height": 0,
>   "points": [[0, 0], [200, 0]] }
>
> // WRONG — will break file rendering
> { "x": 100, "y": 150, "points": [[200, 0], [400, 0]] }
> ```

> ⚠️ **CRITICAL — `index` field must be unique across ALL elements:**
> Every element (shapes, text, arrows) needs a distinct `index` string for z-ordering.
> Bound text elements added alongside shapes must NOT reuse `"a0"` — assign sequential values.
> Use a simple counter: `"a0"`, `"a1"`, ..., `"a9"`, `"aA"`, ..., `"aZ"`, `"b0"`, `"b1"`, ...
> Duplicate `index` values will prevent the file from opening in Excalidraw.

> ⚠️ **CRITICAL — Size every box to fit its text (no overflow):**
> Compute box size from the text BEFORE placing it. For hand-drawn font at `fontSize` `fs`:
> - `textWidth  ≈ maxLineLength × fs × 0.58`   (longest line, by character count)
> - `textHeight ≈ lineCount × fs × 1.25`
> - `boxWidth  = max(minWidth, textWidth + 34)` and `boxHeight = textHeight + 26` (padding)
>
> Never hardcode a width like `180` and then put a longer label in it — the text spills
> outside the box. Always derive width/height from the longest line and line count.
>
> This applies to **free-floating labels and titles too** (not just boxes). A standalone
> text element whose `width` is too small renders **clipped/truncated** (e.g. a title
> "Data Model Diagram" shows only "Data Model"). Set `width ≈ len(text) × fs × 0.62 + 8`
> for these, and keep `autoResize: true`. Under-estimating (e.g. `len × 6`) clips wide
> fonts; over-estimate slightly rather than under.

> ⚠️ **CRITICAL — Bound text element `height` must equal `lineCount × fontSize × 1.25` (never hardcode 38 for multi-line text):**
> When a text element is bound to a container (`containerId` set), its own `height` field
> in the JSON **must** reflect the actual rendered line count. Common values:
> - **`fontSize: 15`** — 1 line → `19` | 2 lines → `38` | 3 lines → `57` | 4 lines → `75`
> - **`fontSize: 13`** — 1 line → `17` | 2 lines → `33` | 3 lines → `49` | 4 lines → `65`
>
> The container must also be tall enough: `containerHeight = textHeight + 32px` (16px padding
> each side). For `verticalAlign: "middle"`, center the text: `textY = containerY + (containerH − textH) / 2`.
>
> ```json
> // 3-line text at fontSize:15 inside a container
> { "id": "box1", "type": "rectangle", "y": 100, "height": 89 }  // 57 + 32 = 89
> { "id": "txt1", "type": "text", "y": 116, "height": 57,         // (89−57)/2 = 16 → y=116
>   "containerId": "box1", "autoResize": true }
> ```
> Mismatched height clips the bottom line(s) even when `autoResize: true` is set, because
> the saved `height` value is used directly by the renderer on first load.

> ⚠️ **CRITICAL — Edge labels (arrow labels) must not overlap each other or adjacent boxes:**
> Free-floating text labels that annotate an arrow ("edge labels") are a common source of
> visual collisions. Follow these rules for every edge label:
> 1. **Clear of source AND target boxes**: keep the label at least **20 px away** from the
>    nearest box edge (horizontally AND vertically). A label only 2–3 px below a box looks
>    like it's inside that box.
> 2. **Never share a y-row with another label** unless their x-ranges are at least **30 px
>    apart**. Two labels at the same `y` whose x-ranges overlap will render as a single
>    unreadable blob (e.g. "semantic cache check" + "answer stream" fusing into garbage text).
> 3. **Compute bounding boxes before placing**: for a label at `(lx, ly)` with `width w` and
>    `height h`, the label occupies `[lx, lx+w] × [ly, ly+h]`. Check this rectangle against
>    every other label and every box in the diagram — if they intersect, shift the label
>    along the arrow (farther from the nearest end) until the intersection is gone.
> 4. **Prefer placing labels beside the arrow mid-segment, not at segment endpoints**. For a
>    horizontal segment, center the label horizontally on that segment and offset it **10–14 px
>    above** (for top-of-arrow labels) or **4–6 px below** (for below-arrow labels). For a
>    vertical segment, place the label to the **right** of the arrow with a 10 px gap.
> 5. **If two edge labels must be near the same location** (e.g., two arrows leaving the same
>    box), stagger them vertically by at least `fontSize * lineCount * 1.25 + 12` px.
> 6. **Wrap the label text when it is wider than the gap it sits in.** Before placing a label
>    on a horizontal segment, measure `gapWidth = targetBox.x − sourceBox.right`. If
>    `labelWidth > gapWidth − 40` (leaving 20 px margin on each side), split the text at a
>    word boundary to produce 2 lines. Recompute `width` and `height` after wrapping.
>    Example: "workspace_id lookup" (143 px) in a 134 px gap → wrap to "workspace_id\nlookup"
>    (≈92 px wide, 2 lines) before checking placement.
> 7. **Never place a label whose y-range overlaps the vertical span of a nearby box, even if
>    its x-range is technically in the gap between boxes.** For any box with
>    `[boxTop, boxBottom]`, a label placed at y inside `[boxTop, boxBottom]` will look embedded
>    in that box if its x is anywhere near the box's horizontal extent. Rule: if the label's
>    y falls within `[anyBox.y − 5, anyBox.y + anyBox.height + 5]`, move it **below** that
>    box row (`newY = anyBox.y + anyBox.height + 20`) or above it (`newY = anyBox.y − labelHeight − 14`),
>    whichever is closer to the arrow segment being annotated.

> ⚠️ **CRITICAL — Align to a uniform grid and route arrows through gutters:**
> Messy diagrams come from misaligned boxes and arrows drawn center-to-center (which cut
> diagonally across other boxes). To avoid this:
> 1. **Uniform grid**: pick `pitchX = maxBoxWidth + gapX` and `pitchY = maxBoxHeight + gapY`
>    (gaps ≥ 70px). Place each box CENTERED on its `(col, row)` cell center:
>    `cx = x0 + col×pitchX`, `cy = y0 + row×pitchY`. This guarantees boxes in the same row
>    share a center-Y and the same column share a center-X → arrows between them are straight.
> 2. **Anchor arrows on box EDGES**, not centers (exit the side facing the target).
> 3. **Route orthogonally through the empty gutters** between cells (never along a row/column
>    centerline, which passes through other boxes). For non-adjacent boxes use an L (1 bend),
>    Z (2 bends), or U (3 bends) path whose segments travel only in the gaps between boxes.
>    Before finalizing each arrow, check every segment against all OTHER box rectangles and
>    reroute (try a different exit side / gutter lane) if it intersects one.
> 4. Keep arrowheads only on the destination end (`endArrowhead: "arrow"`, `startArrowhead: null`).
>
> A reference generator implementing all of this (auto-sizing + grid + gutter routing) is in
> `scripts/` — prefer adapting it over hand-placing coordinates for any diagram with >6 boxes.

**All text elements must use `fontFamily: 5` (Excalifont) for consistent visual appearance.**

### Step 5: Format the Output

Structure the complete Excalidraw file:

```json
{
  "type": "excalidraw",
  "version": 2,
  "source": "https://excalidraw.com",
  "elements": [
    // Array of diagram elements
  ],
  "appState": {
    "viewBackgroundColor": "#ffffff",
    "gridSize": 20
  },
  "files": {}
}
```

### Step 6: Save and Provide Instructions

1. Save as `<descriptive-name>.excalidraw`
2. Inform user how to open:
   - Visit https://excalidraw.com
   - Click "Open" or drag-and-drop the file
   - Or use Excalidraw VS Code extension

## Best Practices

### Element Count Guidelines

| Diagram Type | Recommended Count | Maximum |
|--------------|-------------------|---------|
| Flowchart steps | 3-10 | 15 |
| Relationship entities | 3-8 | 12 |
| Mind map branches | 4-6 | 8 |
| Mind map sub-topics per branch | 2-4 | 6 |

### Layout Tips

1. **Start positions**: Center important elements, use consistent spacing
2. **Uniform grid (prevents misalignment)**: place boxes on a fixed `pitchX × pitchY` grid,
   centered on each cell, so rows/columns line up and arrows stay straight.
3. **Spacing**: gaps BETWEEN boxes of at least:
   - Horizontal gap: 70-120px (more for wide boxes)
   - Vertical gap: 70-100px between rows (leaves empty gutters for arrow routing)
4. **Arrows**: anchor on box edges and route orthogonally through the gutters; never draw
   center-to-center across other boxes. Verify no segment intersects a non-endpoint box.
5. **Colors**: Use consistent color scheme
   - Primary elements: Light blue (`#a5d8ff`)
   - Secondary elements: Light green (`#b2f2bb`)
   - Important/Central: Yellow (`#ffec99`)
   - Alerts/Warnings: Light red (`#ffc9c9`)
6. **Text sizing**: 15-24px; ALWAYS size the box to fit the text (see CRITICAL rule above)
7. **Font**: Always use `fontFamily: 5` (Excalifont) for all text elements

### Complexity Management

**If user request has too many elements:**
- Suggest breaking into multiple diagrams
- Focus on main elements first
- Offer to create detailed sub-diagrams

**Example response:**
```
"Your request includes 15 components. For clarity, I recommend:
1. High-level architecture diagram (6 main components)
2. Detailed diagram for each subsystem

Would you like me to start with the high-level view?"
```

## Example Prompts and Responses

### Example 1: Simple Flowchart

**User:** "Create a flowchart for user registration"

**Agent generates:**
1. Extract steps: "Enter email" → "Verify email" → "Set password" → "Complete"
2. Create flowchart with 4 rectangles + 3 arrows
3. Save as `user-registration-flow.excalidraw`

### Example 2: Relationship Diagram

**User:** "Diagram the relationship between User, Post, and Comment entities"

**Agent generates:**
1. Entities: User, Post, Comment
2. Relationships: User → Post ("creates"), User → Comment ("writes"), Post → Comment ("contains")
3. Save as `user-content-relationships.excalidraw`

### Example 3: Mind Map

**User:** "Mind map about machine learning concepts"

**Agent generates:**
1. Center: "Machine Learning"
2. Branches: Supervised Learning, Unsupervised Learning, Reinforcement Learning, Deep Learning
3. Sub-topics under each branch
4. Save as `machine-learning-mindmap.excalidraw`

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Elements overlap | Increase spacing between coordinates |
| Text doesn't fit in boxes | Increase box width or reduce font size |
| Too many elements | Break into multiple diagrams |
| Unclear layout | Use grid layout (rows/columns) or radial layout (mind maps) |
| Colors inconsistent | Define color palette upfront based on element types |

## Advanced Techniques

### Grid Layout (for Relationship Diagrams)
```javascript
const columns = Math.ceil(Math.sqrt(entityCount));
const x = startX + (index % columns) * horizontalGap;
const y = startY + Math.floor(index / columns) * verticalGap;
```

### Radial Layout (for Mind Maps)
```javascript
const angle = (2 * Math.PI * index) / branchCount;
const x = centerX + radius * Math.cos(angle);
const y = centerY + radius * Math.sin(angle);
```

### Auto-generated IDs
Use timestamp + random string for unique IDs:
```javascript
const id = Date.now().toString(36) + Math.random().toString(36).substr(2);
```

## Output Format

Always provide:
1. ✅ Complete `.excalidraw` JSON file
2. 📊 Summary of what was created
3. 📝 Element count
4. 💡 Instructions for opening/editing

**Example summary:**
```
Created: user-workflow.excalidraw
Type: Flowchart
Elements: 7 rectangles, 6 arrows, 1 title text
Total: 14 elements

To view:
1. Visit https://excalidraw.com
2. Drag and drop user-workflow.excalidraw
3. Or use File → Open in Excalidraw VS Code extension
```

## Validation Checklist

Before delivering the diagram:
- [ ] All elements have unique IDs
- [ ] Coordinates prevent overlapping
- [ ] Text is readable (font size 16+)
- [ ] **All text elements use `fontFamily: 5` (Excalifont)**
- [ ] Arrows connect logically
- [ ] Colors follow consistent scheme
- [ ] File is valid JSON
- [ ] Element count is reasonable (<20 for clarity)
- [ ] **Bound text `height` = `lineCount × fontSize × 1.25` (not hardcoded 38 for 3+ line text)**
- [ ] **Container height ≥ textHeight + 32px (16px vertical padding each side)**
- [ ] **Multi-section footers/legends use one colored box per section, not a single gray text blob**
- [ ] **Edge labels are ≥20 px clear of every box edge (not hugging box borders)**
- [ ] **No two edge labels share the same y-row with overlapping x-ranges**
- [ ] **No edge label text is wider than its gap — wrapped to 2 lines if needed**
- [ ] **No edge label y-range overlaps the vertical span of any adjacent box row**

## Icon Libraries (Optional Enhancement)

For specialized diagrams (e.g., AWS/GCP/Azure architecture diagrams), you can use pre-made icon libraries from Excalidraw. This provides professional, standardized icons instead of basic shapes.

### When User Requests Icons

**If user asks for AWS/cloud architecture diagrams or mentions wanting to use specific icons:**

1. **Check if library exists**: Look for `libraries/<library-name>/reference.md`
2. **If library exists**: Proceed to use icons (see AI Assistant Workflow below)
3. **If library does NOT exist**: Respond with setup instructions:

   ```
   To use [AWS/GCP/Azure/etc.] architecture icons, please follow these steps:
   
   1. Visit https://libraries.excalidraw.com/
   2. Search for "[AWS Architecture Icons/etc.]" and download the .excalidrawlib file
   3. Create directory: skills/excalidraw-diagram-generator/libraries/[icon-set-name]/
   4. Place the downloaded file in that directory
   5. Run the splitter script:
      python skills/excalidraw-diagram-generator/scripts/split-excalidraw-library.py skills/excalidraw-diagram-generator/libraries/[icon-set-name]/
   
   This will split the library into individual icon files for efficient use.
   After setup is complete, I can create your diagram using the actual AWS/cloud icons.
   
   Alternatively, I can create the diagram now using simple shapes (rectangles, ellipses) 
   which you can later replace with icons manually in Excalidraw.
   ```

### User Setup Instructions (Detailed)

**Step 1: Create Library Directory**
```bash
mkdir -p skills/excalidraw-diagram-generator/libraries/aws-architecture-icons
```

**Step 2: Download Library**
- Visit: https://libraries.excalidraw.com/
- Search for your desired icon set (e.g., "AWS Architecture Icons")
- Click download to get the `.excalidrawlib` file
- Example categories (availability varies; confirm on the site):
   - Cloud service icons
   - UI/Material icons
   - Flowchart symbols

**Step 3: Place Library File**
- Rename the downloaded file to match the directory name (e.g., `aws-architecture-icons.excalidrawlib`)
- Move it to the directory created in Step 1

**Step 4: Run Splitter Script**
```bash
python skills/excalidraw-diagram-generator/scripts/split-excalidraw-library.py skills/excalidraw-diagram-generator/libraries/aws-architecture-icons/
```

**Step 5: Verify Setup**
After running the script, verify the following structure exists:
```
skills/excalidraw-diagram-generator/libraries/aws-architecture-icons/
  aws-architecture-icons.excalidrawlib  (original)
  reference.md                          (generated - icon lookup table)
  icons/                                (generated - individual icon files)
    API-Gateway.json
    CloudFront.json
    EC2.json
    Lambda.json
    RDS.json
    S3.json
    ...
```

### AI Assistant Workflow

**When icon libraries are available in `libraries/`:**

**RECOMMENDED APPROACH: Use Python Scripts (Efficient & Reliable)**

The repository includes Python scripts that handle icon integration automatically:

1. **Create base diagram structure**:
   - Create `.excalidraw` file with basic layout (title, boxes, regions)
   - This establishes the canvas and overall structure

2. **Add icons using Python script**:
   ```bash
   python skills/excalidraw-diagram-generator/scripts/add-icon-to-diagram.py \
     <diagram-path> <icon-name> <x> <y> [--label "Text"] [--library-path PATH]
   ```
   - Edit via `.excalidraw.edit` is enabled by default to avoid overwrite issues; pass `--no-use-edit-suffix` to disable.
   
   **Examples**:
   ```bash
   # Add EC2 icon at position (400, 300) with label
   python scripts/add-icon-to-diagram.py diagram.excalidraw EC2 400 300 --label "Web Server"
   
   # Add VPC icon at position (200, 150)
   python scripts/add-icon-to-diagram.py diagram.excalidraw VPC 200 150
   
   # Add icon from different library
   python scripts/add-icon-to-diagram.py diagram.excalidraw Compute-Engine 500 200 \
     --library-path libraries/gcp-icons --label "API Server"
   ```

3. **Add connecting arrows**:
   ```bash
   python skills/excalidraw-diagram-generator/scripts/add-arrow.py \
     <diagram-path> <from-x> <from-y> <to-x> <to-y> [--label "Text"] [--style solid|dashed|dotted] [--color HEX]
   ```
   - Edit via `.excalidraw.edit` is enabled by default to avoid overwrite issues; pass `--no-use-edit-suffix` to disable.
   
   **Examples**:
   ```bash
   # Simple arrow from (300, 250) to (500, 300)
   python scripts/add-arrow.py diagram.excalidraw 300 250 500 300
   
   # Arrow with label
   python scripts/add-arrow.py diagram.excalidraw 300 250 500 300 --label "HTTPS"
   
   # Dashed arrow with custom color
   python scripts/add-arrow.py diagram.excalidraw 400 350 600 400 --style dashed --color "#7950f2"
   ```

4. **Workflow summary**:
   ```bash
   # Step 1: Create base diagram with title and structure
   # (Create .excalidraw file with initial elements)
   
   # Step 2: Add icons with labels
   python scripts/add-icon-to-diagram.py my-diagram.excalidraw "Internet-gateway" 200 150 --label "Internet Gateway"
   python scripts/add-icon-to-diagram.py my-diagram.excalidraw VPC 250 250
   python scripts/add-icon-to-diagram.py my-diagram.excalidraw ELB 350 300 --label "Load Balancer"
   python scripts/add-icon-to-diagram.py my-diagram.excalidraw EC2 450 350 --label "EC2 Instance"
   python scripts/add-icon-to-diagram.py my-diagram.excalidraw RDS 550 400 --label "Database"
   
   # Step 3: Add connecting arrows
   python scripts/add-arrow.py my-diagram.excalidraw 250 200 300 250  # Internet → VPC
   python scripts/add-arrow.py my-diagram.excalidraw 300 300 400 300  # VPC → ELB
   python scripts/add-arrow.py my-diagram.excalidraw 400 330 500 350  # ELB → EC2
   python scripts/add-arrow.py my-diagram.excalidraw 500 380 600 400  # EC2 → RDS
   ```

**Benefits of Python Script Approach**:
- ✅ **No token consumption**: Icon JSON data (200-1000 lines each) never enters AI context
- ✅ **Accurate transformations**: Coordinate calculations handled deterministically
- ✅ **ID management**: Automatic UUID generation prevents conflicts
- ✅ **Reliable**: No risk of coordinate miscalculation or ID collision
- ✅ **Fast**: Direct file manipulation, no parsing overhead
- ✅ **Reusable**: Works with any Excalidraw library you provide

**ALTERNATIVE: Manual Icon Integration (Not Recommended)**

Only use this if Python scripts are unavailable:

1. **Check for libraries**: 
   ```
   List directory: skills/excalidraw-diagram-generator/libraries/
   Look for subdirectories containing reference.md files
   ```

2. **Read reference.md**:
   ```
   Open: libraries/<library-name>/reference.md
   This is lightweight (typically <300 lines) and lists all available icons
   ```

3. **Find relevant icons**:
   ```
   Search the reference.md table for icon names matching diagram needs
   Example: For AWS diagram with EC2, S3, Lambda → Find "EC2", "S3", "Lambda" in table
   ```

4. **Load specific icon data** (WARNING: Large files):
   ```
   Read ONLY the needed icon files:
   - libraries/aws-architecture-icons/icons/EC2.json (200-300 lines)
   - libraries/aws-architecture-icons/icons/S3.json (200-300 lines)
   - libraries/aws-architecture-icons/icons/Lambda.json (200-300 lines)
   Note: Each icon file is 200-1000 lines - this consumes significant tokens
   ```

5. **Extract and transform elements**:
   ```
   Each icon JSON contains an "elements" array
   Calculate bounding box (min_x, min_y, max_x, max_y)
   Apply offset to all x/y coordinates
   Generate new unique IDs for all elements
   Update groupIds references
   Copy transformed elements into your diagram
   ```

6. **Position icons and add connections**:
   ```
   Adjust x/y coordinates to position icons correctly in the diagram
   Update IDs to ensure uniqueness across diagram
   Add connecting arrows and labels as needed
   ```

**Manual Integration Challenges**:
- ⚠️ High token consumption (200-1000 lines per icon × number of icons)
- ⚠️ Complex coordinate transformation calculations
- ⚠️ Risk of ID collision if not handled carefully
- ⚠️ Time-consuming for diagrams with many icons

### Example: Creating AWS Diagram with Icons

**Request**: "Create an AWS architecture diagram with Internet Gateway, VPC, ELB, EC2, and RDS"

**Recommended Workflow (using Python scripts)**:
**Request**: "Create an AWS architecture diagram with Internet Gateway, VPC, ELB, EC2, and RDS"

**Recommended Workflow (using Python scripts)**:

```bash
# Step 1: Create base diagram file with title
# Create my-aws-diagram.excalidraw with basic structure (title, etc.)

# Step 2: Check icon availability
# Read: libraries/aws-architecture-icons/reference.md
# Confirm icons exist: Internet-gateway, VPC, ELB, EC2, RDS

# Step 3: Add icons with Python script
python scripts/add-icon-to-diagram.py my-aws-diagram.excalidraw "Internet-gateway" 150 100 --label "Internet Gateway"
python scripts/add-icon-to-diagram.py my-aws-diagram.excalidraw VPC 200 200
python scripts/add-icon-to-diagram.py my-aws-diagram.excalidraw ELB 350 250 --label "Load Balancer"
python scripts/add-icon-to-diagram.py my-aws-diagram.excalidraw EC2 500 300 --label "Web Server"
python scripts/add-icon-to-diagram.py my-aws-diagram.excalidraw RDS 650 350 --label "Database"

# Step 4: Add connecting arrows
python scripts/add-arrow.py my-aws-diagram.excalidraw 200 150 250 200  # Internet → VPC
python scripts/add-arrow.py my-aws-diagram.excalidraw 265 230 350 250  # VPC → ELB
python scripts/add-arrow.py my-aws-diagram.excalidraw 415 280 500 300  # ELB → EC2
python scripts/add-arrow.py my-aws-diagram.excalidraw 565 330 650 350 --label "SQL" --style dashed

# Result: Complete diagram with professional AWS icons, labels, and connections
```

**Benefits**:
- No manual coordinate calculation
- No token consumption for icon data
- Deterministic, reliable results
- Easy to iterate and adjust positions

**Alternative Workflow (manual, if scripts unavailable)**:
1. Check: `libraries/aws-architecture-icons/reference.md` exists → Yes
2. Read reference.md → Find entries for Internet-gateway, VPC, ELB, EC2, RDS
3. Load:
   - `icons/Internet-gateway.json` (298 lines)
   - `icons/VPC.json` (550 lines)
   - `icons/ELB.json` (363 lines)
   - `icons/EC2.json` (231 lines) 
   - `icons/RDS.json` (similar size)
   **Total: ~2000+ lines of JSON to process**
4. Extract elements from each JSON
5. Calculate bounding boxes and offsets for each icon
6. Transform all coordinates (x, y) for positioning
7. Generate unique IDs for all elements
8. Add arrows showing data flow
9. Add text labels
10. Generate final `.excalidraw` file

**Challenges with manual approach**:
- High token consumption (~2000-5000 lines)
- Complex coordinate math
- Risk of ID conflicts

### Supported Icon Libraries (Examples — verify availability)

- This workflow works with any valid `.excalidrawlib` file you provide.
- Examples of library categories you may find on https://libraries.excalidraw.com/:
   - Cloud service icons
   - Kubernetes / infrastructure icons
   - UI / Material icons
   - Flowchart / diagram symbols
   - Network diagram icons
- Availability and naming can change; verify exact library names on the site before use.

### Fallback: No Icons Available

**If no icon libraries are set up:**
- Create diagrams using basic shapes (rectangles, ellipses, arrows)
- Use color coding and text labels to distinguish components
- Inform user they can add icons later or set up libraries for future diagrams
- The diagram will still be functional and clear, just less visually polished

## References

See bundled references for:
- `references/excalidraw-schema.md` - Complete Excalidraw JSON schema
- `references/element-types.md` - Detailed element type specifications
- `templates/flowchart-template.json` - Basic flowchart starter
- `templates/relationship-template.json` - Relationship diagram starter
- `templates/mindmap-template.json` - Mind map starter
- `scripts/split-excalidraw-library.py` - Tool to split `.excalidrawlib` files
- `scripts/README.md` - Documentation for library tools
- `scripts/.gitignore` - Prevents local Python artifacts from being committed

## Limitations

- Complex curves are simplified to straight/basic curved lines
- Hand-drawn roughness is set to default (1)
- No embedded images support in auto-generation
- Maximum recommended elements: 20 per diagram
- No automatic collision detection (use spacing guidelines)

## Future Enhancements

Potential improvements:
- Auto-layout optimization algorithms
- Import from Mermaid/PlantUML syntax
- Template library expansion
- Interactive editing after generation
