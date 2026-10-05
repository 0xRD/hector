#!/usr/bin/env python3
"""Generates Sources/HectorApp/Map/WorldData.swift from Natural Earth country shapes.

Natural Earth (https://www.naturalearthdata.com) is in the public domain. The output holds:
- a grid of land dots on a 1000 x 400 equirectangular canvas (lon -180..180, lat 80..-60),
  each tagged with the country it falls in, so the map can tint countries;
- finer grids of the same land (half and a quarter of the spacing) for zoomed-in views, packed
  as base64 so the compiler does not type-check tens of thousands of literals;
- one label point per ISO 3166-1 alpha-2 code, where destination lines end.

Usage: scripts/generate-world-data.py [path/to/ne_50m_admin_0_countries.geojson]
Without an argument the file is downloaded from the natural-earth-vector repository.
"""
import base64
import json
import os
import struct
import sys
import urllib.request

SOURCE_URL = ("https://raw.githubusercontent.com/nvkelso/natural-earth-vector/"
              "master/geojson/ne_50m_admin_0_countries.geojson")
WIDTH, HEIGHT, SPACING = 1000, 400, 10
# Finer grids for zoomed-in views: on screen, each keeps about the spacing of the world view.
DETAIL_SPACINGS = (5, 2.5)
LAT_TOP, LAT_SPAN = 80.0, 140.0
OUTPUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "HectorApp", "Map", "WorldData.swift")


def load(path):
    if path:
        with open(path) as f:
            return json.load(f)
    with urllib.request.urlopen(SOURCE_URL) as response:
        return json.load(response)


def country_code(props):
    for key in ("ISO_A2", "ISO_A2_EH"):
        code = props.get(key)
        if code and code != "-99" and len(code) == 2:
            return code.upper()
    return None


def polygons(geometry):
    if geometry["type"] == "Polygon":
        return [geometry["coordinates"]]
    if geometry["type"] == "MultiPolygon":
        return geometry["coordinates"]
    return []


def inside_ring(x, y, ring):
    inside = False
    j = len(ring) - 1
    for i in range(len(ring)):
        xi, yi = ring[i][0], ring[i][1]
        xj, yj = ring[j][0], ring[j][1]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def land_cells(shapes, spacing):
    """(column, row, code) of every grid cell whose center is on land, row by row. A cell takes
    the first shape that holds it, in the source's order."""
    columns, rows = round(WIDTH / spacing), round(HEIGHT / spacing)
    found = {}
    for code, (x0, y0, x1, y1), polygon in shapes:
        # Only the cells inside the shape's bounding box.
        first_col = max(0, int(((x0 + 180) / 360 * WIDTH) / spacing - 1))
        last_col = min(columns - 1, int(((x1 + 180) / 360 * WIDTH) / spacing + 1))
        first_row = max(0, int(((LAT_TOP - y1) / LAT_SPAN * HEIGHT) / spacing - 1))
        last_row = min(rows - 1, int(((LAT_TOP - y0) / LAT_SPAN * HEIGHT) / spacing + 1))
        for row in range(first_row, last_row + 1):
            for col in range(first_col, last_col + 1):
                if (col, row) in found:
                    continue
                lon = (col * spacing + spacing / 2) / WIDTH * 360 - 180
                lat = LAT_TOP - (row * spacing + spacing / 2) / HEIGHT * LAT_SPAN
                if x0 <= lon <= x1 and y0 <= lat <= y1 and inside_ring(lon, lat, polygon[0]) \
                        and not any(inside_ring(lon, lat, hole) for hole in polygon[1:]):
                    found[(col, row)] = code
    return [(col, row, found[(col, row)]) for row in range(rows) for col in range(columns) if (col, row) in found]


def main():
    data = load(sys.argv[1] if len(sys.argv) > 1 else None)
    shapes = []   # (code, bbox, polygon)
    labels = {}   # code -> (lon, lat), preferring the feature whose own ISO_A2 is the code
    for feature in data["features"]:
        props = feature["properties"]
        code = country_code(props)
        if not code:
            continue
        if code not in labels or props.get("ISO_A2") == code:
            labels[code] = (round(props["LABEL_X"], 2), round(props["LABEL_Y"], 2))
        for polygon in polygons(feature["geometry"]):
            outer = polygon[0]
            xs = [p[0] for p in outer]
            ys = [p[1] for p in outer]
            shapes.append((code, (min(xs), min(ys), max(xs), max(ys)), polygon))

    codes = sorted(labels)
    index = {code: i for i, code in enumerate(codes)}
    dots = []
    for col, row, code in land_cells(shapes, SPACING):
        dots += [int(col * SPACING + SPACING / 2), int(row * SPACING + SPACING / 2), index[code]]

    # Detail grids: little-endian UInt16 triples (column, row, country index).
    details = []
    for spacing in DETAIL_SPACINGS:
        cells = land_cells(shapes, spacing)
        packed = b"".join(struct.pack("<HHH", col, row, index[code]) for col, row, code in cells)
        details.append((spacing, len(cells), base64.b64encode(packed).decode()))

    def chunks(values, size):
        return [", ".join(values[i:i + size]) for i in range(0, len(values), size)]

    lines = [
        "// Generated by scripts/generate-world-data.py from Natural Earth 1:50m countries (public domain).",
        "// Do not edit by hand.",
        "",
        "enum WorldData {",
        f"    /// Canvas the dots are laid out on: lon -180...180 maps to 0...{WIDTH}, lat {LAT_TOP:g}...{LAT_TOP - LAT_SPAN:g} to 0...{HEIGHT}.",
        f"    static let canvasWidth = {WIDTH}.0",
        f"    static let canvasHeight = {HEIGHT}.0",
        f"    static let topLatitude = {LAT_TOP}",
        f"    static let latitudeSpan = {LAT_SPAN}",
        f"    static let dotSpacing = {SPACING}.0",
        "",
        "    /// ISO 3166-1 alpha-2 codes; `dots` and `labelPoints` refer to them by index.",
        "    static let countryCodes: [String] = [",
        *[f"        {line}," for line in chunks([f'"{c}"' for c in codes], 16)],
        "    ]",
        "",
        "    /// Longitude, latitude pairs where lines to a country end, in `countryCodes` order.",
        "    static let labelPoints: [Double] = [",
        *[f"        {line}," for line in chunks([f"{labels[c][0]}, {labels[c][1]}" for c in codes], 6)],
        "    ]",
        "",
        "    /// Land dots as flat triples: x, y, index into `countryCodes`.",
        "    static let dots: [Int16] = [",
        *[f"        {line}," for line in chunks([str(v) for v in dots], 24)],
        "    ]",
        "",
        "    /// Finer land grids for zoomed-in views (see `WorldDots`): spacing, dot count, and base64 of",
        "    /// little-endian UInt16 triples (column, row, index into `countryCodes`).",
        "    static let detailGrids: [(spacing: Double, count: Int, base64: String)] = [",
        *[f'        ({spacing}, {count}, "{data}"),' for spacing, count, data in details],
        "    ]",
        "}",
        "",
    ]
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w") as f:
        f.write("\n".join(lines))
    detail = ", ".join(f"{count} at {spacing:g}" for spacing, count, _ in details)
    print(f"{len(codes)} countries, {len(dots) // 3} dots ({detail}) -> {os.path.normpath(OUTPUT)}")


if __name__ == "__main__":
    main()
