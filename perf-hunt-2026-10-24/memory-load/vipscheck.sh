#!/bin/bash
export PATH=/root/.cache/image_pipe/vips-8.18.7-heif-1.19.8/bin:$PATH LD_LIBRARY_PATH=/root/.cache/image_pipe/vips-8.18.7-heif-1.19.8/lib
L=/tmp/claude-0/-home-user-image-pipe/d9301eaf-e830-533b-9e40-eef149fee684/scratchpad/load
cd $L/images
for f in dog_2.jpg mountain.jpg beach.jpg; do
  echo "$f interlaced=$(vipsheader -f interlaced $f 2>&1) subsample=$(vipsheader -f jpeg-chroma-subsample $f 2>&1)"
  /usr/bin/time -f "  thumbnail w800 maxrss %M KB" vipsthumbnail $f -s 800 -o $L/t_%s.jpg
  /usr/bin/time -f "  jpegload shrink=4 seq -> v maxrss %M KB" vips jpegload $f $L/t.v --shrink 4 --access sequential
done
