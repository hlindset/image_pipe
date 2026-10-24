Code.require_file("common.exs", __DIR__)
d = T.dir(); File.mkdir_p!(d <> "/imgs")
k = T.key(); k2 = String.duplicate("4567ef01", 8)
base = %{"IPS_URL__ALLOW_UNSIGNED" => "true"}
src = %{"IPS_SOURCES__P__ADAPTER" => "file", "IPS_SOURCES__P__MATCH" => "path", "IPS_SOURCES__P__ROOT" => d <> "/imgs", "IPS_SOURCES__P__ROOT_ID" => "p"}
e = fn m -> Map.merge(Map.merge(base, src), m) end
sources = fn c -> Keyword.get(T.opts(c), :sources).sources end

File.write!(d <> "/hdr", "secretvalue\n")
T.show("header file + bearer file", e.(%{"IPS_SOURCES__W__ADAPTER" => "http", "IPS_SOURCES__W__MATCH__PREFIX" => "w", "IPS_SOURCES__W__BASE_URL" => "https://x.com", "IPS_SOURCES__W__REQUEST_HEADERS__X-API-KEY_FILE" => d <> "/hdr", "IPS_SOURCES__W__BEARER_TOKEN_FILE" => d <> "/hdr"}), fn c -> :shown end)
T.show("web identity token_file", e.(%{"IPS_SOURCES__M__ADAPTER" => "s3", "IPS_SOURCES__M__MATCH__SCHEME" => "s3", "IPS_SOURCES__M__REGION" => "eu-west-1", "IPS_SOURCES__M__ENDPOINT" => "https://s3.eu-west-1.amazonaws.com", "IPS_SOURCES__M__CREDENTIALS__PROVIDER" => "web_identity", "IPS_SOURCES__M__CREDENTIALS__TOKEN_FILE" => "/var/run/tok", "AWS_ROLE_ARN" => "arn:aws:iam::1:role/x", "AWS_REGION" => "us-east-1"}), fn c -> elem(sources.(c)[:m],1) end)
T.show("container creds AWS env", e.(%{"IPS_SOURCES__M__ADAPTER" => "s3", "IPS_SOURCES__M__MATCH__SCHEME" => "s3", "IPS_SOURCES__M__REGION" => "eu-west-1", "IPS_SOURCES__M__ENDPOINT" => "https://s3.eu-west-1.amazonaws.com", "IPS_SOURCES__M__CREDENTIALS__PROVIDER" => "container_credentials", "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI" => "/v2/creds", "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE" => "/tok"}), fn c -> elem(sources.(c)[:m],1) end)
T.show("short auth token", e.(%{"IPS_SERVER__AUTH_TOKEN" => "short"}))
T.show("stats no token", e.(%{"IPS_STATS__ENABLED" => "true"}))
T.show("stats short", e.(%{"IPS_STATS__ENABLED" => "true", "IPS_STATS__TOKEN" => "abc"}))
for mp <- ["/images", "/images/", "//", "/a%20b", "images", "/a/b-c.d_e~f"], do: T.show("mount #{mp}", e.(%{"IPS_SERVER__MOUNT_PATH" => mp}), fn c -> c.server[:mount_path] end)
T.show("health same port", e.(%{"IPS_SERVER__HEALTH_PORT" => "8080"}))
T.show("vary_on env", e.(%{"IPS_CACHE__VARY_ON" => "x"}))
T.show("log level warning env", e.(%{"IPS_TELEMETRY__LOG_LEVEL" => "warning", "IPS_TELEMETRY__LOG_FORMAT" => "gcp"}), fn c -> {c.log_level, c.log_format} end)
T.show("watermark env", e.(%{"IPS_PROCESSING__WATERMARKS__LOGO__SOURCE" => "logo.png", "IPS_PROCESSING__WATERMARKS__LOGO__OPACITY" => "0.5"}), fn c -> T.opts(c)[:watermarks] end)
T.show("http cache env", e.(%{"IPS_HTTP__HTTP_CACHE" => "auto", "IPS_HTTP__ALLOW_ORIGIN" => "*"}), fn c -> c.http end)
T.show("svg env", e.(%{"IPS_PROCESSING__SVG__FONT_DIRS" => "/a,/b", "IPS_PROCESSING__SVG__MAX_BYTES" => "5"}), fn c -> T.opts(c)[:svg] end)
T.show("pool low prio", e.(%{"IPS_POOL__LOW_PRIORITY_MAX_CONCURRENCY" => "3"}), fn c -> c.pool end)
