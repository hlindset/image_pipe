defmodule ImagePipe.Parser.IIIF.Grammar do
  @moduledoc false

  @doc """
  Parses a IIIF region token into a typed value.

  Returns:
  - `{:ok, :full}`
  - `{:ok, :square}`
  - `{:ok, {:px, x, y, w, h}}` — pixel coordinates, w > 0 and h > 0
  - `{:ok, {:pct, xr, yr, wr, hr}}` — percent ratios `{:ratio, n, d}`, wr and hr numerators > 0
  - `{:error, {:invalid_region, raw}}`
  """
  @spec region(String.t()) ::
          {:ok, :full}
          | {:ok, :square}
          | {:ok, {:px, non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}}
          | {:ok,
             {:pct, {:ratio, integer(), integer()}, {:ratio, integer(), integer()},
              {:ratio, integer(), integer()}, {:ratio, integer(), integer()}}}
          | {:error, {:invalid_region, String.t()}}
  def region("full"), do: {:ok, :full}
  def region("square"), do: {:ok, :square}

  def region("pct:" <> rest = raw) do
    case parse_pct_quad(rest) do
      {:ok, [xr, yr, wr, hr]} ->
        if ratio_positive?(wr) and ratio_positive?(hr) do
          {:ok, {:pct, xr, yr, wr, hr}}
        else
          {:error, {:invalid_region, raw}}
        end

      :error ->
        {:error, {:invalid_region, raw}}
    end
  end

  def region(raw) do
    case parse_int_quad(raw) do
      {:ok, [x, y, w, h]} when x >= 0 and y >= 0 and w > 0 and h > 0 ->
        {:ok, {:px, x, y, w, h}}

      _ ->
        {:error, {:invalid_region, raw}}
    end
  end

  @doc """
  Parses a IIIF size token into a typed value.

  A leading `^` sets the upscaling flag (`up? = true`).

  Returns:
  - `{:ok, {:max, up?}}`
  - `{:ok, {:w, w, up?}}`
  - `{:ok, {:h, h, up?}}`
  - `{:ok, {:wh, w, h, up?}}`
  - `{:ok, {:confined, w, h, up?}}`
  - `{:ok, {:pct, {:ratio, n, d}, up?}}`
  - `{:error, {:invalid_size, raw}}`
  """
  @spec size(String.t()) ::
          {:ok, {:max, boolean()}}
          | {:ok, {:w, pos_integer(), boolean()}}
          | {:ok, {:h, pos_integer(), boolean()}}
          | {:ok, {:wh, pos_integer(), pos_integer(), boolean()}}
          | {:ok, {:confined, pos_integer(), pos_integer(), boolean()}}
          | {:ok, {:pct, {:ratio, integer(), integer()}, boolean()}}
          | {:error, {:invalid_size, String.t()}}
  def size(raw) do
    {up?, token} =
      case raw do
        "^" <> rest -> {true, rest}
        other -> {false, other}
      end

    parse_size_token(token, up?, raw)
  end

  @doc """
  Parses a IIIF rotation token: an optional leading `!` (mirror = reflection on
  the vertical axis, applied before rotation) followed by a clockwise angle in
  the closed interval `[0, 360]` (any floating point number). `360` folds to `0`
  and whole-number floats fold to integers (so right angles take the lossless
  rotate path).

  Returns `{:ok, {mirror :: boolean, angle :: number}}` or
  `{:error, {:invalid_rotation, raw}}`.
  """
  @spec rotation(String.t()) ::
          {:ok, {boolean(), number()}}
          | {:error, {:invalid_rotation, String.t()}}
  def rotation(raw) do
    {mirror, rest} =
      case raw do
        "!" <> rest -> {true, rest}
        rest -> {false, rest}
      end

    case parse_rotation_angle(rest) do
      {:ok, angle} -> {:ok, {mirror, angle}}
      :error -> {:error, {:invalid_rotation, raw}}
    end
  end

  # Strict remainder ("" only) like every other numeric token in this grammar:
  # rejects "45.", ".5", "45deg", "+45", leading/trailing whitespace, "" ("!"
  # alone). Float.parse handles ints too, so "90" -> 90.0 -> normalized to 90.
  # Note: Float.parse/1 accepts a leading "+", so we reject it explicitly.
  defp parse_rotation_angle("+" <> _), do: :error

  defp parse_rotation_angle(string) do
    case Float.parse(string) do
      {value, ""} when value >= 0.0 and value <= 360.0 -> {:ok, normalize_rotation(value)}
      _ -> :error
    end
  end

  defp normalize_rotation(360.0), do: 0

  defp normalize_rotation(value) do
    truncated = trunc(value)
    if value == truncated, do: truncated, else: value
  end

  @doc """
  Parses a IIIF quality token.

  Returns `{:ok, :default | :color | :gray | :bitonal}` or `{:error, {:invalid_quality, raw}}`.
  """
  @spec quality(String.t()) ::
          {:ok, :default | :color | :gray | :bitonal}
          | {:error, {:invalid_quality, String.t()}}
  def quality("default"), do: {:ok, :default}
  def quality("color"), do: {:ok, :color}
  def quality("gray"), do: {:ok, :gray}
  def quality("bitonal"), do: {:ok, :bitonal}
  def quality(raw), do: {:error, {:invalid_quality, raw}}

  @doc """
  Parses a IIIF format token.

  Returns `{:ok, :jpg | :png | :webp | :avif}` or `{:error, {:invalid_format, raw}}`.
  """
  @spec format(String.t()) ::
          {:ok, :jpg | :png | :webp | :avif}
          | {:error, {:invalid_format, String.t()}}
  def format("jpg"), do: {:ok, :jpg}
  def format("png"), do: {:ok, :png}
  def format("webp"), do: {:ok, :webp}
  def format("avif"), do: {:ok, :avif}
  def format(raw), do: {:error, {:invalid_format, raw}}

  @doc """
  Converts a decimal string to an exact integer ratio `{:ratio, num, den}`.

  This is a plain decimal parser — it does NOT divide by 100. The ratio represents
  the numeric value of the string directly. Callers (such as `region/1` and `size/1`)
  apply the /100 percent conversion themselves if needed.

  The ratio is unreduced. Integer strings `"k"` produce `{:ratio, k, 1}`.
  Decimal strings `"i.f"` produce `{:ratio, i * 10^len(f) + f_int, 10^len(f)}`.

  Returns `{:ok, {:ratio, num, den}}` or `:error`.
  """
  @spec pct_to_ratio(String.t()) :: {:ok, {:ratio, integer(), integer()}} | :error
  def pct_to_ratio(str) do
    case String.split(str, ".", parts: 2) do
      [integer_part] ->
        case Integer.parse(integer_part) do
          {n, ""} when n >= 0 -> {:ok, {:ratio, n, 1}}
          _ -> :error
        end

      [integer_part, fraction_part] ->
        with {i, ""} <- Integer.parse(integer_part),
             true <- i >= 0,
             true <- fraction_part != "",
             true <- decimal_digits?(fraction_part),
             {f, ""} <- Integer.parse(fraction_part) do
          scale = Integer.pow(10, byte_size(fraction_part))
          num = i * scale + f
          {:ok, {:ratio, num, scale}}
        else
          _ -> :error
        end
    end
  end

  # --- private helpers ---

  # Converts a pct_to_ratio result to a fraction of 1 (divides by 100).
  # "10.5" → pct_to_ratio = {105, 10} → pct_ratio = {105, 1000} (= 10.5%)
  defp pct_to_fraction(str) do
    case pct_to_ratio(str) do
      {:ok, {:ratio, num, den}} -> {:ok, {:ratio, num, den * 100}}
      :error -> :error
    end
  end

  defp parse_size_token("max", up?, _raw), do: {:ok, {:max, up?}}

  defp parse_size_token("pct:" <> rest, up?, raw) do
    case pct_to_fraction(rest) do
      {:ok, ratio} -> validate_pct_size(ratio, up?, raw)
      :error -> {:error, {:invalid_size, raw}}
    end
  end

  defp parse_size_token("!" <> rest, up?, raw) do
    case String.split(rest, ",") do
      [w_str, h_str] ->
        with {:ok, w} <- parse_positive_int(w_str),
             {:ok, h} <- parse_positive_int(h_str) do
          {:ok, {:confined, w, h, up?}}
        else
          _ -> {:error, {:invalid_size, raw}}
        end

      _ ->
        {:error, {:invalid_size, raw}}
    end
  end

  defp parse_size_token(token, up?, raw) do
    case String.split(token, ",") do
      [w_str, ""] ->
        case parse_positive_int(w_str) do
          {:ok, w} -> {:ok, {:w, w, up?}}
          _ -> {:error, {:invalid_size, raw}}
        end

      ["", h_str] ->
        case parse_positive_int(h_str) do
          {:ok, h} -> {:ok, {:h, h, up?}}
          _ -> {:error, {:invalid_size, raw}}
        end

      [w_str, h_str] ->
        with {:ok, w} <- parse_positive_int(w_str),
             {:ok, h} <- parse_positive_int(h_str) do
          {:ok, {:wh, w, h, up?}}
        else
          _ -> {:error, {:invalid_size, raw}}
        end

      _ ->
        {:error, {:invalid_size, raw}}
    end
  end

  # pct value must be > 0, and may exceed 100% (num > den) only when upscaling (^).
  defp validate_pct_size({:ratio, num, den} = ratio, up?, raw) do
    cond do
      num <= 0 -> {:error, {:invalid_size, raw}}
      not up? and num > den -> {:error, {:invalid_size, raw}}
      true -> {:ok, {:pct, ratio, up?}}
    end
  end

  defp parse_positive_int(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_non_neg_int(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_pct_quad(str) do
    case String.split(str, ",") do
      [_, _, _, _] = parts -> reduce_quad(parts, &pct_to_fraction/1)
      _ -> :error
    end
  end

  defp parse_int_quad(str) do
    case String.split(str, ",") do
      [_, _, _, _] = parts -> reduce_quad(parts, &parse_non_neg_int/1)
      _ -> :error
    end
  end

  # Parse each of four comma-separated parts via parse_fun (returns {:ok, v} | :error),
  # collecting into {:ok, [v1, v2, v3, v4]} or halting at the first :error.
  defp reduce_quad(parts, parse_fun) do
    parts
    |> Enum.reduce_while([], fn part, acc ->
      case parse_fun.(part) do
        {:ok, value} -> {:cont, [value | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      reversed -> {:ok, Enum.reverse(reversed)}
    end
  end

  defp ratio_positive?({:ratio, num, _den}), do: num > 0

  defp decimal_digits?(value) do
    value
    |> String.to_charlist()
    |> Enum.all?(&(&1 in ?0..?9))
  end
end
