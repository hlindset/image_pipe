"""Writes the seed corpus: small SVGs that reach each limit, from the PR #856
reviews, and ordinary SVGs. Run from fuzz/: python3 seeds.py"""

import base64
import os

SVG = '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="64" height="64">{}</svg>'
RECT = '<rect width="8" height="8" fill="#f00"/>'


def svg(body):
    return SVG.format(body)


def data_svg(inner):
    return "data:image/svg+xml;base64," + base64.b64encode(inner.encode()).decode()


documents = {
    "shapes": svg(
        '<defs><linearGradient id="g"><stop offset="0" stop-color="#f00"/>'
        '<stop offset="1" stop-color="#00f"/></linearGradient></defs>'
        '<rect width="64" height="32" fill="url(#g)"/><circle cx="32" cy="48" r="12" opacity=".5"/>'
        '<path d="M0 0 L64 64 Q32 0 0 64Z" stroke="#0f0" fill="none"/>'
    ),
    "text": svg('<text x="0" y="40" font-family="sans-serif">Hi <tspan>there</tspan></text>'),
    "entity_bomb": '<!DOCTYPE svg [<!ENTITY x "' + "a" * 50 + '"><!ENTITY y "' + "&x;" * 50
    + '">]>' + svg('<rect id="' + "&y;" * 50 + '" width="1" height="1"/>'),
    "entity_decoy": '<!-- <!DOCTYPE x> --><!DOCTYPE svg SYSTEM "a>b" [<?pi \' ?><!-- <!ENTITY y "z"> -->'
    '<!ENTITY x "aaaa"><!ENTITY y "&x;&x;&x;">]>' + svg("<text>&y;</text>"),
    "entity_chain": "<!DOCTYPE svg ["
    + "".join(f'<!ENTITY e{i} "&e{i + 1};">' for i in range(20))
    + '<!ENTITY e20 "a">]>' + svg("<text>&e0;</text>"),
    "deep": svg("<g>" * 1100 + "</g>" * 1100),
    "use_bomb": svg('<g id="a">' + RECT * 10 + "</g>" + '<g id="b">' + '<use href="#a"/>' * 10
                    + "</g>" + '<use href="#b"/>' * 10),
    "marker": svg('<marker id="m"><circle r="1"/></marker><polyline marker-mid="url(#m)" points="'
                  + " ".join(f"{i % 64},{i // 64}" for i in range(500)) + '"/>'),
    "clip_obb": svg('<clipPath id="c" clipPathUnits="objectBoundingBox">' + RECT * 5 + "</clipPath>"
                    + '<rect width="8" height="8" clip-path="url(#c)"/>' * 50),
    "mask_obb": svg('<mask id="k" maskContentUnits="objectBoundingBox">' + RECT * 5 + "</mask>"
                    + '<rect width="8" height="8" mask="url(#k)"/>' * 50),
    "fe_image": svg('<g id="s">' + RECT * 5 + '</g><filter id="f"><feImage href="#s"/></filter>'
                    + '<rect width="8" height="8" filter="url(#f)"/>' * 50),
    "blur": svg('<filter id="b"><feGaussianBlur stdDeviation="10"/></filter>'
                + '<g filter="url(#b)">' * 20 + RECT + "</g>" * 20),
    "nested_svg": svg('<image id="i" width="8" height="8" href="' + data_svg(svg(RECT * 20)) + '"/>'
                      + '<use href="#i"/>' * 20),
    "tspans": svg("<text>" + "<tspan>ab</tspan>" * 300 + "</text>"),
    "style": svg('<style>.a{clip-path:url(#c)}</style><clipPath id="c">' + RECT + "</clipPath>"
                 + '<rect class="a" width="8" height="8"/>' * 20),
}

templates = {
    "rect": RECT,
    "group": "<g>" + RECT * 3 + "</g>",
    "text": "<text>ab</text>",
    "use": '<use href="#g"/>',
    "markup": "<!-- c --><![CDATA[x]]><?p ?>",
}


def write(directory, name, data):
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, name), "wb") as file:
        file.write(data)


for name, text in documents.items():
    for target in ("render", "expansion"):
        write(f"seeds/{target}", name, text.encode())

for template in range(9):
    for name, payload in templates.items():
        write("seeds/templates", f"{template}_{name}", bytes([template, 25]) + payload.encode())
