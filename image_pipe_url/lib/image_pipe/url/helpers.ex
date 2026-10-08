defmodule ImagePipe.URL.Helpers do
  @moduledoc """
  An `image_url/2` macro that builds image URLs in templates and checks their
  options at compile time.

  In an app that serves its own images with `image_pipe`, name the
  `ImagePipe` instance:

      # lib/my_app_web.ex, in html_helpers
      use ImagePipe.URL.Helpers, instance: MyApp.Images

  ```heex
  <img src={image_url("cat.jpg", group: [resize: [width: 400, height: 300, fit: :cover]])} />
  <img src={image_url(@photo.path, group: [resize: [width: @width]], output: [format: :webp])} />
  ```

  In an app that builds URLs for an image service running elsewhere, give a
  function that returns the URL configuration. The helper calls this function
  for every URL, so build the configuration once when the app starts and
  return the stored copy:

      # lib/my_app/image_urls.ex
      defmodule MyApp.ImageURLs do
        def put_config do
          config =
            ImagePipe.URL.config(
              base_url: "https://images.example.com",
              keys: [System.fetch_env!("IMAGE_PIPE_SIGNING_KEY")]
            )

          :persistent_term.put(__MODULE__, config)
        end

        def config, do: :persistent_term.get(__MODULE__)
      end

      # lib/my_app/application.ex, in start/2, before the endpoint starts
      MyApp.ImageURLs.put_config()

      # lib/my_app_web.ex, in html_helpers
      use ImagePipe.URL.Helpers, config: {MyApp.ImageURLs, :config, []}

  Calling `put_config/0` again replaces the stored configuration without a
  restart. [Signing URLs and rotating keys](https://hexdocs.pm/image_pipe/signing-urls.html)
  gives the order for rotating a key.

  ## Options

    * `:instance` - the `:name` of an `ImagePipe` instance. Each URL uses
      the instance's URL settings from `ImagePipe.url_config/2`: its base
      URL, signing keys, source encryption settings, and the presets, request
      defaults, and watermark settings it checks options against. Building a
      URL raises `ArgumentError` when the instance isn't running. Needs the
      `image_pipe` package.
    * `:mount` - with `:instance`, one of the instance's `:mounts`, whose URL
      options the URLs use instead of the instance's own.
    * `:config` - `{module, function, args}`, called for each URL, that
      returns an `ImagePipe.URL.Config`. Use it in place of `:instance`.
    * `:on_invalid` - `:warn` (the default) or `:raise`. See
      [Checks when the page renders](#image_url/2-checks-when-the-page-renders).

  The configuration is read each time a URL is built, so signing keys stay
  out of the compiled code. Without `:instance` or `:config`, URLs use
  `ImagePipe.URL.config([])`: no base URL, signing, or encryption.
  """

  require Logger

  alias ImagePipe.Plan.Spec.Issue

  @attribute :image_pipe_url_helpers

  defmacro __using__(options) do
    quote do
      @image_pipe_url_helpers ImagePipe.URL.Helpers.__options__(unquote(options))
      import ImagePipe.URL.Helpers, only: [image_url: 2]
    end
  end

  # Runs in the using module's body, so `ImagePipe` is loaded there when the
  # app depends on `image_pipe`, even though this library compiles first.
  @doc false
  def __options__(options) do
    case Keyword.split(options, [:config, :instance, :mount, :on_invalid]) do
      {known, []} ->
        on_invalid = Keyword.get(known, :on_invalid, :warn)

        unless on_invalid in [:warn, :raise],
          do: raise(ArgumentError, ":on_invalid must be :warn or :raise")

        [config: config(known), on_invalid: on_invalid]

      {_known, unknown} ->
        raise ArgumentError, "unknown options: #{inspect(Keyword.keys(unknown))}"
    end
  end

  defp config(options), do: config(options[:config], options[:instance], options[:mount])

  defp config(nil, nil, nil), do: nil

  defp config({module, function, args} = mfa, nil, nil)
       when is_atom(module) and is_atom(function) and is_list(args),
       do: mfa

  defp config(nil, instance, mount)
       when is_atom(instance) and instance != nil and is_atom(mount) do
    unless Code.ensure_loaded?(ImagePipe),
      do: raise(ArgumentError, "instance: needs the image_pipe package. Use config: instead")

    args = if mount, do: [instance, [mount: mount]], else: [instance]
    {ImagePipe, :url_config, args}
  end

  defp config(_config, _instance, _mount) do
    raise ArgumentError,
          "expected config: {module, function, args}, or instance: with an optional mount:"
  end

  @doc """
  Builds the URL for `source` with the options of `ImagePipe.URL`.

      image_url("cat.jpg",
        new: [filename: "cat"],
        group: [resize: [width: 400, height: 300, fit: :cover]],
        group: [blur: 2],
        output: [format: :webp]
      )
      # "/w=400/h=300/fit=cover/-/blur=2/format=webp/filename=cat/src/cat.jpg"

  `new:` takes the request controls of `ImagePipe.URL.new/2`, each `group:`
  the options of one `ImagePipe.URL.group/2` call, in order, and `output:`
  the options of `ImagePipe.URL.output/2`. `new:` applies first wherever it
  is in the call. The option names must be written out in the call, and a
  list that isn't fails to compile. Use `ImagePipe.URL` for options built at
  runtime. Values can be variables or assigns.

  ## Checks at compile time

  Each option name and value written out in the call is checked when the
  module compiles. A list value, such as `gradient:` or `jpeg_options:`, is
  checked only when all of it is written out, except `resize:`, whose
  options are checked one by one. A mistake is a compiler warning at the
  call site:

  ```text
  warning: image_url: invalid_value at {:group, 0, :fit}: invalid value for :fit option: expected one of [:contain, :cover, :stretch, :auto], got: :fill
  ```

  With `mix compile --warnings-as-errors`, a mistake fails the build. Values
  that are variables are checked when the page renders. How the options
  combine depends on the server's presets and request defaults, so how the
  options combine is checked at render, with `:instance` or a configuration
  that has `:validate_against`.

  ## Checks when the page renders

  The URL is built with `ImagePipe.URL.url_with_issues/3`, so an error in
  the options or the source never raises. The URL includes it, the server
  rejects the URL with `400`, and the browser shows a broken image. Each
  error is logged at `:warning`, and each warning, such as a mistake the
  builder repaired or an option that has no effect, at `:debug`. The log
  names the call's file and line, the reason, and the option, not the source
  or values:

  ```text
  [warning] image_url (lib/my_app_web/controllers/page_html/home.html.heex:3): invalid_value at {:group, 0, :fit}
  ```

  These messages come from the `ImagePipe.URL.Helpers` module, so Logger's
  module levels control them. To turn them off in production, set
  `Logger.put_module_level(ImagePipe.URL.Helpers, :none)` when the app
  starts.

  With `on_invalid: :raise`, an error raises `ArgumentError` instead. To
  raise only in tests, read the setting from the app's configuration:

      # config/test.exs
      config :my_app, :image_url_on_invalid, :raise

      # lib/my_app_web.ex, in html_helpers
      use ImagePipe.URL.Helpers,
        instance: MyApp.Images,
        on_invalid: Application.compile_env(:my_app, :image_url_on_invalid, :warn)
  """
  defmacro image_url(source, options) do
    settings =
      Module.get_attribute(__CALLER__.module, @attribute) ||
        raise ArgumentError,
              "image_url/2 needs `use ImagePipe.URL.Helpers` in #{inspect(__CALLER__.module)}"

    calls = calls!(options)
    warn_compile_issues(calls, __CALLER__)

    quote do
      unquote(__MODULE__).__url__(
        unquote(Macro.escape(settings[:config])),
        unquote(calls),
        unquote(source),
        unquote(settings[:on_invalid]),
        unquote(call_site(__CALLER__))
      )
    end
  end

  # Where the call is written, relative to the project, for messages at
  # render.
  defp call_site(env), do: "#{Path.relative_to_cwd(env.file)}:#{env.line}"

  # The call's structure: `new:`, `group:`, and `output:` with literal keyword
  # lists, kept in order, with `new:` first.
  defp calls!(options) do
    unless literal_keywords?(options),
      do:
        raise(
          ArgumentError,
          "image_url/2 expects a literal keyword list of new:, group:, and output:"
        )

    if Enum.count(options, &match?({:new, _}, &1)) > 1,
      do: raise(ArgumentError, "image_url/2 takes new: at most once")

    {new, rest} = Enum.split_with(options, &match?({:new, _}, &1))
    options = new ++ rest

    for {kind, value} <- options do
      unless kind in [:new, :group, :output],
        do:
          raise(
            ArgumentError,
            "image_url/2 takes new:, group:, and output:, got: #{inspect(kind)}"
          )

      unless literal_keywords?(value),
        do:
          raise(
            ArgumentError,
            "image_url/2 expects a literal keyword list for #{kind}:. Use ImagePipe.URL to build options at runtime"
          )

      {kind, value}
    end
  end

  defp literal_keywords?(list) when is_list(list),
    do: Enum.all?(list, &match?({key, _value} when is_atom(key), &1))

  defp literal_keywords?(_ast), do: false

  # Builds the plan with each value that isn't written out replaced by
  # `:unset`, which every option accepts, so names are still checked.
  defp warn_compile_issues(calls, env) do
    issues =
      calls
      |> Enum.map(fn {kind, options} -> {kind, checkable(kind, options)} end)
      |> build(ImagePipe.URL.config())
      |> ImagePipe.URL.validate()
      |> elem(1)

    for issue <- issues, do: IO.warn("image_url: " <> describe(issue), env)
    :ok
  end

  # The call's options as the builder checks them at compile time. A value
  # that isn't written out becomes `:unset`, which every option accepts, so
  # its name is still checked. In a group, `presets:` and `resize:` don't
  # accept `:unset` and are left out instead, and a group left empty by that
  # gets a placeholder so it isn't reported as empty.
  defp checkable(:group, options) do
    case for({key, value} <- options, checkable = group_option(key, value), do: checkable) do
      [] when options != [] -> [blur: :unset]
      checkable -> checkable
    end
  end

  defp checkable(_kind, options), do: for({key, value} <- options, do: option(key, value))

  defp group_option(:resize, value) do
    if literal_keywords?(value),
      do: {:resize, for({key, value} <- value, do: option(key, value))},
      else: nil
  end

  defp group_option(:presets, value) do
    case literal(value) do
      {:ok, term} -> {:presets, term}
      :error -> nil
    end
  end

  defp group_option(key, value), do: option(key, value)

  defp option(key, value) do
    case literal(value) do
      {:ok, term} -> {key, term}
      :error -> {key, :unset}
    end
  end

  # The value a literal written in the call stands for, such as a tuple of
  # any size or a negative number.
  defp literal(value) when is_atom(value) or is_number(value) or is_binary(value),
    do: {:ok, value}

  defp literal({op, _meta, [number]}) when op in [:-, :+] and is_number(number),
    do: {:ok, if(op == :-, do: -number, else: number)}

  defp literal({:{}, _meta, items}) do
    with {:ok, items} <- literals(items), do: {:ok, List.to_tuple(items)}
  end

  defp literal({first, second}) do
    with {:ok, [first, second]} <- literals([first, second]), do: {:ok, {first, second}}
  end

  defp literal(list) when is_list(list), do: literals(list)
  defp literal(_ast), do: :error

  defp literals(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case literal(item) do
        {:ok, term} -> {:cont, {:ok, [term | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  @doc false
  def __url__(config, calls, source, on_invalid, call_site) do
    config =
      case config do
        {module, function, args} -> apply(module, function, args)
        nil -> ImagePipe.URL.config()
      end

    {url, issues} = calls |> build(config) |> ImagePipe.URL.url_with_issues(source)
    report(issues, on_invalid, call_site)
    url
  end

  defp build([{:new, options} | calls], config),
    do: build(calls, ImagePipe.URL.new(config, options))

  defp build(calls, %ImagePipe.URL.Config{} = config), do: build(calls, ImagePipe.URL.new(config))

  defp build(calls, builder) do
    Enum.reduce(calls, builder, fn
      {:group, options}, builder -> ImagePipe.URL.group(builder, options)
      {:output, options}, builder -> ImagePipe.URL.output(builder, options)
    end)
  end

  defp report([], _on_invalid, _call_site), do: :ok

  defp report(issues, on_invalid, call_site) do
    {errors, warnings} = Enum.split_with(issues, &(&1.severity == :error))

    if errors != [] and on_invalid == :raise,
      do: raise(ArgumentError, "image_url (#{call_site}): #{Issue.summary(errors)}")

    prefix = "image_url (#{call_site}): "
    for issue <- errors, do: Logger.warning(prefix <> describe(issue, :short))
    for issue <- warnings, do: Logger.debug(prefix <> describe(issue, :short))
    :ok
  end

  # The compile-time message includes the builder's detail: the values in it
  # are written in the source file. At render, only reasons and locations.
  defp describe(issue, form \\ :full) do
    where =
      case issue.locations do
        [] -> ""
        locations -> " at " <> Enum.map_join(locations, ", ", &inspect/1)
      end

    case {form, issue.detail} do
      {:full, detail} when is_binary(detail) -> "#{issue.reason}#{where}: #{detail}"
      _other -> "#{issue.reason}#{where}"
    end
  end
end
