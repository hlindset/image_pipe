defmodule ImagePipe.Transform.Executor.Step do
  # Runs one operation for the executor.
  #
  # The table below gives each operation struct its stage name (the
  # `[:transform, :operation]` span's `:operation`) and its function. The
  # executor may name a step after the request option it serves instead, such
  # as `:padding` for an `ExtendCanvas` or `:monochrome` for a `Duotone`.
  # `random_access?/1` is the materialization policy: an operation that reads
  # pixels out of row order runs after the image is copied to memory, and
  # everything else streams. Classify an operation as streaming only after
  # `test/image_pipe/transform/sequential_access_test.exs` proves it.
  @moduledoc false

  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.Operation.Background
  alias ImagePipe.Transform.Operation.Bitonal
  alias ImagePipe.Transform.Operation.Blur
  alias ImagePipe.Transform.Operation.Brightness
  alias ImagePipe.Transform.Operation.Colorize
  alias ImagePipe.Transform.Operation.Contrast
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Duotone
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Gradient
  alias ImagePipe.Transform.Operation.Gray
  alias ImagePipe.Transform.Operation.Pixelate
  alias ImagePipe.Transform.Operation.ProgressiveBlur
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.Operation.Rotate
  alias ImagePipe.Transform.Operation.Saturation
  alias ImagePipe.Transform.Operation.Sharpen
  alias ImagePipe.Transform.Operation.Trim
  alias ImagePipe.Transform.Operation.Watermark
  alias ImagePipe.Transform.State
  alias ImagePipe.Transform.WorkLimits

  defp step(%Background{}), do: {:background, &Background.execute/2}
  defp step(%Bitonal{}), do: {:bitonal, &Bitonal.execute/2}
  defp step(%Blur{}), do: {:blur, &Blur.execute/2}
  defp step(%Brightness{}), do: {:brightness, &Brightness.execute/2}
  defp step(%Colorize{}), do: {:colorize, &Colorize.execute/2}
  defp step(%Contrast{}), do: {:contrast, &Contrast.execute/2}
  defp step(%Crop{}), do: {:crop, &Crop.execute/2}
  defp step(%Duotone{}), do: {:duotone, &Duotone.execute/2}
  defp step(%ExtendCanvas{}), do: {:extend_canvas, &ExtendCanvas.execute/2}
  defp step(%Gradient{}), do: {:gradient, &Gradient.execute/2}
  defp step(%Gray{}), do: {:gray, &Gray.execute/2}
  defp step(%Pixelate{}), do: {:pixelate, &Pixelate.execute/2}
  defp step(%ProgressiveBlur{}), do: {:progressive_blur, &ProgressiveBlur.execute/2}
  defp step(%Resize{}), do: {:resize, &Resize.execute/2}
  defp step(%Rotate{}), do: {:rotate, &Rotate.execute/2}
  defp step(%Saturation{}), do: {:saturation, &Saturation.execute/2}
  defp step(%Sharpen{}), do: {:sharpen, &Sharpen.execute/2}
  defp step(%Trim{}), do: {:trim, &Trim.execute/2}
  defp step(%Watermark{}), do: {:watermark, &Watermark.execute/2}

  @doc "True when `operation` reads pixels out of row order, so it runs on a materialized image."
  @spec random_access?(struct()) :: boolean()
  def random_access?(%Rotate{}), do: true
  def random_access?(%Trim{}), do: true
  def random_access?(%ProgressiveBlur{}), do: true
  def random_access?(%Crop{gravity: :smart}), do: true
  def random_access?(%Crop{gravity: {:smart, _}}), do: true
  def random_access?(%Crop{gravity: {:detect, _}}), do: true
  def random_access?(_operation), do: false

  @doc """
  Runs one operation, materializing first when it needs random access.

  Emits a `[:transform, :operation]` span with the operation's stage name (or
  `name`, when given), parameters, outcome, and resulting dimensions. libvips
  defers most pixel work, so this span measures pipeline construction plus any
  materialization it triggers.

  Returns transform failures as `{:error, {:transform, reason}}` and
  materialization failures as `Materializer` classifies them.
  Programmer errors propagate through the span unchanged.
  """
  @spec run(State.t(), struct(), keyword(), atom() | nil) ::
          {:ok, State.t()} | {:error, {:transform, term()} | {:decode, term()}}
  def run(%State{} = state, operation, opts \\ [], name \\ nil) do
    {stage, execute} = step(operation)

    Telemetry.span(
      Telemetry.telemetry_opts(opts),
      [:transform, :operation],
      %{operation: name || stage, params: operation},
      fn ->
        result =
          with {:ok, state} <- prepare(state, operation) do
            transform_result(execute.(operation, state))
          end

        {result, stop_metadata(result)}
      end
    )
  end

  defp prepare(state, operation) do
    if random_access?(operation), do: materialize(state), else: {:ok, state}
  end

  defp materialize(%State{materialized?: true} = state) do
    case WorkLimits.check(state) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, {:transform, reason}}
    end
  end

  defp materialize(state), do: Materializer.materialize(state)

  defp transform_result({:ok, %State{}} = ok), do: ok

  # Resize and watermark buffer images of their own, and return the
  # materializer's classified failure.
  defp transform_result({:error, {tag, _reason}} = error) when tag in [:decode, :transform],
    do: error

  defp transform_result({:error, reason}), do: {:error, {:transform, reason}}

  defp stop_metadata({:ok, %State{image: image}}),
    do: %{result: :ok, dims: {Image.width(image), Image.height(image)}}

  defp stop_metadata({:error, _reason}), do: %{result: :error}
end
