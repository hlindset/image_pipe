defmodule ImagePipe.SourceTest.InvalidConfigAdapter do
  @moduledoc false

  def source_kinds, do: [:path, :url, :object]

  def validate_options(_opts), do: {:error, {:invalid_source_config, :bad_option}}
end
