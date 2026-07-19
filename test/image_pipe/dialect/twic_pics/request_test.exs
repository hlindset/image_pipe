defmodule ImagePipe.Dialect.TwicPics.RequestTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.TwicPics.Request
  alias ImagePipe.Plan.Operation.Blur
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Response
  alias ImagePipe.Plan.Source.Path

  test "enforces exactly the canonical request fields" do
    canonical_fields = [:source, :steps, :output, :response, :auto_rotate]

    request_fields =
      Request
      |> struct()
      |> Map.from_struct()
      |> Map.keys()

    assert MapSet.new(request_fields) == MapSet.new(canonical_fields)

    attrs = Map.new(canonical_fields, &{&1, nil})

    Enum.each(canonical_fields, fn field ->
      assert_raise ArgumentError, fn -> struct!(Request, Map.delete(attrs, field)) end
    end)
  end

  test "constructs every ordered semantic step form" do
    operation = %Blur{sigma: 1.5}

    focused = %CropGuided{
      width: {:px, 40},
      height: {:px, 30},
      guide: :center
    }

    steps = [
      {:set_focus, {:coord, {:px, 10}, {:ratio, 1, 2}}},
      :set_auto_focus,
      {:operation, operation},
      {:focused, focused}
    ]

    request = request(steps)

    assert request.steps == steps
  end

  test "canonical request terms recursively exclude framework strategy and runtime vocabulary" do
    request =
      request([
        {:set_focus, {:anchor, :left, :top}},
        :set_auto_focus,
        {:operation, %Blur{sigma: 1.5}},
        {:focused, %CropGuided{width: {:px, 40}, height: {:px, 30}, guide: :center}}
      ])

    assert forbidden_terms(request) == []
  end

  test "forbidden-vocabulary scan descends recursively and recognizes every rejected form" do
    assert match?([{:raw_pair, _}], forbidden_terms(%{nested: [{"resize", "40x30"}]}))
    assert match?([{:conn, _}], forbidden_terms(%Plug.Conn{}))
    assert match?([{:pid, _}], forbidden_terms(self()))
    assert match?([{:reference, _}], forbidden_terms(make_ref()))
  end

  defp request(steps) do
    %Request{
      source: %Path{segments: ["images", "cat.jpg"]},
      steps: steps,
      output: %Output{mode: :automatic},
      response: %Response{},
      auto_rotate: true
    }
  end

  defp forbidden_terms(term), do: do_forbidden_terms(term, [])

  defp do_forbidden_terms(%Plug.Conn{} = conn, violations),
    do: [{:conn, conn} | violations]

  defp do_forbidden_terms(term, violations) when is_pid(term),
    do: [{:pid, term} | violations]

  defp do_forbidden_terms(term, violations) when is_reference(term),
    do: [{:reference, term} | violations]

  defp do_forbidden_terms(module, violations) when is_atom(module) do
    case module |> Atom.to_string() |> String.contains?("Resolver") do
      true -> [{:resolver, module} | violations]
      false -> violations
    end
  end

  defp do_forbidden_terms({name, args} = pair, violations)
       when is_binary(name) and is_binary(args),
       do: [{:raw_pair, pair} | violations]

  defp do_forbidden_terms(%_{} = struct, violations),
    do: do_forbidden_terms(Map.from_struct(struct), violations)

  defp do_forbidden_terms(map, violations) when is_map(map) do
    Enum.reduce(map, violations, fn {key, value}, acc ->
      acc = do_forbidden_terms(key, acc)
      do_forbidden_terms(value, acc)
    end)
  end

  defp do_forbidden_terms(list, violations) when is_list(list),
    do: Enum.reduce(list, violations, &do_forbidden_terms/2)

  defp do_forbidden_terms(tuple, violations) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(violations, &do_forbidden_terms/2)
  end

  defp do_forbidden_terms(_term, violations), do: violations
end
