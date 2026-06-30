defmodule ImagePipe.Response.ErrorStatusTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Response.ErrorStatus

  describe "resolve_status/1 — status axis" do
    test "transform bad_request details all map to 400 (open detail)" do
      assert {400, _} =
               ErrorStatus.resolve_status({:transform_error, {:bad_request, :upscale_required}})

      assert {400, _} =
               ErrorStatus.resolve_status({:transform_error, {:bad_request, :some_future_detail}})
    end

    test "generic transform / plan-validation / empty pipeline stay 422" do
      assert {422, _} = ErrorStatus.resolve_status({:transform_error, {SomeMod, :boom}})
      assert {422, _} = ErrorStatus.resolve_status({:invalid_pipeline_operation, :x})
      assert {422, _} = ErrorStatus.resolve_status(:empty_pipeline_plan)
    end

    test "source transport reasons map imgproxy-shaped" do
      assert {404, _} = ErrorStatus.resolve_status({:source, :connect_error})
      assert {404, _} = ErrorStatus.resolve_status({:source, :too_many_redirects})
      assert {502, _} = ErrorStatus.resolve_status({:source, {:bad_status, 503}})
      assert {451, _} = ErrorStatus.resolve_status({:source, {:bad_status, 451}})
      assert {404, _} = ErrorStatus.resolve_status({:source, {:bad_status, 199}})
      assert {504, _} = ErrorStatus.resolve_status({:source, :receive_timeout})
      assert {422, _} = ErrorStatus.resolve_status({:source, :body_too_large})
      assert {422, _} = ErrorStatus.resolve_status({:source, :invalid_body})
      assert {500, _} = ErrorStatus.resolve_status({:source, :invalid_adapter_config})
    end

    test "unrecognized source reason falls back to 422; unknown top-level to 500" do
      assert {422, _} = ErrorStatus.resolve_status({:source, :some_host_adapter_reason})
      assert {500, _} = ErrorStatus.resolve_status(:totally_unknown)
    end

    test "decode/input-limit/unsupported-output unchanged" do
      assert {415, _} = ErrorStatus.resolve_status({:decode, :x})
      assert {415, _} = ErrorStatus.resolve_status(:source_format_required)
      assert {413, _} = ErrorStatus.resolve_status({:input_limit, :x})
      assert {501, _} = ErrorStatus.resolve_status({:unsupported_output_format, :jp2})
    end

    test "class-leading custom reason routes by class from any producer" do
      assert {404, _} = ErrorStatus.resolve_status({:source, {:not_found, :my_detail}})
      assert {504, _} = ErrorStatus.resolve_status({:render, {:source, :receive_timeout}})
    end

    test "passthrough echoes the code, clamping an out-of-range value to 502" do
      assert {451, _} = ErrorStatus.resolve_status({:source, {:passthrough, 451}})
      assert {502, _} = ErrorStatus.resolve_status({:source, {:passthrough, 999}})
    end
  end

  describe "resolve_status/1 — message axis" do
    test "messages are distinct across reasons and never embed a URL" do
      reasons = [
        {:transform_error, {:bad_request, :upscale_required}},
        {:transform_error, {SomeMod, :boom}},
        {:source, :connect_error},
        {:source, :too_many_redirects},
        {:source, {:bad_status, 503}},
        {:source, :receive_timeout},
        {:source, :body_too_large},
        {:source, :invalid_body},
        {:decode, :x},
        {:input_limit, :x},
        {:unsupported_output_format, :jp2}
      ]

      messages = Enum.map(reasons, fn r -> elem(ErrorStatus.resolve_status(r), 1) end)

      assert length(Enum.uniq(messages)) == length(messages), "messages must be distinct"
      assert Enum.all?(messages, &(not String.contains?(&1, ["http://", "https://"])))
    end

    test "bad_status message interpolates the upstream code" do
      assert {_, "upstream responded 503"} =
               ErrorStatus.resolve_status({:source, {:bad_status, 503}})
    end
  end
end
