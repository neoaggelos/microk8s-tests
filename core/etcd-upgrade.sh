#!/bin/bash -xe

export ID=${BUILD_NUMBER:-$$}
export CHANNELS="${CHANNELS:-1.21 1.22 1.23 1.24 1.25 latest/edge/etcd35}"

cleanup() {
  juju destroy-model "${JUJU_MODEL}" --force --yes
}

# Initialize model
if [[ "x$JUJU_MODEL" = "x" ]]; then
  JUJU_MODEL="${JUJU_MODEL:-microk8s-etcd-upgrade-$ID}"
  juju add-model "${JUJU_MODEL}"
  juju add-machine -m "${JUJU_MODEL}" --constraints 'mem=4G cores=4 root-disk=40G'

  if [[ "x$CLEANUP" != "xno" ]]; then
    trap cleanup EXIT
  fi
fi

export JUJU_MODEL="${JUJU_MODEL}"

# Install MicroK8s and switch to etcd.
# Set timeout to 20 minutes since disabling HA takes a long time due to a bug.
juju run --machine 0 --timeout 20m "
sudo snap install microk8s --classic --channel ${CHANNELS%% *}
sudo microk8s disable ha-cluster --force
"

# Upgrade MicroK8s versions and continuously check that etcd is up
C="/var/snap/microk8s/current/certs"
for channel in ${CHANNELS}; do
  juju run --machine 0 "sudo snap refresh microk8s --channel '${channel}'"

  while ! juju run --machine 0 "sudo ETCDCTL_API=3 /snap/microk8s/current/etcdctl --cacert $C/ca.crt --cert $C/server.crt --key $C/server.key endpoint health --endpoints https://127.0.0.1:12379"; do
    echo "waiting for etcd to come up"
    sleep 2
  done
  while ! juju run --machine 0 "sudo ETCDCTL_API=3 /snap/microk8s/current/etcdctl --cacert $C/ca.crt --cert $C/server.crt --key $C/server.key endpoint status --endpoints https://127.0.0.1:12379"; do
    echo "waiting for etcd to come up"
    sleep 2
  done
done

# Sanity check whether Kubernetes is still working by creating a deployment
juju run --machine 0 "sudo microk8s kubectl create deploy --image nginx --replicas 3 nginx"
while ! juju run --machine 0 "sudo microk8s kubectl wait deploy/nginx --for=jsonpath='{.status.readyReplicas}'=3"; do
  echo waiting for deployment to come up
  sleep 3
done
