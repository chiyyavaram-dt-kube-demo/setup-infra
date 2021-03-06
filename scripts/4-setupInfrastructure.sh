#!/bin/bash

LOG_LOCATION=./logs
exec > >(tee -i $LOG_LOCATION/setupInfrastructure.log)
exec 2>&1
clear

# validate that have utlities installed first
./validatePrerequisites.sh
if [ $? -ne 0 ]
then
  exit 1
fi

# validate that have kubectl configured first
./validateKubectl.sh
if [ $? -ne 0 ]
then
  exit 1
fi

# using fixed versus 'latest' version 
export DT_LATEST_RELEASE='v0.3.0'

echo " "
echo "===================================================="
echo About to setup demo app infrastructure with these parameters:
cat creds.json | grep -E "jenkins|dynatrace|github"
echo ""
echo "Using Dynatrace OneAgent Operator version : $DT_LATEST_RELEASE"
echo ""
read -rsp $'Press ctrl-c to abort. Press any key to continue...\n====================================================' -n1 key

export START_TIME=$(date)
export JENKINS_USER=$(cat creds.json | jq -r '.jenkinsUser')
export JENKINS_PASSWORD=$(cat creds.json | jq -r '.jenkinsPassword')
export GITHUB_PERSONAL_ACCESS_TOKEN=$(cat creds.json | jq -r '.githubPersonalAccessToken')
export GITHUB_USER_NAME=$(cat creds.json | jq -r '.githubUserName')
export GITHUB_USER_EMAIL=$(cat creds.json | jq -r '.githubUserEmail')
export GITHUB_ORGANIZATION=$(cat creds.json | jq -r '.githubOrg')
export DT_TENANT_ID=$(cat creds.json | jq -r '.dynatraceTenant')
export DT_API_TOKEN=$(cat creds.json | jq -r '.dynatraceApiToken')
export DT_PAAS_TOKEN=$(cat creds.json | jq -r '.dynatracePaaSToken')
export DT_TENANT_URL="$DT_TENANT_ID.live.dynatrace.com"
export REGISTRY_URL=$(cat creds.json | jq -r '.registry')
export REGISTRY_TOKEN=$(cat creds.json | jq -r '.registryToken')

echo "----------------------------------------------------"
echo "Creating K8s namespaces ..."
kubectl create -f ../manifests/namespaces.yml 

echo "----------------------------------------------------"
echo "Deploying Jenkins ..."
rm -f ../manifests/gen/k8s-jenkins-deployment.yml

mkdir -p ../manifests/gen
cat ../manifests/jenkins/k8s-jenkins-deployment.yml | \
  sed 's~GITHUB_USER_EMAIL_PLACEHOLDER~'"$GITHUB_USER_EMAIL"'~' | \
  sed 's~GITHUB_ORGANIZATION_PLACEHOLDER~'"$GITHUB_ORGANIZATION"'~' | \
  sed 's~DOCKER_REGISTRY_IP_PLACEHOLDER~'"$REGISTRY_URL"'~' | \
  sed 's~DT_TENANT_URL_PLACEHOLDER~'"$DT_TENANT_URL"'~' | \
  sed 's~DT_API_TOKEN_PLACEHOLDER~'"$DT_API_TOKEN"'~' >> ../manifests/gen/k8s-jenkins-deployment.yml

kubectl create -f ../manifests/jenkins/k8s-jenkins-pvcs.yml 
kubectl create -f ../manifests/gen/k8s-jenkins-deployment.yml
kubectl create -f ../manifests/jenkins/k8s-jenkins-rbac.yml

echo "----------------------------------------------------"
echo "Letting Jenkins start up [150 seconds] ..."
sleep 150

# Export Jenkins route in a variable
export JENKINS_URL=$(kubectl get service jenkins -n cicd -o=json | jq -r .status.loadBalancer.ingress[].hostname)
export JENKINS_URL_PORT=$(kubectl get service jenkins -n cicd -o=json | jq -r '.spec.ports[] | select(.name=="http") | .port')

echo "----------------------------------------------------"
echo "Creating Credential 'registry-creds' within Jenkins ..."
curl -X POST http://$JENKINS_URL:$JENKINS_URL_PORT/credentials/store/system/domain/_/createCredentials --user $JENKINS_USER:$JENKINS_PASSWORD \
--data-urlencode 'json={
  "": "0",
  "credentials": {
    "scope": "GLOBAL",
    "id": "registry-creds",
    "username": "'$REGISTRY_USER'",
    "password": "'$REGISTRY_TOKEN'",
    "description": "Token used by Jenkins to push to the container registry",
    "$class": "com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl"
  }
}'

echo "----------------------------------------------------"
echo "Creating Credential 'git-credentials-acm' within Jenkins ..."
curl -X POST http://$JENKINS_URL:$JENKINS_URL_PORT/credentials/store/system/domain/_/createCredentials --user $JENKINS_USER:$JENKINS_PASSWORD \
--data-urlencode 'json={
  "": "0",
  "credentials": {
    "scope": "GLOBAL",
    "id": "git-credentials-acm",
    "username": "'$GITHUB_USER_NAME'",
    "password": "'$GITHUB_PERSONAL_ACCESS_TOKEN'",
    "description": "Token used by Jenkins to access the GitHub repositories",
    "$class": "com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl"
  }
}'

echo "----------------------------------------------------"
echo "Creating Credential 'perfsig-api-token' within Jenkins ..."
curl -X POST http://$JENKINS_URL:$JENKINS_URL_PORT/credentials/store/system/domain/_/createCredentials --user $JENKINS_USER:$JENKINS_PASSWORD \
--data-urlencode 'json={
  "": "0",
  "credentials": {
    "scope": "GLOBAL",
    "id": "perfsig-api-token",
    "apiToken": "'$DT_API_TOKEN'",
    "description": "Dynatrace API Token used by the Performance Signature plugin",
    "$class": "de.tsystems.mms.apm.performancesignature.dynatracesaas.model.DynatraceApiTokenImpl"
  }
}'

echo "----------------------------------------------------"
echo "Creating Pipleine Jobs in Jenkins "
echo "Using source as: https://github.com/$GITHUB_ORGANIZATION"
./importPipelines.sh $GITHUB_ORGANIZATION
./updateJenkinsPlugins.sh just-perfsig
./showJenkins.sh

echo "----------------------------------------------------"
echo "Installing Dynatrace Operator $DT_LATEST_RELEASE ..."
kubectl create -f https://raw.githubusercontent.com/Dynatrace/dynatrace-oneagent-operator/$DT_LATEST_RELEASE/deploy/kubernetes.yaml

echo "----------------------------------------------------"
echo "Letting Dynatrace OneAgent operator start up [60 seconds] ..."
sleep 60

echo "----------------------------------------------------"
echo "Deploying Dynatrace OneAgent pods ..."
kubectl -n dynatrace create secret generic oneagent --from-literal="apiToken=$DT_API_TOKEN" --from-literal="paasToken=$DT_PAAS_TOKEN"

if [ -f ../manifests/gen/cr.yml ]; then
  rm -f ../manifests/gen/cr.yml
fi

mkdir -p ../manifests/gen/dynatrace
curl -o ../manifests/gen/dynatrace/cr.yml https://raw.githubusercontent.com/Dynatrace/dynatrace-oneagent-operator/$DT_LATEST_RELEASE/deploy/cr.yaml
cat ../manifests/gen/dynatrace/cr.yml | sed 's/ENVIRONMENTID/'"$DT_TENANT_ID"'/' >> ../manifests/gen/cr.yml

kubectl create -f ../manifests/gen/cr.yml

echo "----------------------------------------------------"
echo "Apply auto tagging rules in Dynatrace ..."
./applyAutoTaggingRules.sh $DT_TENANT_ID $DT_API_TOKEN

echo "----------------------------------------------------"
echo "Letting Dynatrace tagging rules be applied [100 seconds] ..."
sleep 150

#echo "----------------------------------------------------"
#echo "Deploying Istio ..."
#./setupIstio.sh $DT_TENANT_ID $DT_PAAS_TOKEN

echo "===================================================="
echo "Finished setting up demo app infrastructure "
echo "===================================================="
echo "Script start time : "$START_TIME
echo "Script end time   : "$(date)

echo ""
echo ""
./showJenkins.sh 