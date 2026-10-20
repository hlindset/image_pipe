defmodule ImagePipeServer.LogHandlerTest do
  # Sets IPS_CONFIG_TOML, which the rest of the suite must not see.
  use ExUnit.Case, async: false

  @config_dir Path.expand("../../config", __DIR__)

  test "the running server's log handler drops lines instead of blocking or rate-limiting" do
    assert {:ok, %{config: config}} = :logger.get_handler_config(:default)
    assert_overload_options(config)
  end

  test "the release keeps the overload options with every log format" do
    for format <- ["text", "json", "gcp"] do
      handler =
        release_logger_config(~s([telemetry]\nlog_format = "#{format}"\n))[:default_handler]

      assert Keyword.has_key?(handler, :formatter) == (format != "text")
      assert_overload_options(Map.new(Keyword.fetch!(handler, :config)))
    end
  end

  defp assert_overload_options(config) do
    assert config.burst_limit_enable == false
    assert config.sync_mode_qlen == config.drop_mode_qlen
    assert config.drop_mode_qlen >= 1000
  end

  defp release_logger_config(toml) do
    System.put_env("IPS_CONFIG_TOML", toml)

    try do
      @config_dir
      |> Path.join("config.exs")
      |> Config.Reader.read!(env: :prod, target: :host)
      |> Config.Reader.merge(
        Config.Reader.read!(Path.join(@config_dir, "runtime.exs"),
          env: :prod,
          target: :host,
          imports: :disabled
        )
      )
      |> Keyword.fetch!(:logger)
    after
      System.delete_env("IPS_CONFIG_TOML")
    end
  end
end
