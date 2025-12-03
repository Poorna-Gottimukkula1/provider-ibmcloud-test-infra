#!/bin/bash
set -euo pipefail

### ---------------------------------------------------
### 0. DETECT DYNAMIC CLUSTER NAME & BUILD PATHS
### ---------------------------------------------------

# If KUBECONFIG not defined, default to local kubeconfig
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# Detect current Kubernetes cluster name from kubeconfig
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')

# Sanitize cluster name (remove admin@ prefix if exists)
CLUSTER_NAME=${CLUSTER_NAME##*@}

if [[ -z "$CLUSTER_NAME" ]]; then
  echo "[ERROR] Failed to detect cluster name. Exiting."
  exit 1
fi

echo "[INFO] Detected cluster: $CLUSTER_NAME"

# Base dynamic path based on detected cluster
BASE_PATH="/workspace/test-repo/provider-ibmcloud-test-infra/${CLUSTER_NAME}"

# Ensure directory exists to avoid missing file issues
mkdir -p "$BASE_PATH"

export KUBECONFIG="${BASE_PATH}/kubeconfig"
export INSTANCE_LIST_JSON="${INSTANCE_LIST_JSON:-${BASE_PATH}/instance_list.json}"
export POWERVS_REGION="${POWERVS_REGION:-syd}"
export POWERVS_ZONE="${POWERVS_ZONE:-syd05}"
export POWERVS_CLOUD_INSTANCE_ID="${POWERVS_CLOUD_INSTANCE_ID:-17b50a72-238e-4849-aed0-8c139564b92a}"
export CSI_VERSION="${CSI_VERSION:-v0.10.0}"

echo "[INFO] Updated paths:"
echo "  KUBECONFIG        = $KUBECONFIG"
echo "  INSTANCE_LIST_JSON = $INSTANCE_LIST_JSON"
echo ""

### ---------------------------------------------------
### VERIFY REQUIRED ENV VARS
### ---------------------------------------------------

required_vars=("KUBECONFIG" "POWERVS_REGION" "POWERVS_ZONE" "POWERVS_CLOUD_INSTANCE_ID" "INSTANCE_LIST_JSON")

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "[ERROR] Missing required env var: $var"
    exit 1
  fi
done

kubectl get nodes

### ---------------------------------------------------
### 1. PATCH PROVIDER ID FOR ALL NODES
### ---------------------------------------------------

echo "[INFO] Patching providerID on nodes..."

for row in $(jq -c '.[]' "$INSTANCE_LIST_JSON"); do
    INSTANCE_ID=$(echo "$row" | jq -r '.id')
    NODE_NAME=$(echo "$row" | jq -r '.name')

    PROVIDER_ID="ibmpowervs://$POWERVS_REGION/$POWERVS_ZONE/$POWERVS_CLOUD_INSTANCE_ID/$INSTANCE_ID"

    echo "[INFO] → $NODE_NAME = $PROVIDER_ID"
    kubectl patch node "$NODE_NAME" -p "{\"spec\":{\"providerID\":\"$PROVIDER_ID\"}}"
done

### ---------------------------------------------------
### 2. CREATE SECRET FOR CSI DRIVER
### ---------------------------------------------------

if [[ -z "${TF_VAR_powervs_api_key:-$IBMCLOUD_API_KEY}" ]]; then
  echo "ERROR: No API key in TF_VAR_powervs_api_key or IBMCLOUD_API_KEY"
  exit 1
fi

echo "[INFO] Creating IBM cloud secret"

kubectl create secret generic ibm-secret \
  -n kube-system \
  --from-literal=IBMCLOUD_API_KEY="${TF_VAR_powervs_api_key:-$IBMCLOUD_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

### ---------------------------------------------------
### 3. INSTALL CSI DRIVER
### ---------------------------------------------------

echo "[INFO] Installing CSI driver ($CSI_VERSION)..."

kubectl apply -k "https://github.com/kubernetes-sigs/ibm-powervs-block-csi-driver/deploy/kubernetes/overlays/stable/?ref=$CSI_VERSION"

echo "[INFO] Waiting for controller to be ready..."
kubectl -n kube-system wait --for=condition=available deployment/powervs-csi-controller --timeout=300s

echo "[INFO] Waiting for CSI node pods..."
kubectl -n kube-system wait --for=condition=Ready pod -l app.kubernetes.io/name=ibm-powervs-block-csi-driver --timeout=300s

echo "[INFO] CSI driver status:"
kubectl get deploy,pods -n kube-system -l app.kubernetes.io/name=ibm-powervs-block-csi-driver

### ---------------------------------------------------
### 4. LABEL NODES
### ---------------------------------------------------

echo "[INFO] Applying node labels..."

for row in $(jq -c '.[]' "$INSTANCE_LIST_JSON"); do
    INSTANCE_ID=$(echo "$row" | jq -r '.id')
    NODE_NAME=$(echo "$row" | jq -r '.name')

    kubectl label node "$NODE_NAME" powervs.kubernetes.io/cloud-instance-id="$POWERVS_CLOUD_INSTANCE_ID"
    kubectl label node "$NODE_NAME" powervs.kubernetes.io/pvm-instance-id="$INSTANCE_ID"

    echo "[INFO] Labeled: $NODE_NAME"
done

### ---------------------------------------------------
### 5. RUN CSI E2E TESTS
### ---------------------------------------------------

echo "[INFO] Running CSI e2e tests..."

rm -rf ibm-powervs-block-csi-driver
git clone https://github.com/kubernetes-sigs/ibm-powervs-block-csi-driver.git
cd ibm-powervs-block-csi-driver

make test-e2e

echo "[SUCCESS] PowerVS CSI driver installation & validation complete"
