resource "aws_instance" "jenkins" {

  ami = "ami-0f5ee92e2d63afc18"

  instance_type = "t3.small"

  key_name = "devops-key"

  security_groups = [aws_security_group.devops_sg.name]

  tags = {

    Name = "Jenkins-Server"

  }

}

resource "aws_instance" "kubernetesmaster" {

  ami = "ami-0f5ee92e2d63afc18"

  instance_type = "t3.small"

  key_name = "devops-key"

  security_groups = [aws_security_group.devops_sg.name]

  tags = {

    Name = "Kubernetes-Master"

  }

}

resource "aws_instance" "kubernetesworker" {

  ami = "ami-0f5ee92e2d63afc18"

  instance_type = "t3.small"

  key_name = "devops-key"

  security_groups = [aws_security_group.devops_sg.name]

  tags = {

    Name = "Kubernetes-Worker"

  }

}
