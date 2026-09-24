defmodule ImagePipe.Plan.Builder.Values do
  @moduledoc false

  alias ImagePipe.Plan.Builder.Options
  alias ImagePipe.Plan.Color

  @max_axis 2_147_483_647

  def cast(value, kind) do
    case normalize(value, kind) do
      {:ok, _value} = ok -> ok
      _invalid -> {:error, "invalid #{kind} value"}
    end
  end

  defp normalize(value, :preset_name) when is_binary(value) do
    case Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, value) do
      true -> {:ok, value}
      false -> :error
    end
  end

  defp normalize(value, :positive) when is_number(value) and value > 0, do: float(value)
  defp normalize(value, :nonnegative) when is_number(value) and value >= 0, do: float(value)

  defp normalize(value, :fraction) when is_number(value) and value >= 0 and value <= 1,
    do: float(value)

  defp normalize(value, :rotate) when is_number(value) and value >= 0 and value <= 360 do
    case value == trunc(value) do
      true -> {:ok, rem(trunc(value), 360)}
      false -> {:ok, value}
    end
  end

  defp normalize(value, :angle) when is_number(value) do
    with {:ok, value} <- float(value) do
      angle = :math.fmod(value, 360.0)

      case angle < 0 do
        true -> {:ok, angle + 360.0}
        false -> {:ok, angle}
      end
    end
  end

  defp normalize({x, y}, :zoom), do: pair(x, y, :positive)
  defp normalize(value, :zoom), do: pair(value, value, :positive)
  defp normalize({x, y}, :focus), do: pair(x, y, :fraction)
  defp normalize({x, y}, :offset), do: pair(x, y, :offset_length)
  defp normalize({width, height}, :crop), do: pair(width, height, :positive_length)

  defp normalize({x, y, width, height}, :region) do
    with {:ok, {x, y}} <- pair(x, y, :length),
         {:ok, {width, height}} <- pair(width, height, :positive_length) do
      {:ok, {x, y, width, height}}
    end
  end

  defp normalize({unit, value}, :length) when unit in [:px, :pct] and is_number(value),
    do: {:ok, {unit, value}}

  defp normalize(value, :length) when is_number(value), do: {:ok, {:px, value}}

  defp normalize(value, :positive_length) do
    with {:ok, {_unit, size} = length} <- normalize(value, :length),
         true <- size > 0 do
      {:ok, length}
    end
  end

  defp normalize(value, :offset_length) do
    with {:ok, {_unit, size} = length} <- normalize(value, :length),
         {:ok, _scaled} <- float_scaled(size, @max_axis) do
      {:ok, length}
    end
  end

  defp normalize({numerator, denominator}, :ratio)
       when is_integer(numerator) and numerator > 0 and is_integer(denominator) and
              denominator > 0 do
    ratio(numerator, denominator)
  end

  defp normalize({r, g, b}, :color) do
    with {:ok, color} <- Color.rgb(r, g, b), do: {:ok, color.channels}
  end

  defp normalize("#" <> hex, :color), do: hex_color(hex)

  defp normalize(value, :color) when is_binary(value) do
    case hex_color(value) do
      {:ok, _color} = ok -> ok
      {:error, _reason} -> Color.rgb_name(value)
    end
  end

  defp normalize(:auto, :trim), do: {:ok, :auto}

  defp normalize({color, tolerance}, :trim) do
    with {:ok, color} <- normalize(color, :color),
         {:ok, _finite} <- normalize(tolerance, :nonnegative) do
      {:ok, {color, tolerance}}
    end
  end

  defp normalize(color, :trim) do
    with {:ok, color} <- normalize(color, :color), do: {:ok, {color, nil}}
  end

  defp normalize({color, alpha}, :background) do
    with {:ok, color} <- normalize(color, :color),
         {:ok, alpha} <- normalize(alpha, :fraction) do
      {:ok, {color, alpha}}
    end
  end

  defp normalize(color, :background) do
    with {:ok, color} <- normalize(color, :color), do: {:ok, {color, nil}}
  end

  defp normalize(value, :padding) when is_integer(value) and value >= 0,
    do: {:ok, {value, value, value, value}}

  defp normalize({vertical, horizontal}, :padding),
    do: normalize({vertical, horizontal, vertical, horizontal}, :padding)

  defp normalize({top, horizontal, bottom}, :padding),
    do: normalize({top, horizontal, bottom, horizontal}, :padding)

  defp normalize({top, right, bottom, left} = padding, :padding) do
    case Enum.all?([top, right, bottom, left], &(is_integer(&1) and &1 >= 0)) do
      true -> {:ok, padding}
      false -> :error
    end
  end

  defp normalize(value, :path_token) when is_binary(value) do
    case Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, value) do
      true -> {:ok, value}
      false -> :error
    end
  end

  defp normalize(value, effect)
       when effect in [:monochrome, :duotone, :colorize, :gradient, :progressive_blur] do
    with {:ok, fields} <- Options.validate(value, effect_schema(effect)),
         do: {:ok, Map.new(fields)}
  end

  defp normalize(:all, :detect), do: {:ok, [{:all, 1.0}]}
  defp normalize(classes, :detect) when is_list(classes) and classes != [], do: detect(classes)
  defp normalize(_value, _kind), do: :error

  defp pair(x, y, kind) do
    with {:ok, x} <- normalize(x, kind), {:ok, y} <- normalize(y, kind), do: {:ok, {x, y}}
  end

  defp float(value), do: float_scaled(value, 1)

  defp float_scaled(value, scale) do
    {:ok, value * 1.0 * scale}
  rescue
    ArithmeticError -> :error
  end

  defp ratio(numerator, denominator) do
    forward = numerator / denominator
    reverse = denominator / numerator

    with true <- forward > 0 and reverse > 0,
         {:ok, _forward} <- float_scaled(forward, @max_axis),
         {:ok, _reverse} <- float_scaled(reverse, @max_axis) do
      gcd = Integer.gcd(numerator, denominator)
      {:ok, {:ratio, div(numerator, gcd), div(denominator, gcd)}}
    end
  rescue
    ArithmeticError -> :error
  end

  defp hex_color(hex) do
    with {:ok, color} <- Color.rgb_hex(hex), do: {:ok, color.channels}
  end

  defp field(kind, opts), do: [type: {:custom, __MODULE__, :cast, [kind]}] ++ opts

  defp effect_schema(:monochrome),
    do: [
      intensity: field(:fraction, required: true),
      color: field(:color, default: {179, 179, 179})
    ]

  defp effect_schema(:duotone),
    do: [
      intensity: field(:fraction, required: true),
      shadow: field(:color, default: {0, 0, 0}),
      highlight: field(:color, default: {255, 255, 255})
    ]

  defp effect_schema(:colorize),
    do: [
      opacity: field(:fraction, required: true),
      color: field(:color, required: true),
      keep_alpha: [type: :boolean, default: false]
    ]

  defp effect_schema(:gradient),
    do: [
      opacity: field(:fraction, required: true),
      color: field(:color, required: true),
      angle: field(:angle, default: 0.0),
      start: field(:fraction, default: 0.0),
      stop: field(:fraction, default: 1.0)
    ]

  defp effect_schema(:progressive_blur),
    do: [
      sigma: field(:nonnegative, required: true),
      angle: field(:angle, default: 0.0),
      start: field(:fraction, default: 0.0),
      stop: field(:fraction, default: 1.0)
    ]

  defp detect(classes) do
    with {:ok, pairs} <- detect_pairs(classes),
         names = Enum.map(pairs, &elem(&1, 0)),
         true <- Enum.uniq(names) == names do
      {:ok, pairs}
    end
  end

  defp detect_pairs(classes) do
    Enum.reduce_while(classes, {:ok, []}, fn item, {:ok, pairs} ->
      case detect_pair(item) do
        {:ok, pair} -> {:cont, {:ok, [pair | pairs]}}
        _invalid -> {:halt, :error}
      end
    end)
  end

  defp detect_pair({name, weight}) do
    with true <- valid_class?(name),
         {:ok, weight} <- normalize(weight, :positive),
         true <- weight <= 1_000_000 do
      {:ok, {name, weight}}
    end
  end

  defp detect_pair(name), do: detect_pair({name, 1.0})
  defp valid_class?(:all), do: true
  defp valid_class?("all"), do: false

  defp valid_class?(name) when is_binary(name),
    do: Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, name)

  defp valid_class?(_name), do: false
end
