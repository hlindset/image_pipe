# Render budget spike (image_plug-aoym.2)

Times resvg 0.48.1 on pathological SVGs, configured like the planned NIF
(no system fonts, external hrefs refused, 300×150 default size).

```sh
vips gaussnoise noise.png 1000 1000
python3 gen.py cases            # writes cases/*.svg (needs noise.png)
cargo build --release
./target/release/svgbench cases/blur_s10.svg 4000
```

`results.txt` holds one run on an Apple M-series laptop, with peak RSS from
`/usr/bin/time -l` and a 60 s cutoff ("terminated abnormally").
