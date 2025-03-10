#!/bin/bash

# Licensed to the LF AI & Data foundation under one
# or more contributor license agreements. See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership. The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License. You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Exit immediately for non zero status
# set -e

# Print commands
set -x


MILVUS_HELM_REPO="https://github.com/milvus-io/milvus-helm.git"
MILVUS_HELM_RELEASE_NAME="${MILVUS_HELM_RELEASE_NAME:-milvus-testing}"
MILVUS_CLUSTER_ENABLED="${MILVUS_CLUSTER_ENABLED:-false}"
MILVUS_IMAGE_REPO="${MILVUS_IMAGE_REPO:-milvusdb/milvus}"
MILVUS_IMAGE_TAG="${MILVUS_IMAGE_TAG:-latest}"
MILVUS_HELM_NAMESPACE="${MILVUS_HELM_NAMESPACE:-default}"
# Increase timeout from 500 to 800 because pulsar has one more node now
MILVUS_INSTALL_TIMEOUT="${MILVUS_INSTALL_TIMEOUT:-800s}"

# Delete any previous Milvus cluster
echo "Deleting previous Milvus cluster with name=${MILVUS_HELM_RELEASE_NAME}"
if ! (helm uninstall -n "${MILVUS_HELM_NAMESPACE}" "${MILVUS_HELM_RELEASE_NAME}" > /dev/null 2>&1); then
  echo "No existing Milvus cluster with name ${MILVUS_HELM_RELEASE_NAME}. Continue..."
else
  MILVUS_LABELS1="app.kubernetes.io/instance=${MILVUS_HELM_RELEASE_NAME}"
  MILVUS_LABELS2="release=${MILVUS_HELM_RELEASE_NAME}"
  kubectl delete pvc -n "${MILVUS_HELM_NAMESPACE}" $(kubectl get pvc -n "${MILVUS_HELM_NAMESPACE}" -l "${MILVUS_LABELS1}" -o jsonpath='{range.items[*]}{.metadata.name} ') || true
  kubectl delete pvc -n "${MILVUS_HELM_NAMESPACE}" $(kubectl get pvc -n "${MILVUS_HELM_NAMESPACE}" -l "${MILVUS_LABELS2}" -o jsonpath='{range.items[*]}{.metadata.name} ') || true
fi

if [[ "${TEST_ENV}" == "kind-metallb" ]]; then
  MILVUS_SERVICE_TYPE="${MILVUS_SERVICE_TYPE:-LoadBalancer}"
else
  MILVUS_SERVICE_TYPE="${MILVUS_SERVICE_TYPE:-ClusterIP}"
fi

if [[ -n "${DISABLE_KIND:-}" ]]; then
  # Use cluster IP to deploy milvus when kinD cluster is removed
  MILVUS_SERVICE_TYPE="ClusterIP"
fi

# Get Milvus Chart from git
if [[ ! -d "${MILVUS_HELM_CHART_PATH:-}" ]]; then
  TMP_DIR="$(mktemp -d)"
  git clone --depth=1 -b "${MILVUS_HELM_BRANCH:-master}" "${MILVUS_HELM_REPO}" "${TMP_DIR}"
  MILVUS_HELM_CHART_PATH="${TMP_DIR}/charts/milvus"
fi

# Create namespace when it does not exist
kubectl create namespace "${MILVUS_HELM_NAMESPACE}" > /dev/null 2>&1 || true

echo "[debug]  cluster type is ${MILVUS_SERVICE_TYPE}"
if [[ "${MILVUS_CLUSTER_ENABLED}" == "true" ]]; then
  helm install --wait --timeout "${MILVUS_INSTALL_TIMEOUT}" \
                               --set image.all.repository="${MILVUS_IMAGE_REPO}" \
                               --set image.all.tag="${MILVUS_IMAGE_TAG}" \
                               --set image.all.pullPolicy="${MILVUS_PULL_POLICY:-Always}" \
                               --set cluster.enabled="${MILVUS_CLUSTER_ENABLED}" \
                               --set service.type="${MILVUS_SERVICE_TYPE}" \
                               --set pulsar.broker.replicaCount=2 \
                               --set pulsar.broker.podMonitor.enabled=true \
                               --set pulsar.proxy.podMonitor.enabled=true \
                               --namespace "${MILVUS_HELM_NAMESPACE}" \
                               "${MILVUS_HELM_RELEASE_NAME}" \
                               ${@:-} "${MILVUS_HELM_CHART_PATH}"
else
  helm install --wait --timeout "${MILVUS_INSTALL_TIMEOUT}" \
                               --set image.all.repository="${MILVUS_IMAGE_REPO}" \
                               --set image.all.tag="${MILVUS_IMAGE_TAG}" \
                               --set image.all.pullPolicy="${MILVUS_PULL_POLICY:-Always}" \
                               --set cluster.enabled="${MILVUS_CLUSTER_ENABLED}" \
                               --set pulsar.enabled=false \
                               --set minio.mode=standalone \
                               --set etcd.replicaCount=1 \
                               --set service.type="${MILVUS_SERVICE_TYPE}" \
                               --namespace "${MILVUS_HELM_NAMESPACE}" \
                               "${MILVUS_HELM_RELEASE_NAME}" \
                               ${@:-} "${MILVUS_HELM_CHART_PATH}"
fi

exitcode=$?
# List pod list & pvc list before exit after helm install
kubectl get pods -n ${MILVUS_HELM_NAMESPACE} -o wide | grep "${MILVUS_HELM_RELEASE_NAME}-"
kubectl get pvc -n ${MILVUS_HELM_NAMESPACE} |  grep "${MILVUS_HELM_RELEASE_NAME}-" | awk '{$3=null;print $0}'
exit ${exitcode}
