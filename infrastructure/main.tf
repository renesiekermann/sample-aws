###############################################################################
## VPC                                                                       ##
###############################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 4.0.0"

  name = "${var.env_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true

  map_public_ip_on_launch = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${var.env_name}-eks-cluster" = "shared"
    "kubernetes.io/role/elb"                            = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/${var.env_name}-eks-cluster" = "shared"
    "kubernetes.io/role/internal-elb"                = 1
  }

  tags = var.tags
}

###############################################################################
## MongoDB Instance                                                          ##
###############################################################################

module "mongodb_instance" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 4.5.0"

  name = "mongodb"

  ami                    = var.ubuntu_1604_ami
  instance_type          = "t3.micro"
  key_name               = var.key_name
  subnet_id              = module.vpc.public_subnets[0]
  vpc_security_group_ids = [module.mgmt_sg.security_group_id, module.mongodb_sg.security_group_id]

  iam_instance_profile = aws_iam_instance_profile.mongodb.name

  user_data = file("${path.module}/mongodb-user_data.sh")

  tags = var.tags
}

###############################################################################
## Excessive IAM role for MongoDB instance                                   ##
###############################################################################

# Make sure role has a unique name.
resource "random_id" "role_id" {
  byte_length = 8
}

resource "aws_iam_role" "mongodb" {
  name = "${var.env_name}-EC2FullAccessRole-${random_id.role_id.hex}"

  tags               = var.tags
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "mongodb" {
  name   = "${var.env_name}-EC2FullAccess-${random_id.role_id.hex}"
  role   = aws_iam_role.mongodb.id
  policy = <<EOF
{
  "Version" : "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ec2:*",
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_iam_instance_profile" "mongodb" {
  name = "${var.env_name}-MongoDB-InstanceProfile"
  role = aws_iam_role.mongodb.name
  path = "/"
}

###############################################################################
## Publicly accessible S3 bucket                                             ##
###############################################################################

module "mongodb_backup_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 3.8.1"

  bucket_prefix = "${var.env_name}-mongodb-backup-"

  tags = var.tags
}

# Need for avoid `Error putting S3 policy: AccessDenied: Access Denied`
resource "time_sleep" "wait_2_seconds" {
  depends_on      = [module.mongodb_backup_bucket.s3_bucket_website_domain]
  create_duration = "2s"
}

resource "aws_s3_bucket_policy" "read_access" {
  bucket = module.mongodb_backup_bucket.s3_bucket_id
  policy = data.aws_iam_policy_document.read_access.json

  depends_on = [
    time_sleep.wait_2_seconds
  ]
}

data "aws_iam_policy_document" "read_access" {
  statement {
    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:GetObject",
    ]

    resources = [
      module.mongodb_backup_bucket.s3_bucket_arn,
      "${module.mongodb_backup_bucket.s3_bucket_arn}/*",
    ]
  }
}

###############################################################################
## Security Groups                                                           ##
###############################################################################

module "mgmt_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.17.0"

  name        = "Mgmt-SG"
  description = "Management Security Group"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = var.mgmt_cidrs
  ingress_rules       = ["ssh-tcp"]

  egress_rules = ["all-all"]

  tags = var.tags
}

module "mongodb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.17.0"

  name        = "MongoDB-SG"
  description = "MongoDB Security Group"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = ["10.0.0.0/16"]
  ingress_rules       = ["all-all"]

  egress_rules = ["all-all"]

  tags = var.tags
}

###############################################################################
## EKS Cluster                                                               ##
###############################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.13.0"

  cluster_name    = "${var.env_name}-eks-cluster"
  cluster_version = "1.24"

  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true

  cluster_addons = {
    aws-ebs-csi-driver = {
      resolve_conflicts        = "OVERWRITE"
      service_account_role_arn = module.ebs_csi_addon_irsa.iam_role_arn
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    "${var.env_name}-eks" = {
      instance_types = ["m5.large"]
      min_size       = 1
      max_size       = 2
      desired_size   = 2
    }
  }

  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
  }

  tags = var.tags
}

module "ebs_csi_addon_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.17.0"

  role_name = "AmazonEKS_EBS_CSI_DriverRole"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

## Budget Notifications
resource "aws_budgets_budget" "this" {
  count = var.create_budget ? 1 : 0

  name         = var.budget_name
  budget_type  = "COST"
  limit_amount = var.budget_amount
  limit_unit   = var.budget_currency
  time_unit    = var.budget_time_unit

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = "80"
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = "100"
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = "100"
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}
