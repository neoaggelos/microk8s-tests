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

# Initialize LXD
juju run --machine 0 "
  sudo usermod -a -G lxd ubuntu
  sudo lxd init --auto
  sudo lxc network set lxdbr0 ipv4.address=10.10.10.1/24 ipv6.address=none
  sudo lxc profile create microk8s || true
  curl --silent '${PROFILE}' | sudo lxc profile edit microk8s

  # configure dns
  sudo resolvectl dns lxdbr0 10.10.10.1
  sudo resolvectl domain lxdbr0 lxd

  # generate hosts.toml file
  echo \"
    server = 'http://10.10.10.1:32000'

    [host.'http://10.10.10.1:32000']
    capabilities = ['pull', 'resolve']
  \" > hosts.toml
"

# Download snaps
juju run --machine 0 "
  snap download core18 --basename core18
  snap download microk8s --basename microk8s --channel '${CHANNEL}'
"

# Install registry
juju run --machine 0 "
  sudo snap ack ./core18.assert
  sudo snap ack ./microk8s.assert
  sudo snap install ./core18.snap
  sudo snap install ./microk8s.snap --classic

  sudo microk8s enable registry
"

juju run --machine 0 "
  while ! curl --silent 127.0.0.1:32000/v2/_catalog; do
    echo waiting for registry
    sleep 2
  done
"

# Load images
for image in ${IMAGES}; do
  mirror="$(echo "${image}" | sed 's,\(docker.io\|k8s.gcr.io\|quay.io\),10.10.10.1:32000,g')"
  juju run --machine 0 "
    sudo microk8s ctr image pull '${image}'
    sudo microk8s ctr image convert '${image}' '${mirror}'
    sudo microk8s ctr image push '${mirror}' --plain-http
  "
done

# Launch 3 MicroK8s machines.
for x in 0 1 2; do
  CONTAINER="k8s-${x}"

  # Launch and configure networking
  juju run --machine 0 -- lxc launch -p default -p microk8s "ubuntu:${SERIES}" "${CONTAINER}"
  juju run --machine 0 -- lxc exec "${CONTAINER}" -- bash -x -c "
    netplan set ethernets.eth0.dhcp4-overrides.use-routes=false
    netplan set ethernets.eth0.routes='[{ to: 0.0.0.0/0, scope: link }]'
    netplan apply
  "
  if juju run --machine 0 -- lxc exec "${CONTAINER}" -- bash -c "ping -c1 1.1.1.1"; then
    echo "machine ${x} has internet access when it should not"
    exit 1
  fi

  # Install MicroK8s
  juju run --machine 0 "
    lxc file push microk8s.snap '${CONTAINER}/opt/'
    lxc file push microk8s.assert '${CONTAINER}/opt/'
    lxc file push core18.snap '${CONTAINER}/opt/'
    lxc file push core18.assert '${CONTAINER}/opt/'
  "
  juju run --machine 0 -- lxc exec "${CONTAINER}" -- bash -x -c '
    snap ack /opt/core18.assert
    snap ack /opt/microk8s.assert
    snap install /opt/core18.snap
    snap install /opt/microk8s.snap --classic
  '

  # Configure registry mirrors
  juju run --machine 0 "
    lxc file push -p hosts.toml '${CONTAINER}/var/snap/microk8s/current/args/certs.d/docker.io/hosts.toml'
    lxc file push -p hosts.toml '${CONTAINER}/var/snap/microk8s/current/args/certs.d/k8s.gcr.io/hosts.toml'
    lxc file push -p hosts.toml '${CONTAINER}/var/snap/microk8s/current/args/certs.d/quay.io/hosts.toml'
  "
done

# Form cluster
join_cmd="$(
  juju run --machine 0 -- lxc exec k8s-0 -- bash -c "microk8s add-node --token-ttl 10000" \
    | grep "microk8s join" \
    | head -1
)"
juju run --machine 0 -- lxc exec k8s-1 -- bash -x -c "${join_cmd}"
juju run --machine 0 -- lxc exec k8s-2 -- bash -x -c "${join_cmd} --worker"

# Install addons
juju run --machine 0 -- lxc exec k8s-0 -- bash -x -c "microk8s enable dns ingress hostpath-storage"

# Wait for addons to become ready
juju run --machine 0 -- lxc shell k8s-0 -- bash -x -c "
  while ! microk8s kubectl wait -n kube-system ds/calico-node --for=jsonpath='{.status.numberReady}'=3; do
    echo waiting for calico
    sleep 3
  done
"
juju run --machine 0 -- lxc shell k8s-0 -- bash -x -c "
  while ! microk8s kubectl wait -n kube-system deploy/hostpath-provisioner --for=jsonpath='{.status.readyReplicas}'=1; do
    echo waiting for hostpath provisioner
    sleep 3
  done
"
juju run --machine 0 -- lxc shell k8s-0 -- bash -x -c "
  while ! microk8s kubectl wait -n kube-system deploy/coredns --for=jsonpath='{.status.readyReplicas}'=1; do
    echo waiting for coredns
    sleep 3
  done
"
