for u <- [
  "https://firebasestorage.googleapis.com/v0/b/app.appspot.com/o/a.jpg?alt=media&token=1b2c-SECRET",
  "https://x.supabase.co/storage/v1/object/sign/b/a.jpg?token=eyJSECRET",
  "https://b.oss-cn-hangzhou.aliyuncs.com/a.jpg?OSSAccessKeyId=STS.x&Expires=1&Signature=s&security-token=SECRETSTS",
  "https://b.oss-cn-hangzhou.aliyuncs.com/a.jpg?x-oss-signature-version=OSS4-HMAC-SHA256&x-oss-credential=c&x-oss-signature=SECRETSIG&x-oss-security-token=SECRETSTS",
  "https://b.cos.ap-guangzhou.myqcloud.com/a.jpg?q-sign-algorithm=sha1&q-ak=AK&q-signature=SECRETSIG&x-cos-security-token=SECRETSTS",
  "https://cdn.example.com/a.jpg?__token__=exp=1~hmac=SECRET",
  "https://example.b-cdn.net/a.jpg?token=SECRET&expires=1",
  "https://f.backblazeb2.com/file/b/a.jpg?Authorization=SECRET",
  "https://api.example.com/img?access_token=SECRET&api_key=SECRET2",
  "https://b.s3.amazonaws.com/a.jpg?X-Amz-Signature=s&X-Amz-Credential=c&X-Amz-Security-Token=t",
  "https://h/a.jpg?X-Amz-Signature%00=SECRET",
  "https://h/a.jpg?X%2DAmz%2DSignature=SECRET",
  "https://h/a.jpg?x-amz-signature=a=b&",
  "https://h/a.jpg?a=1&&X-Amz-Signature=SECRET#frag?X-Amz-Signature=SECRET2",
  "https://us%3Aer:p@ss@h/a.jpg",
  "//user:pass@h/a.jpg",
  "user:pass@h/a.jpg",
] do
  IO.puts(ImagePipe.Telemetry.source_url(u))
end
