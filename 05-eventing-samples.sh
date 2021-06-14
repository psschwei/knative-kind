#!/usr/bin/env bash

set -eo pipefail
set -u

NAMESPACE=${NAMESPACE:-default}
BROKER_NAME=${BROKER_NAME:-example-broker}

#Installing Domain Mapping to expose broker externally
KNATIVE_VERSION=${KNATIVE_VERSION:-0.23.0}

n=0
set +e
until [ $n -ge 2 ]; do
  kubectl apply -f https://github.com/knative/serving/releases/download/v$KNATIVE_VERSION/serving-domainmapping-crds.yaml > /dev/null && break
  n=$[$n+1]
  sleep 5
done
set -e
kubectl wait --for=condition=Established --all crd > /dev/null

n=0
set +e
until [ $n -ge 2 ]; do
  kubectl apply -f https://github.com/knative/serving/releases/download/v$KNATIVE_VERSION/serving-domainmapping.yaml > /dev/null && break
  n=$[$n+1]
  sleep 5
done
set -e
kubectl wait pod --timeout=-1s --for=condition=Ready -l '!job-name' -n knative-serving > /dev/null


kubectl -n $NAMESPACE apply -f - << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-display
spec:
  replicas: 1
  selector:
    matchLabels: &labels
      app: hello-display
  template:
    metadata:
      labels: *labels
    spec:
      containers:
        - name: event-display
          image: gcr.io/knative-releases/knative.dev/eventing-contrib/cmd/event_display

---

kind: Service
apiVersion: v1
metadata:
  name: hello-display
spec:
  selector:
    app: hello-display
  ports:
  - protocol: TCP
    port: 80
    targetPort: 8080
EOF

kubectl  -n $NAMESPACE wait pod --timeout=-1s  -l app=hello-display --for=condition=Ready > /dev/null

kubectl -n $NAMESPACE apply -f - << EOF
apiVersion: eventing.knative.dev/v1
kind: Trigger
metadata:
  name: hello-display
spec:
  broker: $BROKER_NAME
  filter:
    attributes:
      type: greeting
  subscriber:
    ref:
      apiVersion: v1
      kind: Service
      name: hello-display
EOF

# Exposing broker externally using Knative Domain Mapping
kubectl -n knative-eventing apply -f - << EOF
apiVersion: serving.knative.dev/v1alpha1
kind: DomainMapping
metadata:
  name: broker-ingress.knative-eventing.127.0.0.1.nip.io
spec:
  ref:
    name: broker-ingress
    kind: Service
    apiVersion: v1
EOF
kubectl wait -n knative-eventing king broker-ingress --timeout=-1s --for=condition=Ready > /dev/null

MSG=""
echo 'Sending Cloud Event to event broker'
until [[ $MSG == *"Hello Knative"* ]]; do
  curl -s -v  "http://broker-ingress.knative-eventing.127.0.0.1.nip.io/$NAMESPACE/$BROKER_NAME" \
  -X POST \
  -H "Ce-Id: say-hello" \
  -H "Ce-Specversion: 1.0" \
  -H "Ce-Type: greeting" \
  -H "Ce-Source: not-sendoff" \
  -H "Content-Type: application/json" \
  -d '{"msg":"Hello Knative!"}' > /dev/null
  sleep 5
  MSG=$(kubectl -n $NAMESPACE logs -l app=hello-display --tail=100 | grep msg || true)
done
echo "Cloud Event Delivered $MSG" | head -1

