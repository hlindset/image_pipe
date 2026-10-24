#!/bin/bash
# Builds the load-test source set.
set -e
export PATH=/root/.cache/image_pipe/vips-8.18.7-heif-1.19.8/bin:$PATH
S=/tmp/claude-0/-home-user-image-pipe/d9301eaf-e830-533b-9e40-eef149fee684/scratchpad
SRC=/home/user/image_pipe/.claude/worktrees/agent-a6052be7146ed379e/image_pipe/priv/static/images
I=$S/images
mkdir -p $I
for f in $SRC/*; do echo "$(basename $f) $(vipsheader -f width $f)x$(vipsheader -f height $f) bands=$(vipsheader -f bands $f) $(stat -c %s $f)"; done
cp $SRC/waterfall.jpg $SRC/dog_2.jpg $SRC/mountain.jpg $SRC/beach.jpg $SRC/woman.jpg $SRC/concert.jpeg $SRC/cooking.png $I/
# PNG with alpha, 2000 px
vips thumbnail $SRC/flower.jpg $I/tmp_flower.v 2000
vips bandjoin_const $I/tmp_flower.v $I/alpha.png 200
rm $I/tmp_flower.v
# WebP large
vips copy $SRC/paraglider.jpg $I/para.webp[Q=85]
# many distinct sources (soak per-distinct-source)
mkdir -p $I/many
vips thumbnail $SRC/dog.jpg $I/tmp_dog.jpg 1600
for n in $(seq 1 400); do cp $I/tmp_dog.jpg $I/many/d$n.jpg; printf "%08d" $n >> $I/many/d$n.jpg; done
rm $I/tmp_dog.jpg
ls -la $I
