#!/bin/bash -e

redeploy() {
  kubectl delete -f "$1" &> /dev/null || true
  kubectl apply -f "$1"
}

create_waggle_config() {
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: waggle-config
data:
  WAGGLE_NODE_ID: "$WAGGLE_NODE_ID"
  WAGGLE_NODE_VSN: "$WAGGLE_NODE_VSN"
  WAGGLE_BEEHIVE_HOST: "$WAGGLE_BEEHIVE_HOST"
  WAGGLE_BEEHIVE_RABBITMQ_HOST: "$WAGGLE_BEEHIVE_RABBITMQ_HOST"
  WAGGLE_BEEHIVE_RABBITMQ_PORT: "$WAGGLE_BEEHIVE_RABBITMQ_PORT"
  WAGGLE_BEEHIVE_UPLOAD_HOST: "$WAGGLE_BEEHIVE_UPLOAD_HOST"
  WAGGLE_BEEHIVE_UPLOAD_PORT: "$WAGGLE_BEEHIVE_UPLOAD_PORT"
EOF
}

file_must_exist() {
  if [ ! -s "$1" ] ; then
    echo "file $1 is missing or empty"
    exit 1
  fi
}

# TODO clean up defining this initial config
if [ "${1}_" != "skip-env_" ] ; then
  file_must_exist /etc/waggle/node-id
  # TODO(sean) document upper / lower conventions and where they're used
  export WAGGLE_NODE_ID=$(awk '{print tolower($0)}' /etc/waggle/node-id)
  echo "WAGGLE_NODE_ID=$WAGGLE_NODE_ID"

  file_must_exist /etc/waggle/vsn
  export WAGGLE_NODE_VSN=$(awk '{print toupper($0)}' /etc/waggle/vsn)
  echo "WAGGLE_NODE_VSN=$WAGGLE_NODE_VSN"

  export WAGGLE_BEEHIVE_HOST=${WAGGLE_BEEHIVE_HOST:-beehive1.mcs.anl.gov}
  echo "WAGGLE_BEEHIVE_HOST=$WAGGLE_BEEHIVE_HOST"

  # TODO clean this up! for now, we just assume that "beehive" and rabbitmq are on the same host
  export WAGGLE_BEEHIVE_RABBITMQ_HOST=${WAGGLE_BEEHIVE_RABBITMQ_HOST:-$WAGGLE_BEEHIVE_HOST}
  export WAGGLE_BEEHIVE_RABBITMQ_PORT=${WAGGLE_BEEHIVE_RABBITMQ_PORT:-15671}
  echo "WAGGLE_BEEHIVE_RABBITMQ $WAGGLE_BEEHIVE_RABBITMQ_HOST:$WAGGLE_BEEHIVE_RABBITMQ_PORT"

  export WAGGLE_BEEHIVE_UPLOAD_HOST=${WAGGLE_BEEHIVE_UPLOAD_HOST:-$WAGGLE_BEEHIVE_HOST}
  export WAGGLE_BEEHIVE_UPLOAD_PORT=${WAGGLE_BEEHIVE_UPLOAD_PORT:-20022}
  echo "WAGGLE_BEEHIVE_UPLOAD $WAGGLE_BEEHIVE_UPLOAD_HOST:$WAGGLE_BEEHIVE_UPLOAD_PORT"

  echo "creating waggle config"
  create_waggle_config
fi

echo "creating default waggle-data-config, if doesn't already exist."
kubectl create configmap waggle-data-config --from-file=data-config.json=data-config.json || true

echo "deploying default resource limits"
kubectl apply -f wes-default-limits.yaml

echo "deploying priority classes"
kubectl apply -f wes-priority-classes.yaml

echo "deploying network policies"
kubectl apply -f wes-plugin-network-policy.yaml

echo "updating node labels"
for node in $(kubectl get node | awk '/ws-nxcore/ {print $1}'); do
    kubectl label nodes "$node" resource.bme280=true || true
done
for node in $(kubectl get node | awk '/ws-rpi/ {print $1}'); do
    kubectl label nodes "$node" resource.microphone=true || true
    kubectl label nodes "$node" resource.raingauge=true || true
    kubectl label nodes "$node" resource.bme680=true || true
done

echo "deploying prometheus node exporter"
kubectl apply -f node-exporter.yaml

echo "deploying rabbitmq server"
kubectl apply -f wes-rabbitmq.yaml

echo "generating rabbitmq service account credentials"
./update-rabbitmq-auth.sh wes-rabbitmq-service-account-secret service '.*' '.*' '.*'
./update-rabbitmq-auth.sh wes-rabbitmq-shovel-account-secret shovel '^$' '^$' '^to-beehive|to-beekeeper$'

echo "deploying rest of node stack"
# NOTE we redeploy these to make sure they are restarted with any updated configs / secrets
redeploy wes-upload-agent.yaml
redeploy wes-audio-server.yaml
redeploy wes-data-sharing-service.yaml
redeploy wes-metrics-agent.yaml

echo "enabling data shovel"
./shovelctl.sh enable
