defmodule ImagePipe.Parser.TwicPics.Units do
  @moduledoc false

  @type measure :: {:px, non_neg_integer()} | {:ratio, non_neg_integer(), pos_integer()}

  # TwicPics lengths have only two unit suffixes: `p` (percent) and `s` (scale).
  # Pixels are bare numbers — there is NO `px` unit. A `px` substring only ever
  # appears inside a Size/Coordinates token (e.g. `10px150`), where the caller
  # splits on `x` first (`10p` × `150` = 10% × 150px), so a length parser never
  # receives a `px`-suffixed token from real input.
  #
  # Every numeric leaf (`length`, `size`, `coordinates`, `crop size`, `ratio`) is
  # a TwicPics `number`: a decimal literal OR a parenthesized expression over
  # `+ - * /` with nesting (`(100/2)`, `5*(7+2)/3`, `100/(4/2)`). `eval_number/1`
  # folds it to an exact rational `{num, den}` at parse time, so percent/scale
  # suffixes stay exact (`{:ratio, n, d}`, no float rounding): percent divides by
  # 100, scale is the raw fraction.
  #
  # Bare pixels are absolute, so they collapse to a concrete `{:px, n}` at parse:
  # the exact value is rounded half away from zero (matching the live TwicPics
  # API — `(7/2)` → 4px, `7.2` → 7px, `2.5` → 3px). The sign/zero rule is checked
  # against the exact value, then the rounded dimension is clamped to ≥ 1 — so a
  # strictly-positive value that rounds down to zero (`(1/4)` = 0.25) becomes 1px
  # rather than being rejected, while an exact zero/negative (`(2-2)`, `(1-2)`) is
  # rejected. Positions round the same way but allow zero and apply no clamp.

  # Dimension length: strictly positive.
  @spec dimension_length(String.t()) :: {:ok, measure()} | {:error, term()}
  def dimension_length(value), do: parse_length(value, :positive)

  # Position length: zero-based, non-negative.
  @spec position_length(String.t()) :: {:ok, measure()} | {:error, term()}
  def position_length(value), do: parse_length(value, :non_negative)

  defp parse_length(value, sign) when is_binary(value) do
    {expr, unit_denominator} =
      cond do
        String.ends_with?(value, "p") -> {String.trim_trailing(value, "p"), 100}
        String.ends_with?(value, "s") -> {String.trim_trailing(value, "s"), 1}
        true -> {value, nil}
      end

    with {:ok, {num, den}} <- eval_number(expr),
         :ok <- check_sign(num, sign) do
      {:ok, build_measure(num, den, unit_denominator, sign)}
    else
      _ -> {:error, {:invalid_length, value}}
    end
  end

  defp check_sign(num, :positive) when num > 0, do: :ok
  defp check_sign(num, :non_negative) when num >= 0, do: :ok
  defp check_sign(_num, _sign), do: :error

  # Bare pixels: absolute, fold to a concrete rounded integer.
  defp build_measure(num, den, nil, :positive), do: {:px, max(1, round_half_up(num, den))}
  defp build_measure(num, den, nil, :non_negative), do: {:px, round_half_up(num, den)}

  # Percent/scale: stay an exact relative ratio, resolved against the running axis
  # at execution time.
  defp build_measure(num, den, unit_denominator, _sign) do
    denominator = den * unit_denominator
    gcd = max(1, Integer.gcd(num, denominator))
    {:ratio, div(num, gcd), div(denominator, gcd)}
  end

  # Round a non-negative rational `num/den` half away from zero (den > 0).
  defp round_half_up(num, den), do: div(2 * num + den, 2 * den)

  @spec size(String.t()) :: {:ok, {measure() | :auto, measure() | :auto}} | {:error, term()}
  def size(value), do: pair(value, :auto)

  @spec crop_size(String.t()) ::
          {:ok, {measure() | :full_axis, measure() | :full_axis}} | {:error, term()}
  def crop_size(value), do: pair(value, :full_axis)

  defp pair(value, omitted) do
    case String.split(value, "x", parts: 2) do
      [single] ->
        with {:ok, w} <- dimension(single, omitted), do: {:ok, {w, omitted}}

      [w, h] ->
        with {:ok, w} <- dimension(w, omitted),
             {:ok, h} <- dimension(h, omitted) do
          {:ok, {w, h}}
        end
    end
  end

  defp dimension("-", omitted), do: {:ok, omitted}
  defp dimension("", omitted), do: {:ok, omitted}
  defp dimension(value, _omitted), do: dimension_length(value)

  # Ratios accept two strictly-positive numbers — integer, decimal, or expression,
  # e.g. `16:9`, `1.5:2`, `(5*2):3`. Each side folds to an exact rational and is
  # combined into a `{:ratio, n, d}` of positive integers (so it maps cleanly onto
  # the integer aspect-ratio the crop operation expects). No pixel rounding: a
  # ratio is already exact.
  @spec ratio(String.t()) :: {:ok, {:ratio, pos_integer(), pos_integer()}} | {:error, term()}
  def ratio(value) do
    with [w, h] <- String.split(value, ":", parts: 2),
         {:ok, {nw, dw}} <- eval_number(w),
         {:ok, {nh, dh}} <- eval_number(h),
         true <- nw > 0 and nh > 0 do
      numerator = nw * dh
      denominator = dw * nh
      gcd = Integer.gcd(numerator, denominator)
      {:ok, {:ratio, div(numerator, gcd), div(denominator, gcd)}}
    else
      _ -> {:error, {:invalid_ratio, value}}
    end
  end

  # --- number expression evaluator ----------------------------------------
  #
  # A TwicPics `number` is a decimal literal OR a fully *parenthesized* expression
  # over `+ - * /` (normal precedence, nesting, unary +/-): `50`, `7.2`, `(1/3)`,
  # `(5*(7+2)/3)`, `(+5)`. A bare top-level operator (`5*3`) is rejected — live
  # TwicPics 404s it; the operators must be wrapped (`(5*3)`). That outer-paren
  # requirement is also what lets the chain splitter treat a top-level `/` as a
  # segment separator and an in-paren `/` as division (see Manipulation).
  #
  # Folds to an exact rational `{num, den}` with `den > 0`; `num` may be zero or
  # negative (the consuming parameter applies its own sign/zero rule). Returns
  # `:error` on malformed input, an unconsumed tail, or division by zero.
  @spec eval_number(String.t()) :: {:ok, {integer(), pos_integer()}} | :error
  defp eval_number(string) do
    with {:ok, tokens} <- tokenize(string, []),
         {:ok, rational} <- number(tokens) do
      {:ok, normalize(rational)}
    else
      _ -> :error
    end
  end

  # Top-level: a single decimal literal, or one parenthesized expression that
  # consumes every token. No bare top-level operators.
  defp number([{:num, rational}]), do: {:ok, rational}

  defp number([:lparen | _] = tokens) do
    case factor(tokens) do
      {:ok, rational, []} -> {:ok, rational}
      _ -> :error
    end
  end

  defp number(_tokens), do: :error

  defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}
  defp tokenize(<<?+, rest::binary>>, acc), do: tokenize(rest, [:add | acc])
  defp tokenize(<<?-, rest::binary>>, acc), do: tokenize(rest, [:sub | acc])
  defp tokenize(<<?*, rest::binary>>, acc), do: tokenize(rest, [:mul | acc])
  defp tokenize(<<?/, rest::binary>>, acc), do: tokenize(rest, [:div | acc])
  defp tokenize(<<?(, rest::binary>>, acc), do: tokenize(rest, [:lparen | acc])
  defp tokenize(<<?), rest::binary>>, acc), do: tokenize(rest, [:rparen | acc])

  defp tokenize(<<c, _::binary>> = bin, acc) when c in ?0..?9 or c == ?. do
    {literal, rest} = take_number(bin, "")

    case decimal_to_rational(literal) do
      {:ok, rational} -> tokenize(rest, [{:num, rational} | acc])
      :error -> :error
    end
  end

  defp tokenize(_other, _acc), do: :error

  defp take_number(<<c, rest::binary>>, acc) when c in ?0..?9 or c == ?.,
    do: take_number(rest, <<acc::binary, c>>)

  defp take_number(rest, acc), do: {acc, rest}

  # Decimal literal → exact `{integer, pos_integer}` (`"7.2"` → `{72, 10}`,
  # `".5"` → `{5, 10}`, `"16"` → `{16, 1}`). Allows zero; rejects multiple dots
  # and empty/non-numeric.
  defp decimal_to_rational(literal) do
    case String.split(literal, ".") do
      [whole] -> scaled_rational(whole, "")
      [whole, frac] -> scaled_rational(whole, frac)
      _ -> :error
    end
  end

  defp scaled_rational(whole, frac) do
    case Integer.parse(whole <> frac) do
      {n, ""} -> {:ok, {n, Integer.pow(10, byte_size(frac))}}
      _ -> :error
    end
  end

  # Recursive descent: expr := term (('+'|'-') term)* ; term := factor
  # (('*'|'/') factor)* ; factor := '-' factor | '(' expr ')' | number.
  defp expr(tokens) do
    with {:ok, left, rest} <- term(tokens), do: expr_rest(left, rest)
  end

  defp expr_rest(left, [op | rest]) when op in [:add, :sub] do
    with {:ok, right, rest} <- term(rest), do: expr_rest(apply_op(op, left, right), rest)
  end

  defp expr_rest(left, rest), do: {:ok, left, rest}

  defp term(tokens) do
    with {:ok, left, rest} <- factor(tokens), do: term_rest(left, rest)
  end

  defp term_rest(left, [op | rest]) when op in [:mul, :div] do
    case factor(rest) do
      {:ok, right, rest} ->
        case apply_op(op, left, right) do
          :error -> :error
          folded -> term_rest(folded, rest)
        end

      _ ->
        :error
    end
  end

  defp term_rest(left, rest), do: {:ok, left, rest}

  defp factor([:add | rest]), do: factor(rest)

  defp factor([:sub | rest]) do
    with {:ok, {n, d}, rest} <- factor(rest), do: {:ok, {-n, d}, rest}
  end

  defp factor([:lparen | rest]) do
    case expr(rest) do
      {:ok, value, [:rparen | rest]} -> {:ok, value, rest}
      _ -> :error
    end
  end

  defp factor([{:num, rational} | rest]), do: {:ok, rational, rest}
  defp factor(_tokens), do: :error

  defp apply_op(:add, {a, b}, {c, d}), do: {a * d + c * b, b * d}
  defp apply_op(:sub, {a, b}, {c, d}), do: {a * d - c * b, b * d}
  defp apply_op(:mul, {a, b}, {c, d}), do: {a * c, b * d}
  defp apply_op(:div, _ab, {0, _d}), do: :error
  defp apply_op(:div, {a, b}, {c, d}), do: {a * d, b * c}

  # Reduce and force a positive denominator.
  defp normalize({num, den}) do
    gcd = max(1, Integer.gcd(num, den))
    {n, d} = {div(num, gcd), div(den, gcd)}
    if d < 0, do: {-n, -d}, else: {n, d}
  end

  @spec coordinates(String.t()) :: {:ok, {measure(), measure()}} | {:error, term()}
  def coordinates(value) do
    with [x, y] <- String.split(value, "x", parts: 2),
         {:ok, x} <- position_length(x),
         {:ok, y} <- position_length(y) do
      {:ok, {x, y}}
    else
      _ -> {:error, {:invalid_coordinates, value}}
    end
  end

  @anchors %{
    "top" => {:anchor, :center, :top},
    "bottom" => {:anchor, :center, :bottom},
    "left" => {:anchor, :left, :center},
    "right" => {:anchor, :right, :center},
    "top-left" => {:anchor, :left, :top},
    "top-right" => {:anchor, :right, :top},
    "bottom-left" => {:anchor, :left, :bottom},
    "bottom-right" => {:anchor, :right, :bottom}
  }

  @spec anchor(String.t()) :: {:ok, {:anchor, atom(), atom()}} | {:error, term()}
  def anchor(value) do
    case Map.fetch(@anchors, value) do
      {:ok, guide} -> {:ok, guide}
      :error -> {:error, {:invalid_anchor, value}}
    end
  end
end
