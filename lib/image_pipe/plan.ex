defmodule ImagePipe.Plan do
  @moduledoc """
  Canonical request value types shared by parsing, execution, and output policy.
  """

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Format],
    exports: [
      Request,
      Request.Group,
      Request.Output,
      Output,
      Output.QualitySearch,
      Output.QualitySearch.Metric,
      Output.QualitySearch.Size,
      Output.QualitySearch.Ssimulacra2,
      Output.QualitySearch.Butteraugli,
      Output.JpegOptions,
      Output.PngOptions,
      Output.WebpOptions,
      Output.AvifOptions,
      Output.JxlOptions,
      Response,
      SourceInfo,
      Color,
      Source,
      Source.Identity,
      Source.Path,
      Source.URL,
      Source.Object,
      Source.Reference
    ]
end
