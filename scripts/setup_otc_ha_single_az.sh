#!/bin/bash -e

function exportParams() {
	name=`grep 'name' ${PARAMS_FILE} | awk -F'|' '{print $2}' | sed -e 's/^ *//g;s/ *$//g'`
	customer=`grep 'customer' ${PARAMS_FILE} | awk -F'|' '{print $2}' | sed -e 's/^ *//g;s/ *$//g'`
	vpcID=`grep 'vpcID' ${PARAMS_FILE} | awk -F'|' '{print $2}' | sed -e 's/^ *//g;s/ *$//g'`
	subnetID=`grep 'subnetID' ${PARAMS_FILE} | awk -F'|' '{print $2}' | sed -e 's/^ *//g;s/ *$//g'`
	capacity=`grep 'capacity' ${PARAMS_FILE} | awk -F'|' '{print $2}' | sed -e 's/^ *//g;s/ *$//g'`
	region=`grep 'region' ${PARAMS_FILE} | awk -F'|' '{print $2}' | sed -e 's/^ *//g;s/ *$//g'`
	adminEmail=`grep 'adminEmail' ${PARAMS_FILE} | awk -F'|' '{print $2}' | sed -e 's/^ *//g;s/ *$//g'`
	adminPassword=`grep 'adminPassword' ${PARAMS_FILE} | awk -F'|' '{print $2}' | sed -e 's/^ *//g;s/ *$//g'`
	svmPassword=${adminPassword}
	keyPair=`grep 'keyPair' ${PARAMS_FILE} | awk -F'|' '{print $2}' | sed -e 's/^ *//g;s/ *$//g'`
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
capacity='NONE'
region='NONE'
adminEmail='NONE'
adminPassword='NONE'
svmPassword='NONE'
keyPair='NONE'

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
  curl http://localhost/occm/api/audit?workingEnvironmentId=${1} -X GET --header 'Content-Type:application/json' --header 'Referer:AWSQS2' --cookie cookies.txt | jq -r .[${3}].status > /tmp/temp.txt
  test=`cat /tmp/temp.txt`
  if [ ${test} = null ] ; then
	sleep ${2}
	waitForAction ${1} ${2} ${3}
  fi
  while [ ${test} = Received ] || [ ${test} = null ] ; do sleep ${2};curl http://localhost/occm/api/audit?workingEnvironmentId=${1} -X GET --header 'Content-Type:application/json' --header 'Referer:AWSQS2' --cookie cookies.txt | jq -r .[${3}].status > /tmp/temp.txt;test=`cat /tmp/temp.txt`; done
  if [ ${test} = Failed ] ; then
	  curl http://localhost/occm/api/audit?workingEnvironmentId=${1} -X GET --header 'Content-Type:application/json' --header 'Referer:AWSQS2' --cookie cookies.txt | jq -r .[${3}] > /tmp/temp.txt
	  errorMessage=`cat /tmp/temp.txt| jq -r .errorMessage`
	  actionName=`cat /tmp/temp.txt| jq -r .actionName`
	  echo "Action: $actionName failed due to: $errorMessage" > /tmp/occmError.txt
	  exit 1
  fi
}

dataAccessCidr=`aws ec2 describe-subnets --region $region --subnet-id $subnetID | jq -r '.Subnets[0].CidrBlock'`
sleep 60
## Setup Cloud Manager
curl http://localhost/occm/api/occm/setup/init -X POST --header 'Content-Type:application/json' --header 'Referer:AWSQS2' --retry 20 --data '{ "proxyUrl": { "uri": "" }, "userRequest":{  "email": "'${adminEmail}'","lastName": "admin", "firstName":"admin","accessKey": "nokeys","roleId": "Role-1","secretKey": "nokeys","password": "'${adminPassword}'"  }, "site": "'${customer}_site'", "company": "'${customer}'","tenantRequest": { "name": "'${customer}_tenant'", "description": "", "costCenter": "", "nssKeys": {} }}' >> /tmp/occm-init.txt
echo "Cloud manager setup initialized"
sleep 40
until sudo wget http://localhost/occmui > /dev/null 2>&1; do sudo wget http://localhost > /dev/null 2>&1 ; done
sleep 80
## Authenticate to Cloud Manager
echo "Authenticating to cloud manager"
curl http://localhost/occm/api/auth/login  --retry 20 --header 'Content-Type:application/json' --header 'Referer:AWSQS2' --data '{"email":"'${adminEmail}'","password":"'${adminPassword}'"}' --cookie-jar cookies.txt
sleep 5
## Get the Tenant ID so we can create the ONTAP Cloud system in that Cloud Manager Tenant
tenantId=`curl http://localhost/occm/api/tenants -X GET --header 'Content-Type:application/json' --header 'Referer:AWSQS2' --cookie cookies.txt | jq -r .[0].publicId`
## Create a ONTAP Cloud HA working env
name=$(tr '-' 'x' <<< ${name:0:30})
curl http://localhost/occm/api/aws/ha/working-environments -X POST --cookie cookies.txt --header 'Content-Type:application/json' --header 'Referer:AWSQS2' --data '{"name":"'${name}otcHA'","tenantId":"'${tenantId}'","region":"'${region}'","ebsVolumeType":"gp2","ebsVolumeSize": {"size": 1, "unit": "TB", "_identifier": "1 TB"},"haParams": {"failoverMode":"PrivateIP","node1SubnetId":"'${subnetID}'","node2SubnetId":"'${subnetID}'","mediatorSubnetId":"'${subnetID}'","mediatorKeyPairName":"'${keyPair}'"},"dataEncryptionType":"AWS","ontapEncryptionParameters":null,"skipSnapshots": "true","svmPassword":"'${svmPassword}'","vpcId":"'${vpcID}'","vsaMetadata":{"platformLicense":null,"ontapVersion":"latest","useLatestVersion": true,"licenseType":"ha-cot-standard-paygo","instanceType":"c4.2xlarge"}}' > /tmp/createVSA.txt
sourceVsaPublicId=`cat /tmp/createVSA.txt| jq -r .publicId`
if [ ${sourceVsaPublicId} = null ] ; then
  message=`cat /tmp/createVSA.txt| jq -r .message`
  echo "OCCM setup failed: $message" > /tmp/occmError.txt
  exit 1
fi
sleep 2
## Check SRC VSA
waitForAction ${sourceVsaPublicId} 60 1
## Create volume on VSA
srcSvmName=`curl http://localhost/occm/api/aws/ha/working-environments/${sourceVsaPublicId} -X GET --header 'Content-Type:application/json' --header 'Referer:AWSQS2' --cookie cookies.txt | jq -r .svmName`
echo "${srcSvmName}" > /tmp/svmName.txt
## Confirm it's possible to create a new volume
curl http://localhost/occm/api/aws/ha/volumes/quote -X POST --header 'Content-Type:application/json' --header 'Referer:AWSQS2' --data '{"workingEnvironmentId": "'${sourceVsaPublicId}'","svmName": "'${srcSvmName}'","aggregateName": "aggr1", "name": "nfsvolume", "size": {"size": "'${capacity}'", "unit": "GB"}, "enableThinProvisioning": "true","verifyNameUniqueness": "true"}' --cookie cookies.txt  >  /tmp/quote.txt
disks=`cat /tmp/quote.txt| jq -r .numOfDisks`
aggrName=`cat /tmp/quote.txt| jq -r .aggregateName`
sleep 2
## Create new volume
curl http://localhost/occm/api/aws/ha/volumes -X POST --header 'Content-Type:application/json' --header 'Referer:AWSQS2' --data '{"workingEnvironmentId":"'${sourceVsaPublicId}'","svmName":"'${srcSvmName}'","aggregateName":"aggr1","name":"volume1","size":{"size":"'${capacity}'","unit":"GB"},"snapshotPolicyName":"default","exportPolicyInfo":{"policyType":"custom","ips":["'${dataAccessCidr}'"]},"enableThinProvisioning":"true","enableDeduplication":"true","enableCompression":"false","maxNumOfDisksApprovedToAdd":"'${disks}'","syncToS3": "false"}' --cookie cookies.txt > /tmp/volcreate.txt
## Check volume creation
waitForAction ${sourceVsaPublicId} 10 1
sleep 10
curl http://localhost/occm/api/aws/ha/volumes/?workingEnvironmentId=${sourceVsaPublicId} -X GET --header 'Content-Type:application/json' --header 'Referer:AWSQS2' --cookie cookies.txt > /tmp/volinfo.txt
mountPoint=`cat /tmp/volinfo.txt| jq -r .[0].mountPoint`
echo "${mountPoint}" > /tmp/mountpoint.txt
## grab the cluster properties
curl http://localhost/occm/api/aws/ha/working-environments/${sourceVsaPublicId}?fields=ontapClusterProperties -X GET --header 'Content-Type:application/json' --header 'Referer:AWSQS2' --cookie cookies.txt > /tmp/clusterprops.txt
## grab the Cluster managment LIF IP address
cat /tmp/clusterprops.txt  | jq '.ontapClusterProperties.nodes[0].lifs[] | select(.lifType=="Cluster Management").ip' | tr -d '"' > /tmp/clusterLif.txt
## grab the iSCSI data LIF IP address
cat /tmp/clusterprops.txt  | jq '.ontapClusterProperties.nodes[0].lifs[] | select(.lifType=="Data") | select(.dataProtocols[0]=="iscsi").ip' | tr -d '"' > /tmp/iscsiLif.txt
## grab the NFS and CIFS data LIF IP address
cat /tmp/clusterprops.txt  | jq '.ontapClusterProperties.nodes[0].lifs[] | select(.lifType=="Data") | select(.dataProtocols[0]=="nfs").ip' | tr -d '"' > /tmp/nasLif.txt

# Remove passwords from files
sed -i s/${adminPassword}/xxxxx/g /var/log/cloud-init.log
sed -i s/${svmPassword}/xxxxx/g /var/log/cloud-init.log