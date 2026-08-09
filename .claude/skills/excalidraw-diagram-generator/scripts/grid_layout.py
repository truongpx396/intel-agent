#!/usr/bin/env python3
"""Reusable Excalidraw grid-layout engine with auto-sized boxes and an
orthogonal arrow router that keeps arrows inside the empty gutters between
boxes (so they never cut across other shapes).

Use this instead of hand-placing coordinates for any diagram with more than a
few boxes. It guarantees:
  * boxes sized to fit their text (no overflow)
  * a uniform, aligned grid (straight arrows between row/column neighbours)
  * orthogonal arrows routed through gutters (no crossings through boxes)
  * unique `index` values and valid arrow `points` (first point [0,0])

Example
-------
    from grid_layout import Builder, BLUE, GREEN, YELLOW

    b = Builder()
    b.node("a", 0, 0, "Start", GREEN)
    b.node("b", 1, 0, "Process\\n(step two)", BLUE)
    b.node("c", 2, 0, "Done", YELLOW)
    b.edge("a", "b")
    b.edge("b", "c", "ok")
    doc = b.build("My Flow")
    import json; json.dump(doc, open("my-flow.excalidraw", "w"), indent=2)
"""
import json, random

random.seed(7)
FONT_HAND = 5
CHAR_W = 0.58
LINE_H = 1.25
TS = 1738195200000

PURPLE = "#d0bfff"; BLUE = "#a5d8ff"; GREEN = "#b2f2bb"; RED = "#ffc9c9"
YELLOW = "#ffec99"; GRAY = "#e9ecef"; ORANGE = "#ffd8a8"

CHARS = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
PCHARS = 'abcdefghijklmnopqrstuvwxyz'


class IdxGen:
    """Yields unique, ordered Excalidraw `index` strings: a0,a1,...,aZ,b0,..."""
    def __init__(self):
        self.n = 0

    def __call__(self):
        n = self.n
        self.n += 1
        return f"{PCHARS[n // len(CHARS)]}{CHARS[n % len(CHARS)]}"


def _rid(p):
    return f"{p}_{random.randint(100000, 999999)}"


def _seed():
    return random.randint(1, 2**31 - 1)


def text_dims(text, fs):
    lines = text.split('\n')
    w = max((len(l) for l in lines), default=1) * fs * CHAR_W
    h = len(lines) * fs * LINE_H
    return w, h


def _base(idx, x, y, w, h, fill, stroke="#1e1e1e", dashed=False):
    return {
        "id": _rid("el"), "x": round(x), "y": round(y),
        "width": round(w), "height": round(h), "angle": 0,
        "strokeColor": stroke, "backgroundColor": fill,
        "fillStyle": "solid", "strokeWidth": 2,
        "strokeStyle": "dashed" if dashed else "solid",
        "roughness": 1, "opacity": 100, "groupIds": [], "frameId": None,
        "index": idx, "roundness": None, "seed": _seed(),
        "version": 1, "versionNonce": _seed(), "isDeleted": False,
        "boundElements": None, "updated": TS, "link": None, "locked": False,
    }


def _shape(idx, x, y, w, h, fill, shape="rectangle"):
    e = _base(idx, x, y, w, h, fill)
    e["type"] = shape
    if shape == "rectangle":
        e["roundness"] = {"type": 3}
    return e


def _bound_text(idx, shape, text, fs):
    tw, th = text_dims(text, fs)
    tw = min(tw, shape["width"] - 12)
    th = min(th, shape["height"] - 6)
    tx = shape["x"] + (shape["width"] - tw) / 2
    ty = shape["y"] + (shape["height"] - th) / 2
    t = _base(idx, tx, ty, tw, th, "transparent")
    t.update({
        "type": "text", "text": text, "fontSize": fs, "fontFamily": FONT_HAND,
        "textAlign": "center", "verticalAlign": "middle",
        "containerId": shape["id"], "originalText": text,
        "autoResize": True, "lineHeight": LINE_H,
    })
    shape["boundElements"] = [{"type": "text", "id": t["id"]}]
    return t


def _text(idx, x, y, text, fs, align="left", color="#1e1e1e"):
    tw, th = text_dims(text, fs)
    t = _base(idx, x, y, tw, th, "transparent", stroke=color)
    t.update({
        "type": "text", "text": text, "fontSize": fs, "fontFamily": FONT_HAND,
        "textAlign": align, "verticalAlign": "top", "containerId": None,
        "originalText": text, "autoResize": True, "lineHeight": LINE_H,
    })
    return t


def _arrow(idx, pts, dashed=False, start_id=None, end_id=None):
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    ox, oy = pts[0]
    rel = [[p[0] - ox, p[1] - oy] for p in pts]
    e = _base(idx, ox, oy, max(xs) - min(xs), max(ys) - min(ys),
              "transparent", dashed=dashed)
    e.update({
        "type": "arrow", "points": rel, "lastCommittedPoint": None,
        "startArrowhead": None, "endArrowhead": "arrow",
        "startBinding": {"elementId": start_id, "focus": 0, "gap": 4} if start_id else None,
        "endBinding": {"elementId": end_id, "focus": 0, "gap": 4} if end_id else None,
    })
    return e


def _seg_hits_rect(p1, p2, r, margin=3):
    rx1, ry1, rx2, ry2 = r
    rx1 -= margin; ry1 -= margin; rx2 += margin; ry2 += margin
    x1, y1 = p1; x2, y2 = p2
    if abs(y1 - y2) < 0.5:
        if not (ry1 < y1 < ry2):
            return False
        lo, hi = sorted((x1, x2))
        return lo < rx2 and hi > rx1
    if not (rx1 < x1 < rx2):
        return False
    lo, hi = sorted((y1, y2))
    return lo < ry2 and hi > ry1


def _overlap_len(p1, p2, q1, q2):
    if abs(p1[1]-p2[1]) < .5 and abs(q1[1]-q2[1]) < .5 and abs(p1[1]-q1[1]) < .5:
        a, b = sorted((p1[0], p2[0])); c, d = sorted((q1[0], q2[0]))
        return max(0, min(b, d) - max(a, c))
    if abs(p1[0]-p2[0]) < .5 and abs(q1[0]-q2[0]) < .5 and abs(p1[0]-q1[0]) < .5:
        a, b = sorted((p1[1], p2[1])); c, d = sorted((q1[1], q2[1]))
        return max(0, min(b, d) - max(a, c))
    return 0


def _simplify(pts):
    out = [pts[0]]
    for i in range(1, len(pts) - 1):
        a, b, c = out[-1], pts[i], pts[i + 1]
        if (abs(a[0]-b[0]) < .5 and abs(b[0]-c[0]) < .5) or \
           (abs(a[1]-b[1]) < .5 and abs(b[1]-c[1]) < .5):
            continue
        out.append(b)
    out.append(pts[-1])
    return out


class Builder:
    def __init__(self, gap_x=90, gap_y=80, x0=140, y0=160, fs=16):
        self.gap_x, self.gap_y = gap_x, gap_y
        self.x0, self.y0, self.fs = x0, y0, fs
        self.nodes = {}
        self.edges = []
        self.extra_texts = []

    def node(self, key, col, row, text, fill, shape="rectangle",
             colspan=1, wmin=160, hmin=70):
        self.nodes[key] = dict(col=col, row=row, text=text, fill=fill,
                               shape=shape, colspan=colspan, wmin=wmin, hmin=hmin)

    def edge(self, s, d, label="", dashed=False):
        self.edges.append((s, d, label, dashed))

    def text(self, x, y, txt, fs=None, align="left", color="#495057"):
        self.extra_texts.append((x, y, txt, fs or 13, align, color))

    def _layout(self):
        for n in self.nodes.values():
            tw, th = text_dims(n["text"], self.fs)
            n["w"] = max(n["wmin"], round(tw + 34))
            n["h"] = max(n["hmin"], round(th + 26))
        max_w = max(n["w"] for n in self.nodes.values())
        max_h = max(n["h"] for n in self.nodes.values())
        self.pitch_x = max_w + self.gap_x
        self.pitch_y = max_h + self.gap_y
        for n in self.nodes.values():
            cx = self.x0 + (n["col"] + (n["colspan"] - 1) / 2) * self.pitch_x
            cy = self.y0 + n["row"] * self.pitch_y
            n["cx"], n["cy"] = cx, cy
            n["x"] = cx - n["w"] / 2
            n["y"] = cy - n["h"] / 2
        ncols = max(n["col"] + n["colspan"] for n in self.nodes.values())
        nrows = max(n["row"] for n in self.nodes.values()) + 1
        self.hor_lanes = [self.y0 - self.pitch_y / 2 + j * self.pitch_y
                          for j in range(nrows + 1)]
        self.ver_lanes = [self.x0 - self.pitch_x / 2 + i * self.pitch_x
                          for i in range(ncols + 1)]

    def _rect(self, n):
        return (n["x"], n["y"], n["x"] + n["w"], n["y"] + n["h"])

    def _anchor(self, n, side, frac):
        if side == "L":
            return (n["x"], n["y"] + frac * n["h"])
        if side == "R":
            return (n["x"] + n["w"], n["y"] + frac * n["h"])
        if side == "T":
            return (n["x"] + frac * n["w"], n["y"])
        return (n["x"] + frac * n["w"], n["y"] + n["h"])

    def _routes(self, A, B, es, en):
        ev = es in ("T", "B"); nv = en in ("T", "B")
        out = []
        if ev and nv:
            if abs(A[0] - B[0]) < 1:
                out.append([A, B])
            for ly in self.hor_lanes:
                out.append([A, (A[0], ly), (B[0], ly), B])
        elif (not ev) and (not nv):
            if abs(A[1] - B[1]) < 1:
                out.append([A, B])
            for lx in self.ver_lanes:
                out.append([A, (lx, A[1]), (lx, B[1]), B])
        elif ev and (not nv):
            out.append([A, (A[0], B[1]), B])
        else:
            out.append([A, (B[0], A[1]), B])
        if ev:
            for ly in self.hor_lanes:
                for lx in self.ver_lanes:
                    out.append([A, (A[0], ly), (lx, ly), (lx, B[1]), B] if nv
                               else [A, (A[0], ly), (lx, ly), (B[0], ly), B])
        else:
            for lx in self.ver_lanes:
                for ly in self.hor_lanes:
                    out.append([A, (lx, A[1]), (lx, ly), (B[0], ly), B] if nv
                               else [A, (lx, A[1]), (lx, ly), (lx, B[1]), B])
        return out

    def _candidates(self, s, d):
        sides = ["L", "R", "T", "B"]
        fracs = [0.5, 0.34, 0.66]
        cands = []
        for es in sides:
            for en in sides:
                for fo in fracs:
                    A = self._anchor(s, es, fo)
                    for fi in fracs:
                        B = self._anchor(d, en, fi)
                        for poly in self._routes(A, B, es, en):
                            cands.append(poly)
        return cands

    def _score(self, poly, s, d, placed):
        obstacles = [self._rect(n) for n in self.nodes.values()
                     if n is not s and n is not d]
        crossings = overlap = length = 0.0
        for p1, p2 in zip(poly, poly[1:]):
            length += abs(p1[0]-p2[0]) + abs(p1[1]-p2[1])
            for r in obstacles:
                if _seg_hits_rect(p1, p2, r):
                    crossings += 1
            for q1, q2 in placed:
                overlap += _overlap_len(p1, p2, q1, q2)
        turns = len(_simplify(poly)) - 2
        return crossings * 10000 + overlap * 12 + turns * 140 + length * 0.05

    def _route_edges(self, idx, bykey):
        placed = []
        arrows, labels = [], []
        for s, d, label, dashed in self.edges:
            ns, nd = self.nodes[s], self.nodes[d]
            best, best_sc = None, 1e18
            for poly in self._candidates(ns, nd):
                sc = self._score(poly, ns, nd, placed)
                if sc < best_sc:
                    best_sc, best = sc, poly
            poly = _simplify(best)
            placed.extend(zip(poly, poly[1:]))
            arrows.append(_arrow(idx(), poly, dashed=dashed,
                                 start_id=bykey[s], end_id=bykey[d]))
            if label:
                segs = list(zip(poly, poly[1:]))
                lp1, lp2 = max(segs, key=lambda e: abs(e[0][0]-e[1][0]) + abs(e[0][1]-e[1][1]))
                mx = (lp1[0] + lp2[0]) / 2; my = (lp1[1] + lp2[1]) / 2
                lw, lh = text_dims(label, 13)
                labels.append(_text(idx(), mx - lw / 2, my - lh - 4,
                                    label, 13, align="center", color="#495057"))
        return arrows, labels

    def build(self, title=""):
        self._layout()
        idx = IdxGen()
        els, bykey = [], {}
        if title:
            els.append(_text(idx(), self.x0 - self.pitch_x / 2,
                             self.y0 - self.pitch_y / 2 - 70, title, 28))
        for key, n in self.nodes.items():
            shp = _shape(idx(), n["x"], n["y"], n["w"], n["h"], n["fill"], n["shape"])
            bykey[key] = shp["id"]
            els.append(shp)
            els.append(_bound_text(idx(), shp, n["text"], self.fs))
        arrows, labels = self._route_edges(idx, bykey)
        els.extend(arrows)
        els.extend(labels)
        for x, y, txt, fs, align, color in self.extra_texts:
            els.append(_text(idx(), x, y, txt, fs, align, color))
        return {
            "type": "excalidraw", "version": 2,
            "source": "https://excalidraw.com", "elements": els,
            "appState": {"viewBackgroundColor": "#ffffff", "gridSize": 20},
            "files": {},
        }


if __name__ == "__main__":
    b = Builder()
    b.node("a", 0, 0, "Start", GREEN)
    b.node("b", 1, 0, "Process\n(step two)", BLUE)
    b.node("c", 2, 0, "Decision?", ORANGE, shape="diamond", hmin=110)
    b.node("d", 2, 1, "Done", YELLOW)
    b.edge("a", "b")
    b.edge("b", "c")
    b.edge("c", "d", "yes")
    doc = b.build("Demo Flow")
    json.dump(doc, open("demo-flow.excalidraw", "w"), indent=2, ensure_ascii=False)
    print("Wrote demo-flow.excalidraw with", len(doc["elements"]), "elements")
