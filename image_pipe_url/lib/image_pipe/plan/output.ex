defmodule ImagePipe.Plan.Output do
  # Output value types shared by request parsing, output policy, and encoding.
  # Per-format encoder options and the quality search live in the nested modules.
  @moduledoc false

  @type format :: :avif | :webp | :jpeg | :png
  @type quality :: :default | {:quality, 1..100}
  @type color_profile :: :preserve_source | :strip | {:convert, term()}
  @type hdr :: :tone_map | :preserve
end
