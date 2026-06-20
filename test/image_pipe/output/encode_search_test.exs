defmodule ImagePipe.Output.EncodeSearchTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS

  test "size picks the highest quality under the byte target" do
    rs = %RQS{objective: :size, target: 50_000, min_quality: 10, max_quality: 80}
    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end

    assert {:ok, _bin, %{quality: 50, outcome: :hit}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, max_iterations: 8)
  end

  test "size best-effort returns min_quality when even the floor exceeds the budget" do
    rs = %RQS{objective: :size, target: 5_000, min_quality: 10, max_quality: 80}
    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end

    assert {:ok, _bin, %{quality: 10, outcome: :best_effort}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, max_iterations: 8)
  end

  test "ssim2 picks the lowest quality clearing the tolerance band" do
    rs = %RQS{
      objective: :ssim2,
      target: 90.0,
      min_quality: 10,
      max_quality: 80,
      allowed_error: 0.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> byte_size(bin) / 100 + 20.0 end

    assert {:ok, _bin, %{quality: 70, outcome: :hit, score: s}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)

    assert s >= 90.0
  end

  test "ssim2 reports :hit at the default iteration cap on a realistic bracket" do
    rs = %RQS{
      objective: :ssim2,
      target: 90.0,
      min_quality: 70,
      max_quality: 80,
      allowed_error: 0.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> byte_size(bin) / 100 + 20.0 end

    assert {:ok, _bin, %{quality: 70, outcome: :hit}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 6)
  end

  test "ssim2 allowed_error loosens the band downward" do
    rs = %RQS{
      objective: :ssim2,
      target: 90.0,
      min_quality: 10,
      max_quality: 80,
      allowed_error: 5.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> byte_size(bin) / 100 + 20.0 end

    assert {:ok, _bin, %{quality: 65}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)
  end

  test "ssim2 best-effort returns max_quality when target unreachable" do
    rs = %RQS{
      objective: :ssim2,
      target: 99.0,
      min_quality: 10,
      max_quality: 80,
      allowed_error: 0.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> byte_size(bin) / 100 / 2.0 end

    assert {:ok, _bin, %{quality: 80, outcome: :best_effort}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)
  end

  test "max_bytes lowers the ssim2 pick when it exceeds the budget" do
    rs = %RQS{
      objective: :ssim2,
      target: 80.0,
      min_quality: 10,
      max_quality: 90,
      allowed_error: 0.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end
    score = fn bin -> byte_size(bin) / 1000 end

    # meta.score must reflect the DELIVERED q=60 (score == q == 60.0), not the
    # objective pick's q=80 score.
    assert {:ok, _bin, %{quality: 60, score: 60.0}} =
             EncodeSearch.search(rs, 60_000,
               encode_fun: enc,
               score_fun: score,
               max_iterations: 16
             )
  end

  test "max_bytes alone searches [10, base] for the highest fit" do
    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end

    assert {:ok, _bin, %{quality: 40}} =
             EncodeSearch.search(:none, 40_000,
               encode_fun: enc,
               base_quality: 90,
               max_iterations: 8
             )
  end

  # Task 13b
  test "skip?/2 true when megapixels exceed a positive max_resolution" do
    assert EncodeSearch.skip?(%{max_resolution: 2}, 5)
    refute EncodeSearch.skip?(%{max_resolution: 0}, 100)
    refute EncodeSearch.skip?(%{max_resolution: 10}, 5)
  end
end
