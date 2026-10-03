defmodule ImagePipe.SourceTest.InvalidConfigAdapter do
  @moduledoc false

  def identifiers,
    do: [ImagePipe.Plan.Source.Path, ImagePipe.Plan.Source.URL, ImagePipe.Plan.Source.Object]

  def validate_options(_opts), do: {:error, {:invalid_source_config, :bad_option}}
end
