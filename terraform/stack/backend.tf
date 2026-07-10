terraform {
  backend "s3" {
    bucket         = "ztd-capstone-tfstate-514422154867"
    key            = "stack/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "ztd-capstone-tflock"
    encrypt        = true
    profile        = "infrathrone-new"
  }
}
