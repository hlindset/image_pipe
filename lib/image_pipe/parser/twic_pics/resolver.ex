defmodule ImagePipe.Parser.TwicPics.Resolver do
  @moduledoc """
  TwicPics geometry-resolution strategy (spec §4.4/§9 Stage 3; #438): carries
  the TwicPics focus point as its strategy state, resolves the positional
  `set_focus` directive into that carry, substitutes `:deferred` gravity with a
  concrete point before emission, and delegates all geometry resolution to
  `ImagePipe.Transform.NeutralResolver`, advancing the point through each
  emitted stage with the executables' pure geometry helpers
  (`ImagePipe.Parser.TwicPics.PointFlow`).
  """

  @behaviour ImagePipe.Resolver

  alias ImagePipe.Parser.TwicPics.PointFlow
  alias ImagePipe.Plan.Operation.Directive
  alias ImagePipe.Transform.Focus
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.SourceShape

  @impl ImagePipe.Resolver
  def init, do: nil

  @impl ImagePipe.Resolver
  def behavior_version, do: 1

  @impl ImagePipe.Resolver
  def resolve(%SourceShape{} = shape, _point, %Directive{name: :set_focus, payload: operand}) do
    resolved =
      Focus.resolve(
        operand,
        %{storage: SourceShape.live_dims(shape), decode_shrink: shape.decode_shrink},
        shape.pending_orientation
      )

    {[], {:advance, shape, resolved}}
  end

  def resolve(%SourceShape{} = shape, point, operation) do
    {ops, continuation} = NeutralResolver.resolve(shape, nil, operation)
    PointFlow.advance(ops, continuation, point, shape)
  end

  @impl ImagePipe.Resolver
  def continue(tag, measured, %SourceShape{} = shape, seam_state),
    do: PointFlow.continue(tag, measured, shape, seam_state)
end
