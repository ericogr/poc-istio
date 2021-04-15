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

create_namespace() {
  PARAM_NAMESPACE=$1
  echo '->'Criando namespace $PARAM_NAMESPACE
  kubectl create ns $PARAM_NAMESPACE --dry-run=client -oyaml|kubectl apply -f -
}

wait_rollout() {
  PARAM_NAMESPACE=$1
  PARAM_DEPLOYMENT=$2
  PARAM_RETRIES=$3
  echo "->Aguarda rollout do $PARAM_NAMESPACE/$PARAM_DEPLOYMENT - $PARAM_RETRIES tentativas"

  for i in $(seq $PARAM_RETRIES); do
    err=0
    kubectl rollout status deployment -n $PARAM_NAMESPACE $PARAM_DEPLOYMENT || err=$?

    if [ $err -eq 0 ]; then
      echo "->Istiod OK"
      break
    else
      echo "->Erro, tentando novamente $i de $PARAM_RETRIES"
      sleep 5
    fi
  done
}

# download do istio
if [ ! -f $ISTIO_BIN ]; then
  echo '->'Download do Istio
  curl -L https://istio.io/downloadIstio | sh -
  if [ ! -d $DIR/bin ]; then
    echo '->'Criando diretório de destino do istioctl
    mkdir $DIR/bin
  fi

  echo '->'Movendo o istioctl para sua pasta bin
  mv istio-$ISTIO_VERSION bin
fi

# comandos extras comentados para consulta futura
# uninstall: istioctl x uninstall --purge
#            kubectl delete namespace istio-system

# -----------------------
# instalar metrics server
# -----------------------
echo '->'Instalando o metrics server
kubectl -n kube-system apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server --patch "$(cat metrics-server-patch.yaml)"

# -------------------------------
# instalar operator do prometheus
# -------------------------------
echo '->'Instalando o Prometheus operator
create_namespace $PROMETHEUS_NAMESPACE
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
echo '->'Instalando o Istio operator
$ISTIO_BIN operator init --operatorNamespace istio-operator

# ---------------------
# configurar o operator
# ---------------------

# criar namespace
create_namespace $ISTIO_NAMESPACE

# instalar com profile demo com istio operator
echo '->'Configurar o Istio usando o operator com perfil demo
kubectl apply -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: $ISTIO_NAMESPACE
  name: example-istiocontrolplane
spec:
  profile: demo
EOF

# aguardar rollout do operator
wait_rollout $ISTIO_NAMESPACE istiod 5

# --------------------------
# configurar a demo do istio
# --------------------------

# configurar o namespace da demo
create_namespace $DEMO_NAMESPACE
echo '->'Habilitar o namespace da demonstração para o Istio
kubectl label --overwrite=true namespace $DEMO_NAMESPACE istio-injection=enabled

# instalar a demo
echo '->' Instalando a demo bookinfo
kubectl apply -n $DEMO_NAMESPACE -f https://raw.githubusercontent.com/istio/istio/release-1.9/samples/bookinfo/platform/kube/bookinfo.yaml

# configurar o ingress gateway da demo
echo '->' Configurar o ingress gateway da demo
kubectl apply -n $DEMO_NAMESPACE -f https://raw.githubusercontent.com/istio/istio/release-1.9/samples/bookinfo/networking/bookinfo-gateway.yaml

# descobrir portas e IP's (configurado para kubernetes kind)
INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
SECURE_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
TCP_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="tcp")].nodePort}')
INGRESS_HOST=$(kubectl get po -l istio=ingressgateway -n istio-system -o jsonpath='{.items[0].status.hostIP}')
GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT

echo '->' Demo disponível em: http://$GATEWAY_URL/productpage

# aplicar regras de destino adicionais (teste)
#echo '->'Aplicar regras adicionais na demo do Istio
#kubectl apply -n $DEMO_NAMESPACE -f https://raw.githubusercontent.com/istio/istio/release-1.9/samples/bookinfo/networking/destination-rule-all.yaml

# -----------------------------
# configuração do monitoramento
# -----------------------------

# criar o service monitoring
echo '->'Configurar o monitoramento do Prometheus para o Istio
kubectl -n $ISTIO_NAMESPACE apply -f https://raw.githubusercontent.com/istio/istio/4461a6b2324bceabd6f0ef3896ca1ca338180c45/samples/addons/extras/prometheus-operator.yaml
kubectl -n $ISTIO_NAMESPACE label --overwrite -f https://raw.githubusercontent.com/istio/istio/4461a6b2324bceabd6f0ef3896ca1ca338180c45/samples/addons/extras/prometheus-operator.yaml release=prometheus-operator

# este script é o completo, para todas as métricas. o basico no script deve ser suficiente
# kubectl -n $ISTIO_NAMESPACE apply -f optionals/service-monitor-istio.yaml

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
create_namespace $KIALI_NAMESPACE
echo '->'Instalação do Kiali
helm upgrade \
    --install \
    --set cr.create=true \
    --set cr.namespace=$KIALI_NAMESPACE \
    --namespace $KIALI_NAMESPACE \
    --repo https://kiali.org/helm-charts \
    kiali-operator \
    kiali-operator
echo '->'Configuração do Kiali com o operator
kubectl -n $KIALI_NAMESPACE apply -f kiali.yaml

# executar o kiali: istioctl dashboard kiali
# executar port-forward kiali: kubectl -n kiali-operator port-forward service/kiali 20001
