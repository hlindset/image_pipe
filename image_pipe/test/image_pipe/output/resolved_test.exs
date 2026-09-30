defmodule ImagePipe.Output.ResolvedTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch

  test "Resolved carries quality_search and max_bytes, defaulting off" do
    r = %Resolved{
      format: :jpeg,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }

    assert r.quality_search == :none
    assert r.max_bytes == nil
  end

  test "ResolvedQualitySearch holds a format-clamped bracket" do
    s = %ResolvedQualitySearch.Ssimulacra2{
      target: 90.0,
      min_quality: 60,
      max_quality: 65,
      allowed_error: 1.0
    }

    assert s.min_quality == 60 and s.max_quality == 65
  end
end
