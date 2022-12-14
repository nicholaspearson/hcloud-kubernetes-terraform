# Create Leader
resource "hcloud_server" "leader" {
  name        = format("leader-%s.%s.%s", count.index + 1, var.cluster_tag, var.cluster_domain)
  count       = 1
  image       = "centos-stream-8"
  server_type = var.leader_instance_type
  ssh_keys    = [hcloud_ssh_key.root_openssh_public_key.id]
  user_data   = file("${path.module}/files/user-data/leader.tftpl")

  datacenter = var.hcloud_location

  network {
    network_id = hcloud_network.sdn_cidr.id
  }

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait > /dev/null",
      "echo 'Completed cloud-init, starting cluster pre-flight checks/init...'",
      "curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash",
      "kubeadm init --pod-network-cidr=10.244.0.0/16",
      "export KUBECONFIG=/etc/kubernetes/admin.conf",
      "kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml",
      "kubectl -n kube-flannel patch ds kube-flannel-ds --type json -p '[{\"op\":\"add\",\"path\":\"/spec/template/spec/tolerations/-\",\"value\":{\"key\":\"node.cloudprovider.kubernetes.io/uninitialized\",\"value\":\"true\",\"effect\":\"NoSchedule\"}}]'",
      "kubectl -n kube-system create secret generic hcloud --from-literal=token=${var.hcloud_token} --from-literal=network=${hcloud_network.sdn_cidr.id}",
      "kubectl -n kube-system create secret generic hcloud-csi --from-literal=token=${var.hcloud_token}",
      "kubectl apply -f  https://github.com/hetznercloud/hcloud-cloud-controller-manager/releases/latest/download/ccm-networks.yaml",
      "kubectl set env deployment -n kube-system hcloud-cloud-controller-manager HCLOUD_LOAD_BALANCERS_LOCATION=${var.hcloud_lb_location}",
      "kubectl set env deployment -n kube-system hcloud-cloud-controller-manager HCLOUD_LOAD_BALANCERS_USE_PRIVATE_IP=true",
      "kubectl apply -f https://raw.githubusercontent.com/hetznercloud/csi-driver/v1.6.0/deploy/kubernetes/hcloud-csi.yml",
      "helm repo add traefik https://helm.traefik.io/traefik",
      "helm repo update",
      "helm install traefik traefik/traefik"
    ]

    connection {
      type        = "ssh"
      host        = self.ipv4_address
      user        = "root"
      private_key = tls_private_key.global_key.private_key_pem
    }
  }

  labels = merge(local.labels, {
    "Role" : "Leader"
  })

  depends_on = [
    hcloud_network_subnet.sdn_cidr_subnet
  ]

}

resource "ssh_resource" "leader_join_command" {
  host        = hcloud_server.leader[0].ipv4_address
  user        = "root"
  private_key = tls_private_key.global_key.private_key_pem

  commands = [
    "kubeadm token create --print-join-command"
  ]

  depends_on = [
    hcloud_server.leader
  ]
}

resource "ssh_resource" "leader_kubeconfig" {
  host        = hcloud_server.leader[0].ipv4_address
  user        = "root"
  private_key = tls_private_key.global_key.private_key_pem

  commands = [
    "cat /etc/kubernetes/admin.conf"
  ]

  depends_on = [
    hcloud_server.leader
  ]
}