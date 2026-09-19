defmodule ImagePipe.Plan.ResponseTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Response

  test "renders attachment with ASCII filename parameters" do
    response = %Response{disposition: :attachment, filename: "report"}

    assert Response.content_disposition(response, "image/webp") ==
             {:ok, ~s(attachment; filename="report.webp")}
  end

  test "renders encoded filename and UTF-8 filename star when filename needs encoding" do
    response = %Response{disposition: :inline, filename: "katt-æøå"}

    assert Response.content_disposition(response, "image/webp") ==
             {:ok,
              ~s(inline; filename="katt-%C3%A6%C3%B8%C3%A5.webp"; filename*=utf-8''katt-%C3%A6%C3%B8%C3%A5.webp)}
  end

  test "uses encoded filename when the whole stem needs encoding" do
    response = %Response{disposition: :inline, filename: "東京"}

    assert Response.content_disposition(response, "image/png") ==
             {:ok,
              ~s(inline; filename="%E6%9D%B1%E4%BA%AC.png"; filename*=utf-8''%E6%9D%B1%E4%BA%AC.png)}
  end

  test "uses canonical extensions for complete-body terminals" do
    response = %Response{disposition: :attachment, filename: "report"}

    assert Response.content_disposition(response, "application/json") ==
             {:ok, ~s(attachment; filename="report.json")}

    assert Response.content_disposition(response, "text/plain") ==
             {:ok, ~s(attachment; filename="report.txt")}
  end

  test "rejects unsupported cached content type for delivery filename extension" do
    response = %Response{disposition: :inline, filename: "report"}

    assert Response.content_disposition(response, "image/gif") ==
             {:error, {:unsupported_delivery_content_type, "image/gif"}}
  end
end
