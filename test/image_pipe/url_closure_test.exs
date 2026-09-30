defmodule ImagePipe.URLClosureTest do
  # The URL builder is meant to ship as its own package with only pure
  # dependencies. This walks the compiled call graph (function-level xref)
  # and asserts every call leaving the URL module set lands in an allowed app.
  use ExUnit.Case, async: true

  @url_namespaces ~w(ImagePipe.URL ImagePipe.API ImagePipe.Plan ImagePipe.Security ImagePipe.Format)
  @allowed_apps [:elixir, :stdlib, :kernel, :erts, :crypto, :nimble_options, :color, :mime]

  setup_all do
    Mix.ensure_application!(:tools)
    {:ok, xref} = :xref.start(xref_mode: :functions)
    :xref.set_default(xref, warnings: false, verbose: false)
    app_path = String.to_charlist(Mix.Project.app_path())
    {:ok, _app} = :xref.add_application(xref, app_path, name: :image_pipe)
    {:ok, edges} = :xref.q(xref, ~c"E")
    :xref.stop(xref)

    %{edges: edges}
  end

  test "the URL module set calls nothing outside itself except pure dependencies", %{
    edges: edges
  } do
    assert Enum.any?(edges, fn {{caller, _, _}, _callee} -> in_url_set?(caller) end)

    violations =
      for {{caller, _, _} = from, {callee, _, _} = to} <- edges,
          in_url_set?(caller),
          not in_url_set?(callee),
          # xref's placeholder for dynamic dispatch (`module.fun()` on a variable)
          callee != :"$M_EXPR",
          app(callee) not in @allowed_apps,
          do: {from, to, app(callee)}

    assert violations == []
  end

  test "the walk sees calls leaving the set from server modules", %{edges: edges} do
    assert Enum.any?(edges, fn {{caller, _, _}, {callee, _, _}} ->
             caller == ImagePipe.Plug.Runner and app(callee) == :plug
           end)
  end

  defp in_url_set?(module) do
    name = module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
    Enum.any?(@url_namespaces, &(name == &1 or String.starts_with?(name, &1 <> ".")))
  end

  defp app(module), do: Application.get_application(module)
end
