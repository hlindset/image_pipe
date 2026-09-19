<script lang="ts">
  let { value }: { value: string } = $props();
</script>

<div
  class="lqip-preview"
  role="img"
  aria-label="LQIP CSS placeholder"
  style={`--lqip: ${value}`}
></div>

<style>
  /*!
   * Decoder adapted from https://github.com/frzi/lqip-css
   * MIT License — Copyright (c) 2025 frzi
   *
   * Permission is hereby granted, free of charge, to any person obtaining a copy
   * of this software and associated documentation files (the "Software"), to deal
   * in the Software without restriction, including without limitation the rights
   * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   * copies of the Software, and to permit persons to whom the Software is
   * furnished to do so, subject to the following conditions:
   *
   * The above copyright notice and this permission notice shall be included in all
   * copies or substantial portions of the Software.
   *
   * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
   * SOFTWARE.
   */
  .lqip-preview {
    width: min(480px, 65vw);
    max-width: 100%;
    aspect-ratio: 4 / 3;
    border-radius: 0.5rem;
    box-shadow: var(--image-shadow);
    --c0: color(
      from var(--lqip) srgb calc(round(down, r * 255 / 16) / 15)
        calc(mod(round(down, r * 255), 16) / 15) calc(round(down, g * 255 / 32) / 7) / 1
    );
    --c1: color(
      from var(--lqip) srgb calc(mod(round(down, g * 255 / 2), 16) / 15)
        calc((mod(round(down, g * 255), 2) * 8 + round(down, b * 255 / 32)) / 15)
        calc(mod(round(down, b * 255 / 4), 8) / 7) / 1
    );
    --c2: color(
      from var(--lqip) srgb
        calc((mod(round(down, b * 255), 4) * 2 + round(down, alpha * 255 / 128)) / 7)
        calc(mod(round(down, alpha * 255 / 8), 16) / 15)
        calc(mod(round(down, alpha * 255), 8) / 7) / 1
    );
    background:
      radial-gradient(
        150% 75% at 80% 100%,
        var(--c2),
        rgb(from var(--c2) r g b / 98%) 10%,
        rgb(from var(--c2) r g b / 92%) 20%,
        rgb(from var(--c2) r g b / 82%) 30%,
        rgb(from var(--c2) r g b / 68%) 40%,
        rgb(from var(--c2) r g b / 32%) 60%,
        rgb(from var(--c2) r g b / 18%) 70%,
        rgb(from var(--c2) r g b / 8%) 80%,
        rgb(from var(--c2) r g b / 2%) 90%,
        transparent
      ),
      radial-gradient(
        100% 75% at 40% 50%,
        var(--c1),
        rgb(from var(--c1) r g b / 98%) 10%,
        rgb(from var(--c1) r g b / 92%) 20%,
        rgb(from var(--c1) r g b / 82%) 30%,
        rgb(from var(--c1) r g b / 68%) 40%,
        rgb(from var(--c1) r g b / 32%) 60%,
        rgb(from var(--c1) r g b / 18%) 70%,
        rgb(from var(--c1) r g b / 8%) 80%,
        rgb(from var(--c1) r g b / 2%) 90%,
        transparent
      ),
      var(--c0);
  }
</style>
