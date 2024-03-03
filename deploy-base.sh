#!/bin/bash
set -o xtrace

## Configuration
export PRIMARY_REGION="eu-central-1"
export SECONDARY_REGION="eu-west-1"
export ENV_NAME="base"
export APP_NAME="ghost"
export GITHUB_ORG="milashenko"
export REPOSITORY_NAME=ghost-aws-ha
## End of Configuration

ACCOUNT_ID=`aws sts get-caller-identity --query=Account --output=text`

# Cloudformation buckets
export PRIMARY_BUCKET_NAME="$ENV_NAME-$PRIMARY_REGION-templates"
aws s3 mb "s3://$PRIMARY_BUCKET_NAME" --region=$PRIMARY_REGION || true

export SECONDARY_BUCKET_NAME="$ENV_NAME-$SECONDARY_REGION-templates"
aws s3 mb "s3://$SECONDARY_BUCKET_NAME" --region=$SECONDARY_REGION || true

export GLOBAL_BUCKET_NAME="$ENV_NAME-us-east-1-templates"
aws s3 mb "s3://$GLOBAL_BUCKET_NAME" --region=us-east-1 || true

#### ECR
# Primary
sam deploy --stack-name="$APP_NAME-ecr" \
    --parameter-overrides="AppName=\"$APP_NAME\"" \
    --tags="env=$ENV_NAME" \
    --capabilities="CAPABILITY_NAMED_IAM" \
    --region=$PRIMARY_REGION \
    --s3-bucket=$PRIMARY_BUCKET_NAME \
    --no-fail-on-empty-changeset \
    --template-file base.ecr.yaml || exit 2
# Secondary
sam deploy --stack-name="$APP_NAME-ecr" \
    --parameter-overrides="AppName=\"$APP_NAME\"" \
    --tags="env=$ENV_NAME" \
    --capabilities="CAPABILITY_NAMED_IAM" \
    --region=$SECONDARY_REGION \
    --s3-bucket=$SECONDARY_BUCKET_NAME \
    --no-fail-on-empty-changeset \
    --template-file base.ecr.yaml || exit 2

# GitHub
sam deploy --stack-name="$APP_NAME-github" \
    --parameter-overrides="GitHubOrg=\"$GITHUB_ORG\" RepositoryName=\"$REPOSITORY_NAME\" " \
    --tags="env=$ENV_NAME" \
    --capabilities="CAPABILITY_NAMED_IAM" \
    --region=us-east-1 \
    --s3-bucket=$GLOBAL_BUCKET_NAME \
    --no-fail-on-empty-changeset \
    --template-file base.github-oidc.yaml || exit 2
