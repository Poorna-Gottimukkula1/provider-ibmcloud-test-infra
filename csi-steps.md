# k8s setup and IBM PowerVS CSI Driver installation and run e2e  

## 🔧 Setup

### 1. Install Kubernetes Cluster
- Use `kubetest2-tf` to deploy k8s cluster.

### 2. Fetch PowerVS Instance Details and create a instance list json file to consume later in playbook
- Retrieve the following using Terraform mostly in deployer.go(in UP function ):
  - `PowerVS instance IDs for masters/workers`
  - `PowerVS instance Name for masters/workers`
  example file
```bash
All Instances: [
  {
    "id": "7b087a2a-dab2-4644-bc1f-ac3a5e0f754e",
    "name": "config1-1756296092-master"
  },
  {
    "id": "dd79d0d4-353e-4b32-9ca1-5187939d3b6b",
    "name": "config1-1756296092-worker-0"
  },
  {
    "id": "890369a3-d6b1-4345-a12c-c826b4f519b0",
    "name": "config1-1756296092-worker-1"
  }
]

```
### Using ansible
### 3. Pass the below details as extra vars to the playbook to consume later
  - `region`
  - `zone`
  - `workspace ID (service_instance_id)`
example:
```bash
--extra-vars=powervs_zone:${BOSKOS_ZONE},powervs_region:${BOSKOS_REGION},powervs_ws:${BOSKOS_RESOURCE_ID}
```

### 3. Patch Nodes with ProviderID(read the instance id,name from the instance_list json file generated in the 2nd step )
- Patch each Kubernetes node using:
  ```bash
  kubectl patch node <node-name> -p '{"spec": {"providerID": "ibmpowervs://<region>/<zone>/<workspace_id>/<machine_id>"}}'
### 4. Add Required Node Labels

- Apply the following labels to each node:
```bash
kubectl label nodes <node-name> powervs.kubernetes.io/cloud-instance-id=<workspace_id>
kubectl label nodes <node-name> powervs.kubernetes.io/pvm-instance-id=<machine_id>
```
### 5. Create Secret for CSI Driver

- Create a Kubernetes Secret in the kube-system namespace with:
```bash
export IBMCLOUD_API_KEY=your_api_key_here
TF_VAR_powervs_api_key=********** we already have this in pod.

---
May be something like this as we already exported the api key

stringData:
  IBMCLOUD_API_KEY: "{{ lookup('env', 'TF_VAR_powervs_api_key') }}"

  or
sed -i '' "s|IBMCLOUD_API_KEY:.*|IBMCLOUD_API_KEY: \"$TF_VAR_powervs_api_key\"|" secret.yaml

---
```
Use Ansible or kubectl to create the secret safely, avoiding logs or file storage.

### 6. Deploy IBM Cloud CSI Driver

- Apply the official driver manifests:
```bash
kubectl apply -k "https://github.com/kubernetes-sigs/ibm-powervs-block-csi-driver/deploy/kubernetes/overlays/stable/?ref=v0.6.0"
```
## Testing (E2E)

### 7. Set Environment Variable for Tests

Export the API key:
```bash
export IBMCLOUD_API_KEY=your_api_key_here
```
### 8. Verify Node Labels

Ensure all required node labels are present:
```bash
powervs.kubernetes.io/cloud-instance-id
powervs.kubernetes.io/pvm-instance-id
----
kubectl label nodes <node-name> powervs.kubernetes.io/cloud-instance-id=<GUID of the workspace>
kubectl label nodes <node-name> powervs.kubernetes.io/pvm-instance-id=<Instance ID of the PowerVS instance>
----
```
Tests marked with [labels] will be skipped if labels are missing.

### 9. Run E2E Tests

Run the CSI driver E2E test suite to verify:

```
make test-e2e
```

Static provisioning

Dynamic provisioning

Volume scheduling

Mount options

Tests marked with [env] or [labels] will only run if conditions are met.


=====================
Q/A

1. If we keep these beloow output modules in tf, we always seen the output in logs

```
kubetest2-tf\data\powervs\instance\main.tf
# Output: List of instances with ID and Name
output "instance_list" {
  value = [
    for vm in ibm_pi_instance.pvminstance :
    {
      id   = vm.instance_id
      name = vm.pi_instance_name
    }
  ]
  description = "List of PowerVS instance IDs and VM names"
}
```
2. file generation we from tf output we can add condition.
```
kubetest2-tf/deployer/deployer.go
if d.fetchinstancelist {

}
```
