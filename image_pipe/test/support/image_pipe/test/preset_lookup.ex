defmodule ImagePipe.Test.PresetLookup do
  @moduledoc """
  Preset lookup backed by an options map. Reports each `fetch/2` batch to
  `:test_pid` as `{:preset_fetch, names}`.

  `:presets` maps names to fragments. `:fail` makes `fetch/2` return
  `{:error, :down}`, `:raise` makes it raise, and `:reply` replaces the
  return value verbatim. `:validate_reply` replaces `validate_options/1`'s
  return value.
  """

  @behaviour ImagePipe.PresetLookup

  @impl true
  def validate_options(options), do: Keyword.get(options, :validate_reply, {:ok, options})

  @impl true
  def fetch(names, options) do
    send(Keyword.fetch!(options, :test_pid), {:preset_fetch, names})

    cond do
      options[:fail] -> {:error, :down}
      options[:raise] -> raise "backend down"
      Keyword.has_key?(options, :reply) -> options[:reply]
      true -> {:ok, Map.take(Keyword.get(options, :presets, %{}), names)}
    end
  end
end
