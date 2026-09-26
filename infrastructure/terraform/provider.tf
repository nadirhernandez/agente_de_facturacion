# This project is intentionally locked to the dev-infile AWS account.
# Terraform will fail before creating resources if credentials target another account.
provider "aws" {
  profile = "dashboards-dev-infile"
  region  = "us-east-1"

  allowed_account_ids = ["503561412084"]

  default_tags {
    tags = {
      Project     = "dashboards-dinamicos"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}
