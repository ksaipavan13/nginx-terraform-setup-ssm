provider "aws" {
  region = "us-east-1" # Set your preferred region
}

# Create a VPC
resource "aws_vpc" "main_vpc" {
  cidr_block = "10.0.0.0/16"
}

# Create an internet gateway for the VPC
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id
}

# Create a public subnet
resource "aws_subnet" "public_subnet" {
  vpc_id     = aws_vpc.main_vpc.id
  cidr_block = "10.0.1.0/24"
}

# Create a security group for the EC2 instance
resource "aws_security_group" "nginx_sg" {
  vpc_id = aws_vpc.main_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create an IAM role for SSM access with a unique name
resource "aws_iam_role" "ec2_ssm_role" {
  name = "EC2SSMRole-Nginx"  # Updated role name to avoid conflict

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

# Attach the AmazonSSMManagedInstanceCore policy to the new IAM role
resource "aws_iam_role_policy_attachment" "ssm_policy_attach" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Create an instance profile with the updated role name
resource "aws_iam_instance_profile" "ec2_ssm_instance_profile" {
  name = "EC2SSMInstanceProfile-Nginx"  # Updated instance profile name
  role = aws_iam_role.ec2_ssm_role.name
}

# Launch EC2 instance with user data to install Nginx
resource "aws_instance" "nginx_ec2" {
  ami           = "ami-00f251754ac5da7f0"  # Correct AMI ID for your region
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.nginx_sg.id]  # Use security group ID

  iam_instance_profile = aws_iam_instance_profile.ec2_ssm_instance_profile.name

  user_data = <<-EOF
    #!/bin/bash
    sudo amazon-linux-extras install -y nginx1
    sudo systemctl start nginx
    sudo systemctl enable nginx
  EOF

  tags = {
    Name = "Nginx-EC2"
  }
}

# Create a Systems Manager Maintenance Window
resource "aws_ssm_maintenance_window" "nginx_update_window" {
  name     = "Nginx-Update"
  schedule = "cron(0 0 */1 * * ? *)" # Set to run daily at midnight UTC
  duration = 5
  cutoff   = 4
  enabled  = true
}

# Register the EC2 instance as a target for the Maintenance Window
resource "aws_ssm_maintenance_window_target" "nginx_window_target" {
  window_id  = aws_ssm_maintenance_window.nginx_update_window.id
  name       = "Nginx-EC2-Target"
  resource_type = "INSTANCE"
  targets {
    key    = "InstanceIds"
    values = [aws_instance.nginx_ec2.id]
  }
}

# Register a Run Command task to restart Nginx
resource "aws_ssm_maintenance_window_task" "nginx_restart_task" {
  window_id           = aws_ssm_maintenance_window.nginx_update_window.id
  max_concurrency     = "1"
  max_errors          = "1"
  priority            = 1
  task_arn            = "AWS-RunShellScript"
  task_type           = "RUN_COMMAND"
  
  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.nginx_window_target.id]
  }

  task_invocation_parameters {
    run_command_parameters {
      comment = "Restart Nginx"
      timeout_seconds = 3600

      parameter {
        name   = "commands"
        values = ["sudo systemctl restart nginx"]
      }
    }
  }

  service_role_arn = aws_iam_role.ec2_ssm_role.arn
}
