#!/bin/sh
# usage: mkurls.sh PORT > urls.txt   (one URL per line; varied transforms/formats over all sample images)
PORT=$1
IMG=/tmp/claude-0/-home-user-image-pipe/d9301eaf-e830-533b-9e40-eef149fee684/scratchpad/images
for f in $(ls $IMG | grep -E '\.(jpg|jpeg|png|webp|jxl)$'); do
  for op in "w=400" "w=800/format=webp" "w=300/h=300/fit=cover/format=avif" "w=1200/format=png" \
            "w=600/blur=2/format=jpeg" "w=512/sharpen=1.5/format=webp" "rotate=90/w=400/format=jpeg" \
            "w=800/q=70/format=avif" "output=info,blurhash,lqip-css" "w=400/anchor=smart/h=400/fit=cover/format=jpeg" \
            "trim=auto/w=400/format=png" "w=2400/format=jpeg" "pixelate=8/w=400/format=webp"; do
    echo "http://127.0.0.1:$PORT/$op/src/$f"
  done
done
