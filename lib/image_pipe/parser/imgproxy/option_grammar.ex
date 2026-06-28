defmodule ImagePipe.Parser.Imgproxy.OptionGrammar do
  @moduledoc false

  alias ImagePipe.Parser.Imgproxy.CropRequest
  alias ImagePipe.Parser.Imgproxy.Format
  alias ImagePipe.Parser.Imgproxy.PercentEncoding
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, PngOptions, WebpOptions}
  alias ImagePipe.Plan.Response

  # Objw class weights are relative ratios used in a weighted centroid. A weight
  # exceeding this ceiling cannot produce a meaningfully different centroid than a
  # lower weight; it only risks float overflow in `class_weight · √area` arithmetic.
  # 1_000_000 (one million) is far beyond any real relative-importance use case and
  # still orders of magnitude below overflow territory (sqrt of a 10M×10M image is
  # ~10_000, so 1e6 × 10_000 = 1e10, well within float64 range).
  @max_object_weight 1_000_000.0

  @resizing_types %{
    "fit" => :fit,
    "fill" => :fill,
    "fill-down" => :fill_down,
    "force" => :force,
    "auto" => :auto
  }

  @resizing_type_names ~w(fit fill fill-down force auto)

  @option_specs %{
    "resize" => {:resize, [:resizing_type, :width, :height, :enlarge, :extend]},
    "rs" => {:resize, [:resizing_type, :width, :height, :enlarge, :extend]},
    "size" => {:size, [:width, :height, :enlarge, :extend]},
    "s" => {:size, [:width, :height, :enlarge, :extend]},
    "resizing_type" => {:resizing_type, [:resizing_type]},
    "rt" => {:resizing_type, [:resizing_type]},
    "width" => {:width, [:width]},
    "w" => {:width, [:width]},
    "height" => {:height, [:height]},
    "h" => {:height, [:height]},
    "min-width" => {:min_width, [:min_width]},
    "min_width" => {:min_width, [:min_width]},
    "mw" => {:min_width, [:min_width]},
    "min-height" => {:min_height, [:min_height]},
    "min_height" => {:min_height, [:min_height]},
    "mh" => {:min_height, [:min_height]},
    "enlarge" => {:enlarge, [:enlarge]},
    "el" => {:enlarge, [:enlarge]},
    "format" => {:format, [:format]},
    "f" => {:format, [:format]},
    "ext" => {:format, [:format]},
    "quality" => {:quality, [:quality]},
    "q" => {:quality, [:quality]},
    "format_quality" => {:format_quality, [:format, :quality]},
    "fq" => {:format_quality, [:format, :quality]},
    "max_bytes" => {:max_bytes, [:max_bytes]},
    "mb" => {:max_bytes, [:max_bytes]},
    "autoquality" => {:autoquality, [:autoquality]},
    "aq" => {:autoquality, [:autoquality]},
    "cachebuster" => {:cachebuster, [:cachebuster]},
    "cb" => {:cachebuster, [:cachebuster]},
    "expires" => {:expires, [:expires]},
    "exp" => {:expires, [:expires]},
    "filename" => {:filename, [:filename]},
    "fn" => {:filename, [:filename]},
    "return_attachment" => {:return_attachment, [:return_attachment]},
    "att" => {:return_attachment, [:return_attachment]},
    "strip_metadata" => {:strip_metadata, [:strip_metadata]},
    "sm" => {:strip_metadata, [:strip_metadata]},
    "keep_copyright" => {:keep_copyright, [:keep_copyright]},
    "kcr" => {:keep_copyright, [:keep_copyright]},
    "preserve_hdr" => {:preserve_hdr, [:preserve_hdr]},
    "ph" => {:preserve_hdr, [:preserve_hdr]},
    "jpeg_options" => {:jpeg_options, []},
    "jpgo" => {:jpeg_options, []},
    "png_options" => {:png_options, []},
    "pngo" => {:png_options, []},
    "webp_options" => {:webp_options, []},
    "webpo" => {:webp_options, []},
    "avif_options" => {:avif_options, []},
    "avifo" => {:avif_options, []},
    "debug" => {:debug, [:debug]}
  }

  # Declarative specs for regular fixed-arity pipeline options. Each entry maps
  # an option alias to an ordered list of {assignment_key, value_type} args. The
  # value_type names a parser in apply_type/2, which already emits that type's
  # canonical error tag, so per-option diagnostics are preserved without a
  # per-option error override. Irregular options stay in parse_special_option/3.
  @special_specs %{
    "blur" => [{:blur, :non_neg_float}],
    "bl" => [{:blur, :non_neg_float}],
    "sharpen" => [{:sharpen, :non_neg_float}],
    "sh" => [{:sharpen, :non_neg_float}],
    "pixelate" => [{:pixelate, :non_neg_int}],
    "pix" => [{:pixelate, :non_neg_int}],
    "dpr" => [{:dpr, :positive_float}],
    "brightness" => [{:brightness, :brightness_value}],
    "br" => [{:brightness, :brightness_value}],
    "contrast" => [{:contrast, :scale_factor}],
    "co" => [{:contrast, :scale_factor}],
    "saturation" => [{:saturation, :scale_factor}],
    "sa" => [{:saturation, :scale_factor}]
  }

  @gravity_anchors %{
    "no" => {:anchor, :center, :top},
    "so" => {:anchor, :center, :bottom},
    "ea" => {:anchor, :right, :center},
    "we" => {:anchor, :left, :center},
    "noea" => {:anchor, :right, :top},
    "nowe" => {:anchor, :left, :top},
    "soea" => {:anchor, :right, :bottom},
    "sowe" => {:anchor, :left, :bottom},
    "ce" => {:anchor, :center, :center}
  }

  @spec parse(String.t()) ::
          {:ok, {:preset, [String.t()]}}
          | {:ok, {:pipeline | :output | :cache | :policy | :response, keyword()}}
          | {:error, term()}
  def parse(segment) do
    case String.split(segment, ":") do
      [name] when name in ["preset", "pr"] ->
        {:error, {:invalid_option_segment, segment}}

      [name | args] when name in ["preset", "pr"] ->
        parse_preset_args(args, segment)

      [name | args] ->
        parse_non_preset_option(name, args, segment)
    end
  end

  defp parse_preset_args(args, segment) do
    case Enum.any?(args, &(&1 == "")) do
      true -> {:error, {:invalid_option_segment, segment}}
      false -> {:ok, {:preset, args}}
    end
  end

  defp parse_non_preset_option(name, args, segment) do
    case Map.fetch(@option_specs, name) do
      {:ok, {kind, fields}} ->
        with {:ok, assignments} <- parse_known_option(kind, fields, args, segment) do
          {:ok, scoped_assignments(kind, assignments)}
        end

      :error ->
        parse_pipeline_option(name, args, segment)
    end
  end

  # Pipeline-scoped options. Regular fixed-arity options are described
  # declaratively in @special_specs and run through interpret_special/3; the
  # remaining options with irregular arities/sub-grammars stay as bespoke
  # parse_special_option/3 clauses.
  defp parse_pipeline_option(name, args, segment) do
    result =
      case Map.fetch(@special_specs, name) do
        {:ok, arg_specs} -> interpret_special(arg_specs, args, segment)
        :error -> parse_special_option(name, args, segment)
      end

    with {:ok, assignments} <- result do
      {:ok, {:pipeline, assignments}}
    end
  end

  defp scoped_assignments(kind, assignments)
       when kind in [
              :format,
              :quality,
              :format_quality,
              :max_bytes,
              :autoquality,
              :strip_metadata,
              :keep_copyright,
              :preserve_hdr,
              :jpeg_options,
              :png_options,
              :webp_options,
              :avif_options
            ],
       do: {:output, assignments}

  defp scoped_assignments(:cachebuster, assignments), do: {:cache, assignments}

  defp scoped_assignments(:expires, assignments), do: {:policy, assignments}

  defp scoped_assignments(kind, assignments) when kind in [:filename, :return_attachment, :debug],
    do: {:response, assignments}

  defp scoped_assignments(_kind, assignments), do: {:pipeline, assignments}

  defp parse_known_option(kind, fields, args, segment)
       when kind in [
              :resizing_type,
              :width,
              :height,
              :min_width,
              :min_height,
              :enlarge,
              :format,
              :strip_metadata,
              :keep_copyright,
              :preserve_hdr
            ] do
    parse_exact_fields(fields, args, segment)
  end

  defp parse_known_option(:quality, [:quality], [value], segment) when value != "" do
    parse_exact_fields([:quality], [value], segment)
  end

  defp parse_known_option(:cachebuster, [:cachebuster], [value], _segment) when value != "" do
    {:ok, [cachebuster: value]}
  end

  defp parse_known_option(:expires, [:expires], [value], _segment) when value != "" do
    case parse_non_negative_integer(value) do
      {:ok, expires} -> {:ok, [expires: expires]}
      {:error, _reason} -> {:error, {:invalid_expires, value}}
    end
  end

  defp parse_known_option(:filename, [:filename], [value], _segment) when value != "" do
    parse_filename(value, false)
  end

  defp parse_known_option(:filename, [:filename], [value, encoded], segment)
       when value != "" and encoded != "" do
    with {:ok, encoded?} <- parse_boolean(encoded),
         {:ok, assignments} <- parse_filename(value, encoded?) do
      {:ok, assignments}
    else
      {:error, {:invalid_boolean, _value}} -> {:error, {:invalid_option_segment, segment}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_known_option(:return_attachment, [:return_attachment], [value], segment)
       when value != "" do
    case parse_boolean(value) do
      {:ok, true} -> {:ok, [disposition: :attachment]}
      {:ok, false} -> {:ok, [disposition: :inline]}
      {:error, {:invalid_boolean, _value}} -> {:error, {:invalid_option_segment, segment}}
    end
  end

  # `debug:1` opts the response into `X-ImagePipe-*` debug headers. It lives in
  # the signed processing-options path (not a query param), so imgproxy's path
  # HMAC covers it; it does not affect produced bytes, the cache key, or the ETag
  # (it rides on `Plan.Response`, which all three exclude).
  defp parse_known_option(:debug, [:debug], [value], segment) when value != "" do
    case parse_boolean(value) do
      {:ok, debug?} -> {:ok, [debug?: debug?]}
      {:error, {:invalid_boolean, _value}} -> {:error, {:invalid_option_segment, segment}}
    end
  end

  defp parse_known_option(:format_quality, [:format, :quality], [format, value], segment)
       when format != "" and value != "" do
    with {:ok, assignments} <- parse_exact_fields([:format, :quality], [format, value], segment),
         {:ok, format} <- Keyword.fetch(assignments, :format),
         {:ok, quality} <- Keyword.fetch(assignments, :quality) do
      {:ok, [format_qualities: %{format => quality}]}
    end
  end

  defp parse_known_option(:max_bytes, [:max_bytes], [value], segment) when value != "" do
    case parse_non_negative_integer(value) do
      {:ok, 0} -> {:ok, [max_bytes: nil]}
      {:ok, max_bytes} -> {:ok, [max_bytes: max_bytes]}
      {:error, _reason} -> {:error, {:invalid_option, :max_bytes, segment}}
    end
  end

  defp parse_known_option(:autoquality, [:autoquality], args, segment) do
    parse_autoquality(args, segment)
  end

  defp parse_known_option(:resize, fields, args, segment) when length(args) <= 8 do
    with {base_args, extend_gravity_parts} <- Enum.split(args, 5),
         {:ok, assignments} <- parse_fields(fields, base_args, skip_empty: true),
         {:ok, extend_gravity_assignments} <-
           parse_optional_extend_gravity(segment, extend_gravity_parts) do
      assignments =
        assignments
        |> Keyword.merge(explicit_extend_assignment(fields, base_args))
        |> Keyword.merge(extend_gravity_assignments)

      reject_empty_assignments(segment, assignments)
    end
  end

  defp parse_known_option(:size, fields, args, segment) when length(args) <= 7 do
    with {base_args, extend_gravity_parts} <- Enum.split(args, 4),
         {:ok, assignments} <- parse_fields(fields, base_args, skip_empty: true),
         {:ok, extend_gravity_assignments} <-
           parse_optional_extend_gravity(segment, extend_gravity_parts) do
      assignments =
        assignments
        |> Keyword.merge(explicit_extend_assignment(fields, base_args))
        |> Keyword.merge(extend_gravity_assignments)

      reject_empty_assignments(segment, assignments)
    end
  end

  defp parse_known_option(:jpeg_options, _spec, args, segment),
    do:
      codec_options(
        :jpeg,
        JpegOptions,
        args,
        [
          :progressive,
          :no_subsample,
          :trellis_quant,
          :overshoot_deringing,
          :optimize_scans,
          :quant_table
        ],
        &jpeg_arg/2,
        &identity/1,
        segment
      )

  defp parse_known_option(:png_options, _spec, args, segment),
    do:
      codec_options(
        :png,
        PngOptions,
        args,
        [:interlaced, :quantize, :quantization_colors],
        &png_arg/2,
        &identity/1,
        segment
      )

  defp parse_known_option(:webp_options, _spec, args, segment),
    do:
      codec_options(
        :webp,
        WebpOptions,
        args,
        [:compression, :smart_subsample, :preset],
        &webp_arg/2,
        &identity/1,
        segment
      )

  defp parse_known_option(:avif_options, _spec, args, segment),
    do: codec_options(:avif, AvifOptions, args, [:subsample], &avif_arg/2, &identity/1, segment)

  defp parse_known_option(_kind, _fields, _args, segment),
    do: {:error, {:invalid_option_segment, segment}}

  # Walk positional args; empty string ⇒ no override; otherwise translate to
  # libvips field assignments and build the struct, then run a per-format
  # finalizer. Too many args ⇒ invalid.
  defp codec_options(_format_key, _mod, args, positions, _translator, _finalize, segment)
       when length(args) > length(positions),
       do: {:error, {:invalid_option_segment, segment}}

  defp codec_options(format_key, mod, args, positions, translator, finalize, segment) do
    padded = args ++ List.duplicate("", length(positions) - length(args))
    pairs = Enum.zip(positions, padded)

    case Enum.reduce_while(pairs, {:ok, []}, &reduce_codec_arg(&1, &2, translator)) do
      {:ok, assigns} -> {:ok, [encoder_options: %{format_key => finalize.(struct(mod, assigns))}]}
      :error -> {:error, {:invalid_option_segment, segment}}
    end
  end

  defp reduce_codec_arg({_pos, ""}, {:ok, acc}, _translator), do: {:cont, {:ok, acc}}

  defp reduce_codec_arg({pos, raw}, {:ok, acc}, translator) do
    case translator.(pos, raw) do
      {:ok, assigns} -> {:cont, {:ok, acc ++ assigns}}
      :error -> {:halt, :error}
    end
  end

  defp jpeg_arg(:progressive, v), do: bool_assign(:interlace, v)
  # imgproxy no_subsample:true → subsample off; false → :auto (libvips default,
  # "subsampling enabled"). We emit the explicit value (not nil) so a present
  # `0`/`false` can reset an earlier/host-set `:off` — :auto is byte-neutral.
  defp jpeg_arg(:no_subsample, v),
    do: with({:ok, b} <- boolish(v), do: {:ok, [subsample_mode: if(b, do: :off, else: :auto)]})

  defp jpeg_arg(:trellis_quant, v), do: bool_assign(:trellis_quant, v)
  defp jpeg_arg(:overshoot_deringing, v), do: bool_assign(:overshoot_deringing, v)
  defp jpeg_arg(:optimize_scans, v), do: bool_assign(:optimize_scans, v)
  defp jpeg_arg(:quant_table, v), do: int_assign(:quant_table, v, 0..8)

  defp png_arg(:interlaced, v), do: bool_assign(:interlace, v)

  defp png_arg(:quantize, v),
    do:
      with(
        {:ok, b} <- boolish(v),
        do: {:ok, if(b, do: [palette: true, filter: :none], else: [palette: false])}
      )

  defp png_arg(:quantization_colors, v) do
    case Integer.parse(v) do
      {n, ""} when n >= 2 and n <= 256 -> {:ok, [bitdepth: png_bitdepth(n)]}
      _ -> :error
    end
  end

  # Emit BOTH bools explicitly so a present `compression` always fully determines
  # the mode (and can reset an earlier/host-set lossless). `lossy` = both false =
  # libvips default, byte-neutral.
  defp webp_arg(:compression, "lossy"), do: {:ok, [lossless: false, near_lossless: false]}
  defp webp_arg(:compression, "lossless"), do: {:ok, [lossless: true, near_lossless: false]}
  defp webp_arg(:compression, "near_lossless"), do: {:ok, [lossless: false, near_lossless: true]}
  defp webp_arg(:compression, _), do: :error
  defp webp_arg(:smart_subsample, v), do: bool_assign(:smart_subsample, v)

  defp webp_arg(:preset, v) when v in ~w(default photo picture drawing icon text),
    do: {:ok, [preset: String.to_existing_atom(v)]}

  defp webp_arg(:preset, _), do: :error

  defp avif_arg(:subsample, v) when v in ~w(auto on off),
    do: {:ok, [subsample_mode: String.to_existing_atom(v)]}

  defp avif_arg(:subsample, _), do: :error

  # imgproxy's quantization_colors -> libvips bitdepth bucket (vips_pngsave_go).
  defp png_bitdepth(n) when n > 16, do: 8
  defp png_bitdepth(n) when n > 4, do: 4
  defp png_bitdepth(n) when n > 2, do: 2
  defp png_bitdepth(_), do: 1

  defp identity(o), do: o

  defp bool_assign(field, v), do: with({:ok, b} <- boolish(v), do: {:ok, [{field, b}]})

  defp int_assign(field, v, lo..hi//_) do
    case Integer.parse(v) do
      {n, ""} when n >= lo and n <= hi -> {:ok, [{field, n}]}
      _ -> :error
    end
  end

  defp boolish(v) do
    case parse_boolean(v) do
      {:ok, b} -> {:ok, b}
      {:error, _} -> :error
    end
  end

  # autoquality:%method[:%method_args...] — emits the tagged
  # {:autoquality, fields | :disabled} shape, carrying only the URL-present
  # fields; config fills the rest in a later resolution step.
  defp parse_autoquality(["none"], _segment),
    do: {:ok, [quality_search: {:autoquality, :disabled}]}

  defp parse_autoquality(["size" | rest], segment) when length(rest) <= 3 do
    with {:ok, fields} <-
           parse_autoquality_args(rest, [:target_bytes, :min_quality, :max_quality]) do
      autoquality_result([metric: :size] ++ fields, segment)
    end
  end

  defp parse_autoquality(["ssim2" | rest], segment) when length(rest) <= 4 do
    with {:ok, fields} <-
           parse_autoquality_args(rest, [
             :target_float,
             :min_quality,
             :max_quality,
             :allowed_error
           ]) do
      autoquality_result([metric: :ssimulacra2] ++ fields, segment)
    end
  end

  defp parse_autoquality(["butteraugli" | rest], segment) when length(rest) <= 4 do
    with {:ok, fields} <-
           parse_autoquality_args(rest, [
             :target_distance,
             :min_quality,
             :max_quality,
             :allowed_error
           ]) do
      autoquality_result([metric: :butteraugli] ++ fields, segment)
    end
  end

  defp parse_autoquality(["dssim"], _segment),
    do: {:ok, [quality_search: {:autoquality, [metric: :ssimulacra2]}]}

  defp parse_autoquality(_args, segment),
    do: {:error, {:invalid_option, :autoquality, segment}}

  defp autoquality_result(fields, segment) do
    min = Keyword.get(fields, :min_quality)
    max = Keyword.get(fields, :max_quality)

    if is_integer(min) and is_integer(max) and min > max do
      {:error, {:invalid_option, :autoquality, segment}}
    else
      {:ok, [quality_search: {:autoquality, fields}]}
    end
  end

  defp parse_autoquality_args(values, specs) do
    specs
    |> Enum.zip(values)
    |> Enum.reduce_while({:ok, []}, fn {spec, value}, {:ok, acc} ->
      case parse_autoquality_field(spec, value) do
        {:ok, {key, parsed}} -> {:cont, {:ok, [{key, parsed} | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_autoquality_field(:target_bytes, value) do
    with {:ok, target} <- parse_positive_integer(value), do: {:ok, {:target, target}}
  end

  defp parse_autoquality_field(:target_float, value) do
    case parse_float(value) do
      {:ok, float} when float >= 0.0 and float <= 100.0 -> {:ok, {:target, float}}
      {:ok, _float} -> {:error, {:invalid_float, value}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_autoquality_field(:target_distance, value) do
    case parse_non_negative_float(value) do
      {:ok, float} when float <= 25.0 -> {:ok, {:target, float}}
      {:ok, _float} -> {:error, {:invalid_float, value}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_autoquality_field(key, value) when key in [:min_quality, :max_quality] do
    case Integer.parse(value) do
      {integer, ""} when integer in 1..100 -> {:ok, {key, integer}}
      _other -> {:error, {:invalid_non_negative_integer, value}}
    end
  end

  defp parse_autoquality_field(:allowed_error, value) do
    with {:ok, error} <- parse_non_negative_float(value), do: {:ok, {:allowed_error, error}}
  end

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, {:invalid_positive_integer, value}}
    end
  end

  defp parse_filename(value, false) do
    with {:ok, decoded} <- PercentEncoding.decode(value),
         true <- Response.valid_filename?(decoded) do
      {:ok, [filename: decoded]}
    else
      false -> {:error, {:invalid_response_filename, value}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_filename(value, true) do
    with :ok <- reject_base64_padding(value),
         {:ok, decoded} <- Base.url_decode64(value, padding: false),
         true <- Response.valid_filename?(decoded) do
      {:ok, [filename: decoded]}
    else
      false -> {:error, {:invalid_response_filename, value}}
      :error -> {:error, {:invalid_response_filename, value}}
      {:error, _reason} = error -> error
    end
  end

  defp reject_base64_padding(value) do
    if String.contains?(value, "=") do
      {:error, {:invalid_response_filename, value}}
    else
      :ok
    end
  end

  defp parse_exact_fields(fields, args, _segment) when length(args) == length(fields) do
    parse_fields(fields, args)
  end

  defp parse_exact_fields(_fields, _args, segment),
    do: {:error, {:invalid_option_segment, segment}}

  defp reject_empty_assignments(segment, []), do: {:error, {:invalid_option_segment, segment}}
  defp reject_empty_assignments(_segment, assignments), do: {:ok, assignments}

  defp explicit_extend_assignment(fields, args) do
    index = Enum.find_index(fields, &(&1 == :extend))
    value = if is_nil(index), do: nil, else: Enum.at(args, index)

    if value in [nil, ""] do
      []
    else
      [extend_requested: true]
    end
  end

  defp parse_fields(fields, args, opts \\ []) do
    skip_empty? = Keyword.get(opts, :skip_empty, false)

    result =
      fields
      |> Enum.zip(args)
      |> Enum.reduce_while({:ok, []}, fn
        {_field, value}, {:ok, assignments} when skip_empty? and value in [nil, ""] ->
          {:cont, {:ok, assignments}}

        {field, value}, {:ok, assignments} ->
          case parse_field(field, value) do
            {:ok, parsed_value} -> {:cont, {:ok, [{field, parsed_value} | assignments]}}
            {:error, _reason} = error -> {:halt, error}
          end
      end)

    case result do
      {:ok, assignments} -> {:ok, Enum.reverse(assignments)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_field(:resizing_type, value), do: parse_resizing_type_value(value)
  defp parse_field(:width, value), do: parse_pixels(value)
  defp parse_field(:height, value), do: parse_pixels(value)
  defp parse_field(:min_width, value), do: parse_pixels(value)
  defp parse_field(:min_height, value), do: parse_pixels(value)
  defp parse_field(:enlarge, value), do: parse_boolean(value)
  defp parse_field(:extend, value), do: parse_boolean(value)
  defp parse_field(:strip_metadata, value), do: parse_boolean(value)
  defp parse_field(:keep_copyright, value), do: parse_boolean(value)
  defp parse_field(:preserve_hdr, value), do: parse_boolean(value)
  defp parse_field(:format, value), do: Format.parse(value)
  defp parse_field(:quality, value), do: parse_quality(value)

  defp parse_optional_extend_gravity(segment, parts),
    do: parse_optional_extend_gravity(:extend, segment, parts)

  defp parse_optional_extend_gravity(_prefix, _segment, []), do: {:ok, []}
  defp parse_optional_extend_gravity(_prefix, _segment, [""]), do: {:ok, []}
  defp parse_optional_extend_gravity(_prefix, _segment, ["", ""]), do: {:ok, []}
  defp parse_optional_extend_gravity(_prefix, _segment, ["", "", ""]), do: {:ok, []}

  defp parse_optional_extend_gravity(prefix, _segment, [gravity]) do
    case parse_gravity_anchor(gravity) do
      {:ok, anchor} -> {:ok, [{gravity_key(prefix, :gravity), anchor}]}
      {:error, _reason} = error -> error
    end
  end

  defp parse_optional_extend_gravity(prefix, _segment, [gravity, "", ""]) do
    case parse_gravity_anchor(gravity) do
      {:ok, anchor} -> {:ok, [{gravity_key(prefix, :gravity), anchor}]}
      {:error, _reason} = error -> error
    end
  end

  defp parse_optional_extend_gravity(prefix, _segment, [gravity, x_offset, y_offset]) do
    with {:ok, anchor} <- parse_gravity_anchor(gravity),
         {:ok, x_offset} <- parse_float(x_offset),
         {:ok, y_offset} <- parse_float(y_offset) do
      {:ok,
       [
         {gravity_key(prefix, :gravity), anchor},
         {gravity_key(prefix, :x_offset), x_offset},
         {gravity_key(prefix, :y_offset), y_offset}
       ]}
    end
  end

  defp parse_optional_extend_gravity(_prefix, segment, _parts),
    do: {:error, {:invalid_option_segment, segment}}

  defp gravity_key(:extend, :gravity), do: :extend_gravity
  defp gravity_key(:extend, :x_offset), do: :extend_x_offset
  defp gravity_key(:extend, :y_offset), do: :extend_y_offset
  defp gravity_key(:extend_aspect_ratio, :gravity), do: :extend_aspect_ratio_gravity
  defp gravity_key(:extend_aspect_ratio, :x_offset), do: :extend_aspect_ratio_x_offset
  defp gravity_key(:extend_aspect_ratio, :y_offset), do: :extend_aspect_ratio_y_offset

  defp parse_resizing_type_value(value) do
    case Map.fetch(@resizing_types, value) do
      {:ok, resizing_type} -> {:ok, resizing_type}
      :error -> {:error, {:invalid_resizing_type, value, @resizing_type_names}}
    end
  end

  defp parse_pixels(value) do
    case parse_non_negative_integer(value) do
      {:ok, integer} -> {:ok, {:pixels, integer}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_boolean(value), do: ImagePipe.Parser.parse_boolean(value)

  # Generic interpreter for @special_specs entries: each spec is a fixed list of
  # required, non-empty args. Arity/empty-arg failures yield the uniform
  # :invalid_option_segment tag (matching the bespoke parsers); value failures
  # propagate the type parser's own tag.
  defp interpret_special(arg_specs, args, segment) do
    cond do
      length(args) != length(arg_specs) -> {:error, {:invalid_option_segment, segment}}
      Enum.any?(args, &(&1 == "")) -> {:error, {:invalid_option_segment, segment}}
      true -> interpret_special_args(arg_specs, args)
    end
  end

  defp interpret_special_args(arg_specs, args) do
    arg_specs
    |> Enum.zip(args)
    |> Enum.reduce_while({:ok, []}, fn {{key, type}, value}, {:ok, acc} ->
      case apply_type(type, value) do
        {:ok, parsed} -> {:cont, {:ok, [{key, parsed} | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp apply_type(:non_neg_float, value), do: parse_non_negative_float(value)
  defp apply_type(:positive_float, value), do: parse_positive_float(value)
  defp apply_type(:non_neg_int, value), do: parse_non_negative_integer(value)
  defp apply_type(:scale_factor, value), do: parse_scale_factor(value)
  defp apply_type(:brightness_value, value), do: parse_brightness_value(value)

  defp parse_special_option(name, args, segment) when name in ["zoom", "z"] do
    parse_zoom(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["extend", "ex"] do
    parse_extend(args, segment)
  end

  defp parse_special_option(name, args, segment)
       when name in ["extend_aspect_ratio", "extend_ar", "exar"] do
    parse_extend_aspect_ratio(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["crop", "c"] do
    parse_crop(args, segment)
  end

  defp parse_special_option(name, args, segment)
       when name in ["crop_aspect_ratio", "crop_ar", "car"] do
    parse_crop_aspect_ratio(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["auto_rotate", "ar"] do
    parse_auto_rotate(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["rotate", "rot"] do
    parse_rotate(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["flip", "fl"] do
    parse_flip(args, segment)
  end

  defp parse_special_option(name, args, segment)
       when name in ["strip_color_profile", "scp"] do
    parse_strip_color_profile(args, segment)
  end

  defp parse_special_option(name, args, segment)
       when name in ["color_profile", "cp", "icc"] do
    parse_color_profile(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["gravity", "g"] do
    parse_gravity(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["padding", "pd"] do
    parse_padding(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["background", "bg"] do
    parse_background(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["background_alpha", "bga"] do
    parse_background_alpha(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["monochrome", "mc"] do
    parse_monochrome(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["duotone", "dt"] do
    parse_duotone(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["colorize", "col"] do
    parse_colorize(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["gradient", "gr"] do
    parse_gradient(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["trim", "t"] do
    parse_trim(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["adjust", "a"] do
    parse_adjust(args, segment)
  end

  defp parse_special_option(name, _args, _segment), do: {:error, {:unknown_option, name}}

  # adjust:%brightness:%contrast:%saturation — parser-only sugar that fans each
  # present segment out to the existing brightness/contrast/saturation effects.
  # Empty segments are skipped, leaving each field at its default no-op.
  defp parse_adjust(args, _segment) when length(args) in 1..3 do
    specs = [
      {:brightness, &parse_brightness_value/1},
      {:contrast, &parse_scale_factor/1},
      {:saturation, &parse_scale_factor/1}
    ]

    args
    |> Enum.zip(specs)
    |> Enum.reduce_while({:ok, []}, fn
      {"", _spec}, {:ok, acc} ->
        {:cont, {:ok, acc}}

      {value, {key, parser}}, {:ok, acc} ->
        case parser.(value) do
          {:ok, parsed} -> {:cont, {:ok, [{key, parsed} | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_adjust(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  # trim:%threshold:%color:%equal_hor:%equal_ver — enabled iff threshold is set.
  defp parse_trim([], _segment), do: {:ok, []}
  # Empty threshold disables trim, but the arity cap still applies (imgproxy runs
  # ensureMaxArgs before the threshold check), so >4 args is rejected even here.
  defp parse_trim(["" | rest], _segment) when length(rest) <= 3, do: {:ok, []}

  defp parse_trim(args, _segment) when length(args) <= 4 do
    [threshold | rest] = args

    with {:ok, threshold} <- parse_float(threshold),
         {:ok, background} <- parse_trim_color(Enum.at(rest, 0)),
         {:ok, equal_hor} <- parse_trim_flag(Enum.at(rest, 1)),
         {:ok, equal_ver} <- parse_trim_flag(Enum.at(rest, 2)) do
      {:ok,
       [
         trim: [
           threshold: threshold,
           background: background,
           equal_hor: equal_hor,
           equal_ver: equal_ver
         ]
       ]}
    end
  end

  defp parse_trim(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_trim_color(nil), do: {:ok, :auto}
  defp parse_trim_color(""), do: {:ok, :auto}

  defp parse_trim_color(hex) do
    case Color.rgb_hex(hex) do
      {:ok, color} -> {:ok, color}
      {:error, {:invalid_color, _}} -> {:error, {:invalid_trim_color, hex}}
    end
  end

  defp parse_trim_flag(nil), do: {:ok, false}
  defp parse_trim_flag(""), do: {:ok, false}
  defp parse_trim_flag(value), do: parse_boolean(value)

  defp parse_monochrome([intensity], _segment) when intensity != "" do
    with {:ok, intensity} <- parse_intensity(intensity) do
      {:ok, [monochrome: [intensity: intensity]]}
    end
  end

  defp parse_monochrome([intensity, ""], _segment) when intensity != "" do
    with {:ok, intensity} <- parse_intensity(intensity) do
      {:ok, [monochrome: [intensity: intensity]]}
    end
  end

  defp parse_monochrome([intensity, color], _segment) when intensity != "" and color != "" do
    with {:ok, intensity} <- parse_intensity(intensity),
         {:ok, color} <- Color.rgb_hex(color) do
      {:ok, [monochrome: [intensity: intensity, color: color]]}
    else
      {:error, {:invalid_color, _value}} -> {:error, {:invalid_monochrome, color}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_monochrome(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_duotone([intensity], _segment) when intensity != "" do
    with {:ok, intensity} <- parse_intensity(intensity) do
      {:ok, [duotone: [intensity: intensity]]}
    end
  end

  defp parse_duotone([intensity, shadow], _segment) when intensity != "" do
    with {:ok, intensity} <- parse_intensity(intensity),
         {:ok, shadow_assignments} <- parse_optional_duotone_color(:shadow, shadow) do
      {:ok, [duotone: Keyword.merge([intensity: intensity], shadow_assignments)]}
    else
      {:error, {:invalid_color, _value}} -> {:error, {:invalid_duotone, shadow}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_duotone([intensity, shadow, highlight], _segment)
       when intensity != "" do
    with {:ok, intensity} <- parse_intensity(intensity),
         {:ok, shadow_assignments} <- parse_optional_duotone_color(:shadow, shadow),
         {:ok, highlight_assignments} <- parse_optional_duotone_color(:highlight, highlight) do
      duotone =
        [intensity: intensity]
        |> Keyword.merge(shadow_assignments)
        |> Keyword.merge(highlight_assignments)

      {:ok, [duotone: duotone]}
    else
      {:error, {:invalid_color, _value}} -> {:error, {:invalid_duotone, [shadow, highlight]}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_duotone(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_optional_duotone_color(_field, ""), do: {:ok, []}

  defp parse_optional_duotone_color(field, value) do
    with {:ok, color} <- Color.rgb_hex(value) do
      {:ok, [{field, color}]}
    end
  end

  defp parse_colorize([opacity], _segment) when opacity != "" do
    with {:ok, opacity} <- parse_intensity(opacity), do: {:ok, [colorize: [opacity: opacity]]}
  end

  defp parse_colorize([opacity, color], segment) when opacity != "" do
    parse_colorize([opacity, color, ""], segment)
  end

  defp parse_colorize([opacity, color, keep_alpha], _segment) when opacity != "" do
    with {:ok, opacity} <- parse_intensity(opacity),
         {:ok, color_assignments} <- parse_optional_colorize_color(color),
         {:ok, keep_assignments} <- parse_optional_keep_alpha(keep_alpha) do
      {:ok, [colorize: [opacity: opacity] ++ color_assignments ++ keep_assignments]}
    else
      {:error, {:invalid_color, _}} -> {:error, {:invalid_colorize, color}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_colorize(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_optional_colorize_color(""), do: {:ok, []}

  defp parse_optional_colorize_color(value) do
    with {:ok, color} <- Color.rgb_hex(value), do: {:ok, [color: color]}
  end

  defp parse_optional_keep_alpha(""), do: {:ok, []}

  defp parse_optional_keep_alpha(value) do
    with {:ok, bool} <- parse_boolean(value), do: {:ok, [keep_alpha: bool]}
  end

  @gradient_directions %{"down" => 0.0, "left" => 90.0, "up" => 180.0, "right" => 270.0}

  defp parse_gradient([opacity | rest], _segment) when opacity != "" and length(rest) <= 4 do
    with {:ok, opacity} <- parse_intensity(opacity),
         {:ok, assignments} <- parse_gradient_tail(rest) do
      {:ok, [gradient: [opacity: opacity] ++ assignments]}
    end
  end

  defp parse_gradient(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  # rest = [color, direction, start, stop] (any trailing omitted; empty = default)
  defp parse_gradient_tail(rest) do
    [color, direction, start, stop] = rest ++ List.duplicate("", 4 - length(rest))

    with {:ok, color_kw} <- parse_optional_colorize_color(color),
         {:ok, dir_kw} <- parse_optional_gradient_direction(direction),
         {:ok, start_kw} <- parse_optional_gradient_pos(:start, start),
         {:ok, stop_kw} <- parse_optional_gradient_pos(:stop, stop) do
      {:ok, color_kw ++ dir_kw ++ start_kw ++ stop_kw}
    else
      {:error, {:invalid_color, _}} -> {:error, {:invalid_gradient, color}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_optional_gradient_direction(""), do: {:ok, []}

  defp parse_optional_gradient_direction(value) do
    case Map.fetch(@gradient_directions, value) do
      {:ok, angle} ->
        {:ok, [angle: angle]}

      :error ->
        case parse_number(value) do
          {:ok, number} -> {:ok, [angle: normalize_angle(number)]}
          {:error, _} -> {:error, {:invalid_gradient, value}}
        end
    end
  end

  defp parse_optional_gradient_pos(_field, ""), do: {:ok, []}

  defp parse_optional_gradient_pos(field, value) do
    case parse_number(value) do
      {:ok, number} when number >= 0 and number <= 1 -> {:ok, [{field, number * 1.0}]}
      _other -> {:error, {:invalid_gradient, value}}
    end
  end

  defp normalize_angle(number) do
    angle = :math.fmod(number * 1.0, 360.0)
    if angle < 0, do: angle + 360.0, else: angle
  end

  defp parse_scale_factor(value) do
    case parse_number(value) do
      {:ok, number} when number > 0 -> {:ok, number * 1.0}
      _other -> {:error, {:invalid_scale_factor, value}}
    end
  end

  defp parse_brightness_value(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= -255 and integer <= 255 -> {:ok, integer}
      _other -> {:error, {:invalid_brightness, value}}
    end
  end

  defp parse_intensity(value) do
    case parse_alpha_ratio(value) do
      {:ok, ratio} -> {:ok, ratio}
      {:error, _reason} -> {:error, {:invalid_intensity, value}}
    end
  end

  defp parse_padding(args, segment) when length(args) <= 4 do
    with {:ok, parsed_args} <- parse_padding_args(args, segment) do
      {:ok, [padding: parsed_args]}
    end
  end

  defp parse_padding(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_padding_args(args, segment) do
    parse_padding_args(args, segment, [])
  end

  defp parse_padding_args([], _segment, values), do: {:ok, Enum.reverse(values)}

  defp parse_padding_args([arg | args], segment, values) do
    case parse_padding_arg(arg) do
      {:ok, value} -> parse_padding_args(args, segment, [value | values])
      {:error, _reason} -> {:error, {:invalid_option_segment, segment}}
    end
  end

  defp parse_padding_arg(""), do: {:ok, :unset}
  defp parse_padding_arg(value), do: parse_non_negative_integer(value)

  defp parse_background([""], _segment), do: {:ok, [background_color: nil]}

  defp parse_background([hex], _segment) when hex != "" do
    case Color.rgb_hex(hex) do
      {:ok, color} -> {:ok, [background_color: color]}
      {:error, _reason} -> {:error, {:invalid_background, hex}}
    end
  end

  defp parse_background([red, green, blue], _segment)
       when red != "" and green != "" and blue != "" do
    with {:ok, red} <- parse_non_negative_integer(red),
         {:ok, green} <- parse_non_negative_integer(green),
         {:ok, blue} <- parse_non_negative_integer(blue),
         {:ok, color} <- Color.rgb(red, green, blue) do
      {:ok, [background_color: color]}
    else
      {:error, _reason} -> {:error, {:invalid_background, [red, green, blue]}}
    end
  end

  defp parse_background(args, _segment), do: {:error, {:invalid_background, args}}

  defp parse_background_alpha([alpha], _segment) when alpha != "" do
    case parse_alpha_ratio(alpha) do
      {:ok, alpha} -> {:ok, [background_alpha: alpha]}
      {:error, _reason} -> {:error, {:invalid_background_alpha, alpha}}
    end
  end

  defp parse_background_alpha(args, _segment), do: {:error, {:invalid_background_alpha, args}}

  defp parse_alpha_ratio(value) do
    case String.split(value, ".", parts: 2) do
      [integer] -> parse_alpha_integer(integer)
      [integer, fraction] -> parse_alpha_decimal(integer, fraction)
    end
  end

  defp parse_alpha_integer("0"), do: {:ok, {:ratio, 0, 1}}
  defp parse_alpha_integer("1"), do: {:ok, {:ratio, 1, 1}}
  defp parse_alpha_integer(_integer), do: {:error, :alpha}

  defp parse_alpha_decimal(integer, fraction) when integer in ["0", "1"] and fraction != "" do
    with true <- decimal_digits?(fraction),
         {fraction_value, ""} <- Integer.parse(fraction, 10) do
      denominator = Integer.pow(10, byte_size(fraction))
      numerator = String.to_integer(integer) * denominator + fraction_value

      case numerator >= 0 and numerator <= denominator do
        true -> {:ok, {:ratio, numerator, denominator}}
        false -> {:error, :alpha}
      end
    else
      _reason -> {:error, :alpha}
    end
  end

  defp parse_alpha_decimal(_integer, _fraction), do: {:error, :alpha}

  defp decimal_digits?(value) do
    value
    |> String.to_charlist()
    |> Enum.all?(&(&1 in ?0..?9))
  end

  defp parse_zoom([value], _segment) when value != "" do
    with {:ok, zoom} <- parse_positive_float(value) do
      {:ok, [zoom_x: zoom, zoom_y: zoom]}
    end
  end

  defp parse_zoom([x, y], _segment) when x != "" and y != "" do
    with {:ok, x} <- parse_positive_float(x),
         {:ok, y} <- parse_positive_float(y) do
      {:ok, [zoom_x: x, zoom_y: y]}
    end
  end

  defp parse_zoom(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_extend([value], _segment) when value != "" do
    with {:ok, extend?} <- parse_boolean(value) do
      {:ok, [extend: extend?, extend_requested: true]}
    end
  end

  defp parse_extend([value | gravity_parts], segment) when value != "" do
    with {:ok, extend?} <- parse_boolean(value),
         {:ok, extend_gravity_assignments} <-
           parse_optional_extend_gravity(segment, gravity_parts) do
      {:ok, Keyword.merge([extend: extend?, extend_requested: true], extend_gravity_assignments)}
    end
  end

  defp parse_extend(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_extend_aspect_ratio([value], _segment) when value != "" do
    with {:ok, extend?} <- parse_boolean(value) do
      {:ok, [extend_aspect_ratio: extend?]}
    end
  end

  defp parse_extend_aspect_ratio([value | gravity_parts], segment) when value != "" do
    with {:ok, extend?} <- parse_boolean(value),
         {:ok, gravity_assignments} <-
           parse_optional_extend_gravity(:extend_aspect_ratio, segment, gravity_parts) do
      {:ok, Keyword.merge([extend_aspect_ratio: extend?], gravity_assignments)}
    end
  end

  defp parse_extend_aspect_ratio(_args, segment),
    do: {:error, {:invalid_option_segment, segment}}

  defp parse_crop([width, height], _segment) when width != "" and height != "" do
    with {:ok, width} <- parse_crop_dimension(width),
         {:ok, height} <- parse_crop_dimension(height) do
      {:ok, [crop: %CropRequest{width: width, height: height}]}
    end
  end

  defp parse_crop([width, height, "obj" | classes], _segment)
       when width != "" and height != "" do
    with {:ok, width} <- parse_crop_dimension(width),
         {:ok, height} <- parse_crop_dimension(height),
         {:ok, gravity} <- parse_crop_gravity(["obj" | classes]) do
      {:ok, [crop: %CropRequest{width: width, height: height, gravity: gravity}]}
    end
  end

  defp parse_crop([width, height, "objw" | pairs], _segment)
       when width != "" and height != "" do
    with {:ok, width} <- parse_crop_dimension(width),
         {:ok, height} <- parse_crop_dimension(height),
         {:ok, gravity} <- parse_crop_gravity(["objw" | pairs]) do
      {:ok, [crop: %CropRequest{width: width, height: height, gravity: gravity}]}
    end
  end

  defp parse_crop([width, height, gravity], _segment)
       when width != "" and height != "" and gravity != "" do
    with {:ok, width} <- parse_crop_dimension(width),
         {:ok, height} <- parse_crop_dimension(height),
         {:ok, gravity} <- parse_crop_gravity([gravity]) do
      {:ok, [crop: %CropRequest{width: width, height: height, gravity: gravity}]}
    end
  end

  defp parse_crop([width, height, "fp", x, y], _segment)
       when width != "" and height != "" and x != "" and y != "" do
    with {:ok, width} <- parse_crop_dimension(width),
         {:ok, height} <- parse_crop_dimension(height),
         {:ok, gravity} <- parse_crop_gravity(["fp", x, y]) do
      {:ok, [crop: %CropRequest{width: width, height: height, gravity: gravity}]}
    end
  end

  defp parse_crop([width, height, gravity, x_offset, y_offset], _segment)
       when width != "" and height != "" and gravity != "" and x_offset != "" and y_offset != "" do
    with {:ok, width} <- parse_crop_dimension(width),
         {:ok, height} <- parse_crop_dimension(height),
         {:ok, gravity} <- parse_gravity_anchor(gravity),
         {:ok, x_offset} <- parse_gravity_offset(x_offset),
         {:ok, y_offset} <- parse_gravity_offset(y_offset) do
      {:ok,
       [
         crop: %CropRequest{
           width: width,
           height: height,
           gravity: gravity,
           x_offset: x_offset,
           y_offset: y_offset
         }
       ]}
    end
  end

  defp parse_crop(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_crop_aspect_ratio([ratio], segment) when ratio != "" do
    parse_crop_aspect_ratio([ratio, "0"], segment)
  end

  defp parse_crop_aspect_ratio([ratio, enlarge], _segment)
       when ratio != "" and enlarge != "" do
    with {:ok, ratio} <- parse_non_negative_float(ratio),
         {:ok, enlarge?} <- parse_boolean(enlarge) do
      {:ok, [crop_aspect_ratio: ratio, crop_aspect_ratio_enlarge: enlarge?]}
    end
  end

  defp parse_crop_aspect_ratio(_args, segment),
    do: {:error, {:invalid_option_segment, segment}}

  defp parse_crop_gravity(["sm"]), do: {:ok, :sm}

  defp parse_crop_gravity(["fp", x, y]) do
    with {:ok, x} <- parse_focal_coordinate(x),
         {:ok, y} <- parse_focal_coordinate(y) do
      {:ok, {:fp, x, y}}
    end
  end

  defp parse_crop_gravity(["obj" | classes]), do: {:ok, {:obj, classes}}

  defp parse_crop_gravity(["objw" | pairs]) do
    with {:ok, weights} <- parse_object_weights(pairs, "crop") do
      {:ok, {:objw, weights}}
    end
  end

  defp parse_crop_gravity([anchor]), do: parse_gravity_anchor(anchor)
  defp parse_crop_gravity(_args), do: {:error, {:invalid_option_segment, "crop"}}

  # Parses imgproxy objw class/weight pairs into [{class_string, weight_float}].
  # Positional: class then weight, repeating. Rejects odd arity, empty class
  # tokens, and non-positive/non-numeric weights at the parser boundary.
  defp parse_object_weights([], segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_object_weights(tokens, segment), do: parse_object_weights(tokens, segment, [])

  defp parse_object_weights([], _segment, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_object_weights([class, weight | rest], segment, acc) when class != "" do
    with {:ok, weight} <- parse_positive_float(weight),
         :ok <- check_object_weight_magnitude(weight, segment) do
      parse_object_weights(rest, segment, [{class, weight} | acc])
    end
  end

  defp parse_object_weights(_tokens, segment, _acc),
    do: {:error, {:invalid_option_segment, segment}}

  defp check_object_weight_magnitude(weight, _segment) when weight <= @max_object_weight, do: :ok

  defp check_object_weight_magnitude(_weight, segment),
    do: {:error, {:invalid_option_segment, segment}}

  defp parse_auto_rotate([], _segment), do: {:ok, [orientation: [auto_orient: true]]}

  defp parse_auto_rotate([value], _segment) when value != "" do
    with {:ok, auto_orient?} <- parse_boolean(value) do
      {:ok, [orientation: [auto_orient: auto_orient?]]}
    end
  end

  defp parse_auto_rotate(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_strip_color_profile([], _segment),
    do: {:ok, [strip_color_profile: true]}

  defp parse_strip_color_profile([value], _segment) when value != "" do
    with {:ok, value?} <- parse_boolean(value) do
      {:ok, [strip_color_profile: value?]}
    end
  end

  defp parse_strip_color_profile(_args, segment),
    do: {:error, {:invalid_option_segment, segment}}

  defp parse_color_profile([value], segment) when value != "" do
    case color_profile_target(value) do
      {:ok, target} -> {:ok, [color_profile: target]}
      :error -> {:error, {:invalid_option_segment, segment}}
    end
  end

  defp parse_color_profile(_args, segment),
    do: {:error, {:invalid_option_segment, segment}}

  # v1 built-in allowlist. `srgb` is the imgproxy-faithful built-in; `p3`/`display-p3`
  # and `adobe-rgb`/`adobergb` are ImagePipe-specific extensions (Pro reaches these only
  # via a custom profiles dir). No percent-decoding in v1 — identifiers are ASCII-safe.
  defp color_profile_target("srgb"), do: {:ok, :srgb}
  defp color_profile_target("p3"), do: {:ok, :display_p3}
  defp color_profile_target("display-p3"), do: {:ok, :display_p3}
  defp color_profile_target("adobe-rgb"), do: {:ok, :adobe_rgb}
  defp color_profile_target("adobergb"), do: {:ok, :adobe_rgb}
  defp color_profile_target(_), do: :error

  defp parse_rotate([value], _segment) when value != "" do
    case Integer.parse(value) do
      {integer, ""} when rem(integer, 90) == 0 ->
        {:ok, [orientation: [rotate: normalize_rotation(integer)]]}

      _other ->
        {:error, {:invalid_rotate, value}}
    end
  end

  defp parse_rotate(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_flip([], _segment), do: {:ok, [orientation: [flip: :both]]}

  defp parse_flip([horizontal], _segment) when horizontal != "" do
    with {:ok, horizontal?} <- parse_boolean(horizontal) do
      {:ok, [orientation: [flip: flip_value(horizontal?, false)]]}
    end
  end

  defp parse_flip([horizontal, vertical], _segment) when horizontal != "" and vertical != "" do
    with {:ok, horizontal?} <- parse_boolean(horizontal),
         {:ok, vertical?} <- parse_boolean(vertical) do
      {:ok, [orientation: [flip: flip_value(horizontal?, vertical?)]]}
    end
  end

  defp parse_flip(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_gravity(["sm"], _segment), do: {:ok, [gravity: :sm]}

  defp parse_gravity(["fp", x, y], _segment) do
    with {:ok, x} <- parse_focal_coordinate(x),
         {:ok, y} <- parse_focal_coordinate(y) do
      {:ok,
       [gravity: {:fp, x, y}, gravity_x_offset: {:pixels, 0.0}, gravity_y_offset: {:pixels, 0.0}]}
    end
  end

  defp parse_gravity(["obj" | classes], _segment) do
    {:ok,
     [
       gravity: {:obj, classes},
       gravity_x_offset: {:pixels, 0.0},
       gravity_y_offset: {:pixels, 0.0}
     ]}
  end

  defp parse_gravity(["objw" | pairs], segment) when pairs != [] do
    with {:ok, weights} <- parse_object_weights(pairs, segment) do
      {:ok,
       [
         gravity: {:objw, weights},
         gravity_x_offset: {:pixels, 0.0},
         gravity_y_offset: {:pixels, 0.0}
       ]}
    end
  end

  defp parse_gravity([anchor], _segment) do
    with {:ok, anchor} <- parse_gravity_anchor(anchor) do
      {:ok, [gravity: anchor, gravity_x_offset: {:pixels, 0.0}, gravity_y_offset: {:pixels, 0.0}]}
    end
  end

  defp parse_gravity([anchor, x_offset, y_offset], _segment) do
    with {:ok, anchor} <- parse_gravity_anchor(anchor),
         {:ok, x_offset} <- parse_gravity_offset(x_offset),
         {:ok, y_offset} <- parse_gravity_offset(y_offset) do
      {:ok, [gravity: anchor, gravity_x_offset: x_offset, gravity_y_offset: y_offset]}
    end
  end

  defp parse_gravity(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_gravity_anchor(value) do
    case Map.fetch(@gravity_anchors, value) do
      {:ok, anchor} -> {:ok, anchor}
      :error -> {:error, {:invalid_gravity, value}}
    end
  end

  defp parse_gravity_offset(value) do
    case parse_float(value) do
      {:ok, float} when float == 0.0 -> {:ok, {:pixels, 0.0}}
      {:ok, float} when abs(float) >= 1.0 -> {:ok, {:pixels, float}}
      {:ok, float} -> {:ok, {:scale, float}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_focal_coordinate(value) do
    case parse_float(value) do
      {:ok, float} when float >= 0.0 and float <= 1.0 ->
        {:ok, float}

      {:ok, _float} ->
        {:error, {:invalid_gravity_coordinate, value}}

      {:error, _reason} ->
        {:error, {:invalid_gravity_coordinate, value}}
    end
  end

  defp normalize_rotation(value) do
    value
    |> rem(360)
    |> Kernel.+(360)
    |> rem(360)
  end

  defp flip_value(true, true), do: :both
  defp flip_value(true, false), do: :horizontal
  defp flip_value(false, true), do: :vertical
  defp flip_value(false, false), do: nil

  defp parse_crop_dimension(value) do
    case parse_number(value) do
      {:ok, number} when number == 0 ->
        {:ok, :auto}

      {:ok, number} when number > 0 and number < 1 ->
        {:ok, {:scale, number}}

      {:ok, number} when number >= 1 ->
        {:ok, {:pixels, number}}

      {:ok, _number} ->
        {:error, {:invalid_crop_dimension, value}}

      {:error, _reason} ->
        {:error, {:invalid_crop_dimension, value}}
    end
  end

  defp parse_positive_float(value) do
    case parse_float(value) do
      {:ok, float} when float > 0.0 -> {:ok, float}
      {:ok, _float} -> {:error, {:invalid_positive_float, value}}
      {:error, _reason} -> {:error, {:invalid_positive_float, value}}
    end
  end

  defp parse_non_negative_float(value) do
    case parse_float(value) do
      {:ok, float} when float >= 0.0 -> {:ok, float}
      {:ok, _float} -> {:error, {:invalid_non_negative_float, value}}
      {:error, _reason} -> {:error, {:invalid_non_negative_float, value}}
    end
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> {:error, {:invalid_non_negative_integer, value}}
    end
  end

  defp parse_number(value) do
    case Integer.parse(value) do
      {integer, ""} ->
        {:ok, integer}

      _other ->
        parse_float(value)
    end
  end

  defp parse_float(value) do
    case Float.parse(value) do
      {float, ""} -> {:ok, float}
      _other -> {:error, {:invalid_float, value}}
    end
  rescue
    # Float.parse/1 raises ArgumentError for very long digit strings (310+ digits)
    # because it delegates to :erlang.list_to_float which rejects them. This is an
    # untrusted-input boundary, so we degrade safely to {:error, _} rather than crash.
    ArgumentError -> {:error, {:invalid_float, value}}
  end

  defp parse_quality("0"), do: {:ok, :default}

  defp parse_quality(value) do
    case Integer.parse(value) do
      {integer, ""} when integer in 1..100 -> {:ok, {:quality, integer}}
      _other -> {:error, {:invalid_option, :quality, value}}
    end
  end
end
