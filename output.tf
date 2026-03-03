output "jenkins_ip" {

  value = aws_instance.jenkins.public_ip

}

output "master_ip" {

  value = aws_instance.kubernetesmaster.public_ip

}

output "worker_ip" {

  value = aws_instance.kubernetesworker.public_ip

}
