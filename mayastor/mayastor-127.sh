#!/bin/bash -x

export ID=${BUILD_NUMBER:-$$}
export CHANNEL="1.27"

cleanup() {
  juju destroy-model "${JUJU_MODEL}" --force --yes
}

# Initialize model
if [[ "x$JUJU_MODEL" = "x" ]]; then
  JUJU_MODEL="${JUJU_MODEL:-microk8s-mayastor-$ID}"
  juju add-model "${JUJU_MODEL}"
  juju add-machine -m "${JUJU_MODEL}" -n 3 --constraints 'mem=4G cores=4 root-disk=40G'

  if [[ "x$CLEANUP" != "xno" ]]; then
    trap cleanup EXIT
  fi
fi

export JUJU_MODEL="${JUJU_MODEL}"

# Kernel and HugePages
juju run --all -- '
sudo apt-get update
sudo apt-get install linux-modules-extra-$(uname -r) -y
sudo modprobe nvme-tcp
sudo sysctl vm.nr_hugepages=1024
'

# Install MicroK8s
juju run --all "
sudo snap install microk8s --classic --channel $CHANNEL
"

# join cluster
JOIN_CMD="$(juju run --machine 0 "sudo microk8s add-node --token-ttl 10000" | grep "microk8s join" | head -1)"
juju run --machine 1 "sudo ${JOIN_CMD}"
juju run --machine 2 "sudo ${JOIN_CMD}"

# enable mayastor
juju run --machine 0 "
# remove after merging rbac fix
sudo microk8s addons repo add core --force --reference MK-1344/mayastor-rbac https://github.com/canonical/microk8s-core-addons

sudo microk8s enable rbac
sudo microk8s enable mayastor
"

# wait mayastor to come up
while ! juju run --machine 0 "sudo microk8s.kubectl wait -n mayastor ds/mayastor-io-engine --for=jsonpath='{.status.numberReady}'=3"
do
  echo 'waiting for mayastor'
  sleep 5
done

# wait for mayastor pools to come up
while ! juju run --machine 0 "sudo microk8s.kubectl get -n mayastor diskpool | grep Online | wc -l | grep 3"
do
  echo 'waiting for 3 mayastor pools to come online'
  sleep 5
done

# deploy example pods with 1, 2 and 3 replicas
juju run --machine 0 'sudo microk8s.kubectl apply -f - <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: pvc }
spec: { storageClassName: mayastor, accessModes: [ReadWriteOnce], resources: { requests: { storage: 1Gi } } }
---
apiVersion: v1
kind: Pod
metadata: { name: nginx }
spec:
  volumes: [{ name: pvc, persistentVolumeClaim: { claimName: pvc } }]
  containers: [{ name: nginx, image: nginx, volumeMounts: [{ name: pvc, mountPath: /usr/share/nginx/html }] }]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: pvc-3 }
spec: { storageClassName: mayastor-3, accessModes: [ReadWriteOnce], resources: { requests: { storage: 1Gi } } }
---
apiVersion: v1
kind: Pod
metadata: { name: nginx-3 }
spec:
  volumes: [{ name: pvc, persistentVolumeClaim: { claimName: pvc-3 } }]
  containers: [{ name: nginx, image: nginx, volumeMounts: [{ name: pvc, mountPath: /usr/share/nginx/html }] }]
EOF
'

# wait for volumes and pvcs
while ! juju run --machine 0 "sudo microk8s.kubectl wait --for=condition=ready pod/nginx pod/nginx-3"
do
  echo 'waiting for pods to come online'
  sleep 5
done
