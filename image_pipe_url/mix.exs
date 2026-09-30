defmodule ImagePipeURL.MixProject do
  use Mix.Project

  # Released in lockstep with image_pipe, which pins this package with `==`.
  @version "0.1.0"
  @source_url "https://github.com/hlindset/image_pipe"

  def project do
    [
      app: :image_pipe_url,
      version: @version,
      description: description(),
      package: package(),
      elixir: "~> 1.18",
      compilers: extra_compilers(Mix.env()) ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        source_url: @source_url,
        source_url_pattern: "#{@source_url}/blob/v#{@version}/image_pipe_url/%{path}#L%{line}",
        extras: ["README.md", "LICENSE.md"],
        groups_for_modules: [
          "URL builder": [ImagePipe.URL, ImagePipe.URL.Config],
          "Plan Model": [ImagePipe.Plan, ~r/ImagePipe\.Plan\..*/],
          "URL grammar": [ImagePipe.API, ~r/ImagePipe\.API\..*/],
          Internals: [~r/.*/]
        ]
      ],
      dialyzer: [
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ]
    ]
  end

  def application do
    [extra_applications: [:crypto]]
  end

  def ex_dna_options do
    [excluded_macros: [:alias]]
  end

  defp extra_compilers(:prod), do: []
  defp extra_compilers(_env), do: [:boundary]

  defp description do
    "Builds and signs ImagePipe image URLs without the image processing runtime."
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE.md"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      maintainers: ["Håvard Lindset"]
    ]
  end

  defp deps do
    [
      {:nimble_options, "~> 1.1"},
      {:color, "~> 0.13"},
      {:mime, "~> 2.0"},
      {:boundary, "~> 0.10", runtime: false},
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
