# Provider configuration for AWS
provider "aws" {
  region = "us-east-1"
}

# Define variables
variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "subnet_cidr_public" {
  default = [
    "10.0.0.0/20",
    "10.0.16.0/20",
    "10.0.32.0/20"
  ]
}

variable "subnet_cidr_private" {
  default = [
    "10.0.128.0/20",
    "10.0.144.0/20",
    "10.0.160.0/20",
    "10.0.176.0/20",
    "10.0.192.0/20",
    "10.0.208.0/20"
  ]
}

# Create VPC
resource "aws_vpc" "strapi_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Name = "strapi-vpc"
  }
}

# Create public and private subnets
locals {
  azs = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

resource "aws_subnet" "strapi_subnet_public" {
  count                   = length(var.subnet_cidr_public)
  vpc_id                  = aws_vpc.strapi_vpc.id
  cidr_block              = var.subnet_cidr_public[count.index]
  availability_zone       = element(local.azs, count.index % length(local.azs))
  map_public_ip_on_launch = true
  tags = {
    Name = "strapi-subnet-public-${count.index + 1}-${element(local.azs, count.index % length(local.azs))}"
  }
}

resource "aws_subnet" "strapi_subnet_private" {
  count                   = length(var.subnet_cidr_private)
  vpc_id                  = aws_vpc.strapi_vpc.id
  cidr_block              = var.subnet_cidr_private[count.index]
  availability_zone       = element(local.azs, count.index % length(local.azs))
  map_public_ip_on_launch = false

  tags = {
    Name = "strapi-subnet-private-${count.index + 1}-${element(local.azs, count.index % length(local.azs))}"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "strapi_igw" {
  vpc_id = aws_vpc.strapi_vpc.id
}

# Create route tables
resource "aws_route_table" "strapi_rtb_public" {
  vpc_id = aws_vpc.strapi_vpc.id
  tags = {
    Name = "Strapi-rtb-public"
  }
}

resource "aws_route_table" "strapi_rtb_private" {
  count = length(var.subnet_cidr_private)

  vpc_id = aws_vpc.strapi_vpc.id

  tags = {
    Name = "Strapi-rtb-private${count.index + 1}-${element(local.azs, count.index % length(local.azs))}"
  }
}

resource "aws_route" "strapi_route_to_internet" {
  route_table_id         = aws_route_table.strapi_rtb_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.strapi_igw.id
}

# Associate public subnet with public route table
resource "aws_route_table_association" "strapi_rtb_public_association" {
  count          = 3
  subnet_id      = aws_subnet.strapi_subnet_public[count.index].id
  route_table_id = aws_route_table.strapi_rtb_public.id
}

# Associate private subnets with private route tables
resource "aws_route_table_association" "strapi_rtb_private_association" {
  count          = 6
  subnet_id      = aws_subnet.strapi_subnet_private[count.index].id
  route_table_id = aws_route_table.strapi_rtb_private[count.index].id
}

# VPC Endpoint for S3
resource "aws_vpc_endpoint" "strapi_vpce_s3" {
  vpc_id       = aws_vpc.strapi_vpc.id
  service_name = "com.amazonaws.us-east-1.s3"
}

resource "aws_elastic_beanstalk_application" "strapi_web_app" {
  name        = "Strapi-Application"
  description = "strapi web app"
}

# IAM Role for Elastic Beanstalk
resource "aws_iam_role" "strapi_eb_service_role" {
  name               = "strapi-eb-service-role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "elasticbeanstalk.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    },
    {
      "Effect" : "Allow",
      "Principal" : {
        "Service" : "ec2.amazonaws.com"
      },
      "Action" : "sts:AssumeRole"
    }
  ]
}
EOF
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "eb_instance_profile" {
  name = "EB-Instance-Profile"
  role = aws_iam_role.strapi_eb_service_role.name
}

# IAM Role Policy
resource "aws_iam_role_policy_attachment" "eb_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier"
  role       = aws_iam_role.strapi_eb_service_role.name
}

# Elastic Beanstalk Environment
resource "aws_elastic_beanstalk_environment" "strapi_eb_environment" {
  name                   = "Strapi-EB-Environment"
  tier                   = "WebServer"
  wait_for_ready_timeout = "20m"
  application            = aws_elastic_beanstalk_application.strapi_web_app.name
  # solution_stack_name    = "64bit Amazon Linux 2023 v6.1.0 running Node.js 18"
  # solution_stack_name = "64bit Amazon Linux 2023 v4.2.2 running Docker"
  solution_stack_name = "64bit Amazon Linux 2 v3.7.2 running Docker"

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "InstanceType"
    value     = "t3.medium"
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "IamInstanceProfile"
    value     = aws_iam_instance_profile.eb_instance_profile.name
  }

  # Load Balancer
  setting {
    namespace = "aws:elbv2:listener:default"
    name      = "ListenerEnabled"
    value     = "true"
  }

  setting {
    namespace = "aws:elbv2:listener:default"
    name      = "Protocol"
    value     = "HTTP"
  }

  setting {
    namespace = "aws:elbv2:listener:default"
    name      = "Port"
    value     = "5000"
  }

  # RDS Aurora MySQL
  setting {
    namespace = "aws:rds:dbinstance"
    name      = "DBEngine"
    value     = "aurora-mysql"
  }

  setting {
    namespace = "aws:rds:dbinstance"
    name      = "DBInstanceClass"
    value     = "db.t3.medium"
  }
}

resource "aws_iam_policy" "ecr_read_policy" {
  name        = "ECRReadPolicy"
  description = "Allows Elastic Beanstalk environment to read from ECR repository"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ],
        Resource = "*",
      },
    ],
  })
}

resource "aws_iam_policy_attachment" "ecr_read_policy_attachment" {
  name       = "ECRReadPolicyAttachment"
  roles      = [aws_iam_instance_profile.eb_instance_profile.role]
  policy_arn = aws_iam_policy.ecr_read_policy.arn
}
