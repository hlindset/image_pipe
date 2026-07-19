defmodule ImagePipe.Dialect.TwicPics.Shadow do
  @moduledoc false
  # Narrow, upstream-proven resize shadowing.
  #
  # The TwicPics transformations reference states: "Since TwicPics will optimize
  # the manipulation, be aware that a transformation may shadow what came before
  # it. For instance `resize=50p/resize=340` will result in an image that is 340
  # pixel-wide: TwicPics will simply ignore the first resize."
  # (https://www.twicpics.com/docs/reference/transformations)
  #
  # This is NOT a general last-wins rule (manipulations otherwise "are always
  # applied in order"). An *absolute* resize — no relative (`p`/`s`) axis — fully
  # determines its output frame independently of the running dimensions, so an
  # immediately-preceding *aspect-preserving relative* resize has no observable
  # effect and is dropped. Everything narrower stays literal:
  #
  #   - a later relative resize composes against the running frame and stays
  #     (`resize=340/resize=50p` -> 170);
  #   - an intervening manipulation keeps the earlier resize observable;
  #   - a cover/crop/canvas step is not a plain resize and never shadows;
  #   - an aspect-*changing* earlier resize is not proven unobservable upstream,
  #     so it stays.
  #
  # The rewrite derives an execution stream only. Identity retains the literal
  # authored steps, so equivalent chains may occupy separate cache entries.

  alias ImagePipe.Plan.Operation.Resize

  @doc """
  Derive the execution step stream from the literal authored steps by dropping
  resizes that a later resize provably shadows.
  """
  @spec execution_steps([term()]) :: [term()]
  def execution_steps(steps) when is_list(steps) do
    steps
    |> Enum.reverse()
    |> Enum.reduce([], &keep_or_drop/2)
  end

  defp keep_or_drop(step, [next | _] = kept) do
    if shadows?(step, next), do: kept, else: [step | kept]
  end

  defp keep_or_drop(step, []), do: [step]

  defp shadows?(earlier, later),
    do: aspect_preserving_relative_resize?(earlier) and absolute_resize?(later)

  defp aspect_preserving_relative_resize?({:operation, %Resize{mode: :fit} = resize}) do
    (relative_axis?(resize.width) and resize.height == :auto) or
      (resize.width == :auto and relative_axis?(resize.height))
  end

  defp aspect_preserving_relative_resize?(_step), do: false

  defp absolute_resize?({:operation, %Resize{mode: mode} = resize}) when mode in [:fit, :stretch],
    do: not relative_axis?(resize.width) and not relative_axis?(resize.height)

  defp absolute_resize?(_step), do: false

  defp relative_axis?({:ratio, _numerator, _denominator}), do: true
  defp relative_axis?(_axis), do: false
end
