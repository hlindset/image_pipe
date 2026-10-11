import base64, os, sys
d = sys.argv[1]
def w(name, s):
    open(os.path.join(d, name + ".svg"), "w").write(s)
H = '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="100" height="100" viewBox="0 0 100 100">'
for s in [1, 10, 50]:
    w(f"blur_s{s}", H + f'<filter id="f" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="{s}"/></filter><rect x="10" y="10" width="80" height="80" fill="red" filter="url(#f)"/></svg>')
w("blur_x200", H + '<filter id="f"><feGaussianBlur stdDeviation="5"/></filter>' + ''.join(f'<rect x="0" y="0" width="100" height="100" fill="#{i%256:02x}0000" filter="url(#f)"/>' for i in range(200)) + '</svg>')
w("filter_chain", H + '<filter id="f">' + ''.join('<feGaussianBlur stdDeviation="3"/><feMorphology operator="dilate" radius="3"/>' for _ in range(100)) + '</filter><rect width="100" height="100" fill="red" filter="url(#f)"/></svg>')
for n in [1000, 5000]:
    w(f"nest_{n}", H + '<g opacity="0.99">' * n + '<rect width="100" height="100"/>' + '</g>' * n + '</svg>')
for t in [1000, 5000]:
    w(f"pattern_{t}", H + f'<pattern id="p" width="{t}" height="{t}" patternUnits="userSpaceOnUse"><circle cx="5" cy="5" r="5"/></pattern><rect width="100" height="100" fill="url(#p)"/></svg>')
w("pattern_nested", H + '<pattern id="p0" width="10" height="10" patternUnits="userSpaceOnUse"><circle cx="5" cy="5" r="4"/></pattern>' + ''.join(f'<pattern id="p{i}" width="100" height="100" patternUnits="userSpaceOnUse"><rect width="100" height="100" fill="url(#p{i-1})"/></pattern>' for i in range(1, 20)) + '<rect width="100" height="100" fill="url(#p19)"/></svg>')
png = base64.b64encode(open("noise.png", "rb").read()).decode()
w("use_image_x500", H + f'<defs><image id="i" width="100" height="100" href="data:image/png;base64,{png}"/></defs>' + '<use href="#i"/>' * 500 + '</svg>')
w("pattern_image_x500", H + f'<pattern id="p" width="100" height="100" patternUnits="userSpaceOnUse"><image width="100" height="100" href="data:image/png;base64,{png}"/></pattern>' + '<rect width="100" height="100" fill="url(#p)"/>' * 500 + '</svg>')
for lv in [5, 6, 7]:
    s = H + '<defs><rect id="g0" width="1" height="1"/>'
    for i in range(1, lv + 1):
        s += f'<g id="g{i}">' + f'<use href="#g{i-1}"/>' * 10 + '</g>'
    w(f"use_bomb_{lv}", s + f'</defs><use href="#g{lv}"/></svg>')
ent = '<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY a "aaaaaaaaaa">' + ''.join(f'<!ENTITY {chr(98+i)} "' + f'&{chr(97+i)};' * 10 + '">' for i in range(8)) + ']>'
w("entity_bomb", ent + H + '<text y="10">&i;</text></svg>')
w("paths_100k", H + ''.join(f'<path d="M{i%100} {i//1000} l1 1 l-1 0z"/>' for i in range(100000)) + '</svg>')
inner = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10" fill="blue"/></svg>'
for _ in range(5):
    inner = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><image width="10" height="10" href="data:image/svg+xml;base64,' + base64.b64encode(inner.encode()).decode() + '"/></svg>'
w("nested_svg_5", H + '<image width="100" height="100" href="data:image/svg+xml;base64,' + base64.b64encode(inner.encode()).decode() + '"/></svg>')
w("nested_svg_x200", H + ''.join('<image width="100" height="100" href="data:image/svg+xml;base64,' + base64.b64encode(inner.encode()).decode() + '"/>' for _ in range(200)) + '</svg>')
w("mask_chain_100", H + ''.join(f'<mask id="m{i}"' + (f' mask="url(#m{i+1})"' if i < 99 else '') + '><rect width="100" height="100" fill="white"/></mask>' for i in range(100)) + '<rect width="100" height="100" mask="url(#m0)"/></svg>')
w("masks_x500", H + '<mask id="m"><rect width="100" height="100" fill="white"/></mask>' + '<rect width="100" height="100" mask="url(#m)"/>' * 500 + '</svg>')
w("dashes", H + '<path d="' + 'M0 0 L100 100 ' * 200 + '" stroke="black" stroke-dasharray="0.01 0.01" stroke-width="1"/></svg>')
w("baseline", H + '<rect x="10" y="10" width="80" height="80" fill="red"/><circle cx="50" cy="50" r="30" fill="blue"/></svg>')
