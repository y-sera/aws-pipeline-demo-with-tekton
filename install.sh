#!/bin/bash
set -e

# Define version for third party dependencies
export TEKTON_PIPELINE_VERSION="v0.47.0"
export TEKTON_TRIGGERS_VERSION="v0.23.1"
export TEKTON_DASHBOARD_VERSION="v0.35.0"
export CHARTMUSEUM_VERSION="3.1.0"
export AWS_LB_CONTROLLER_VERSION="1.7.1"
export AWS_EBS_CSI_DRIVER_VERSION="2.27.0"
export ARGOCD_VERSION="v2.10.1"
export EKS_VERSION="1.29"

export AWS_AUTHENTICATED_IDENTITY=$(aws sts get-caller-identity | jq -r .Arn | cut -d "/" -f2)
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
export AWS_REGION=$(aws configure get region)
export TMP_FILE=$(mktemp)
export DOCKER_SCAN_SUGGEST=false

export EKS_CLUSTER_NAME="eks-handson-cluster"
export EKS_CLUSTER_STACK="eksctl-${EKS_CLUSTER_NAME}-cluster"

echo "[INFO] Install resources as $AWS_AUTHENTICATED_IDENTITY within account $AWS_ACCOUNT_ID in region $AWS_REGION"
echo "[INFO] Cluster Name: $EKS_CLUSTER_NAME"

# check cluster stack
if [[ $(aws cloudformation describe-stacks --stack-name="$EKS_CLUSTER_STACK" | jq -r '.Stacks[0].StackStatus') = "CREATE_COMPLETE" ]]; then
    echo "[INFO] Cluster Stack Name: $EKS_CLUSTER_STACK"
else
    echo "[ERROR] $(date +"%T") Invalid Cluster Name provided or cluster not yet ready" >&2
fi

export TEKTON_DEMO_CLUSTER_SUBNETS=$(aws cloudformation describe-stacks --stack-name $EKS_CLUSTER_STACK | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "SubnetsPrivate") | .OutputValue')
export TEKTON_DEMO_CLUSTER_VPC=$(aws cloudformation describe-stacks --stack-name $EKS_CLUSTER_STACK | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "VPC") | .OutputValue')
export TEKTON_DEMO_CLUSTER_NODE_SG=$(aws cloudformation describe-stacks --stack-name $EKS_CLUSTER_STACK | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "ClusterSecurityGroupId") | .OutputValue')

echo "[INFO] Cluster VPC: $TEKTON_DEMO_CLUSTER_VPC"
echo "[INFO] Cluster Subnet: $TEKTON_DEMO_CLUSTER_SUBNETS"
echo "[INFO] Cluster Node Security Group: $TEKTON_DEMO_CLUSTER_NODE_SG"


# check allowed source IP
export ALLOWED_SOURCE_IP_RANGE="$(cat ./allowed_source_ip_range)"
if [[ $ALLOWED_SOURCE_IP_RANGE =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    echo "[INFO] import Allowed Source IP Range from ./allowed_source_ip_range (XXX.XXX.XXX.XXX/XX): $ALLOWED_SOURCE_IP_RANGE"
else
    echo "[ERROR] $(date +"%T") Please insert valid ip address [format: XXX.XXX.XXX.XXX/XX]" >&2
fi


# Create OIDC Provider & ServiceAccount for addons
echo "[INFO] $(date +"%T") Configure EKS Cluster..."
eksctl utils associate-iam-oidc-provider --cluster=$EKS_CLUSTER_NAME --approve
eksctl create iamserviceaccount --config-file=eks-cluster-addon-sa-config.yaml --approve

# Install AWS EBS CSI Driver
echo "[INFO] $(date +"%T") Deploy aws-ebs-csi-driver [${AWS_EBS_CSI_DRIVER_VERSION}]..."
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver > /dev/null
helm upgrade --install -n kube-system aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver --version $AWS_EBS_CSI_DRIVER_VERSION --set controller.serviceAccount.create=false > /dev/null

# Install AWS Load Balancer Controller
echo "[INFO] $(date +"%T") Deploy aws-load-balancer-controller [${AWS_LB_CONTROLLER_VERSION}]..."
helm repo add eks https://aws.github.io/eks-charts > /dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller --version $AWS_LB_CONTROLLER_VERSION --set clusterName=${EKS_CLUSTER_NAME} -n kube-system --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller --set region=$AWS_REGION --set vpcId=$TEKTON_DEMO_CLUSTER_VPC > /dev/null



# Create stack TetkonDemoBuckets
echo "[INFO] $(date +"%T") Create <<TektonDemoBucket>> Cloudformation Stack..."
aws cloudformation deploy --stack-name="TektonDemoBuckets" --template-file ./cloudformation/demo-code-bucket.yaml --capabilities "CAPABILITY_IAM" > /dev/null

# Fetch required stack output variables
echo "[INFO] $(date +"%T") Fetch <<TektonDemoBucket>> Cloudformation Stack output variables..."
export TEKTON_DEMO_CHARTMUSEUM_BUCKET=$(aws cloudformation describe-stacks --stack-name TektonDemoBuckets | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "ChartmuseumBucket") | .OutputValue')
export TEKTON_DEMO_CHARTMUSEUM_POLICY=$(aws cloudformation describe-stacks --stack-name TektonDemoBuckets | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "PolicyArnForChartMuseumSa") | .OutputValue')
export TEKTON_DEMO_CODE_BUCKET=$(aws cloudformation describe-stacks --stack-name TektonDemoBuckets | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "CodeBucket") | .OutputValue')



# Package and upload helm-springboot master helm chart
echo "[INFO] $(date +"%T") Package helm master chart and upload to S3..."
helm package helm-springboot > /dev/null
aws s3 cp helm-springboot-0.1.0.tgz s3://${TEKTON_DEMO_CHARTMUSEUM_BUCKET}/ > /dev/null
rm -f helm-springboot-0.1.0.tgz

# Upload tekton-demo-app-build
echo "[INFO] $(date +"%T") Upload source files to S3..."
cat tekton-demo-app-build/pom.xml | envsubst | tee $TMP_FILE > /dev/null && mv $TMP_FILE tekton-demo-app-build/pom.xml
cd tekton-demo-app-build
zip -r tekton-pipeline-demo-app-code.zip . > /dev/null 
aws s3 cp tekton-pipeline-demo-app-code.zip s3://${TEKTON_DEMO_CODE_BUCKET}/ > /dev/null 
rm -f tekton-pipeline-demo-app-code.zip
cd ..

# Upload tekton-demo-app-deploy
echo "[INFO] $(date +"%T") Upload deploy files to S3..."
cd tekton-demo-app-deploy
zip -r tekton-pipeline-demo-deploy-code.zip . > /dev/null 
aws s3 cp tekton-pipeline-demo-deploy-code.zip s3://${TEKTON_DEMO_CODE_BUCKET}/ > /dev/null 
rm -f tekton-pipeline-demo-deploy-code.zip
cd ..

# Build and upload tekton-webhook-middleware
echo "[INFO] $(date +"%T") Compile webhook lambda and upload to S3..."
cd tekton-webhook-middleware
GOOS=linux GOARCH=amd64 go build -o bootstrap main.go > /dev/null
zip bootstrap.zip bootstrap > /dev/null 
aws s3 cp bootstrap.zip s3://${TEKTON_DEMO_CODE_BUCKET}/ > /dev/null
rm -f bootstrap.zip
rm -f bootstrap
cd ..


# Create CF Stack "TektonDemoInfra"
echo "[INFO] $(date +"%T") Create <<TektonDemoInfra>> Cloudformation Stack..."
aws cloudformation deploy --stack-name="TektonDemoInfra" --template-file ./cloudformation/demo-infra.yaml --parameter-overrides TektonDemoSourceBucket="${TEKTON_DEMO_CODE_BUCKET}" TektonDemoClusterSubnets="${TEKTON_DEMO_CLUSTER_SUBNETS}" TektonDemoClusterVpc="${TEKTON_DEMO_CLUSTER_VPC}" AllowedIpAddress="${ALLOWED_SOURCE_IP_RANGE}" --capabilities "CAPABILITY_IAM" > /dev/null
export TEKTON_DEMO_CHARTMUSEUM_SG=$(aws cloudformation describe-stacks --stack-name TektonDemoInfra | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "ChartmuseumSecurityGroup") | .OutputValue')
export TEKTON_DEMO_DASHBOARD_SG=$(aws cloudformation describe-stacks --stack-name TektonDemoInfra | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "DashboardSecurityGroup") | .OutputValue')
export TEKTON_DEMO_APP_SG=$(aws cloudformation describe-stacks --stack-name TektonDemoInfra | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "AppSecurityGroup") | .OutputValue')
export TEKTON_DEMO_WEBHOOK_SG=$(aws cloudformation describe-stacks --stack-name TektonDemoInfra | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "WebhookSecurityGroup") | .OutputValue')

# Update Security Group of Worker Nodes
echo "[INFO] $(date +"%T") Update EKS worker node security groups..."
aws ec2 authorize-security-group-ingress --group-id $TEKTON_DEMO_CLUSTER_NODE_SG --ip-permissions IpProtocol=tcp,FromPort=30000,ToPort=32767,UserIdGroupPairs=[{GroupId=$TEKTON_DEMO_DASHBOARD_SG}]
aws ec2 authorize-security-group-ingress --group-id $TEKTON_DEMO_CLUSTER_NODE_SG --ip-permissions IpProtocol=tcp,FromPort=30000,ToPort=32767,UserIdGroupPairs=[{GroupId=$TEKTON_DEMO_APP_SG}]
aws ec2 authorize-security-group-ingress --group-id $TEKTON_DEMO_CLUSTER_NODE_SG --ip-permissions IpProtocol=tcp,FromPort=30000,ToPort=32767,UserIdGroupPairs=[{GroupId=$TEKTON_DEMO_WEBHOOK_SG}]
aws ec2 authorize-security-group-ingress --group-id $TEKTON_DEMO_CLUSTER_NODE_SG --ip-permissions IpProtocol=tcp,FromPort=30000,ToPort=32767,UserIdGroupPairs=[{GroupId=$TEKTON_DEMO_CHARTMUSEUM_SG}]

# Build cloner image
echo "[INFO] $(date +"%T") Build cloner container image and upload to ECR..."
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com > /dev/null
docker build -t cloner ./docker/cloner > /dev/null
docker tag cloner:latest ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/cloner:latest
docker push ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/cloner:latest > /dev/null 

# Build maven-builder image
echo "[INFO] $(date +"%T") Build maven-build container image and upload to ECR..."
docker build -t maven-builder ./docker/maven-builder > /dev/null
docker tag maven-builder:latest ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/maven-builder:latest
docker push ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/maven-builder:latest > /dev/null 

# Create Service Account for tekton components
cat eks-cluster-iam-config.yaml | envsubst | tee $TMP_FILE > /dev/null && mv $TMP_FILE eks-cluster-iam-config.yaml
eksctl create iamserviceaccount --config-file=eks-cluster-iam-config.yaml --approve

###########################
# Install Tekton components
###########################

# Install Tekton Pipelines
echo "[INFO] $(date +"%T") Deploy Tekton Pipelines [${TEKTON_PIPELINE_VERSION}]..."
kubectl apply --filename https://storage.googleapis.com/tekton-releases/pipeline/previous/${TEKTON_PIPELINE_VERSION}/release.yaml

# Install Tekton Triggers
echo "[INFO] $(date +"%T") Deploy Tekton Triggers [${TEKTON_TRIGGERS_VERSION}]..."
kubectl apply --filename https://storage.googleapis.com/tekton-releases/triggers/previous/${TEKTON_TRIGGERS_VERSION}/release.yaml

# Install Tekton Dashboard
echo "[INFO] $(date +"%T") Deploy Tekton Dashboard [${TEKTON_DASHBOARD_VERSION}]..."
kubectl apply --filename https://github.com/tektoncd/dashboard/releases/download/${TEKTON_DASHBOARD_VERSION}/release.yaml

# Install Chartmuseum
echo "[INFO] $(date +"%T") Deploy Chartmuseum [${CHARTMUSEUM_VERSION}]..."
helm repo add chartmuseum https://chartmuseum.github.io/charts > /dev/null
cat chartmuseum-values.yaml | envsubst | tee $TMP_FILE > /dev/null && mv $TMP_FILE chartmuseum-values.yaml
kubectl apply -f ./namespace/support.yaml
helm upgrade --install -n support chartmuseum chartmuseum/chartmuseum --version $CHARTMUSEUM_VERSION -f chartmuseum-values.yaml > /dev/null

# Install ArgoCD
echo "[INFO] $(date +"%T") Deploy ArgoCD [${ARGOCD_VERSION}]..."
kubectl apply -f ./namespace/argocd.yaml
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml

# Patch K8S SVCs
kubectl patch svc tekton-dashboard -n tekton-pipelines -p '{"spec": {"type": "NodePort"}}'
kubectl patch svc chartmuseum -n support -p '{"spec": {"type": "NodePort"}}'

kubectl -n argocd delete cm argocd-cm
kubectl -n argocd delete svc argocd-server



#####################
# Setup tekton Demo
#####################

# Generate GIT Credentials for CodeCommit
echo "[INFO] $(date +"%T") Create git credentials for user ${AWS_AUTHENTICATED_IDENTITY}..."
export TEKTON_DEMO_GIT_PASSWORD_RAW=$(aws iam create-service-specific-credential --service-name codecommit.amazonaws.com --user-name $AWS_AUTHENTICATED_IDENTITY | jq -r .ServiceSpecificCredential.ServicePassword)
export TEKTON_DEMO_GIT_PASSWORD=$(echo -n $TEKTON_DEMO_GIT_PASSWORD_RAW | jq -Rr @uri)
export TEKTON_DEMO_GIT_USERNAME=$(aws iam list-service-specific-credentials --service-name codecommit.amazonaws.com --user-name ${AWS_AUTHENTICATED_IDENTITY} | jq -r '.ServiceSpecificCredentials[] | select(.ServiceName == "codecommit.amazonaws.com") | .ServiceUserName')

# INSTALL TEKTON DEMO
echo "[INFO] $(date +"%T") Deploy resources related to the demo..."
cat tekton-pipeline-demo-k8s-artifacts/values.yaml | envsubst | tee $TMP_FILE > /dev/null && mv $TMP_FILE tekton-pipeline-demo-k8s-artifacts/values.yaml
helm install tekton-pipeline-demo-k8s-artifacts -f tekton-pipeline-demo-k8s-artifacts/values.yaml --generate-name > /dev/null 
sleep 30

# Adjust Tekton Webhook
echo "[INFO] $(date +"%T") Update webhook lambda function..."
export TEKTON_DEMO_WEBHOOK_URL=$(aws elbv2 describe-load-balancers | jq -r '.LoadBalancers[] | select(.DNSName | contains("webhook")) | .DNSName')
aws lambda update-function-configuration --function-name=TektonPipelineDemoWebhook --environment Variables={TEKTON_WEBHOOK_URL=http://${TEKTON_DEMO_WEBHOOK_URL}} > /dev/null

export TEKTON_DEMO_CHARTMUSEUM_URL=$(aws elbv2 describe-load-balancers | jq -r '.LoadBalancers[] | select(.DNSName | contains("chartmuseum")) | .DNSName')

echo "[INFO] $(date +"%T") Update manifest files within deploy repository..."
mkdir -p git-clone
cd git-clone
git clone https://${TEKTON_DEMO_GIT_USERNAME}:${TEKTON_DEMO_GIT_PASSWORD}@git-codecommit.${AWS_REGION}.amazonaws.com/v1/repos/tekton-demo-app-deploy > /dev/null 
cd tekton-demo-app-deploy
cat values.yaml | envsubst | tee $TMP_FILE > /dev/null && mv $TMP_FILE values.yaml
cat requirements.yaml | envsubst | tee $TMP_FILE > /dev/null && mv $TMP_FILE requirements.yaml
git add values.yaml
git add requirements.yaml
git commit -m "[AUTO_UPDATE]" > /dev/null 
git push > /dev/null 
cd ../..
rm -rf git-clone

echo "[INFO] $(date +"%T") Trigger initial pipelinerun..."
aws codecommit test-repository-triggers --repository-name tekton-demo-app-build --triggers name=LambdaFunctionTrigger,destinationArn=$(aws codecommit get-repository-triggers --repository-name tekton-demo-app-build | jq -r .triggers[0].destinationArn),events=all,branches=master,customData=tekton-demo-app-build  > /dev/null 

TEKTON_DEMO_ARGOCD_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
TEKTON_DEMO_ARGOCD_URL=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[*].hostname}')
TEKTON_DEMO_DASHBOARD_URL=$(aws elbv2 describe-load-balancers | jq -r '.LoadBalancers[] | select(.DNSName | contains("dashboard")) | .DNSName')
TEKTON_DEMO_APP_URL=$(aws elbv2 describe-load-balancers | jq -r '.LoadBalancers[] | select(.DNSName | contains("apps")) | .DNSName')

echo "[INFO] $(date +"%T") Display output values..."
echo "[INFO] DEMO APP => http://${TEKTON_DEMO_APP_URL}"
echo "[INFO] TEKTON DASHBOARD => http://${TEKTON_DEMO_DASHBOARD_URL}"
echo "[INFO] ARGOCD => http://${TEKTON_DEMO_ARGOCD_URL}"
echo "[INFO] SOURCE REPO => https://git-codecommit.${AWS_REGION}.amazonaws.com/v1/repos/tekton-demo-app-build"
echo "[INFO] GIT USERNAME => ${TEKTON_DEMO_GIT_USERNAME}"
echo "[INFO] GIT PASWORD => ${TEKTON_DEMO_GIT_PASSWORD}"
echo "[INFO] ARGOCD USERNAME => admin"
echo "[INFO] ARGOCD PASSWORD => ${TEKTON_DEMO_ARGOCD_PW}"

echo "[INFO] $(date +"%T") Successfully installed demo environment!"
