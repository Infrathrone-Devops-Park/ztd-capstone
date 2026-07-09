# Self-hosted SonarQube (Community Edition) + Postgres via docker-compose on
# a single EC2 instance. Access is via SSM Session Manager only — no SSH key,
# no port 22 anywhere in this configuration.

resource "random_password" "sonar_db" {
  length  = 24
  special = false
}

locals {
  sonar_db_password_effective = var.sonar_db_password == "" ? random_password.sonar_db.result : var.sonar_db_password
  sonar_ssm_pw_name            = "/${var.project}/sonar/db-password"
}

resource "aws_ssm_parameter" "sonar_db" {
  name  = local.sonar_ssm_pw_name
  type  = "SecureString"
  value = local.sonar_db_password_effective

  tags = {
    project    = var.project
    managed-by = "terraform"
    layer      = "stack"
  }
}

data "aws_iam_policy_document" "sonar_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sonar" {
  name               = "${var.project}-sonar-role"
  assume_role_policy = data.aws_iam_policy_document.sonar_assume_role.json
}

resource "aws_iam_role_policy_attachment" "sonar_ssm" {
  role       = aws_iam_role.sonar.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "sonar_ssm_param_read" {
  statement {
    actions   = ["ssm:GetParameter"]
    effect    = "Allow"
    resources = [aws_ssm_parameter.sonar_db.arn]
  }
}

resource "aws_iam_role_policy" "sonar_ssm_param_read" {
  name   = "${var.project}-sonar-ssm-param-read"
  role   = aws_iam_role.sonar.id
  policy = data.aws_iam_policy_document.sonar_ssm_param_read.json
}

resource "aws_iam_instance_profile" "sonar" {
  name = "${var.project}-sonar-profile"
  role = aws_iam_role.sonar.name
}

# Fresh security group, dedicated to this instance. Never touches the
# cluster SG or any other pre-existing SG.
resource "aws_security_group" "sonar" {
  name        = "${var.project}-sonar-sg"
  description = "SonarQube EC2: inbound 9000 only, SSM for admin access (no SSH)"
  vpc_id      = var.vpc_id

  ingress {
    description = "SonarQube web UI/API"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = [var.sonar_ingress_cidr]
  }

  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name       = "${var.project}-sonar-sg"
    project    = var.project
    managed-by = "terraform"
    layer      = "stack"
  }
}

resource "aws_instance" "sonar" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.sonar_instance_type
  subnet_id              = element(var.public_subnet_ids, 0)
  vpc_security_group_ids = [aws_security_group.sonar.id]
  iam_instance_profile   = aws_iam_instance_profile.sonar.name

  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp3"
    volume_size = var.sonar_disk_gib
  }

  user_data = templatefile("${path.module}/templates/sonar_userdata.sh.tftpl", {
    ssm_pw_name = local.sonar_ssm_pw_name
    region      = var.region
  })

  tags = {
    Name       = "${var.project}-sonarqube"
    project    = var.project
    managed-by = "terraform"
    layer      = "stack"
  }
}

resource "aws_eip" "sonar" {
  instance = aws_instance.sonar.id
  domain   = "vpc"

  tags = {
    Name       = "${var.project}-sonarqube-eip"
    project    = var.project
    managed-by = "terraform"
    layer      = "stack"
  }
}
