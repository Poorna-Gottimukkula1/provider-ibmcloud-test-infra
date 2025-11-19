#!/bin/bash
set -x

### ---------------------------------------------------
### 0. BASIC CONFIG
### ---------------------------------------------------

export KUBECONFIG="/workspace/provider-ibmcloud-test-infra/test-k8s-vm/kubeconfig"
export POWERVS_REGION="syd"
export POWERVS_ZONE="syd05"
export POWERVS_CLOUD_INSTANCE_ID="17b50a72-238e-4849-aed0-8c139564b92a"

INSTANCE_LIST_JSON="/workspace/provider-ibmcloud-test-infra/test-k8s-vm/instance_list.json"

echo "[INFO] Using KUBECONFIG = $KUBECONFIG"
kubectl get nodes

### ---------------------------------------------------
### 1. PATCH PROVIDER ID FOR ALL NODES
### ---------------------------------------------------

echo "[INFO] Starting providerID patching..."

for row in $(jq -c '.[]' "$INSTANCE_LIST_JSON"); do
    INSTANCE_ID=$(echo "$row" | jq -r '.id')
    NODE_NAME=$(echo "$row" | jq -r '.name')

    PROVIDER_ID="ibmpowervs://$POWERVS_REGION/$POWERVS_ZONE/$POWERVS_CLOUD_INSTANCE_ID/$INSTANCE_ID"

    echo "[INFO] Patching providerID on node: $NODE_NAME"
    echo "        → $PROVIDER_ID"

    kubectl patch node "$NODE_NAME" -p "{\"spec\":{\"providerID\":\"$PROVIDER_ID\"}}"
done

### ---------------------------------------------------
### 2. CREATE & APPLY CSI SECRET
### ---------------------------------------------------

#echo "[INFO] Downloading CSI driver secret template..."
#curl -s https://raw.githubusercontent.com/kubernetes-sigs/ibm-powervs-block-csi-driver/main/deploy/kubernetes/secret.yaml -o secret.yaml

echo "[INFO] Creating IBMCLOUD_API_KEY secret key"
kubectl create secret generic ibm-secret \
  -n kube-system \
  --from-literal=IBMCLOUD_API_KEY="$TF_VAR_powervs_api_key" \
  --dry-run=client -o yaml | kubectl apply -f - 
#sed -i "s|IBMCLOUD_API_KEY:.*|IBMCLOUD_API_KEY: \"$IBMCLOUD_API_KEY\"|" secret.yaml

#kubectl apply -f secret.yaml

### ---------------------------------------------------
### 3. INSTALL THE CSI DRIVER
### ---------------------------------------------------

echo "[INFO] Installing PowerVS CSI driver..."
kubectl apply -k "https://github.com/kubernetes-sigs/ibm-powervs-block-csi-driver/deploy/kubernetes/overlays/stable/?ref=v0.10.0"


echo "[INFO] Waiting for CSI pods to be running..."
kubectl -n kube-system wait --for=condition=Ready pod -l app.kubernetes.io/name=ibm-powervs-block-csi-driver --timeout=300s

# Check if the kubectl command was successful
if [ $? -ne 0 ]; then
  echo "[ERROR] CSI pods did not become ready in the allotted time. Exiting script."
  exit 1
fi

echo "[INFO] CSI pods are now running."

### ---------------------------------------------------
### 4. LABEL NODES (AUTO)
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
### 5. RUN CSI E2E TESTS
### ---------------------------------------------------

echo "[INFO] Cloning CSI repo..."
rm -rf ibm-powervs-block-csi-driver
git clone https://github.com/kubernetes-sigs/ibm-powervs-block-csi-driver.git

cd ibm-powervs-block-csi-driver

echo "[INFO] Running e2e tests..."
make test-e2e

echo "[SUCCESS] All steps completed successfully!"