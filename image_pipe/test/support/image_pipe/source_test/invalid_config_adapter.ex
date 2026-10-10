defmodule ImagePipe.SourceTest.InvalidConfigAdapter do
  @moduledoc false

  def identifiers(_options),
    do: [ImagePipe.Source.Path, ImagePipe.Source.URL, ImagePipe.Source.Object]

  def validate_options(_opts), do: {:error, {:invalid_source_config, :bad_option}}
end
