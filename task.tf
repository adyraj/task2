provider "aws" {
    region     = "ap-south-1"
    profile    = "myadi"
}

// Creating Key Pair

resource "tls_private_key" "web_key" {
    algorithm = "RSA"
}

resource "aws_key_pair" "task_key" {
    key_name   = "mytaskkey"
    public_key = tls_private_key.web_key.public_key_openssh
}

resource "local_file" "key-file" {
    content  = tls_private_key.web_key.private_key_pem
    filename = "task_key.pem"
}

// Creating VPC, Subnet and Internet Gateway
resource "aws_vpc" "main" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"

  tags = {
    Name = "myvpc1"
  }
}

resource "aws_subnet" "subnet1" {
  vpc_id = aws_vpc.main.id
  cidr_block = "10.0.0.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name = "subnet1"
  }

  depends_on = [
      aws_vpc.main
  ]
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "mygw1"
  }
  
  depends_on = [
      aws_vpc.main
  ]
}


resource "aws_route_table" "r" {
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "route1"
  }

  
  depends_on = [
      aws_internet_gateway.gw
  ]
}

resource "aws_route_table_association" "a" {
  subnet_id = aws_subnet.subnet1.id
  route_table_id = aws_route_table.r.id

  depends_on = [
      aws_subnet.subnet1,
      aws_route_table.r
  ]
}

// Creating Security Group

resource "aws_security_group" "task-security" {
    name        = "task-security-group"
    description = "Allow SSH inbound HTTP"
    vpc_id      = aws_vpc.main.id

    ingress {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
  }

    ingress {
      description = "HTTP"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
  }

    ingress {
      description = "NFS"
      from_port   = 2049
      to_port     = 2049
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }

    egress {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
  }

    tags = {
      Name = "firewall-ssh-http"
  }
    depends_on = [
        aws_route_table_association.a
  ]
}

// Launch EC2 Instance

resource "aws_instance" "web" {
    //depends_on    = [ aws_efs_mount_target.efs_mount ]
    ami           = "ami-0447a12f28fddb066"
    instance_type = "t2.micro"
    key_name      = aws_key_pair.task_key.key_name
    subnet_id     = aws_subnet.subnet1.id
    security_groups = [ aws_security_group.task-security.id ]

    tags = {
      Name = "webos"
  }

    connection {
        type    = "ssh"
        user    = "ec2-user"
        host    = aws_instance.web.public_ip
        port    = 22
        private_key = tls_private_key.web_key.private_key_pem
    }
    provisioner "remote-exec" {
        inline = [
        "sudo yum install httpd -y",
        "sudo systemctl start httpd",
        "sudo systemctl enable httpd",
        "sudo yum install git -y",
        "sudo yum install amazon-efs-utils -y",
        "sudo yum install nfs-utils -y"
        ]
    }
}


// Create EFS Volume

resource "aws_efs_file_system" "efs1" {
    creation_token = "my-product"
    performance_mode = "generalPurpose"

    tags = {
      Name = "webefs"
  }
    depends_on = [
        aws_instance.web
    ]
}

// Mounting EFS Storage

resource "aws_efs_mount_target" "efs_mount" {
    file_system_id = aws_efs_file_system.efs1.id
    subnet_id = aws_subnet.subnet1.id
    security_groups = [ aws_security_group.task-security.id ]

    depends_on = [
        aws_efs_file_system.efs1,
    ]
}

resource "null_resource" "mount_efs_volume" {
    connection {
        type    = "ssh"
        user    = "ec2-user"
        host    = aws_instance.web.public_ip
        port    = 22
        private_key = tls_private_key.web_key.private_key_pem
    }

    provisioner "remote-exec" {
        inline = [
        "sudo mount aws_efs_file_system.efs1.id:/ /var/www/html",
        "sudo echo 'aws_efs_file_system.efs1.id:/ /var/www/html efs defaults,_netdev 0 0' >> /etc/fstab",
        "sudo rm -rf /var/www/html/*",
        "sudo git clone https://github.com/adyraj/task.git /var/www/html/"
        ]
    }
  depends_on = [
      aws_instance.web,
      aws_efs_file_system.efs1, 
      aws_efs_mount_target.efs_mount
  ]
}




//Creating S3 Bucket

resource "aws_s3_bucket" "b" {
    bucket = "task-bucket123"
    acl    = "public-read"

    provisioner "local-exec" {
        when        =   destroy
        command     =   "echo rmdir /Q /S image"
    }


    provisioner "local-exec" {
        command     = "git clone https://github.com/adyraj/task_image.git image"
    }

    tags = {
      Name        = "My bucket"
  }
}

resource "aws_s3_bucket_object" "image_upload" {
    bucket  = aws_s3_bucket.b.bucket
    key     = "myimage.jfif"
    source  = "image/image.jfif"
    acl     = "public-read"
}

// Create Cloudfront

locals {
    s3_origin_id = "myS3_123"
    image_url = "${aws_cloudfront_distribution.s3_distribution.domain_name}/${aws_s3_bucket_object.image_upload.key}"
}

resource "aws_cloudfront_distribution" "s3_distribution" {
    origin {
        domain_name = aws_s3_bucket.b.bucket_domain_name
        origin_id   = local.s3_origin_id
    }

    default_cache_behavior {
        allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
        cached_methods   = ["GET", "HEAD"]
        target_origin_id = local.s3_origin_id
        forwarded_values {
            query_string = false
            cookies {
                forward = "none"
            }
        }
        viewer_protocol_policy = "allow-all"
    }

    enabled             = true

    restrictions {
        geo_restriction {
        restriction_type = "none"
        }
    }
    viewer_certificate {
        cloudfront_default_certificate = true
    }

    connection {
        type    = "ssh"
        user    = "ec2-user"
        host    = aws_instance.web.public_ip
        port    = 22
        private_key = tls_private_key.web_key.private_key_pem
    }
    provisioner "remote-exec" {
        inline  = [
            "sudo su << EOF",
            "echo \"<img src='http://${self.domain_name}/${aws_s3_bucket_object.image_upload.key}' width=400 height=300>\" >> /var/www/html/index.html",
            "EOF"
        ]
    }
}

output "myos_ip" {
  value = aws_instance.web.public_ip
}

resource "null_resource" "nulllocal"  {
depends_on = [
    aws_cloudfront_distribution.s3_distribution,
  ]

	provisioner "local-exec" {
	    command = "start chrome  ${aws_instance.web.public_ip}"
  	}
}
