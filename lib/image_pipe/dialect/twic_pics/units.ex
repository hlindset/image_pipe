defmodule ImagePipe.Dialect.TwicPics.Units do
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
  # ex_dna:disable-for-next-line
  def dimension_length(value), do: parse_length(value, :positive)

  # Position length: zero-based, non-negative.
  @spec position_length(String.t()) :: {:ok, measure()} | {:error, term()}
  # ex_dna:disable-for-next-line
  def position_length(value), do: parse_length(value, :non_negative)

  # ex_dna:disable-for-next-line
  defp parse_length(value, sign) when is_binary(value) do
    {expr, unit_denominator} =
      cond do
        String.ends_with?(value, "p") -> {String.replace_suffix(value, "p", ""), 100}
        String.ends_with?(value, "s") -> {String.replace_suffix(value, "s", ""), 1}
        true -> {value, nil}
      end

    with {:ok, {num, den}} <- eval_number(expr),
         :ok <- check_sign(num, sign) do
      {:ok, build_measure(num, den, unit_denominator, sign)}
    else
      _ -> {:error, {:invalid_length, value}}
    end
  end

  # ex_dna:disable-for-next-line
  defp check_sign(num, :positive) when num > 0, do: :ok
  defp check_sign(num, :non_negative) when num >= 0, do: :ok
  defp check_sign(_num, _sign), do: :error

  # Bare pixels: absolute, fold to a concrete rounded integer.
  # ex_dna:disable-for-next-line
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
  # ex_dna:disable-for-next-line
  defp round_half_up(num, den), do: div(2 * num + den, 2 * den)

  @spec size(String.t()) :: {:ok, {measure() | :auto, measure() | :auto}} | {:error, term()}
  # ex_dna:disable-for-next-line
  def size(value), do: pair(value, :auto)

  @spec crop_size(String.t()) ::
          {:ok, {measure() | :full_axis, measure() | :full_axis}} | {:error, term()}
  # ex_dna:disable-for-next-line
  def crop_size(value), do: pair(value, :full_axis)

  # ex_dna:disable-for-next-line
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

  # ex_dna:disable-for-next-line
  defp dimension("-", omitted), do: {:ok, omitted}
  defp dimension("", omitted), do: {:ok, omitted}
  defp dimension(value, _omitted), do: dimension_length(value)

  # Ratios accept two strictly-positive numbers — integer, decimal, or expression,
  # e.g. `16:9`, `1.5:2`, `(5*2):3`. Each side folds to an exact rational and is
  # combined into a `{:ratio, n, d}` of positive integers (so it maps cleanly onto
  # the integer aspect-ratio the crop operation expects). No pixel rounding: a
  # ratio is already exact.
  @spec ratio(String.t()) :: {:ok, {:ratio, pos_integer(), pos_integer()}} | {:error, term()}
  # ex_dna:disable-for-next-line
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
  # ex_dna:disable-for-next-line
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
  # ex_dna:disable-for-next-line
  defp number([{:num, rational}]), do: {:ok, rational}

  defp number([:lparen | _] = tokens) do
    case factor(tokens) do
      {:ok, rational, []} -> {:ok, rational}
      _ -> :error
    end
  end

  defp number(_tokens), do: :error

  # ex_dna:disable-for-next-line
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

  # ex_dna:disable-for-next-line
  defp take_number(<<c, rest::binary>>, acc) when c in ?0..?9 or c == ?.,
    do: take_number(rest, <<acc::binary, c>>)

  # A JSON exponent suffix begins the moment an `e`/`E` follows the mantissa; the
  # optional sign and digits belong to this number token (so `1e-2` is one token,
  # not `1e` minus `2`). Well-formedness is judged by `decimal_to_rational`.
  defp take_number(<<e, rest::binary>>, acc) when e in [?e, ?E],
    do: take_exponent(rest, <<acc::binary, e>>)

  defp take_number(rest, acc), do: {acc, rest}

  # ex_dna:disable-for-next-line
  defp take_exponent(<<s, rest::binary>>, acc) when s in [?+, ?-],
    do: take_exponent_digits(rest, <<acc::binary, s>>)

  defp take_exponent(rest, acc), do: take_exponent_digits(rest, acc)

  # ex_dna:disable-for-next-line
  defp take_exponent_digits(<<d, rest::binary>>, acc) when d in ?0..?9,
    do: take_exponent_digits(rest, <<acc::binary, d>>)

  defp take_exponent_digits(rest, acc), do: {acc, rest}

  # JSON number literal → exact `{integer, pos_integer}` (`"7.2"` → `{72, 10}`,
  # `"16"` → `{16, 1}`, `"0.05"` → `{5, 100}`, `"1e2"` → `{100, 1}`, `"5e-1"` →
  # `{5, 10}`). The mantissa follows the JSON grammar: the integer part is `0` or
  # a no-leading-zero run, and a dot (if present) needs a non-empty fraction. An
  # optional `[eE][+-]?[0-9]+` exponent folds in as `mantissa × 10^exp` (the
  # exponent may carry a leading zero — `1e02` = `1e2`). Rejects `.5`, `5.`,
  # `00.5`, `01`, multi-dot `1.2.3`, and a malformed/empty exponent — live
  # TwicPics 404s them.
  # ex_dna:disable-for-next-line
  defp decimal_to_rational(literal) do
    case String.split(literal, ["e", "E"], parts: 2) do
      [mantissa] ->
        mantissa_rational(mantissa)

      [mantissa, exponent] ->
        with {:ok, rational} <- mantissa_rational(mantissa),
             {:ok, exp} <- exponent_value(exponent),
             do: {:ok, apply_exponent(rational, exp)}
    end
  end

  # ex_dna:disable-for-next-line
  defp mantissa_rational(mantissa) do
    case String.split(mantissa, ".") do
      [whole] ->
        with :ok <- valid_int_part(whole), do: scaled_rational(whole, "")

      [whole, frac] ->
        with :ok <- valid_int_part(whole),
             :ok <- valid_frac_part(frac),
             do: scaled_rational(whole, frac)

      _ ->
        :error
    end
  end

  # `[+-]?` then one or more digits (leading zeros allowed). Empty / sign-only
  # rejects (`1e`, `1e+`).
  # ex_dna:disable-for-next-line
  defp exponent_value("+" <> digits), do: exponent_digits(digits)
  defp exponent_value("-" <> digits), do: with({:ok, n} <- exponent_digits(digits), do: {:ok, -n})
  defp exponent_value(digits), do: exponent_digits(digits)

  # ex_dna:disable-for-next-line
  defp exponent_digits(""), do: :error

  defp exponent_digits(digits) do
    case Integer.parse(digits) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  # ex_dna:disable-for-next-line
  defp apply_exponent({n, d}, exp) when exp >= 0, do: {n * Integer.pow(10, exp), d}
  defp apply_exponent({n, d}, exp), do: {n, d * Integer.pow(10, -exp)}

  # Tokenizer guarantees digit-only parts; these enforce the JSON shape on top.
  # ex_dna:disable-for-next-line
  defp valid_int_part("0"), do: :ok
  defp valid_int_part(<<d, _::binary>>) when d in ?1..?9, do: :ok
  defp valid_int_part(_), do: :error

  # ex_dna:disable-for-next-line
  defp valid_frac_part(""), do: :error
  defp valid_frac_part(_frac), do: :ok

  # ex_dna:disable-for-next-line
  defp scaled_rational(whole, frac) do
    case Integer.parse(whole <> frac) do
      {n, ""} -> {:ok, {n, Integer.pow(10, byte_size(frac))}}
      _ -> :error
    end
  end

  # Recursive descent: expr := term (('+'|'-') term)* ; term := factor
  # (('*'|'/') factor)* ; factor := '-' factor | '(' expr ')' | number.
  # ex_dna:disable-for-next-line
  defp expr(tokens) do
    with {:ok, left, rest} <- term(tokens), do: expr_rest(left, rest)
  end

  # ex_dna:disable-for-next-line
  defp expr_rest(left, [op | rest]) when op in [:add, :sub] do
    with {:ok, right, rest} <- term(rest), do: expr_rest(apply_op(op, left, right), rest)
  end

  defp expr_rest(left, rest), do: {:ok, left, rest}

  # ex_dna:disable-for-next-line
  defp term(tokens) do
    with {:ok, left, rest} <- factor(tokens), do: term_rest(left, rest)
  end

  # ex_dna:disable-for-next-line
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

  # ex_dna:disable-for-next-line
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

  # ex_dna:disable-for-next-line
  defp apply_op(:add, {a, b}, {c, d}), do: {a * d + c * b, b * d}
  defp apply_op(:sub, {a, b}, {c, d}), do: {a * d - c * b, b * d}
  defp apply_op(:mul, {a, b}, {c, d}), do: {a * c, b * d}
  defp apply_op(:div, _ab, {0, _d}), do: :error
  defp apply_op(:div, {a, b}, {c, d}), do: {a * d, b * c}

  # Reduce and force a positive denominator.
  # ex_dna:disable-for-next-line
  defp normalize({num, den}) do
    gcd = max(1, Integer.gcd(num, den))
    {n, d} = {div(num, gcd), div(den, gcd)}
    if d < 0, do: {-n, -d}, else: {n, d}
  end

  @spec coordinates(String.t()) :: {:ok, {measure(), measure()}} | {:error, term()}
  # ex_dna:disable-for-next-line
  def coordinates(value) do
    with [x, y] <- String.split(value, "x", parts: 2),
         {:ok, x} <- position_length(x),
         {:ok, y} <- position_length(y) do
      {:ok, {x, y}}
    else
      _ -> {:error, {:invalid_coordinates, value}}
    end
  end

  @dialect_anchors Map.new([
                     {"top", {:anchor, :center, :top}},
                     {"bottom", {:anchor, :center, :bottom}},
                     {"left", {:anchor, :left, :center}},
                     {"right", {:anchor, :right, :center}},
                     {"top-left", {:anchor, :left, :top}},
                     {"top-right", {:anchor, :right, :top}},
                     {"bottom-left", {:anchor, :left, :bottom}},
                     {"bottom-right", {:anchor, :right, :bottom}}
                   ])

  @spec anchor(String.t()) :: {:ok, {:anchor, atom(), atom()}} | {:error, term()}
  # ex_dna:disable-for-next-line
  def anchor(value) do
    case Map.fetch(@dialect_anchors, value) do
      {:ok, guide} -> {:ok, guide}
      :error -> {:error, {:invalid_anchor, value}}
    end
  end
end
