# Terraform state stored in S3. Locking uses S3 native lockfiles (Terraform >= 1.10),
# so no DynamoDB table is needed (the dynamodb_table argument is deprecated).
terraform {
  backend "s3" {
    bucket       = "tfstate-tahaelidrissi-devsecops"
    region       = "us-west-2"
    key          = "three-tier-devsecops-project/jenkins-server-terraform/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }

  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
