defmodule ImagePipe.URL.ArchitectureBoundaryTest do
  # The Boundary compiler checks calls against each boundary's declaration.
  # This pins the declarations themselves so a dependency can't be widened
  # unnoticed. It reads the definition Boundary persists on each boundary module.
  use ExUnit.Case, async: true

  @declarations %{
    ImagePipe.URL => {
      [ImagePipe.API, ImagePipe.Plan, ImagePipe.Security],
      [ImagePipe.URL.Config, ImagePipe.URL.Helpers]
    },
    ImagePipe.API => {
      [ImagePipe.Plan, ImagePipe.Security],
      [
        ImagePipe.API.Diagnostic,
        ImagePipe.API.DiagnosticRenderer,
        ImagePipe.API.Parser,
        ImagePipe.API.Path,
        ImagePipe.API.Presets,
        ImagePipe.API.URL
      ]
    },
    ImagePipe.Plan => {
      [],
      [
        ImagePipe.Plan.Presets,
        ImagePipe.Plan.Spec,
        ImagePipe.Plan.Spec.Group,
        ImagePipe.Plan.Spec.Output,
        ImagePipe.Plan.Spec.Issue,
        ImagePipe.Plan.Output,
        ImagePipe.Plan.Output.QualitySearch,
        ImagePipe.Plan.Output.JpegOptions,
        ImagePipe.Plan.Output.PngOptions,
        ImagePipe.Plan.Output.WebpOptions,
        ImagePipe.Plan.Output.AvifOptions,
        ImagePipe.Plan.Color,
        ImagePipe.Plan.ValueBounds,
        ImagePipe.Plan.ValueSpellings,
        ImagePipe.Plan.Source,
        ImagePipe.Plan.Source.Identity,
        ImagePipe.Plan.Source.Path,
        ImagePipe.Plan.Source.URL,
        ImagePipe.Plan.Source.Object
      ]
    },
    ImagePipe.Security => {[], []}
  }

  for {boundary, {deps, exports}} <- @declarations do
    test "#{inspect(boundary)} declares its dependencies and exports" do
      opts = declaration(unquote(boundary))

      assert opts |> Keyword.get(:deps, []) |> Enum.map(&dep_module/1) |> Enum.sort() ==
               Enum.sort(unquote(deps))

      assert opts
             |> Keyword.get(:exports, [])
             |> Enum.map(&Module.concat(unquote(boundary), &1))
             |> Enum.sort() == Enum.sort(unquote(exports))
    end
  end

  defp declaration(boundary) do
    [%{opts: opts}] = Keyword.fetch!(boundary.__info__(:attributes), Boundary)
    opts
  end

  defp dep_module({module, _mode}), do: module
  defp dep_module(module), do: module
end
