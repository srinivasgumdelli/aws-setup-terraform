terraform {
  backend "s3" {
    bucket = "terraform.account-new"
    key    = "account-state"
    region = "us-east-1"
  }
}

variable "account_name" {
  default = "test"
}

provider "aws" {
  region = "us-east-1"
  version = "~> 3.0"
}

# Setup VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.2.0"

  name = var.account_name
  cidr = "10.12.0.0/16"

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.12.1.0/24", "10.12.2.0/24", "10.12.3.0/24"]
  public_subnets  = ["10.12.101.0/24", "10.12.102.0/24", "10.12.103.0/24"]

  enable_nat_gateway = false
  enable_vpn_gateway = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

# Setup Security group
module "sg" {
  source = "terraform-aws-modules/security-group/aws"

  name          = "web-server"
  description   = "Security group for web-server with HTTP ports open within VPC"
  ingress_rules = ["ssh-tcp"]
  vpc_id        = module.vpc.vpc_id

  # Allow specific IP address for SSH
  ingress_cidr_blocks = ["8.8.8.8/32"]
  egress_rules = ["all-all"]

  ingress_with_cidr_blocks = [
    {
      rule = "http-80-tcp"
      cidr_blocks = "10.12.0.0/16"
    }
  ]
}

resource "aws_key_pair" "ssh_keypair" {
  key_name   = "account-key"
  # Add your public SSH key here
  public_key = "<public ssh key here>"
}

resource "aws_ami" "ami_from_snapshot" {
  name = "${var.account_name}_snapshot_ami"
  virtualization_type = "hvm"
  root_device_name = "/dev/xvda"
  ebs_block_device {
    device_name = "/dev/xvda"
    snapshot_id = "<snapshot_id_here>"

    # update to desired volume size
    volume_size = 8
  }
}


module "ec2_cluster" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 2.0"

  name           = var.account_name
  instance_count = 1

  # Include ami if restoring from snapshot
  ami                    = aws_ami.ami_from_snapshot.id
  instance_type          = "t2.micro"
  key_name               = aws_key_pair.ssh_keypair.key_name
  monitoring             = true
  vpc_security_group_ids = [module.sg.security_group_id]
  subnet_id              = module.vpc.public_subnets[0]


  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

variable "db_password" {
  description = "Database administrator password"
  type        = string
  sensitive   = true
}

module "rds_sg" {
  source = "terraform-aws-modules/security-group/aws"

  name          = "rds-server"
  description   = "Security group for web-server with HTTP ports open within VPC"
  ingress_rules = ["mysql-tcp"]
  vpc_id        = module.vpc.vpc_id

  ingress_cidr_blocks = module.vpc.public_subnets_cidr_blocks

}

data "aws_db_snapshot" "db_snapshot" {
    most_recent = true
    include_shared = true
    # Use this if restoring database from snapshot
    db_snapshot_identifier = "<snapshot_identifier here>"
}

module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 3.0"

  identifier = "<database_identifier_here>"

  engine            = "mysql"
  engine_version    = "5.7.34"
  instance_class    = "db.t2.micro"
  allocated_storage = 5
  # Use if restoring from snapshot
  snapshot_identifier = data.aws_db_snapshot.db_snapshot.id

  name     = "<database_name>"
  username = "root"
  password = var.db_password
  port     = "3306"

  iam_database_authentication_enabled = true

  vpc_security_group_ids = [module.rds_sg.security_group_id]

  maintenance_window = "Mon:00:00-Mon:03:00"
  backup_window      = "03:00-06:00"

  tags = {
    ManagedBy   = "Terraform"
    Environment = "dev"
  }

  # DB subnet group
  subnet_ids = module.vpc.private_subnets

  # DB parameter group
  family = "mysql5.7"

  # DB option group
  major_engine_version = "5.7"

  # Database Deletion Protection
  deletion_protection = true

  parameters = [
    {
      name = "character_set_client"
      value = "utf8mb4"
    },
    {
      name = "character_set_server"
      value = "utf8mb4"
    }
  ]

  options = [
    {
      option_name = "MARIADB_AUDIT_PLUGIN"

      option_settings = [
        {
          name  = "SERVER_AUDIT_EVENTS"
          value = "CONNECT"
        },
        {
          name  = "SERVER_AUDIT_FILE_ROTATIONS"
          value = "37"
        },
      ]
    },
  ]
}

output "public_ip" {
  description = "List of public IP addresses assigned to the instance"
  value       = module.ec2_cluster.public_ip
}

output "elb_dns" {
  description = "elb dns"
  value       = module.elb_http.this_elb_dns_name
}
