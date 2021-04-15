#!/usr/bin/env bash
# Testes por ÉricoGR
# 20210414
# script demo para testar o istio em um cluster kubernetes KIND (https://kind.sigs.k8s.io/docs/user/quick-start/)

set -e
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# -----------------
# Parametros gerais
# -----------------
ISTIO_VERSION=1.9.2
TARGET_ARCH=x86_64
DEMO_NAMESPACE=istio-demo
KIALI_NAMESPACE=kiali-operator
PROMETHEUS_NAMESPACE=prometheus-operator

# ---------------------------------
# Parametros internos (não alterar)
# ---------------------------------
ISTIO_NAMESPACE=istio-system
ISTIO_BIN=bin/istio-$ISTIO_VERSION/bin/istioctl

# download do istio
if [ ! -f $ISTIO_BIN ]; then
  curl -L https://istio.io/downloadIstio | sh -
  if [ ! -d $DIR/bin ]; then
    mkdir $DIR/bin
  fi

  mv istio-$ISTIO_VERSION bin
fi

# comandos extras comentados para consulta futura
# uninstall: istioctl x uninstall --purge
#            kubectl delete namespace istio-system

# -----------------------
# instalar metrics server
# -----------------------
kubectl -n kube-system apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server --patch "$(cat metrics-server-patch.yaml)"

# -------------------------------
# instalar operator do prometheus
# -------------------------------
kubectl create ns $PROMETHEUS_NAMESPACE --dry-run=client -oyaml|kubectl apply -f -
helm upgrade \
  --install \
  -n $PROMETHEUS_NAMESPACE \
  --repo https://prometheus-community.github.io/helm-charts \
  prometheus-operator \
  kube-prometheus-stack

# --------------------------
# instalar operator do istio
# --------------------------
# instalação
$ISTIO_BIN operator init --operatorNamespace istio-operator

# ---------------------
# configurar o operator
# ---------------------

# criar namespace
kubectl create ns $ISTIO_NAMESPACE --dry-run=client -oyaml | kubectl apply -f -

# instalar com profile demo com istio operator
kubectl apply -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: $ISTIO_NAMESPACE
  name: example-istiocontrolplane
spec:
  profile: demo
EOF

# --------------------------
# configurar a demo do istio
# --------------------------

# configurar o namespace da demo
echo configurar o namespace da demo
kubectl create ns $DEMO_NAMESPACE --dry-run=client -oyaml | kubectl apply -f -
kubectl label --overwrite=true namespace $DEMO_NAMESPACE istio-injection=enabled

# instalar a demo
echo Instalando a demo bookinfo
kubectl apply -n $DEMO_NAMESPACE -f https://raw.githubusercontent.com/istio/istio/release-1.9/samples/bookinfo/platform/kube/bookinfo.yaml

# configurar o ingress gateway da demo
echo Configurar o ingress gateway da demo
kubectl apply -n $DEMO_NAMESPACE -f https://raw.githubusercontent.com/istio/istio/release-1.9/samples/bookinfo/networking/bookinfo-gateway.yaml

# descobrir portas e IP's (configurado para kubernetes kind)
INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
SECURE_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
TCP_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="tcp")].nodePort}')
INGRESS_HOST=$(kubectl get po -l istio=ingressgateway -n istio-system -o jsonpath='{.items[0].status.hostIP}')
GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT

echo Demo disponível em: http://$GATEWAY_URL/productpage

# aplicar regras de destino
kubectl apply -n $DEMO_NAMESPACE -f https://raw.githubusercontent.com/istio/istio/release-1.9/samples/bookinfo/networking/destination-rule-all.yaml

# -----------------------------
# configuração do monitoramento
# -----------------------------

# criar o service monitoring
kubectl -n $ISTIO_NAMESPACE apply -f https://raw.githubusercontent.com/istio/istio/4461a6b2324bceabd6f0ef3896ca1ca338180c45/samples/addons/extras/prometheus-operator.yaml
kubectl -n $ISTIO_NAMESPACE label --overwrite -f https://raw.githubusercontent.com/istio/istio/4461a6b2324bceabd6f0ef3896ca1ca338180c45/samples/addons/extras/prometheus-operator.yaml release=prometheus

# istio multicluster (único prometheus)
# https://istio.io/latest/docs/ops/best-practices/observability/#federation-using-workload-level-aggregated-metrics
# kubectl apply -n $DEMO_NAMESPACE -f optionals/service-monitor-istio-federation.yaml

# https://istio.io/latest/docs/ops/best-practices/observability/#workload-level-aggregation-via-recording-rules
# kubectl apply -n $ISTIO_NAMESPACE -f optionals/prometheus-rule-istio-metrics-aggregation.yaml

# istio multicluster (um prometheus por cluster)
# https://istio.io/latest/docs/ops/configuration/telemetry/monitoring-multicluster-prometheus/#production-prometheus-on-an-in-mesh-cluster

# --------------------------
# instalação padrão do kiali
# --------------------------
# se o script abaixo falhar, tente rodar novamente depois de alguns segundos
kubectl create ns $KIALI_NAMESPACE --dry-run=client -oyaml | kubectl apply -f -
helm upgrade \
    --install \
    --set cr.create=true \
    --set cr.namespace=istio-system \
    --namespace $KIALI_NAMESPACE \
    --repo https://kiali.org/helm-charts \
    kiali-operator \
    kiali-operator
kubectl -n $KIALI_NAMESPACE apply -f kiali.yaml

# executar o kiali: istioctl dashboard kiali
# executar port-forward kiali: kubectl -n kiali-operator port-forward service/kiali 20001
