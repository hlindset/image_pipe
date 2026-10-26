defmodule ImagePipe.SrgbProfile do
  # Recognises embedded RGB profiles that describe sRGB closely enough to treat
  # the image as untagged. Most web images embed one (vendor sRGB profiles and
  # compact variants), and converting through it costs a LittleCMS transform
  # each time while changing at most 1 level in a few channel values.
  #
  # A profile is checked once: a lattice of 8-bit sRGB colors goes through it
  # in both directions, and it is equivalent when no value moves by more than
  # 1 level. The answer depends only on the profile, so it's kept in an ETS
  # table by the profile's digest. Profiles come from untrusted sources, so
  # the table holds at most `@limit` answers and forgets an arbitrary one to
  # make room. While the process that owns the table isn't running, such as
  # during a restart, each use checks the profile again. The lattice and its
  # import from sRGB don't depend on the profile, so they're made once.
  @moduledoc false

  use Boundary, top_level?: true, deps: [], exports: []
  use GenServer

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage
  alias Vix.Vips.Operation

  @table __MODULE__
  @limit 4096
  @lattice_key {__MODULE__, :lattice}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end

  @doc "Whether `profile` is an RGB profile equivalent to sRGB."
  @spec equivalent?(binary()) :: boolean()
  def equivalent?(<<_::binary-size(16), "RGB ", _::binary-size(108), _::binary>> = profile) do
    key = :crypto.hash(:sha256, profile)

    case lookup(key) do
      nil ->
        answer = check(profile)
        store(key, answer)
        answer

      answer ->
        answer
    end
  end

  def equivalent?(_profile), do: false

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, answer}] -> answer
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp store(key, answer) do
    if :ets.info(@table, :size) >= @limit, do: :ets.delete(@table, :ets.first(@table))
    :ets.insert(@table, {key, answer})
  rescue
    ArgumentError -> true
  end

  # Every color on a 16-level lattice, including 255.
  @lattice for r <- Enum.map(0..16, &min(&1 * 16, 255)),
               g <- Enum.map(0..16, &min(&1 * 16, 255)),
               b <- Enum.map(0..16, &min(&1 * 16, 255)),
               into: <<>>,
               do: <<r, g, b>>
  @lattice_width div(byte_size(@lattice), 3)

  # Dialyzer can't see through Vix's generated Operation typings, so it reports
  # the icc calls as failing, and the comparison after them as unreachable.
  # They succeed at runtime.
  @dialyzer {:nowarn_function, check: 1, lattice: 0, close?: 1, within_one?: 2}

  defp check(profile) do
    {lattice, imported} = lattice()

    with {:ok, tagged} <- with_profile(lattice, profile),
         {:ok, to_srgb} <- Operation.icc_transform(tagged, "sRGB", embedded: true, depth: 8),
         # `imported` is in memory and shared, and mutating an in-memory image
         # edits it in place, so the profile goes on a private copy.
         {:ok, imported} <- Operation.copy(imported),
         {:ok, imported} <- with_profile(imported, profile),
         {:ok, from_srgb} <- Operation.icc_export(imported, depth: 8) do
      close?(to_srgb) and close?(from_srgb)
    else
      {:error, _reason} -> false
    end
  end

  # The lattice as sRGB pixels, and imported from sRGB into the PCS.
  defp lattice do
    case :persistent_term.get(@lattice_key, nil) do
      nil ->
        {:ok, lattice} =
          VipsImage.new_from_binary(@lattice, @lattice_width, 1, 3, :VIPS_FORMAT_UCHAR)

        {:ok, lattice} = Operation.copy(lattice, interpretation: :VIPS_INTERPRETATION_sRGB)
        {:ok, imported} = Operation.icc_import(lattice, input_profile: "sRGB")
        {:ok, imported} = VipsImage.copy_memory(imported)
        :persistent_term.put(@lattice_key, {lattice, imported})
        {lattice, imported}

      lattice ->
        lattice
    end
  end

  defp with_profile(image, profile) do
    VipsImage.mutate(image, fn mutable ->
      MutableImage.set(mutable, "icc-profile-data", :VipsBlob, profile)
    end)
  end

  defp close?(image) do
    VipsImage.bands(image) == 3 and VipsImage.format(image) == :VIPS_FORMAT_UCHAR and
      case VipsImage.write_to_binary(image) do
        {:ok, bytes} -> within_one?(bytes, @lattice)
        {:error, _reason} -> false
      end
  end

  defp within_one?(<<a, rest_a::binary>>, <<b, rest_b::binary>>) when abs(a - b) <= 1,
    do: within_one?(rest_a, rest_b)

  defp within_one?(<<>>, <<>>), do: true
  defp within_one?(_bytes, _lattice), do: false
end
