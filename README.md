# quickstart-netapp-ontapcloud-sql

This Quick Start automatically deploys a Microsoft SQL Server 2014 environment that receives its storage and enterprise-class data management capabilities from a NetApp ONTAP Cloud system running on AWS. The Quick Start uses NetApp OnCommand Cloud Manager to deploy and configure ONTAP Cloud.

ONTAP Cloud is a software-only version of Data ONTAP, which is the data management operating system from NetApp that is used on physical NetApp storage appliances. With ONTAP Cloud, the operating system has been customized to run as an AWS Elastic Compute Cloud (Amazon EC2) instance. With ONTAP Cloud on AWS, you can spin up a new enterprise class data management system in minutes on the cloud.

This Quick Start deploys ONTAP Cloud with SQL Server using AWS CloudFormation templates. It offers two deployment options: you can build a new AWS infrastructure for your ONTAP Cloud stack, or deploy the software into your existing AWS infrastructure. Each deployment takes about 45 minutes.

### NetApp ONTAP cloud on AWS

![Quick Start Cloudera Architecture](https://d0.awsstatic.com/partner-network/QuickStart/datasheets/netapp-ontap-on-aws-architecture.png)

Deployment steps:

1. Sign up for an AWS account at http://aws.amazon.com, select a region, and create a key pair.
2. Subscribe to the AMIs for NetApp Software ([ONTAP Cloud](https://aws.amazon.com/marketplace/pp/B011KEZ734), [Cloud Manager](https://aws.amazon.com/marketplace/pp/B018REK8QG)).
3. In the AWS CloudFormation console, launch one of the following templates to build a new stack:
  * /templates/netapp-otc-sql-master.template (to deploy NetApp ONTAP cloud into a new VPC)
  * /templates/netapp-otc-sql.template (to deploy NetApp ONTAP cloud into your existing VPC)
4. Access your ONTAP Cloud with SQL Server Deployment using the instructions provided in the [deployment guide](https://s3.amazonaws.com/quickstart-reference/netapp/ontapcloud/sql/latest/doc/netapp-ontap-cloud-on-the-aws-cloud.pdf).

The Quick Start provides parameters that you can set to customize your deployment. For architectural details, best practices, step-by-step instructions, and customization options, see the [deployment guide](https://s3.amazonaws.com/quickstart-reference/netapp/ontapcloud/sql/latest/doc/netapp-ontap-cloud-on-the-aws-cloud.pdf).