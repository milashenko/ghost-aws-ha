#!/bin/bash
set -o xtrace

## Configuration
export PRIMARY_REGION="eu-central-1"
export ENV_NAME="dev"
export APP_NAME="ghost"
if [ -z "$IMAGE_TAG" ]; then
    IMAGE_TAG="local-`date -u +"%Y%m%dT%H%M%S"`"
fi
echo "IMAGE_TAG=$IMAGE_TAG"
## End of Configuration

ACCOUNT_ID=`aws sts get-caller-identity --query=Account --output=text`

# Cloudformation buckets
export PRIMARY_BUCKET_NAME="$ENV_NAME-$PRIMARY_REGION-templates"
aws s3 mb "s3://$PRIMARY_BUCKET_NAME" --region=$PRIMARY_REGION || true


#### Build container
docker build -t $APP_NAME:latest . || exit 3
# Push image to primary region
export PRIMARY_ECR_URI=`aws cloudformation list-exports --query="Exports[?Name=='$APP_NAME-RepositoryUri'][Value]" --region=$PRIMARY_REGION --output=text` || exit 3
docker tag $APP_NAME:latest $PRIMARY_ECR_URI:$IMAGE_TAG || exit 3
aws ecr get-login-password --region $PRIMARY_REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$PRIMARY_REGION.amazonaws.com || exit 3
docker push $PRIMARY_ECR_URI:$IMAGE_TAG || exit 3

#### Resource Group
# Primary
sam deploy --stack-name="$ENV_NAME-resource-group" \
    --parameter-overrides="Value=\"$ENV_NAME\" TagName=\"env\"" \
    --tags="env=$ENV_NAME" \
    --capabilities="CAPABILITY_NAMED_IAM" \
    --region=$PRIMARY_REGION \
    --s3-bucket=$PRIMARY_BUCKET_NAME \
    --no-fail-on-empty-changeset \
    --template-file 0.resource-group.yaml || exit 2

#### VPC
# Primary
export VpcCIDRNet="10.200"
sam deploy --stack-name="$ENV_NAME-vpc" \
    --parameter-overrides="EnvName=\"$ENV_NAME\" VpcCIDR=\"$VpcCIDRNet.0.0/16\" PublicSubnet1CIDR=\"$VpcCIDRNet.10.0/24\" PublicSubnet2CIDR=\"$VpcCIDRNet.11.0/24\" PrivateSubnet1CIDR=\"$VpcCIDRNet.20.0/24\" PrivateSubnet2CIDR=\"$VpcCIDRNet.21.0/24\"" \
    --tags="env=$ENV_NAME" \
    --capabilities="CAPABILITY_NAMED_IAM" \
    --region=$PRIMARY_REGION \
    --s3-bucket=$PRIMARY_BUCKET_NAME \
    --no-fail-on-empty-changeset \
    --template-file 1.vpc.yaml || exit 2

#### EFS
# Primary - create primary and configure replication to sedondary
sam deploy --stack-name="$ENV_NAME-efs" \
    --parameter-overrides="EnvName=\"$ENV_NAME\"" \
    --tags="env=$ENV_NAME" \
    --capabilities="CAPABILITY_NAMED_IAM" \
    --region=$PRIMARY_REGION \
    --s3-bucket=$PRIMARY_BUCKET_NAME \
    --no-fail-on-empty-changeset \
    --template-file 3.efs.yaml || exit 2

#### DB
# Create global DB secret manager from primary region
sam deploy --stack-name="$ENV_NAME-secrets" \
    --parameter-overrides="EnvName=\"$ENV_NAME\"" \
    --tags="env=$ENV_NAME" \
    --capabilities="CAPABILITY_NAMED_IAM" \
    --region=$PRIMARY_REGION \
    --s3-bucket=$PRIMARY_BUCKET_NAME \
    --no-fail-on-empty-changeset \
    --template-file 0.secrets.yaml || exit 2

export MASTER_SECRET_ARN=`aws cloudformation list-exports --query="Exports[?Name=='$ENV_NAME-MasterSecret'][Value]" --region=$PRIMARY_REGION --output=text`
echo "SecretArn=$MASTER_SECRET_ARN"
export MASTER_SECRET_NAME=`echo "$MASTER_SECRET_ARN" | awk -F ":" '{ print $7 }'`
echo "SecretName=$MASTER_SECRET_NAME"

# Primary - Create global DB and source cluster first
export EXISTING_GLOBAL_DB="" # keep empty to to create new global DB
sam deploy --stack-name="$ENV_NAME-aurora-mysql" \
    --parameter-overrides="EnvName=\"$ENV_NAME\" DBInstanceClass=\"db.r5.large\" ExistingGlobalDbArn=\"$EXISTING_GLOBAL_DB\" MasterSecretName=\"$MASTER_SECRET_NAME\"" \
    --tags="env=$ENV_NAME" \
    --capabilities="CAPABILITY_NAMED_IAM" \
    --region=$PRIMARY_REGION \
    --s3-bucket=$PRIMARY_BUCKET_NAME \
    --no-fail-on-empty-changeset \
    --template-file 2.aurora-mysql.yaml || exit 2

# #### Main APP
# Primary
# According to https://ghost.org/docs/faq/clustering-sharding-multi-server/ max number of simultaniously running instances can be 1
sam deploy --stack-name="$ENV_NAME-app" \
    --parameter-overrides="EnvName=\"$ENV_NAME\" AppName=\"$APP_NAME\" ImageTag=\"$IMAGE_TAG\" MasterSecretName=\"$MASTER_SECRET_NAME\" DesiredCount=\"1\"" \
    --tags="env=$ENV_NAME" \
    --capabilities="CAPABILITY_NAMED_IAM" \
    --region=$PRIMARY_REGION \
    --s3-bucket=$PRIMARY_BUCKET_NAME \
    --no-fail-on-empty-changeset \
    --template-file 4.app.yaml || exit 2

export PRIMARY_ALB=`aws cloudformation list-exports --query="Exports[?Name=='$ENV_NAME-LoadBalancer-DNSName'][Value]" --region=$PRIMARY_REGION --output=text`
echo "PRIMARY_ALB=$PRIMARY_ALB"
