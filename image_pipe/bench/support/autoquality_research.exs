defmodule AutoqualityResearch do
  alias ImagePipe.API.Parser
  alias ImagePipe.Output.{Encoder, Policy, RequestPolicy}
  alias ImagePipe.Output.Metric.Ssimulacra2
  alias ImagePipe.Output.Ssim2Metric.CropScore
  alias ImagePipe.Plug.Config
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  def configure do
    Vix.Vips.cache_set_max(0)
    Vix.Vips.cache_set_max_mem(0)

    case System.get_env("AUTOQUALITY_VIPS_THREADS") do
      nil -> :ok
      value -> Vix.Vips.concurrency_set(String.to_integer(value))
    end
  end

  def environment do
    %{
      kind: :environment,
      elixir: System.version(),
      otp: System.otp_release(),
      libvips: Vix.Vips.version(),
      vix: Application.spec(:vix, :vsn) |> to_string(),
      image: Application.spec(:image, :vsn) |> to_string(),
      dirty_cpu_schedulers: :erlang.system_info(:dirty_cpu_schedulers),
      vips_concurrency: Vix.Vips.concurrency_get(),
      target: 75.0,
      allowed_error: 0.5,
      operation_cache: false
    }
  end

  def policy(format, options \\ []) do
    config = Config.validate!([])
    segments = ["format=#{format}", "autoquality" | options]

    lexed = %{
      segments: Enum.map(segments, &{&1, {0, byte_size(&1)}}),
      source: {:src, "bench.png", {0, 9}}
    }

    {:ok, request} = Parser.parse(lexed, config)
    {:ok, policy} = RequestPolicy.resolve(request.output, config, "")
    {:ok, resolved} = Policy.resolve(policy, format)
    resolved
  end

  def open(path) do
    {:ok, image} = Image.open(path, access: :random)
    {:ok, srgb} = Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB)
    {:ok, flattened} = Image.flatten(srgb, background: [255, 255, 255])
    {:ok, memory} = VipsImage.copy_memory(flattened)
    memory
  end

  def size(base, mp) do
    {:ok, resized} = Image.resize(base, :math.sqrt(mp / megapixels(base)))
    {:ok, memory} = VipsImage.copy_memory(resized)
    memory
  end

  def megapixels(image), do: Image.width(image) * Image.height(image) / 1_000_000

  def scorer(base) do
    case megapixels(base) > CropScore.crossover_megapixels() do
      true -> :crop
      false -> :full
    end
  end

  def score_context(base, :full) do
    {:ok, ref} = Ssimulacra2.reference(base)
    {:full, ref}
  end

  def score_context(base, :crop) do
    {:ok, refs} = CropScore.references(base)
    {:crop, refs}
  end

  def score({:full, ref}, body) do
    {:ok, candidate} = Image.from_binary(body)
    {:ok, score} = Ssimulacra2.score(ref, candidate)
    score
  end

  def score({:crop, refs}, body) do
    {:ok, candidate} = Image.from_binary(body)
    {:ok, score} = CropScore.p10(refs, candidate)
    score - 1.0
  end

  def truth(base, body), do: score(score_context(base, :full), body)

  def pixels(body) do
    {:ok, candidate} = Image.from_binary(body)
    {:ok, memory} = VipsImage.write_to_binary(candidate)
    memory
  end

  def production_encode(base, policy, quality) do
    {:ok, body} = Encoder.encode_to_buffer(base, policy, quality)
    body
  end

  def body_summary(body),
    do: %{
      bytes: byte_size(body),
      sha256: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    }

  def emit(output, row), do: File.write!(output, JSON.encode!(row) <> "\n", [:append])

  def subjects(manifest) do
    all = manifest |> File.read!() |> JSON.decode!()

    case System.get_env("AUTOQUALITY_PATHS") do
      nil -> all
      paths -> Enum.filter(all, &(&1["path"] in String.split(paths, ",")))
    end
  end

  def numbers(key, default) do
    System.get_env(key, default)
    |> String.split(",")
    |> Enum.map(fn text ->
      {number, ""} = Float.parse(text)
      number
    end)
  end

  def rotate(variants, trial) do
    {first, last} = Enum.split(variants, rem(trial - 1, length(variants)))
    last ++ first
  end
end
