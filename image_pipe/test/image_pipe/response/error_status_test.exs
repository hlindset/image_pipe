defmodule ImagePipe.Response.ErrorStatusTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Response.ErrorStatus

  describe "resolve_status/1 — status axis" do
    test "transform bad_request details all map to 400 (open detail)" do
      assert {400, _} =
               ErrorStatus.resolve_status({:transform, {:bad_request, :region_out_of_bounds}})

      assert {400, _} =
               ErrorStatus.resolve_status({:transform, {:bad_request, :some_future_detail}})
    end

    test "generic transform failures map to 422" do
      assert {422, _} = ErrorStatus.resolve_status({:transform, {SomeMod, :boom}})
    end

    test "missing capabilities map to 501" do
      assert {501, _} = ErrorStatus.resolve_status({:detector, :unavailable})
      assert {501, _} = ErrorStatus.resolve_status({:unsupported_output_format, :jp2})
    end

    test "sources that don't exist from the client's view map to 404" do
      for reason <- [
            :not_found,
            :denied_path,
            :denied_bucket,
            :denied_host,
            :denied_scheme,
            :denied_address,
            :invalid_object,
            {:bad_status, 401},
            {:bad_status, 403},
            {:bad_status, 404},
            {:bad_status, 410}
          ] do
        assert {404, _} = ErrorStatus.resolve_status({:source, reason}), inspect(reason)
      end
    end

    test "origin and transport failures map to 502" do
      for reason <- [
            :connect_error,
            :too_many_redirects,
            :redirect_not_followed,
            :invalid_redirect,
            {:bad_status, 400},
            {:bad_status, 429},
            {:bad_status, 451},
            {:bad_status, 503},
            {:bad_status, 199},
            {:bad_status, 302},
            :version_mismatch,
            :truncated_body,
            :invalid_body,
            :invalid_stream_chunk,
            :stream_exception,
            :some_host_adapter_reason
          ] do
        assert {502, _} = ErrorStatus.resolve_status({:source, reason}), inspect(reason)
      end
    end

    test "a slow origin maps to 504; ImagePipe's own timeout maps to 503" do
      assert {504, _} = ErrorStatus.resolve_status({:source, :receive_timeout})
      assert {503, _} = ErrorStatus.resolve_status({:processing, :timeout})
      assert {503, _} = ErrorStatus.resolve_status({:processing, :overloaded})

      assert {503, "image processing timeout"} =
               ErrorStatus.resolve_status({:session, :timeout})
    end

    test "host-side source failures map to 500" do
      for reason <- [:unreadable, :credentials_unavailable, :invalid_adapter_config] do
        assert {500, _} = ErrorStatus.resolve_status({:source, reason}), inspect(reason)
      end

      assert {500, _} = ErrorStatus.resolve_status({:decode, {:peek_failed, :eacces}})
      assert {500, _} = ErrorStatus.resolve_status(:totally_unknown)
    end

    test "oversized sources map to 413 whether measured in bytes or pixels" do
      assert {413, _} = ErrorStatus.resolve_status({:source, :body_too_large})
      assert {413, _} = ErrorStatus.resolve_status({:input_limit, :x})
    end

    test "sources that aren't a supported image map to 415" do
      assert {415, _} = ErrorStatus.resolve_status({:decode, :x})
      assert {415, _} = ErrorStatus.resolve_status(:source_format_required)
    end

    test "class-leading custom reason routes by class from any producer" do
      assert {404, _} = ErrorStatus.resolve_status({:source, {:not_found, :my_detail}})
      assert {502, _} = ErrorStatus.resolve_status({:source, {:bad_gateway, :my_detail}})
    end
  end

  describe "resolve_status/1 — message axis" do
    test "messages never embed a URL or an origin status code" do
      reasons = [
        {:transform, {:bad_request, :region_out_of_bounds}},
        {:transform, {SomeMod, :boom}},
        {:source, :connect_error},
        {:source, :too_many_redirects},
        {:source, {:bad_status, 403}},
        {:source, {:bad_status, 503}},
        {:source, :receive_timeout},
        {:source, :body_too_large},
        {:source, :invalid_body},
        {:decode, :x},
        {:input_limit, :x},
        {:unsupported_output_format, :jp2}
      ]

      for reason <- reasons do
        {_status, message} = ErrorStatus.resolve_status(reason)
        refute String.contains?(message, ["http://", "https://", "403", "503"]), message
      end
    end

    test "a concealed upstream rejection reads the same as a missing source" do
      assert {404, message} = ErrorStatus.resolve_status({:source, {:bad_status, 403}})
      assert {404, ^message} = ErrorStatus.resolve_status({:source, :not_found})
      assert {404, ^message} = ErrorStatus.resolve_status({:source, :denied_path})
    end
  end
end
