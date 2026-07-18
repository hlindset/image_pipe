defmodule ImagePipe.ExDnaIgnoreParityTest do
  use ExUnit.Case, async: true

  test "Credo and the standalone ExDNA gate ignore the same files" do
    credo_ignores = credo_ignores()
    mise_ignores = mise_ignores()

    assert Enum.uniq(credo_ignores) == credo_ignores
    assert Enum.uniq(mise_ignores) == mise_ignores
    assert Enum.sort(credo_ignores) == Enum.sort(mise_ignores)
  end

  defp credo_ignores do
    %{configs: [%{checks: checks}]} = eval_config(".credo.exs")
    {ExDNA.Credo, options} = Enum.find(checks, &match?({ExDNA.Credo, _options}, &1))
    Keyword.fetch!(options, :ignore)
  end

  defp mise_ignores do
    mise_toml = File.read!("mise.toml")
    [command] = Regex.run(~r/"(mix ex_dna [^"]+)"/, mise_toml, capture: :all_but_first)

    for [path] <- Regex.scan(~r/--ignore\s+(\S+)/, command, capture: :all_but_first), do: path
  end

  defp eval_config(path) do
    {config, _bindings} = Code.eval_file(path)
    config
  end
end
