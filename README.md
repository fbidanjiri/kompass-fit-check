# Kompass Fit Check

A self-service questionnaire for scoping a Kompass PoV. Customers (or an SE on a call with them)
fill out a cloud-aware, conditional question set; answers are saved and emailed to the team,
along with an internal fit/verdict analysis.

## Layout

- `template.yaml` — CloudFormation/SAM stack: S3 + CloudFront (static site), API Gateway + Lambda
  + DynamoDB + SES (submission pipeline).
- `site/kompass-fit-check-78f701d1.html` — the entire tool: a single self-contained HTML file with
  embedded vanilla JS (no build step, no framework).
- `scripts/kompass-fit-discover.sh` — optional read-only `kubectl` discovery script. Run against a
  prospect's cluster to pre-answer the cluster-detectable questions (K8s version, autoscaler, CNI,
  HPA/KEDA/VPA, GitOps tooling, observability stack, etc.) instead of asking. Auto-detects the
  cloud (AWS/Azure/Oracle) from node `providerID` and adjusts its checks and notes accordingly.
- `cfn-deploy-role-trust-policy.json` / `cfn-deploy-role-permissions.json` — IAM role used to
  deploy the CloudFormation stack.

## Deploying

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name kompass-fit-check \
  --capabilities CAPABILITY_IAM \
  --profile zesty-sales

aws s3 cp site/kompass-fit-check-78f701d1.html \
  s3://<SiteBucketName>/kompass-fit-check-78f701d1.html \
  --content-type "text/html; charset=utf-8" --cache-control "no-cache" \
  --profile zesty-sales

aws cloudfront create-invalidation \
  --distribution-id <DistributionId> \
  --paths "/kompass-fit-check-78f701d1.html" \
  --profile zesty-sales
```

Stack outputs (`SiteBucketName`, `DistributionId`, `PageUrl`, etc.) are available via
`aws cloudformation describe-stacks --stack-name kompass-fit-check`.
