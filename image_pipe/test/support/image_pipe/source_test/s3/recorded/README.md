# Recorded AWS credential responses

Real response bodies from AWS-compatible servers, replayed by the S3
credential-provider unit tests so their parsers see real response shapes
rather than hand-written stubs.

| File | Server | Request |
| --- | --- | --- |
| `assume_role.xml` | `localstack/localstack:3` (`SERVICES=sts`) | STS `AssumeRole` |
| `web_identity.xml` | `localstack/localstack:3` (`SERVICES=sts`) | STS `AssumeRoleWithWebIdentity` |
| `imds_credentials.json` | `public.ecr.aws/aws-ec2/amazon-ec2-metadata-mock:v1.13.0` | IMDSv2 `GET /latest/meta-data/iam/security-credentials/<role>` |

To re-record, run the containers and save the bodies with curl:

```bash
docker run -d --rm --name sts -e SERVICES=sts -p 4566:4566 localstack/localstack:3
docker run -d --rm --name imds -p 1338:1338 public.ecr.aws/aws-ec2/amazon-ec2-metadata-mock:v1.13.0

curl -s -o assume_role.xml -X POST localhost:4566/ \
  --data 'Action=AssumeRole&Version=2011-06-15&RoleArn=arn:aws:iam::000000000000:role/image-pipe&RoleSessionName=image-pipe'
curl -s -o web_identity.xml -X POST localhost:4566/ \
  --data 'Action=AssumeRoleWithWebIdentity&Version=2011-06-15&RoleArn=arn:aws:iam::000000000000:role/image-pipe-eks&RoleSessionName=image-pipe&WebIdentityToken=x'

token=$(curl -s -X PUT localhost:1338/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')
role=$(curl -s -H "X-aws-ec2-metadata-token: $token" localhost:1338/latest/meta-data/iam/security-credentials/)
curl -s -o imds_credentials.json -H "X-aws-ec2-metadata-token: $token" \
  "localhost:1338/latest/meta-data/iam/security-credentials/$role"
```

The servers return test credentials, but LocalStack's look real enough that
GitHub push protection blocks them, so the access key ID, secret key and
session token in the STS files are replaced with AWS documentation example
values. Everything else is as recorded.
