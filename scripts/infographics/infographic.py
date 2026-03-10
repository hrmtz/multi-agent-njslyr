"""
Infographic Generator — Pure HTML/CSS, self-contained
Reusable across content-forge articles and instagram-slides.

All components output self-contained HTML with inline styles.
Scale control: wrap in <div style="font-size: 16px"> and adjust.

Usage:
    from infographic import comparison_table, stat_cards, timeline_bar, range_bar

    html = comparison_table(
        title="鼻整形の術式比較",
        columns=["術式", "適応", "回復期間", "費用目安", "リスク"],
        rows=[
            {"術式": "隆鼻術", "適応": "鼻筋を高く", ...},
        ],
        highlight_col="費用目安",
    )
"""

from typing import Optional


# ── Color Palettes ──────────────────────────────────────────────────────────

PALETTES = {
    "clinical": {
        "primary": "#0ea5e9",
        "primary_light": "#e0f2fe",
        "primary_dark": "#0369a1",
        "accent": "#f43f5e",
        "accent_light": "#ffe4e6",
        "bg": "#ffffff",
        "text": "#1e293b",
        "text_dim": "#64748b",
        "border": "#e2e8f0",
        "row_alt": "#f8fafc",
        "success": "#22c55e",
        "warning": "#f59e0b",
        "danger": "#ef4444",
    },
    "warm": {
        "primary": "#d97706",
        "primary_light": "#fef3c7",
        "primary_dark": "#92400e",
        "accent": "#ec4899",
        "accent_light": "#fce7f3",
        "bg": "#fffbeb",
        "text": "#1c1917",
        "text_dim": "#78716c",
        "border": "#e7e5e4",
        "row_alt": "#fef9ee",
        "success": "#16a34a",
        "warning": "#ea580c",
        "danger": "#dc2626",
    },
    # example-clinic.com brand colors
    "example": {
        "primary": "#b08d57",
        "primary_light": "#f5f0e8",
        "primary_dark": "#8b6f3a",
        "accent": "#c4956a",
        "accent_light": "#faf3ed",
        "bg": "#ffffff",
        "text": "#333333",
        "text_dim": "#888888",
        "border": "#e5ddd0",
        "row_alt": "#faf8f5",
        "success": "#5a9e6f",
        "warning": "#d4a843",
        "danger": "#c75050",
    },
}


def load_instagram_theme(yaml_path: str) -> dict:
    """Load an instagram-slides theme YAML and map to infographic palette.

    Maps instagram-slides theme keys to infographic palette keys:
        colors.primary → primary
        colors.primary_light → primary_light
        colors.primary_dark → primary_dark
        colors.text_dark → text
        colors.text_muted → text_dim
        colors.slide_bg → bg
        risk.danger → danger
        risk.warning → warning
    """
    try:
        import yaml
        theme = yaml.safe_load(open(yaml_path))
    except Exception:
        return PALETTES["clinical"]

    colors = theme.get("colors", {})
    risk = theme.get("risk", {})

    return {
        "primary": colors.get("primary", "#0ea5e9"),
        "primary_light": colors.get("primary_light", "#e0f2fe"),
        "primary_dark": colors.get("primary_dark", "#0369a1"),
        "accent": colors.get("accent_border", "#f43f5e"),
        "accent_light": colors.get("primary_light", "#ffe4e6"),
        "bg": colors.get("slide_bg", "#ffffff"),
        "text": colors.get("text_dark", "#1e293b"),
        "text_dim": colors.get("text_muted", "#64748b"),
        "border": colors.get("primary_border", "#e2e8f0"),
        "row_alt": colors.get("body_bg", "#f8fafc"),
        "success": "#22c55e",
        "warning": risk.get("warning", "#f59e0b"),
        "danger": risk.get("danger", "#ef4444"),
    }


def _p(palette="clinical") -> dict:
    """Resolve palette. Accepts:
    - str: built-in palette name ("clinical", "warm", "example")
    - dict: custom color dict (passed through, merged with clinical defaults)
    - str path ending in .yaml: instagram-slides theme file
    """
    if isinstance(palette, dict):
        # Custom dict — merge with defaults for any missing keys
        base = PALETTES["clinical"].copy()
        base.update(palette)
        return base
    if isinstance(palette, str) and palette.endswith(".yaml"):
        return load_instagram_theme(palette)
    return PALETTES.get(palette, PALETTES["clinical"])


# ── Comparison Table ────────────────────────────────────────────────────────

def comparison_table(
    title: str,
    columns: list[str],
    rows: list[dict],
    highlight_col: Optional[str] = None,
    palette: str = "clinical",
    note: str = "",
) -> str:
    """Generate a comparison table infographic.

    Args:
        title: Table heading
        columns: Column header names
        rows: List of dicts, each key matching a column name
        highlight_col: Column to visually emphasize
        palette: Color palette name
        note: Small footnote text
    """
    c = _p(palette)
    col_count = len(columns)

    # Header cells
    header_cells = ""
    for col in columns:
        is_hl = col == highlight_col
        bg = c["primary"] if is_hl else c["primary_dark"]
        fw = "700" if is_hl else "600"
        header_cells += (
            f'<div style="padding:0.6em 0.4em;background:{bg};color:#fff;'
            f'font-weight:{fw};text-align:center;font-size:0.85em;'
            f'border-right:1px solid rgba(255,255,255,0.2)">{col}</div>'
        )

    # Data rows
    data_rows = ""
    for i, row in enumerate(rows):
        bg = c["row_alt"] if i % 2 == 0 else c["bg"]
        cells = ""
        for col in columns:
            val = row.get(col, "—")
            is_hl = col == highlight_col
            cell_bg = c["primary_light"] if is_hl else bg
            fw = "600" if is_hl else "400"
            # Color-code severity/risk values
            cell_color = c["text"]
            val_str = str(val)
            if any(kw in val_str for kw in ["高", "リスク", "注意"]):
                cell_color = c["danger"]
            elif any(kw in val_str for kw in ["低", "少"]):
                cell_color = c["success"]

            cells += (
                f'<div style="padding:0.5em 0.4em;background:{cell_bg};'
                f'color:{cell_color};font-weight:{fw};font-size:0.8em;'
                f'border-right:1px solid {c["border"]};border-bottom:1px solid {c["border"]};'
                f'text-align:center;line-height:1.4">{val_str}</div>'
            )
        data_rows += cells

    note_html = ""
    if note:
        note_html = (
            f'<div style="padding:0.4em 0.6em;font-size:0.7em;color:{c["text_dim"]};'
            f'text-align:right">※ {note}</div>'
        )

    return (
        f'<div style="font-family:\'Noto Sans JP\',sans-serif;max-width:100%;'
        f'border-radius:0.6em;overflow:hidden;border:1px solid {c["border"]};'
        f'box-shadow:0 2px 8px rgba(0,0,0,0.06)">'
        f'<div style="background:{c["primary_dark"]};color:#fff;padding:0.6em 1em;'
        f'font-weight:700;font-size:1em;text-align:center">{title}</div>'
        f'<div style="display:grid;grid-template-columns:repeat({col_count},1fr)">'
        f'{header_cells}{data_rows}'
        f'</div>'
        f'{note_html}'
        f'</div>'
    )


# ── Stat Cards ──────────────────────────────────────────────────────────────

def stat_cards(
    title: str,
    stats: list[dict],
    palette: str = "clinical",
) -> str:
    """Generate stat highlight cards.

    Args:
        title: Section heading
        stats: List of {"value": "92%", "label": "満足度", "detail": "optional detail", "color": "success|warning|danger|primary"}
    """
    c = _p(palette)
    color_map = {
        "success": (c["success"], "#f0fdf4"),
        "warning": (c["warning"], "#fffbeb"),
        "danger": (c["danger"], "#fef2f2"),
        "primary": (c["primary"], c["primary_light"]),
    }

    cards = ""
    for stat in stats:
        fg, bg = color_map.get(stat.get("color", "primary"), color_map["primary"])
        detail = stat.get("detail", "")
        detail_html = f'<div style="font-size:0.55em;color:{c["text_dim"]};margin-top:0.2em">{detail}</div>' if detail else ""
        cards += (
            f'<div style="background:{bg};border-radius:0.5em;padding:0.8em 0.5em;'
            f'text-align:center;border:1px solid {c["border"]}">'
            f'<div style="font-size:1.8em;font-weight:800;color:{fg};line-height:1">{stat["value"]}</div>'
            f'<div style="font-size:0.7em;color:{c["text"]};margin-top:0.3em;font-weight:600">{stat["label"]}</div>'
            f'{detail_html}'
            f'</div>'
        )

    col_count = min(len(stats), 4)
    return (
        f'<div style="font-family:\'Noto Sans JP\',sans-serif;max-width:100%">'
        f'<div style="font-weight:700;font-size:0.9em;color:{c["text"]};margin-bottom:0.5em">{title}</div>'
        f'<div style="display:grid;grid-template-columns:repeat({col_count},1fr);gap:0.5em">'
        f'{cards}'
        f'</div></div>'
    )


# ── Timeline Bar ────────────────────────────────────────────────────────────

def timeline_bar(
    title: str,
    events: list[dict],
    palette: str = "clinical",
) -> str:
    """Generate a horizontal timeline.

    Args:
        title: Timeline heading
        events: [{"time": "術後1日", "label": "腫れピーク", "severity": "high|medium|low"}]
    """
    c = _p(palette)
    sev_colors = {
        "high": c["danger"],
        "medium": c["warning"],
        "low": c["success"],
    }

    items = ""
    for i, ev in enumerate(events):
        color = sev_colors.get(ev.get("severity", "medium"), c["primary"])
        items += (
            f'<div style="flex:1;text-align:center;position:relative">'
            f'<div style="width:0.8em;height:0.8em;border-radius:50%;background:{color};'
            f'margin:0 auto 0.3em;border:2px solid #fff;box-shadow:0 0 0 2px {color}"></div>'
            f'<div style="font-size:0.7em;font-weight:700;color:{color}">{ev["time"]}</div>'
            f'<div style="font-size:0.65em;color:{c["text"]};margin-top:0.15em">{ev["label"]}</div>'
            f'</div>'
        )

    # Connecting line
    return (
        f'<div style="font-family:\'Noto Sans JP\',sans-serif;max-width:100%">'
        f'<div style="font-weight:700;font-size:0.9em;color:{c["text"]};margin-bottom:0.6em">{title}</div>'
        f'<div style="position:relative;padding:0.5em 0">'
        f'<div style="position:absolute;top:0.9em;left:5%;right:5%;height:3px;'
        f'background:linear-gradient(to right,{c["danger"]},{c["warning"]},{c["success"]});'
        f'border-radius:2px"></div>'
        f'<div style="display:flex;justify-content:space-between;position:relative">'
        f'{items}'
        f'</div></div></div>'
    )


# ── Range Bar ───────────────────────────────────────────────────────────────

def range_bar(
    title: str,
    items: list[dict],
    unit: str = "万円",
    palette: str = "clinical",
) -> str:
    """Generate horizontal range bars.

    Args:
        title: Section heading
        items: [{"label": "隆鼻術", "min": 30, "max": 80, "typical": 50}]
        unit: Unit label (e.g. "万円", "日")
    """
    c = _p(palette)

    # Find global min/max
    all_vals = [v for item in items for v in [item["min"], item["max"]]]
    global_min = min(all_vals)
    global_max = max(all_vals)
    span = global_max - global_min or 1

    bars = ""
    for item in items:
        left_pct = (item["min"] - global_min) / span * 80 + 5
        width_pct = (item["max"] - item["min"]) / span * 80
        typical_pct = (item.get("typical", item["min"]) - global_min) / span * 80 + 5

        bars += (
            f'<div style="margin-bottom:0.6em">'
            f'<div style="display:flex;justify-content:space-between;margin-bottom:0.2em">'
            f'<span style="font-size:0.75em;font-weight:600;color:{c["text"]}">{item["label"]}</span>'
            f'<span style="font-size:0.7em;color:{c["text_dim"]}">{item["min"]}〜{item["max"]}{unit}</span>'
            f'</div>'
            f'<div style="position:relative;height:1.2em;background:{c["border"]};border-radius:0.6em">'
            f'<div style="position:absolute;left:{left_pct:.1f}%;width:{width_pct:.1f}%;height:100%;'
            f'background:linear-gradient(to right,{c["primary_light"]},{c["primary"]});border-radius:0.6em"></div>'
            f'</div></div>'
        )

    return (
        f'<div style="font-family:\'Noto Sans JP\',sans-serif;max-width:100%">'
        f'<div style="font-weight:700;font-size:0.9em;color:{c["text"]};margin-bottom:0.5em">{title}</div>'
        f'{bars}</div>'
    )


# ── Convenience: Generate all for a surgical article ────────────────────────

def surgical_comparison(procedures: list[dict], palette: str = "clinical") -> str:
    """Generate a complete surgical comparison infographic block.

    Args:
        procedures: [{
            "name": "隆鼻術",
            "target": "鼻筋を高く",
            "recovery": "2-3週間",
            "cost_min": 30, "cost_max": 80,
            "risk_level": "低〜中",
            "key_point": "自家組織orプロテーゼ",
        }]
    """
    # 1. Comparison table
    table = comparison_table(
        title="術式の比較",
        columns=["術式", "適応", "回復期間", "リスク", "特徴"],
        rows=[{
            "術式": p["name"],
            "適応": p["target"],
            "回復期間": p["recovery"],
            "リスク": p["risk_level"],
            "特徴": p["key_point"],
        } for p in procedures],
        highlight_col="術式",
        palette=palette,
        note="費用・回復期間には個人差があります",
    )

    # 2. Cost range bars
    cost = range_bar(
        title="費用の目安",
        items=[{
            "label": p["name"],
            "min": p["cost_min"],
            "max": p["cost_max"],
        } for p in procedures],
        unit="万円",
        palette=palette,
    )

    return (
        f'<div style="display:flex;flex-direction:column;gap:1.5em;'
        f'font-size:1em;max-width:640px;margin:1.5em auto">'
        f'{table}{cost}</div>'
    )
