defmodule ImagePipe.Output.Negotiate do
  @moduledoc false

  # The shared output-negotiation seam. Every stack (the framework delivery
  # build and both in-tree dialects) resolves its output through this helper so
  # the `[:output, :negotiate]` span is emitted from ONE place, with identical
  # start/stop metadata, rather than re-implemented per stack.
  #
  # The span encloses BOTH resolution legs — `Policy.resolve/2` and the
  # `:needs_final_image_alpha` second resolution — so exactly one span is emitted
  # per request regardless of which leg runs. The final-alpha probe is deferred
  # to the caller via `alpha_fun`, because the three stacks hold different image
  # handles at negotiation time.
  #
  # Error-shape ownership stays with the caller: the helper returns
  # `{:error, reason}` UNWRAPPED. The framework re-wraps it as
  # `{:error, {:output, reason}}` at its call site; the dialects pass it through
  # unwrapped. Each stack's observable error shape is therefore unchanged.

  alias ImagePipe.Error
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Telemetry

  @spec negotiate_output(Policy.t(), Policy.source_format() | nil, (-> boolean()), keyword()) ::
          {:ok, Resolved.t()} | {:error, term()}
  def negotiate_output(%Policy{} = policy, source_format, alpha_fun, telemetry_opts)
      when is_function(alpha_fun, 0) do
    Telemetry.span(
      Telemetry.telemetry_opts(telemetry_opts),
      [:output, :negotiate],
      %{output_mode: output_mode(policy)},
      fn ->
        result = resolve(policy, source_format, alpha_fun)
        {result, stop_metadata(result)}
      end
    )
  end

  defp resolve(%Policy{} = policy, source_format, alpha_fun) do
    case Policy.resolve(policy, source_format) do
      {:ok, %Resolved{} = resolved} ->
        {:ok, resolved}

      {:needs_final_image_alpha, :source} ->
        {:ok, Policy.resolve_final_image_alpha(policy, alpha_fun.())}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp output_mode(%Policy{mode: {:explicit, _format}}), do: :explicit
  defp output_mode(%Policy{mode: :source}), do: :automatic

  defp stop_metadata({:ok, %Resolved{format: format}}),
    do: %{result: :ok, output_format: format}

  defp stop_metadata({:error, reason}),
    do: %{result: :output_error, error: Error.tag(reason)}
end
