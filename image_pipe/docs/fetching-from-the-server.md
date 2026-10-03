# Fetching images from the server

Use a processed image, placeholder, or image information inside your
application by requesting its signed URL with an HTTP client. This guide
assumes your application builds URLs for an ImagePipe server running
elsewhere (see [URL builder with an external server](external-server.md)).

`image_pipe_url` has no fetch function. The signed URL is the interface, so
any HTTP client works. The examples use [Req](https://hexdocs.pm/req) 0.8,
currently a release candidate. `Req.stream/4` needs it.

The server can only process images it reads from its own sources. An image
that exists only in your application, such as an upload, has to be stored
somewhere the server reads first, because the server has no upload
endpoint.

## Build URLs for the internal address

The signature covers only the part of the URL after the base URL, so a URL
signed for your CDN is also valid at the server's internal address. To skip
the CDN for server-side requests, build a second URL configuration with the
same keys and the server's internal address as `base_url`:

```elixir
internal = ImagePipe.URL.config(
  base_url: "http://image-service:4000/images",
  keys: signing_keys
)

url =
  ImagePipe.URL.new(internal)
  |> ImagePipe.URL.output(terminal: :lqip_css)
  |> ImagePipe.URL.url!(source)
```

Use the same settings as your public configuration otherwise, such as
`source_encryption_keys` and `encrypt_source`.

## Choose the format

Without a `format` in the plan, the server returns AVIF or WebP when the
request's `Accept` header lists it, and otherwise the original's format where
possible. Set `format:` with `ImagePipe.URL.output/2` to get one fixed
format.

## Buffer small results

Read placeholders, image information, and thumbnails into memory:

```elixir
case Req.get(url,
       decode_body: false,
       receive_timeout: 30_000,
       headers: [accept: "image/avif,image/webp"]
     ) do
  {:ok, %Req.Response{status: 200, body: body} = response} ->
    [content_type] = Req.Response.get_header(response, "content-type")
    {:ok, body, content_type}

  {:ok, %Req.Response{status: status}} ->
    {:error, {:http_status, status}}

  {:error, exception} ->
    {:error, exception}
end
```

For the `lqip_css` URL above, this returns
`{:ok, "#ddd97765", "text/plain; charset=utf-8"}`.

- `decode_body: false` keeps every body as raw bytes, including the JSON of
  image information.
- Req returns error responses as `{:ok, response}`, so check the status. A
  `4xx` means the server rejected the request: an invalid option (`400`), a
  bad signature (`403`), a missing source (`404`), or an expired URL
  (`410`). Retrying won't help. Req retries transient failures, such as a
  `503`, by default.
- Set `receive_timeout` above the time your slowest image takes to process
  the first time. Cached results return quickly.

## Stream large results to a file

Write large images to a file instead of holding them in memory:

```elixir
case Req.get(url,
       decode_body: false,
       receive_timeout: 60_000,
       into: File.stream!(path)
     ) do
  {:ok, %Req.Response{status: 200}} ->
    :ok

  {:ok, %Req.Response{status: status}} ->
    {:error, {:http_status, status}}

  {:error, exception} ->
    File.rm(path)
    {:error, exception}
end
```

Req writes to the file only for a `200` response. A connection that fails
partway leaves part of the image in the file, so remove it on an error.

## Pass chunks onward

To forward chunks as they arrive, for example to a `Plug.Conn` already
switched to a chunked response, use `Req.stream/4`. Its function gets the
response status with each chunk, so it can stop before forwarding an error
body:

```elixir
result =
  Req.stream(url, conn, fn
    chunk, %Req.Response{status: 200}, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      {:cont, conn}

    _chunk, _response, conn ->
      {:halt, conn}
  end, decode_body: false)

case result do
  {:ok, %Req.Response{status: 200}, conn} -> {:ok, conn}
  {:ok, %Req.Response{status: status}, conn} -> {:error, {:http_status, status}, conn}
  {:error, exception, _response, conn} -> {:error, exception, conn}
end
```

## Next steps

- [Shared URL settings](shared-url-settings.md): the settings your
  application and the server must match.
- [Error responses](errors.md): every error status and what causes it.
- [Output and encoding](processing/output.md): placeholders, image
  information, and output formats.
