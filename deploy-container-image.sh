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


#### Build container and push to ecr in primary region
export PRIMARY_ECR_URI=`aws cloudformation list-exports --query="Exports[?Name=='$APP_NAME-RepositoryUri'][Value]" --region=$PRIMARY_REGION --output=text` || exit 3
docker build -t $PRIMARY_ECR_URI:latest . || exit 3
docker tag $PRIMARY_ECR_URI:latest $PRIMARY_ECR_URI:$IMAGE_TAG || exit 3
aws ecr get-login-password --region $PRIMARY_REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$PRIMARY_REGION.amazonaws.com || exit 3
docker push $PRIMARY_ECR_URI:$IMAGE_TAG || exit 3
docker push $PRIMARY_ECR_URI:latest || exit 3

echo "Image $PRIMARY_ECR_URI:$IMAGE_TAG pushed"
echo "Image $PRIMARY_ECR_URI:latest pushed"