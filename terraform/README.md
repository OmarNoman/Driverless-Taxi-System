# Terraform - Week 7 AWS networking + registry

Provisions the AWS VPC and container registry that Week 8 will deploy the three
Node.js services onto: a public subnet for Mosquitto, private subnets for the
services and both databases, VPC endpoints instead of a NAT Gateway, and one ECR
repository per Node.js service. No ECS cluster, running containers, SQS, or
auto-scaling yet, that is Week 8. See `ARCHITECTURE.md` for the full design
rationale and `ROADMAP.md` for the Week 7 plan/validation trace.

## Prerequisites

- Terraform >= 1.7 (`terraform -version`).
- An AWS Academy Learner Lab session, since this account cannot create IAM
  roles/policies and only issues temporary STS credentials.

## Every session: get fresh credentials first

AWS Academy Learner Lab credentials expire after a few hours. At the start of
**every** work session:

1. Start the lab, open **AWS Details**, click **Show** next to AWS CLI credentials.
2. Copy the three values into your shell (PowerShell):

   ```powershell
   $env:AWS_ACCESS_KEY_ID = "..."
   $env:AWS_SECRET_ACCESS_KEY = "..."
   $env:AWS_SESSION_TOKEN = "..."
   $env:AWS_DEFAULT_REGION = "us-east-1"
   ```

   Never write these into any `.tf`, `.tfvars`, or other committed file. Terraform
   reads its region from `terraform.tfvars`, but the AWS CLI needs its own
   `AWS_DEFAULT_REGION` (or a `--region` flag on every command), it does not pick
   one up from Terraform's config, so set it here too or every `aws` command fails
   with `NoRegion`.
3. Confirm they work: `aws sts get-caller-identity`.

If a `plan`/`apply` fails partway through with an `ExpiredToken` error, just repeat
step 2 with a fresh set of credentials and re-run the same command, every resource
here is idempotent.

## Common errors

- **`aws: [ERROR]: An error occurred (NoRegion): You must specify a region.`** - you
  forgot `$env:AWS_DEFAULT_REGION = "us-east-1"` from step 2 above. This one is easy
  to forget because `terraform` commands don't need it (region comes from
  `terraform.tfvars` instead), only the `aws` CLI does. Fix: set it, then re-run the
  same `aws` command, no need to touch Terraform.
- **`ExpiredToken`** - see above, re-export fresh credentials and re-run.
- **`docker login` to ECR fails with `400 Bad Request`, then `docker push` fails with
  `no basic auth credentials`, even with a confirmed-valid token** - a PowerShell
  gotcha, not a real auth problem. PowerShell's pipeline re-terminates the line when
  writing a string to a native process's stdin regardless of `.Trim()` on the source
  string, which corrupts the base64 ECR token before `docker login --password-stdin`
  reads it. The only reliable fix is to bypass PowerShell's pipe entirely: write the
  token to a file with `-NoNewline`, then redirect that file into `docker login`'s
  stdin via `cmd /c` (OS-level redirection, not PowerShell's pipeline machinery).
  ```powershell
  $tokenFile = "$env:TEMP\ecr-token.txt"
  aws ecr get-login-password --region us-east-1 | Out-File -FilePath $tokenFile -Encoding ascii -NoNewline
  cmd /c "docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com < `"$tokenFile`""
  Remove-Item $tokenFile
  ```
- **`docker tag`/`docker push` fail with `failed to connect to the docker API at
  npipe:...`** - Docker Desktop isn't running. Start it and wait for it to fully
  come up before retrying.

## Commands

```powershell
cd terraform
terraform init
terraform validate
terraform plan      # review before applying - expect ~19 resources to add on a first run
terraform apply
```

Verify against the live account (not just the state file):

```powershell
aws ec2 describe-vpcs --filters "Name=tag:Project,Values=sit314-driverless-taxi"
aws ec2 describe-subnets --filters "Name=tag:Project,Values=sit314-driverless-taxi"
aws ec2 describe-vpc-endpoints --filters "Name=tag:Project,Values=sit314-driverless-taxi"
aws ec2 describe-security-groups --filters "Name=tag:Project,Values=sit314-driverless-taxi"
aws ecr describe-repositories
```

Prove the registry itself works (this happens over the public internet from your
own machine, it does not exercise the VPC endpoints - that only happens once a real
task tries to pull an image from inside the private subnet in Week 8):

```powershell
$tokenFile = "$env:TEMP\ecr-token.txt"
aws ecr get-login-password --region us-east-1 | Out-File -FilePath $tokenFile -Encoding ascii -NoNewline
cmd /c "docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com < `"$tokenFile`""
Remove-Item $tokenFile
docker tag dtx-event-router:week7 <account-id>.dkr.ecr.us-east-1.amazonaws.com/dtx-event-router:week7
docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/dtx-event-router:week7
```
(see "Common errors" above for why the login can't just be a plain PowerShell pipe)

(`terraform output ecr_repository_urls` prints the exact repository URLs.)

## Always destroy before ending the session

```powershell
terraform destroy
```

This is not optional. Closing the Lab browser tab does not stop billing, the 3
interface VPC endpoints keep running (and keep costing money against the fixed,
non-resetting Lab budget) until they are actually destroyed. Confirm nothing is
left with the same `describe-*`/`describe-repositories` commands above.

If the Lab resets your whole account between sessions (some course configurations
do this), the local `terraform.tfstate` can go stale. Run `terraform plan` at the
**start** of a session too, not just before ending it, to catch drift early.

## Budget

Everything this week creates costs about **$0.03/hr** while idle, entirely from the
3 interface VPC endpoints (~$0.01/hr each); the VPC itself, subnets, route tables,
security groups, and the S3 gateway endpoint are free. Leaving it up overnight by
accident costs on the order of $0.50-$1, a rounding error, but `terraform destroy`
stays mandatory on principle since Week 8 adds real Fargate compute billing on top
of this same state.
