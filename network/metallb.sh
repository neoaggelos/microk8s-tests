#!/bin/bash -x

export ID=${BUILD_NUMBER:-$$}
export CHANNEL="latest/edge"

cleanup() {
  juju destroy-model "${JUJU_MODEL}" --force --yes
}

# Initialize model
if [[ "x$JUJU_MODEL" = "x" ]]; then
  JUJU_MODEL="${JUJU_MODEL:-microk8s-metallb-$ID}"
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

# enable metallb
juju run --machine 0 "sudo microk8s enable metallb:10.64.0.1-10.64.0.10"

# join cluster
juju run --machine 1 "sudo ${JOIN_CMD}"
juju run --machine 2 "sudo ${JOIN_CMD}"

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

# create lb without pool
juju run --machine 0 "sudo microk8s kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: bot
spec:
  ports: [{ port: 80, protocol: TCP, targetPort: 80 }]
  selector:
    app: bot
  type: LoadBalancer
EOF
"

# attempt to reach lb from each node
for x in 0 1 2; do
  echo "testing connectivity from machine $x"
  if ! juju run --machine $x "
    ip=\`sudo microk8s kubectl get svc bot -o jsonpath='{.status.loadBalancer.ingress[0].ip}'\`
    if ! curl \$ip --connect-timeout 5 --silent > /dev/null; then
      echo failed to reach \$ip from machine $x!
      exit 1
    fi
  "; then
    echo "failed to reach lb from machine $x"
  fi
done

juju run --machine 0 "sudo microk8s kubectl delete svc bot"

# create addresspools
juju run --machine 0 "sudo microk8s kubectl apply -f - <<EOF
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: pool1
  namespace: metallb-system
spec:
  addresses:
  - 10.100.100.100/32
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: pool2
  namespace: metallb-system
spec:
  addresses:
  - 10.10.10.10/32
EOF
"

# create lb services
juju run --machine 0 "sudo microk8s kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: bot-pool1
  annotations:
    metallb.universe.tf/address-pool: pool1
spec:
  ports: [{ port: 80, protocol: TCP, targetPort: 80 }]
  selector:
    app: bot
  type: LoadBalancer
---
apiVersion: v1
kind: Service
metadata:
  name: bot-pool2
  annotations:
    metallb.universe.tf/address-pool: pool2
spec:
  ports: [{ port: 80, protocol: TCP, targetPort: 80 }]
  selector:
    app: bot
  type: LoadBalancer
EOF
"

# attempt to reach lb from each node
for x in 0 1 2; do
  echo "testing connectivity from machine $x"
  if ! juju run --machine $x "
    for ip in 10.10.10.10 10.100.100.100; do
      if ! curl \$ip --connect-timeout 5 --silent > /dev/null; then
        echo failed to reach \$ip from machine $x!
        exit 1
      fi
    done
  "; then
    echo "failed to reach some services from machine $x"
  fi
done

# delete old lbs
juju run --machine 0 "sudo microk8s kubectl delete svc bot-pool1 bot-pool2"
