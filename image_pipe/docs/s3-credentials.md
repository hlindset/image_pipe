# S3 credentials

The `credentials` option on an [S3 source mount](sources.md#s3-compatible-storage) resolves the AWS credentials used to sign S3
requests. Use static keys or a provider that refreshes temporary credentials.

**Static keys** — long-lived access key + secret (plus an optional session
token):

```elixir
credentials:
  {:static, [access_key_id: "AKIA…", secret_access_key: "…", token: nil]}
```

Reading the standard AWS environment variables is a host concern — map them to
static keys yourself:

```elixir
credentials:
  {:static,
   [
     access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
     secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
     token: System.get_env("AWS_SESSION_TOKEN")
   ]}
```

**Provider** — a pluggable module that resolves temporary credentials at
runtime, selected as `{:provider, Module, opts}`. ImagePipe ships these providers:

- **EC2 instance role (incl. Elastic Beanstalk), via IMDSv2:**

  ```elixir
  credentials: {:provider, ImagePipe.Source.S3.InstanceRole, []}
  ```

- **ECS / Fargate / EKS container credentials:**

  ```elixir
  credentials:
    {:provider, ImagePipe.Source.S3.ContainerCredentials,
     relative_uri: System.get_env("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"),
     auth_token: System.get_env("AWS_CONTAINER_AUTHORIZATION_TOKEN")}
  ```

  `full_uri` is accepted only for a loopback host or over `https` (mirroring
  AWS), so a misconfigured URI cannot leak the auth token off-box. If your
  platform injects `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` instead of an inline
  token, read the file in the host and pass its contents as `:auth_token`.

- **STS `AssumeRole` (cross-account):** a composing wrapper. It resolves a base
  provider's credentials and signs an STS `AssumeRole` call with them to obtain
  temporary credentials for a role in another account.

  ```elixir
  credentials:
    {:provider, ImagePipe.Source.S3.AssumeRole,
     base: {:provider, ImagePipe.Source.S3.InstanceRole, []},
     role_arn: "arn:aws:iam::123456789012:role/image-read",
     external_id: "optional-external-id",
     region: "eu-west-1"}
  ```

  The base config (`:base`) is any other credential shape (`{:static, …}` or
  `{:provider, …}`) whose role is allowed to assume `:role_arn`; it is resolved
  through its own cache entry. `:external_id` is optional. The base credentials
  and the assumed credentials are each cached and refreshed before expiry.

- **EKS / IRSA, via STS `AssumeRoleWithWebIdentity`:** reads the projected OIDC
  token file (re-read on every refresh, since it rotates) and exchanges it for
  temporary credentials with an unsigned STS call.

  ```elixir
  credentials:
    {:provider, ImagePipe.Source.S3.WebIdentity,
     token_file: System.get_env("AWS_WEB_IDENTITY_TOKEN_FILE"),
     role_arn: System.get_env("AWS_ROLE_ARN"),
     region: System.get_env("AWS_REGION")}
  ```

Both STS providers call the regional endpoint (`sts.<region>.amazonaws.com`) and
cache through the same refresh cache as the others — one STS call per credential
lifetime, fail-closed on expiry. `:region` is mandatory on both providers.

Hosts can implement their own provider with the
`ImagePipe.Source.S3.CredentialProvider` behaviour.

Provider results are cached per `{provider, opts, bucket}` and refreshed before
expiry. **Expired credentials are never sent to S3**: if refresh fails after the
cached credentials expire, the request fails closed with
`{:source, :credentials_unavailable}`. To avoid first-request latency, add the
optional warm-up worker to the host supervision tree:

```elixir
{ImagePipe.Source.S3.CredentialWarmup,
 provider: ImagePipe.Source.S3.InstanceRole, opts: [], scope: "my-bucket"}
```
