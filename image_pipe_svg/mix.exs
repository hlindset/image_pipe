defmodule ImagePipeSVG.MixProject do
  use Mix.Project

  # Versioned on its own, not with image_pipe: the NIF changes on its own
  # cadence, and each release rebuilds the precompiled matrix.
  @version "0.1.0"
  @source_url "https://github.com/hlindset/image_pipe"

  def project do
    [
      app: :image_pipe_svg,
      version: @version,
      description: description(),
      package: package(),
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: [
        main: "readme",
        source_ref: "image_pipe_svg-v#{@version}",
        source_url: @source_url,
        source_url_pattern:
          "#{@source_url}/blob/image_pipe_svg-v#{@version}/image_pipe_svg/%{path}#L%{line}",
        extras: ["README.md", "CHANGELOG.md", "LICENSE.md"]
      ],
      dialyzer: [
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ]
    ]
  end

  def application, do: []

  defp description do
    "SVG support for ImagePipe, rendering SVG sources with resvg."
  end

  defp package do
    [
      files:
        [
          "lib",
          "mix.exs",
          "native/image_pipe_svg_nif/src",
          "native/image_pipe_svg_nif/.cargo/config.toml",
          "native/image_pipe_svg_nif/build.rs",
          "native/image_pipe_svg_nif/Cargo.toml",
          "native/image_pipe_svg_nif/Cargo.lock",
          "README.md",
          "CHANGELOG.md",
          "LICENSE.md"
        ] ++ Path.wildcard("checksum-*.exs"),
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/image_pipe_svg/CHANGELOG.md"
      },
      maintainers: ["Håvard Lindset"]
    ]
  end

  defp deps do
    [
      {:rustler_precompiled, "~> 0.9"},
      {:rustler, "~> 0.38.0", optional: true},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
