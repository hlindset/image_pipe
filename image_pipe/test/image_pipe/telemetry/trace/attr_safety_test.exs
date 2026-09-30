defmodule ImagePipe.Telemetry.Trace.AttrSafetyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}

  setup do
    TestExporter.set_receiver(self())
    :ok = TestExporter.attach(self())

    on_exit(fn ->
      Telemetry.detach_tracer()
      TestExporter.clear_receiver()
    end)

    :ok
  end

  test "a signed source URL in metadata never reaches span attributes" do
    signed = "https://cdn.example.com/img.jpg?sig=SECRET123&exp=999"

    Telemetry.span(
      [],
      [:source, :fetch],
      %{source_url: signed, source_path: "/img.jpg?sig=SECRET123", source_kind: :http},
      fn ->
        {:ok, %{result: :ok}}
      end
    )

    assert_receive {:span, %Span{name: "image_pipe.source.fetch"} = span}
    flat = inspect(span.attributes)
    refute flat =~ "SECRET123"
    refute flat =~ "cdn.example.com"
    # product-neutral key is allowed through
    assert span.attributes[:source_kind] == :http
  end

  property "no secret-bearing key ever reaches attributes, for any value" do
    check all(
            body <- StreamData.string(:alphanumeric, min_length: 1),
            key <-
              StreamData.member_of([
                :source_url,
                :source_path,
                :signature,
                :token,
                :authorization
              ])
          ) do
      # A distinctive marker prefix so the substring check tests the secret VALUE
      # leaking through, not incidental collisions with allowlisted values
      # (e.g. ":http" contains "p").
      secret = "SECRET_" <> body

      Telemetry.span([], [:source, :fetch], %{key => secret, :source_kind => :http}, fn ->
        {:ok, %{result: :ok}}
      end)

      assert_receive {:span, %Span{name: "image_pipe.source.fetch"} = span}
      refute inspect(span.attributes) =~ secret
      # The secret-bearing key itself must never be present in attributes.
      refute Map.has_key?(span.attributes, key)
    end
  end
end
