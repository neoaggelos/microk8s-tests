#!/bin/bash -x

export ID=${BUILD_NUMBER:-$$}
export CHANNEL="latest/edge"

cleanup() {
  juju destroy-model "${JUJU_MODEL}" --force --yes
}

# Initialize model
if [[ "x$JUJU_MODEL" = "x" ]]; then
  JUJU_MODEL="${JUJU_MODEL:-microk8s-kubeovn-$ID}"
  juju add-model "${JUJU_MODEL}"
  juju add-machine -m "${JUJU_MODEL}" -n 3 --constraints 'mem=4G cores=4 root-disk=40G'

  trap cleanup EXIT
fi

export JUJU_MODEL="${JUJU_MODEL}"

# Install MicroK8s
juju run --all "
sudo snap install microk8s --classic --channel $CHANNEL
"

# join cluster
JOIN_CMD="$(juju run --machine 0 "sudo microk8s add-node --token-ttl 10000" | grep "microk8s join" | head -1)"

# enable kube-ovn
juju run --machine 0 "sudo microk8s enable kube-ovn --force"

# wait for kube-ovn to come online
while ! juju run --machine 0 "sudo microk8s.kubectl wait -n kube-system ds/ovs-ovn --for=jsonpath='{.status.numberReady}'=1"
do
  echo 'waiting for ovs-ovn'
  sleep 5
done

while ! juju run --machine 0 "sudo microk8s.kubectl wait -n kube-system ds/kube-ovn-cni --for=jsonpath='{.status.numberReady}'=1"
do
  echo 'waiting for kube-ovn-cni'
  sleep 5
done

juju run --machine 1 "sudo ${JOIN_CMD}"
juju run --machine 2 "sudo ${JOIN_CMD}"

# wait for kube-ovn to come online on cluster
while ! juju run --machine 0 "sudo microk8s.kubectl wait -n kube-system ds/ovs-ovn --for=jsonpath='{.status.numberReady}'=3"
do
  echo 'waiting for ovs-ovn'
  sleep 5
done
while ! juju run --machine 0 "sudo microk8s.kubectl wait -n kube-system ds/kube-ovn-cni --for=jsonpath='{.status.numberReady}'=3"
do
  echo 'waiting for kube-ovn-cni'
  sleep 5
done

# create a deployment spanning all 3 nodes, ensure we can reach all pods
juju run --machine 0 "
sudo microk8s.kubectl create deploy --image cdkbot/microbot:1 --replicas 10 bot
sudo microk8s.kubectl expose deploy bot --port 80
"
while ! juju run --machine 0 "sudo microk8s.kubectl wait deploy/bot --for=jsonpath='{.status.readyReplicas}'=10"
do
  echo 'waiting for deployment'
  sleep 5
done

# attempt to reach all pods from each node
for x in 0 1 2; do
  echo "testing connectivity from machine $x"
  if ! juju run --machine $x "
    for ip in \`sudo microk8s.kubectl get pod -o template='{{ range .items }}{{ .status.podIP }}{{ \"\n\" }}{{ end }}'\`; do
      if ! curl \$ip --connect-timeout 5 --silent > /dev/null; then
        echo failed to reach \$ip from machine $x!
        exit 1
      fi
    done
  "; then
    echo "failed to reach some pods from machine $x"
  fi
done
