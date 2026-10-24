Code.require_file("common.exs", __DIR__)
d = T.dir()
base = %{"IPS_URL__ALLOW_UNSIGNED" => "true"}
e = fn m -> Map.merge(base, m) end
tm = fn s -> e.(%{"IPS_CONFIG_TOML" => s}) end
w = fn name, c -> p = d <> "/" <> name; File.write!(p, c); p end
T.show("fq ok atom", tm.("[processing]\nformat_quality = { ok = 80 }\n"), fn c -> T.opts(c)[:format_quality] end)
T.show("fq gif", tm.("[processing]\nformat_quality = { gif = 80 }\n"), fn c -> T.opts(c)[:format_quality] end)
T.show("fq unknown", tm.("[processing]\nformat_quality = { zzqqxx = 80 }\n"))
T.show("port str", tm.("[server]\nport = \"SECRETVAL\"\n"))
T.show("log_level", tm.("[telemetry]\nlog_level = \"SECRETVAL\"\n"))
T.show("bind", tm.("[server]\nbind = \"SECRETVAL\"\n"))
T.show("quality_file", e.(%{"IPS_PROCESSING__QUALITY_FILE" => w.("q", "SECRETVAL")}))
T.show("quality_file 500", e.(%{"IPS_PROCESSING__QUALITY_FILE" => w.("q2", "500")}))
T.show("request_defaults_file", e.(%{"IPS_PROCESSING__REQUEST_DEFAULTS_FILE" => w.("rd", "SECRETVAL=1")}))
T.show("http base_url_file", e.(%{"IPS_SOURCES__W__ADAPTER" => "http", "IPS_SOURCES__W__MATCH__PREFIX" => "w", "IPS_SOURCES__W__BASE_URL_FILE" => w.("bu", "ftp://SECRETVAL.example/x")}))
T.show("http allowed_hosts_file", e.(%{"IPS_SOURCES__W__ADAPTER" => "http", "IPS_SOURCES__W__MATCH__SCHEME" => "https", "IPS_SOURCES__W__ALLOWED_HOSTS_FILE" => w.("ah", "SECRET VAL/x")}))
T.show("allow_origin_file", e.(%{"IPS_HTTP__ALLOW_ORIGIN_FILE" => w.("ao", "SECRET\nVAL")}))
T.show("presets", e.(%{"IPS_PROCESSING__PRESETS__CARD_FILE" => w.("pr", "SECRETVAL=3")}))
T.show("watermark", e.(%{"IPS_PROCESSING__WATERMARKS__L__SOURCE_FILE" => w.("wm", "http://SECRETVAL/x.png")}))
T.show("s3 endpoint", e.(%{"IPS_SOURCES__M__ADAPTER" => "s3", "IPS_SOURCES__M__MATCH__SCHEME" => "s3", "IPS_SOURCES__M__REGION" => "r", "IPS_SOURCES__M__ENDPOINT_FILE" => w.("ep", "SECRETVAL")}))
T.show("assume role ext id", tm.("[sources.m]\nadapter=\"s3\"\nmatch={scheme=\"s3\"}\nregion=\"r\"\nendpoint=\"https://s3.x.com\"\ncredentials={provider=\"assume_role\", role_arn=\"SECRETVAL\", region=\"r\", external_id=5}\n"))
