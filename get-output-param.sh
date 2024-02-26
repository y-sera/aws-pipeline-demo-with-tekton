#!/bin/bash

TEKTON_DEMO_APP_URL=$(aws elbv2 describe-load-balancers | jq -r '.LoadBalancers[] | select(.DNSName | contains("apps")) | .DNSName')
TEKTON_DEMO_DASHBOARD_URL=$(aws elbv2 describe-load-balancers | jq -r '.LoadBalancers[] | select(.DNSName | contains("dashboard")) | .DNSName')
TEKTON_DEMO_ARGOCD_URL=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[*].hostname}')
AWS_REGION=$(aws configure get region)
TEKTON_DEMO_GIT_USERNAME=$(cat tekton-pipeline-demo-k8s-artifacts/values.yaml |grep username | cut -f2 -d' ')
TEKTON_DEMO_GIT_PASSWORD=$(cat tekton-pipeline-demo-k8s-artifacts/values.yaml |grep password | cut -f2 -d' ')
eTEKTON_DEMO_ARGOCD_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo "[INFO] $(date +"%T") Display output values..."
echo "[INFO] DEMO APP => http://${TEKTON_DEMO_APP_URL}"
echo "[INFO] TEKTON DASHBOARD => http://${TEKTON_DEMO_DASHBOARD_URL}"
echo "[INFO] ARGOCD => http://${TEKTON_DEMO_ARGOCD_URL}"
echo "[INFO] SOURCE REPO => https://git-codecommit.${AWS_REGION}.amazonaws.com/v1/repos/tekton-demo-app-build"
echo "[INFO] GIT USERNAME => ${TEKTON_DEMO_GIT_USERNAME}"
echo "[INFO] GIT PASWORD => ${TEKTON_DEMO_GIT_PASSWORD}"
echo "[INFO] ARGOCD USERNAME => admin"
echo "[INFO] ARGOCD PASSWORD => ${TEKTON_DEMO_ARGOCD_PW}"


