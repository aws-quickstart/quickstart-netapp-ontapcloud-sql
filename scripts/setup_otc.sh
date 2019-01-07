#!/bin/bash -e

function exportParams() {
	name=`grep 'name' ${PARAMS_FILE} | awk -F'|' '{print $2}' | sed -e 's/^ *//g;s/ *$//g'`
	customer=`grep 'customer' ${PARAMS_FILE} | awk -F'|' '{print $2}' | sed -e 's/^ *//g;s/ *$//g'`
	vpcID=`grep 'vpcID' ${PARAMS_FILE} | awk -F'|' '{print $2}' | sed -e 's/^ *//g;s/ *$//g'`
	subnetID=`grep 'subnetID' ${PARAMS_FILE} | awk -F'|' '{print $2}' | sed -e 's/^ *//g;s/ *$//g'`
	region=`grep 'region' ${PARAMS_FILE} | awk -F'|' '{print $2}' | sed -e 's/^ *//g;s/ *$//g'`
	adminEmail=`grep 'adminEmail' ${PARAMS_FILE} | awk -F'|' '{print $2}' | sed -e 's/^ *//g;s/ *$//g'`
	adminPassword=`grep 'adminPassword' ${PARAMS_FILE} | awk -F'|' '{print $2}' | sed -e 's/^ *//g;s/ *$//g'`
	svmPassword=${adminPassword}
}

if [ $# -ne 1 ]; then
	echo $0: usage: setp_OTC.sh "<param-file-path>"
    exit 1
fi

PARAMS_FILE=$1

name='NONE'
customer='NONE'
vpcID='NONE'
subnetID='NONE'
region='NONE'
adminEmail='NONE'
adminPassword='NONE'
svmPassword='NONE'

if [ -f ${PARAMS_FILE} ]; then
	echo "Extracting parameter values from params file"
	exportParams
else
	echo "Paramaters file not found or accessible."
    exit 1
fi

export PATH=$PATH:/usr/local/aws/bin/

wget -O /usr/bin/jq http://stedolan.github.io/jq/download/linux64/jq
sleep 5
chmod +x /usr/bin/jq

function waitForAction
{
  curl http://localhost/occm/api/audit?workingEnvironmentId=${1} -X GET --header 'Content-Type:application/json' --header 'Referer:AWSQS1' --header "Authorization:$token" | jq -r .[${3}].status > /tmp/temp.txt
  test=`cat /tmp/temp.txt`
  if [ ${test} = null ] ; then
	sleep ${2}
	waitForAction ${1} ${2} ${3}
  fi
  while [ ${test} = Received ] || [ ${test} = null ] ; do sleep ${2};curl http://localhost/occm/api/audit?workingEnvironmentId=${1} -X GET --header 'Content-Type:application/json' --header 'Referer:AWSQS1' --header "Authorization:$token" | jq -r .[${3}].status > /tmp/temp.txt;test=`cat /tmp/temp.txt`; done
  if [ ${test} = Failed ] ; then
	  curl http://localhost/occm/api/audit?workingEnvironmentId=${1} -X GET --header 'Content-Type:application/json' --header 'Referer:AWSQS1' --header "Authorization:$token" | jq -r .[${3}] > /tmp/temp.txt
	  errorMessage=`cat /tmp/temp.txt| jq -r .errorMessage`
	  actionName=`cat /tmp/temp.txt| jq -r .actionName`
	  echo "Action: $actionName failed due to: $errorMessage" > /tmp/occmError.txt
	  exit 1
  fi
}

dataAccessCidr=`aws ec2 describe-subnets --region $region --subnet-id $subnetID | jq -r '.Subnets[0].CidrBlock'`
sleep 60
## Register the OCCM
curl  http://localhost/occm/api/occm/setup-portal/register --header 'Referer:AWSQS1' -X POST
sleep 10
## Get Auth0 details
curl -X GET http://localhost/occm/api/occm/system/support-services --header 'Referer:AWSQS1' |jq -r .portalService.auth0Information > info.txt
clientId=`cat info.txt|jq -r .clientId`
domain=`cat info.txt|jq -r .domain`
audience=`cat info.txt|jq -r .audience`
token="Bearer "
##Get token
curl  https://$domain/oauth/token -X POST --header "Content-Type:application/json" --data '{"grant_type": "password","username": "'${adminEmail}'","password": "'${adminPassword}'","audience": "'${audience}'","scope": "profile","client_id": "'${clientId}'"}' | jq -r .access_token > token.txt
token+=`cat token.txt`
## Setup Cloud Manager
curl  http://localhost/occm/api/occm/setup-portal/init -X POST --header "Content-Type:application/json" --header 'Referer:AWSQS1' --header "Authorization:$token" --data '{"adminUser": {"email": "'${adminEmail}'"},"company": "'${customer}'","site": "'${customer}_site'"}'
sleep 40
until sudo wget http://localhost/occmui > /dev/null 2>&1; do sudo wget http://localhost > /dev/null 2>&1 ; done
sleep 60
## Get Cloud Account id
curl -X GET http://localhost/occm/api/accounts --header 'Referer:AWSQS1' --header "Authorization: $token"  |jq -r '.awsAccounts[0]'.publicId > temp.txt
awsAccountId=`cat temp.txt`
sleep 5
## Get the Tenant ID so we can create the ONTAP Cloud system in that Cloud Manager Tenant
tenantId=`curl http://localhost/occm/api/tenants -X GET --header 'Content-Type:application/json' --header 'Referer:AWSQS1' --header "Authorization:$token" | jq -r .[0].publicId`
## Create a ONTAP Cloud working env
name=$(tr '-' '_' <<< ${name:0:30})
curl http://localhost/occm/api/vsa/working-environments -X POST --header 'Content-Type:application/json' --header 'Referer:AWSQS1' --header "Authorization:$token" --data '{"name":"'${name}_OTC'","tenantId":"'${tenantId}'","region":"'${region}'","subnetId":"'${subnetID}'","ebsVolumeType":"gp2","ebsVolumeSize": {"size": 1, "unit": "TB"},"dataEncryptionType":"AWS","ontapEncryptionParameters":null,"skipSnapshots": "true","svmPassword":"'${svmPassword}'","vpcId":"'${vpcID}'","cloudProviderAccount": "'${awsAccountId}'","vsaMetadata":{"platformLicense":null,"ontapVersion":"latest","useLatestVersion": true,"licenseType":"cot-standard-paygo","instanceType":"r4.xlarge"}}' > /tmp/createVSA.txt
sourceVsaPublicId=`cat /tmp/createVSA.txt| jq -r .publicId`
if [ ${sourceVsaPublicId} = null ] ; then
  message=`cat /tmp/createVSA.txt| jq -r .message`
  echo "OCCM setup failed: $message" > /tmp/occmError.txt
  exit 1
fi
sleep 2
## Check SRC VSA
waitForAction ${sourceVsaPublicId} 60 1
## grab the Cluster managment LIF IP address
clusterLif=`curl 'http://localhost/occm/api/vsa/working-environments/'${sourceVsaPublicId}'?fields=clusterProperties' -X GET --header 'Content-Type:application/json' --header 'Referer:AWSQS1' --header "Authorization:$token" |jq -r .clusterProperties.lifs |grep "Cluster Management" -a2|head -1|cut -f4 -d '"'`
echo "${clusterLif}" > /tmp/clusterLif.txt
## grab the iSCSI data LIF IP address
dataLif=`curl 'http://localhost/occm/api/vsa/working-environments/'${sourceVsaPublicId}'?fields=clusterProperties' -X GET --header 'Content-Type:application/json' --header 'Referer:AWSQS1' --header "Authorization:$token" |jq -r .clusterProperties.lifs |grep iscsi -a4|head -1|cut -f4 -d '"'`
echo "${dataLif}" > /tmp/iscsiLif.txt
## grab the NFS and CIFS data LIF IP address
dataLif2=`curl 'http://localhost/occm/api/vsa/working-environments/'${sourceVsaPublicId}'?fields=clusterProperties' -X GET --header 'Content-Type:application/json' --header 'Referer:AWSQS1' --header "Authorization:$token" |jq -r .clusterProperties.lifs |grep nfs -a4|head -1|cut -f4 -d '"'`
echo "${dataLif2}" > /tmp/nasLif.txt

# Remove passwords from files
sed -i s/${adminPassword}/xxxxx/g /var/log/cloud-init.log
sed -i s/${svmPassword}/xxxxx/g /var/log/cloud-init.log
