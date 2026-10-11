# Credo configuration: Credo's default checks plus ExSlop's, as in
# image_pipe_url. List only overrides here.
%{
  configs: [
    %{
      name: "default",
      plugins: [{ExSlop, []}],
      checks: [
        {Credo.Check.Refactor.DoubleBooleanNegation, []},
        {Credo.Check.Refactor.MapMap, []}
      ]
    }
  ]
}
