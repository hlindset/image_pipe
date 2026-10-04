defmodule ImagePipe.Plan.Spec.Issue do
  @moduledoc """
  A problem with how a plan's options combine, returned by
  `ImagePipe.URL.validate/1` and `ImagePipe.URL.url/3`, and by
  `ImagePipe.validate/2` and `ImagePipe.run/4` in `image_pipe`.

      %ImagePipe.Plan.Spec.Issue{
        reason: :inert_option,
        locations: [{:group, 0, :fit}],
        detail: {:requires, :resize}
      }

  `locations` lists the options involved. `{:group, index, key}` is an option
  of the group at the zero-based `index`, and `{:request, key}` is a
  request-wide option. Keys are builder option names, and `resize:` options
  appear under their own names, such as `:width` and `:fit`.

  `reason` is one of:

    * `:inert_option` - the option has no effect, such as `fit` without a
      width or height, or `jpeg_options` with `format: :webp`.
    * `:mutually_exclusive_options` - the options can't be combined, such as
      `extend` and `extend_ratio`.
    * `:invalid_offset` - a pixel offset is too large to multiply by the
      group's `dpr`.
    * `:unknown_preset` - a named preset isn't defined.
    * `:pipeline_preset_with_group_options`, `:pipeline_preset_with_preset`,
      `:multiple_pipeline_presets` - a preset that defines several groups is
      combined with options or presets it can't be combined with.
    * `:unknown_watermark`, `:watermark_source_disabled` - the plan names a
      watermark the server doesn't define, or uses `watermark_source` where
      the server doesn't allow it. `ImagePipe.validate/2` and
      `ImagePipe.run/4` return both. `ImagePipe.URL.validate/1` and
      `ImagePipe.URL.url/3` return `:unknown_watermark` when the URL
      configuration's `:validate_against` lists the watermark names.

  `detail` describes the failed constraint, such as `{:requires, :resize}`
  or `%{preset: "card"}`.
  """

  @enforce_keys [:reason, :locations, :detail]
  defstruct @enforce_keys

  @type location :: {:group, non_neg_integer(), atom()} | {:request, atom()}
  @type t :: %__MODULE__{reason: atom(), locations: [location()], detail: term()}
end
