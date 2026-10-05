defmodule ImagePipe.URL.HelpersTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  defmodule Images do
    def config, do: ImagePipe.URL.config(base_url: "/images")
  end

  defmodule Page do
    use ImagePipe.URL.Helpers, config: {ImagePipe.URL.HelpersTest.Images, :config, []}

    def thumbnail(source), do: image_url(source, group: [resize: [width: 300, fit: :cover]])

    def sized(source, width, fit),
      do: image_url(source, group: [resize: [width: width, fit: fit]], output: [format: :webp])

    def everything(source) do
      image_url(source,
        new: [filename: "cat"],
        group: [crop: {100, 100}],
        group: [blur: 2],
        output: [quality: 80]
      )
    end
  end

  defmodule StrictPage do
    use ImagePipe.URL.Helpers, on_invalid: :raise

    def sized(source, fit), do: image_url(source, group: [resize: [width: 10, fit: fit]])
  end

  test "builds the URL from the configuration and the options" do
    assert Page.thumbnail("cat.jpg") == "/images/w=300/fit=cover/src/cat.jpg"

    assert Page.everything("cat.jpg") ==
             "/images/crop=100,100/-/blur=2/q=80/filename=cat/src/cat.jpg"
  end

  test "variable values are used at render" do
    assert Page.sized("cat.jpg", 200, :contain) ==
             "/images/w=200/fit=contain/format=webp/src/cat.jpg"
  end

  test "a bad value at render gives a URL the server rejects, and a warning" do
    log =
      capture_log(fn ->
        assert Page.sized("cat.jpg", 200, :fill) ==
                 "/images/w=200/fit=!fill/format=webp/src/cat.jpg"
      end)

    assert log =~
             "image_url (test/image_pipe/url/helpers_test.exs:17): invalid_value at {:group, 0, :fit}"

    refute log =~ "cat.jpg"
  end

  test "an invalid source gives a URL and a warning" do
    log = capture_log(fn -> assert Page.thumbnail(nil) == "/images/w=300/fit=cover/src/" end)
    assert log =~ "invalid_source"
  end

  test "on_invalid: :raise raises for an error" do
    assert StrictPage.sized("cat.jpg", :cover) == "/w=10/fit=cover/src/cat.jpg"

    assert_raise ArgumentError, ~r/invalid_value/, fn -> StrictPage.sized("cat.jpg", :fill) end
  end

  test "a literal mistake is a compile warning at the call site" do
    stderr =
      capture_io(:stderr, fn ->
        Code.compile_string(
          """
          defmodule ImagePipe.URL.HelpersTest.LiteralWarning do
            use ImagePipe.URL.Helpers

            def a, do: image_url("a.jpg", group: [resize: [width: 300, fit: :fill]])
          end
          """,
          "literal_warning.ex"
        )
      end)

    assert stderr =~ "invalid value for :fit option"
    assert stderr =~ "literal_warning.ex:4"
  end

  test "a literal mistake in a HEEx template warns at the template line" do
    stderr =
      capture_io(:stderr, fn ->
        Code.compile_string(
          ~S'''
          defmodule ImagePipe.URL.HelpersTest.HEExWarning do
            use Phoenix.Component
            use ImagePipe.URL.Helpers

            def page(assigns) do
              ~H"""
              <div>
                <img src={image_url("a.jpg", group: [resize: [width: 300, fit: :fill]])} />
              </div>
              """
            end
          end
          ''',
          "heex_warning.ex"
        )
      end)

    assert stderr =~ "invalid value for :fit option"
    assert stderr =~ "heex_warning.ex:8"
  end

  test "names are checked at compile time even when values are variables" do
    stderr =
      capture_io(:stderr, fn ->
        Code.compile_string(
          """
          defmodule ImagePipe.URL.HelpersTest.NameWarning do
            use ImagePipe.URL.Helpers

            def a(w, s), do: image_url("a.jpg", group: [resize: [width: w], shape: s])
          end
          """,
          "name_warning.ex"
        )
      end)

    assert stderr =~ "unknown_option at {:group, 0, :shape}"
    refute stderr =~ ":width"
  end

  test "negative literals and misplaced names in new: and output: are checked" do
    stderr =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule ImagePipe.URL.HelpersTest.MoreWarnings do
          use ImagePipe.URL.Helpers

          def a(p), do: image_url("a.jpg", group: [blur: -1], output: [presets: p])
        end
        """)
      end)

    assert stderr =~ "invalid_value at {:group, 0, :blur}"
    assert stderr =~ "unknown_option at {:request, :presets}"
    refute stderr =~ "{:request, :blur}"
  end

  test "repaired mistakes are compile warnings too" do
    stderr =
      capture_io(:stderr, fn ->
        Code.compile_string(
          """
          defmodule ImagePipe.URL.HelpersTest.RepairWarning do
            use ImagePipe.URL.Helpers

            def a, do: image_url("a.jpg", group: [blur: 1, blur: 2])
          end
          """,
          "repair_warning.ex"
        )
      end)

    assert stderr =~ "repeated_option at {:group, 0, :blur}"
  end

  test "valid calls compile without warnings" do
    assert capture_io(:stderr, fn ->
             Code.compile_string("""
             defmodule ImagePipe.URL.HelpersTest.NoWarning do
               use ImagePipe.URL.Helpers

               def a(w), do: image_url("a.jpg", group: [resize: [width: w, fit: :cover]])
               def b(r), do: image_url("a.jpg", group: [resize: r])
               def c(p), do: image_url("a.jpg", group: [presets: p])

               def d,
                 do:
                   image_url("a.jpg",
                     group: [region: {0, 0, 20, 20}, anchor_offset: {-5, 3}, crop: {20, 20}]
                   )
             end
             """)
           end) == ""
  end

  test "instance: needs image_pipe" do
    assert_raise ArgumentError, ~r/image_pipe/, fn ->
      Code.compile_string("""
      defmodule ImagePipe.URL.HelpersTest.NoImagePipe do
        use ImagePipe.URL.Helpers, instance: MyApp.Images
      end
      """)
    end
  end

  test "options must be literal keyword lists" do
    assert_raise ArgumentError, ~r/literal keyword list/, fn ->
      Code.compile_string("""
      defmodule ImagePipe.URL.HelpersTest.Dynamic do
        use ImagePipe.URL.Helpers

        def a(options), do: image_url("a.jpg", group: options)
      end
      """)
    end
  end
end
