defmodule ImagePipe.Plan.ValueSpellings do
  # URL spellings of each enumerated option value. The URL grammar parses with
  # these maps, the serializer writes their inverse, and the builder accepts
  # their values.
  @moduledoc false

  # Lists, not maps, so values keep their order in the builder's messages.
  @positions [
    {"center", :center},
    {"top", :top},
    {"bottom", :bottom},
    {"left", :left},
    {"right", :right},
    {"top-left", :top_left},
    {"top-right", :top_right},
    {"bottom-left", :bottom_left},
    {"bottom-right", :bottom_right}
  ]

  @spellings %{
    fit: [{"contain", :contain}, {"cover", :cover}, {"stretch", :stretch}, {"auto", :auto}],
    position: @positions,
    anchor: @positions ++ [{"smart", :smart}, {"smart-face", :smart_face}],
    axis: [{"h", :horizontal}, {"v", :vertical}, {"hv", :both}],
    format: [{"jpeg", :jpeg}, {"png", :png}, {"webp", :webp}, {"avif", :avif}],
    output: [
      {"image", :image},
      {"blurhash", :blurhash},
      {"lqip-css", :lqip_css},
      {"info", :info}
    ],
    metadata: [{"strip", :strip}, {"copyright", :copyright}, {"keep", :keep}],
    color_profile: [
      {"strip", :strip},
      {"preserve", :preserve_source},
      {"srgb", {:convert, :srgb}},
      {"display-p3", {:convert, :display_p3}},
      {"adobe-rgb", {:convert, :adobe_rgb}}
    ],
    hdr: [{"tonemap", :tone_map}, {"preserve", :preserve}]
  }

  @written Map.new(
             for {_option, spellings} <- @spellings,
                 {spelling, value} <- spellings,
                 do: {value, spelling}
           )

  @type option ::
          :fit
          | :position
          | :anchor
          | :axis
          | :format
          | :output
          | :metadata
          | :color_profile
          | :hdr

  @doc "The URL spelling to value map for `option`."
  @spec spellings(option()) :: %{String.t() => term()}
  def spellings(option), do: @spellings |> Map.fetch!(option) |> Map.new()

  @doc "The values `option` accepts."
  @spec values(option()) :: [term()]
  def values(option), do: for({_spelling, value} <- Map.fetch!(@spellings, option), do: value)

  @doc "The URL spelling of an enumerated value, or `:error` for other values."
  @spec spelling(term()) :: {:ok, String.t()} | :error
  def spelling(value), do: Map.fetch(@written, value)
end
