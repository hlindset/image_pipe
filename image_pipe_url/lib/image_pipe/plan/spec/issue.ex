defmodule ImagePipe.Plan.Spec.Issue do
  @moduledoc """
  A problem with a plan's options or source, returned by
  `ImagePipe.URL.validate/1`, `ImagePipe.URL.url/3`, and
  `ImagePipe.URL.url_with_issues/3`, and by
  `ImagePipe.validate/2` and `ImagePipe.run/4` in `image_pipe`.

      %ImagePipe.Plan.Spec.Issue{
        reason: :inert_option,
        locations: [{:group, 0, :fit}],
        detail: {:requires, :resize},
        severity: :warning
      }

  `severity` is `:error` or `:warning`. An error fails the request. A warning
  marks an option the request ignores because it has no effect, or a builder
  mistake with one clear meaning, which the builder repairs. The checks
  return warnings alone as `{:ok, warnings}`, and list them after the errors
  in `{:error, issues}`. They report only options the plan sets itself, not
  ones that a preset or the request defaults supply.

  `locations` lists the options involved. `{:group, index, key}` is an option
  of the group at the zero-based `index`, and `{:request, key}` is a
  request-wide option. Keys are builder option names, and `resize:` options
  appear under their own names, such as `:width` and `:fit`.

  `reason` is one of:

    * `:unknown_option` - the name isn't a builder option.
    * `:invalid_value` - the builder rejects the option's value. `detail` is
      the builder's message, such as
      `"invalid value for :fit option: expected one of [:contain, :cover, :stretch, :auto], got: :fill"`.
    * `:repeated_option` - a warning: the option was given twice in one
      builder call, or a key was repeated inside its list value, and the URL
      uses the last value.
    * `:empty_group` - a warning: an `ImagePipe.URL.group/2` call has no
      options, or only an empty `presets:` or `resize:` list, and adds no
      group. `locations` is empty.
    * `:redundant_unset` - a warning: `[:unset]` alone or a repeated leading
      `:unset` in `format_qualities:` or an encoder option such as
      `jpeg_options:`. The builder writes a single `:unset`.
    * `:invalid_source`, `:too_many_options` - returned only by
      `ImagePipe.URL.url_with_issues/3`, for what `ImagePipe.URL.url/3`
      returns as `{:error, :invalid_source}` and
      `{:error, :too_many_options}`. `locations` is empty.
    * `:inert_option` - a warning: the option has no effect, such as `fit`
      without a width or height, or `jpeg_options` with `format: :webp`, so
      the request ignores it.
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
  or `%{preset: "card"}`, holds the builder's message for `:invalid_value`,
  or is `nil`.
  """

  @enforce_keys [:reason, :locations, :detail]
  defstruct @enforce_keys ++ [severity: :error]

  @type location :: {:group, non_neg_integer(), atom()} | {:request, atom()}
  @type t :: %__MODULE__{
          reason: atom(),
          locations: [location()],
          detail: term(),
          severity: :error | :warning
        }

  # Names each error's reason and locations, never its values: a value such
  # as `watermark_source:` can be a private path.
  @doc false
  @spec summary([t()]) :: String.t()
  def summary(issues) do
    issues
    |> Enum.filter(&(&1.severity == :error))
    |> Enum.map_join("; ", fn issue ->
      "#{issue.reason} at #{Enum.map_join(issue.locations, ", ", &inspect/1)}"
    end)
  end
end
