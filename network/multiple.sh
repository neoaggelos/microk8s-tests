#!/bin/bash

# Configuration
CHANNEL="${CHANNEL:-1.25}"
SERIES="${SERIES:-focal}"
IMAGES="${IMAGES:-$(curl --silent https://raw.githubusercontent.com/canonical/microk8s/master/build-scripts/images.txt | tr '\n' ' ')}"
PROFILE="${PROFILE:-https://raw.githubusercontent.com/ubuntu/microk8s/master/tests/lxc/microk8s.profile}"

#############

ID="${BUILD_NUMBER:-$$}"

cleanup() {
  juju destroy-model "${JUJU_MODEL}" --force --yes
}

# Initialize model
if [[ "x$JUJU_MODEL" = "x" ]]; then
  JUJU_MODEL="${JUJU_MODEL:-microk8s-airgap-registry-$ID}"
  juju add-model "${JUJU_MODEL}"

  if [[ "x$CLEANUP" != "xno" ]]; then
    trap cleanup EXIT
  fi

  juju add-machine -m "${JUJU_MODEL}" --constraints 'mem=8G root-disk=40G'
fi

export JUJU_MODEL="${JUJU_MODEL}"

# # Initialize LXD
# juju run --machine 0 "
#   sudo usermod -a -G lxd ubuntu
#   sudo lxd init --auto
#   sudo lxc network create br0 ipv4.address=10.10.10.1/24 ipv4.nat=true
#   sudo lxc network create br1 ipv4.address=10.10.11.1/24 ipv4.nat=true

#   sudo lxc profile create network
#   sudo lxc profile device add network eth0 name=eth0 type=nic network=br0
#   sudo lxc profile device add network eth1 name=eth1 type=nic network=br1

#   sudo lxc profile create microk8s || true
#   curl --silent '${PROFILE}' | sudo lxc profile edit microk8s
# "

# Launch MicroK8s machines.
for x in 0 1; do
  CONTAINER="k8s-${x}"

  # Launch and configure networking
  juju run --machine 0 -- lxc launch -p default -p microk8s -p network "ubuntu:${SERIES}" "${CONTAINER}"
  juju run --machine 0 -- lxc exec "${CONTAINER}" -- bash -x -c "
    netplan set ethernets.eth1.addresses='[10.10.11.1$x/24]'
    netplan apply
  "

  # Install MicroK8s
  while ! juju run --machine 0 -- lxc exec "${CONTAINER}" -- bash -x -c "snap install microk8s --classic --channel '${CHANNEL}'"; do
    echo "retry microk8s install"
    sleep 2
  done

  juju run --machine 0 -- lxc exec "${CONTAINER}" -- bash -x -c "
    echo '--advertise-address=10.10.11.1$x' >> /var/snap/microk8s/current/args/kube-apiserver
    echo '--node-ip=10.10.11.1$x' >> /var/snap/microk8s/current/args/kubelet
    snap restart microk8s
  "
done

# join cluster
join_cmd="$(
  juju run --machine 0 -- lxc exec k8s-0 -- bash -c "microk8s add-node --token-ttl 10000" \
    | grep "10.10.11.1" \
    | head -1
)"
juju run --machine 0 -- lxc exec k8s-1 -- bash -x -c "${join_cmd}"
