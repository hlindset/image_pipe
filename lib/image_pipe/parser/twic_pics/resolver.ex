defmodule ImagePipe.Parser.TwicPics.Resolver do
  @moduledoc """
  TwicPics geometry-resolution strategy (spec §4.4; #438): owns positional
  focus resolution — the operand resolves against the live frame at its chain
  position and commits the carried point through an explicit state update —
  and delegates all other resolution to `ImagePipe.Transform.NeutralResolver`.
  """

  @behaviour ImagePipe.Resolver

  alias ImagePipe.Plan.Operation.Directive
  alias ImagePipe.Transform.Focus
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.Operation.StateUpdate
  alias ImagePipe.Transform.SourceShape

  @impl ImagePipe.Resolver
  def init, do: nil

  @impl ImagePipe.Resolver
  def behavior_version, do: 1

  @impl ImagePipe.Resolver
  def resolve(%SourceShape{} = shape, nil, %Directive{name: :set_focus, payload: operand}) do
    focus_ctx = %{storage: SourceShape.live_dims(shape), decode_shrink: shape.decode_shrink}
    resolved = Focus.resolve(operand, focus_ctx, shape.pending_orientation)
    {[%StateUpdate{fields: %{carried_point: resolved}}], {:advance, shape, nil}}
  end

  def resolve(%SourceShape{} = shape, nil, operation),
    do: NeutralResolver.resolve(shape, nil, operation)
end
