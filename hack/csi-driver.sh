#!/bin/bash
set -euo pipefail

### ---------------------------------------------------
### 0. BASIC CONFIG
### ---------------------------------------------------

export KUBECONFIG="${KUBECONFIG:-/workspace/test-repo/provider-ibmcloud-test-infra/test-k8s-vm-new/kubeconfig}"
export POWERVS_REGION="${POWERVS_REGION:-syd}"
export POWERVS_ZONE="${POWERVS_ZONE:-syd05}"
export POWERVS_CLOUD_INSTANCE_ID="${POWERVS_CLOUD_INSTANCE_ID:-17b50a72-238e-4849-aed0-8c139564b92a}"
#export INSTANCE_LIST_JSON="${INSTANCE_LIST_JSON:-/workspace/test-repo/provider-ibmcloud-test-infra/test-k8s-vm-new/instance_list.json}"
export CSI_VERSION="${CSI_VERSION:-v0.10.0}"


# -------------------------
# 1. Check required environment variables
# -------------------------
required_vars=("KUBECONFIG" "POWERVS_REGION" "POWERVS_ZONE" "POWERVS_CLOUD_INSTANCE_ID" "INSTANCE_LIST_JSON")

for var in "${required_vars[@]}"; do
  if [[ -z "${!var}" ]]; then
    echo "[ERROR] Required environment variable '$var' is not set. Exiting."
    exit 1
  fi
done

echo "[INFO] Using KUBECONFIG = $KUBECONFIG"
kubectl get nodes

### ---------------------------------------------------
### 2. PATCH PROVIDER ID FOR ALL NODES
### ---------------------------------------------------

echo "[INFO] Starting providerID patching..."

for row in $(jq -c '.[]' "$INSTANCE_LIST_JSON"); do
    INSTANCE_ID=$(echo "$row" | jq -r '.id')
    NODE_NAME=$(echo "$row" | jq -r '.name')

    PROVIDER_ID="ibmpowervs://$POWERVS_REGION/$POWERVS_ZONE/$POWERVS_CLOUD_INSTANCE_ID/$INSTANCE_ID"

    echo "[INFO] Patching providerID on node: $NODE_NAME"
    echo "$PROVIDER_ID"

    kubectl patch node "$NODE_NAME" -p "{\"spec\":{\"providerID\":\"$PROVIDER_ID\"}}"
done

### ---------------------------------------------------
### 3. CREATE & APPLY CSI SECRET
### ---------------------------------------------------

if [[ -z "${TF_VAR_powervs_api_key:-$IBMCLOUD_API_KEY}" ]]; then
  echo "Error: No API key available in TF_VAR_powervs_api_key or IBMCLOUD_API_KEY"
  exit 1
fi

echo "[INFO] Creating ibm-secret with IBMCLOUD_API_KEY key"

kubectl create secret generic ibm-secret \
  -n kube-system \
  --from-literal=IBMCLOUD_API_KEY="${TF_VAR_powervs_api_key:-$IBMCLOUD_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

# -------------------------
# 4. Install CSI driver
# -------------------------
echo "[INFO] Installing PowerVS CSI driver version $CSI_VERSION..."
kubectl apply -k "https://github.com/kubernetes-sigs/ibm-powervs-block-csi-driver/deploy/kubernetes/overlays/stable/?ref=$CSI_VERSION"

# -------------------------
# 5. Wait for controller deployment
# -------------------------
echo "[INFO] Waiting for powervs-csi-controller deployment to become available..."
if ! kubectl -n kube-system wait --for=condition=available deployment/powervs-csi-controller --timeout=300s; then
    echo "[ERROR] CSI controller deployment not ready. Exiting."
    kubectl -n kube-system get deploy powervs-csi-controller
    exit 1
fi

# -------------------------
# 6. Wait for node pods
# -------------------------
echo "[INFO] Waiting for CSI node pods to become ready..."
if ! kubectl -n kube-system wait --for=condition=Ready pod -l app.kubernetes.io/name=ibm-powervs-block-csi-driver --timeout=300s; then
    echo "[ERROR] CSI node pods not ready. Exiting."
    kubectl -n kube-system get pods -l app.kubernetes.io/name=ibm-powervs-block-csi-driver
    exit 1
fi

# -------------------------
# 7. Verify installation
# -------------------------
echo "[INFO] CSI driver installed successfully. Current deployments and pods:"
kubectl get deploy -n kube-system -l app.kubernetes.io/name=ibm-powervs-block-csi-driver
kubectl get pods -n kube-system -l app.kubernetes.io/name=ibm-powervs-block-csi-driver

echo "[INFO] PowerVS CSI driver installation complete."

### ---------------------------------------------------
### 8. LABEL NODES (AUTO)
### ---------------------------------------------------

echo "[INFO] Applying node labels..."

for row in $(jq -c '.[]' "$INSTANCE_LIST_JSON"); do
    INSTANCE_ID=$(echo "$row" | jq -r '.id')
    NODE_NAME=$(echo "$row" | jq -r '.name')

    kubectl label node "$NODE_NAME" \
        powervs.kubernetes.io/cloud-instance-id="$POWERVS_CLOUD_INSTANCE_ID"

    kubectl label node "$NODE_NAME" \
        powervs.kubernetes.io/pvm-instance-id="$INSTANCE_ID"

    echo "[INFO] Labeled $NODE_NAME"
done

### ---------------------------------------------------
### 9. RUN CSI E2E TESTS
### ---------------------------------------------------

echo "[INFO] Cloning CSI repo..."
rm -rf ibm-powervs-block-csi-driver
git clone https://github.com/kubernetes-sigs/ibm-powervs-block-csi-driver.git
cd ibm-powervs-block-csi-driver

echo "[INFO] Ensuring ginkgo exists..."

# Ensure GOPATH exists in prow/golang environment
export GOPATH="${GOPATH:-$(go env GOPATH || echo /root/go)}"
export PATH="$PATH:$GOPATH/bin"

if ! command -v ginkgo >/dev/null; then
  echo "[WARN] ginkgo not found. Installing..."
  go install github.com/onsi/ginkgo/v2/ginkgo@latest
fi

which ginkgo || { echo "[ERROR] ginkgo installation failed"; exit 1; }

rm -f *.xml
echo "[INFO] Running official CSI E2E tests with ginkgo"
ginkgo -v --junit-report=csi_report.xml ./tests/e2e

ARTIFACTS_DIR="${ARTIFACTS:-/logs/artifacts}"

echo "Using artifacts dir: ${ARTIFACTS_DIR}"
mkdir -p "${ARTIFACTS_DIR}"

cp -v *.xml "${ARTIFACTS_DIR}/" || echo "No XML files found"
