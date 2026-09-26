terraform {
  required_version = "= 1.16.4"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.60.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "= 2.7.1"
    }
  }
}

/**
 * Remote state in S3 with native locking (use_lockfile), so a lost laptop or a
 * deleted local file no longer orphans the deployed resources.
 */
terraform {
  backend "s3" {
    bucket       = "dashboards-dinamicos-tfstate-503561412084"
    key          = "dev/ventas-inteligentes.tfstate"
    region       = "us-east-1"
    profile      = "dashboards-dev-infile"
    encrypt      = true
    use_lockfile = true
  }
}
