#!/bin/bash

set -e

# Configuration
NAMESPACE="sa-virtiofs-test"
VM_NAME="vm-sa"
PVC_NAME="os-vol-sa"
SERVICE_ACCOUNT_NAME="vm-sa"
IMAGE_ID="default/image-ccv5j"
STORAGE_CLASS="longhorn-image-ccv5j"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${BLUE}[SUCCESS]${NC} $1"
}

# Function to enable virtiofs feature gate
enable_feature_gate() {
    log_info "Enabling virtiofs feature gate..."
    
    KV_NS="$(kubectl get kubevirt -A -o jsonpath='{.items[0].metadata.namespace}')"
    KV_NAME="$(kubectl get kubevirt -A -o jsonpath='{.items[0].metadata.name}')"
    
    if [ -z "$KV_NS" ] || [ -z "$KV_NAME" ]; then
        log_error "KubeVirt resource not found"
        exit 1
    fi
    
    kubectl -n "${KV_NS}" get kubevirt "${KV_NAME}" -o json \
      | jq '
          .spec.configuration.developerConfiguration.featureGates =
          ((.spec.configuration.developerConfiguration.featureGates // [])
            + ["EnableVirtioFsConfigVolumes"] | unique)
        ' \
      | kubectl apply -f -
    
    log_info "Waiting for KubeVirt to reconcile (10 seconds)..."
    sleep 10
}

# Function to create namespace
create_namespace() {
    log_info "Creating namespace: ${NAMESPACE}..."
    
    if kubectl get namespace ${NAMESPACE} &>/dev/null; then
        log_warn "Namespace ${NAMESPACE} already exists"
    else
        kubectl create namespace ${NAMESPACE}
        log_success "Namespace ${NAMESPACE} created"
    fi
}

# Function to create serviceaccount and RBAC
create_serviceaccount() {
    log_info "Creating ServiceAccount and RBAC: ${SERVICE_ACCOUNT_NAME}..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${SERVICE_ACCOUNT_NAME}-read
  namespace: ${NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${SERVICE_ACCOUNT_NAME}-read
  namespace: ${NAMESPACE}
subjects:
- kind: ServiceAccount
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${SERVICE_ACCOUNT_NAME}-read
EOF
    
    log_success "ServiceAccount and RBAC created"
}

# Function to create PVC
create_pvc() {
    log_info "Creating PVC: ${PVC_NAME}..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
  annotations:
    harvesterhci.io/imageId: ${IMAGE_ID}
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  storageClassName: ${STORAGE_CLASS}
  volumeMode: Block
EOF
    
    log_info "Waiting for PVC to be bound..."
    kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/${PVC_NAME} -n ${NAMESPACE} --timeout=120s
}

# Function to create VM
create_vm() {
    log_info "Creating VM: ${VM_NAME}..."
    
    # Generate random MAC address
    MAC_ADDRESS=$(printf 'ee:fe:f9:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
    
    cat <<EOF | kubectl apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${NAMESPACE}
  labels:
    harvesterhci.io/creator: harvester
    harvesterhci.io/os: linux
spec:
  runStrategy: RerunOnFailure
  template:
    metadata:
      labels:
        harvesterhci.io/vmName: ${VM_NAME}
    spec:
      affinity: {}
      architecture: amd64
      domain:
        cpu:
          cores: 2
          sockets: 1
          threads: 1
        devices:
          disks:
          - bootOrder: 1
            disk:
              bus: virtio
            name: disk-0
          - disk:
              bus: virtio
            name: cloudinitdisk
          filesystems:
          - name: serviceaccount-fs
            virtiofs: {}
          inputs:
          - bus: usb
            name: tablet
            type: tablet
          interfaces:
          - macAddress: ${MAC_ADDRESS}
            masquerade: {}
            model: virtio
            name: default
        features:
          acpi:
            enabled: true
        machine:
          type: q35
        memory:
          guest: 5Gi
        resources:
          limits:
            cpu: "2"
            memory: 5Gi
          requests:
            cpu: 125m
            memory: 3413Mi
      evictionStrategy: LiveMigrateIfPossible
      hostname: ${VM_NAME}
      networks:
      - name: default
        pod: {}
      terminationGracePeriodSeconds: 20
      volumes:
      - name: serviceaccount-fs
        serviceAccount:
          serviceAccountName: ${SERVICE_ACCOUNT_NAME}
      - name: disk-0
        persistentVolumeClaim:
          claimName: ${PVC_NAME}
      - name: cloudinitdisk
        cloudInitNoCloud:
          userData: |-
            #cloud-config
            password: abc1234
            chpasswd: { expire: False }
            ssh_pwauth: True
            runcmd:
              - mkdir -p /mnt/serviceaccount
              - mount -t virtiofs serviceaccount-fs /mnt/serviceaccount
              - apt -y install curl ca-certificates || true
              - - systemctl
                - enable
                - --now
                - qemu-guest-agent.service
            package_update: true
            packages:
              - qemu-guest-agent
          networkData: |-
            network:
              ethernets:
                enp2s0:
                  dhcp4: true
                  dhcp6: true
                  dhcp-identifier: mac
              version: 2
EOF
    
    log_info "Waiting for VM to be ready (may take a few minutes)..."
    kubectl wait --for=condition=Ready vm/${VM_NAME} -n ${NAMESPACE} --timeout=300s || true
}

# Function to check VM status
check_vm_status() {
    log_info "Checking VM status..."
    
    kubectl get vm ${VM_NAME} -n ${NAMESPACE} -o wide
    echo ""
    
    log_info "Checking VMI (VirtualMachineInstance)..."
    kubectl get vmi ${VM_NAME} -n ${NAMESPACE} -o wide 2>/dev/null || log_warn "VMI not yet created"
    echo ""
    
    log_info "Getting VM IP address..."
    IP=$(kubectl get vmi ${VM_NAME} -n ${NAMESPACE} -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "Not available yet")
    echo "VM IP: ${IP}"
    echo ""
    
    log_info "ServiceAccount mounted at: /mnt/serviceaccount"
    echo ""
    
    log_success "To connect to VM console, run:"
    echo "  virtctl -n ${NAMESPACE} console ${VM_NAME}"
    echo ""
    
    log_success "To verify serviceaccount mount inside VM, run:"
    echo "  sudo mount | grep virtiofs"
    echo "  sudo ls -al /mnt/serviceaccount"
    echo "  sudo cat /mnt/serviceaccount/namespace"
    echo "  sudo cat /mnt/serviceaccount/token"
    echo ""
    
    log_success "To test Kubernetes API access inside VM:"
    echo '  TOKEN="$(sudo cat /mnt/serviceaccount/token)"'
    echo '  sudo curl --cacert /mnt/serviceaccount/ca.crt \'
    echo '    -H "Authorization: Bearer ${TOKEN}" \'
    echo '    https://kubernetes.default.svc/api'
    echo ""
    echo '  sudo curl --cacert /mnt/serviceaccount/ca.crt \'
    echo '    -H "Authorization: Bearer ${TOKEN}" \'
    echo "    https://kubernetes.default.svc/api/v1/namespaces/${NAMESPACE}/pods"
}

# Function to test serviceaccount from host
test_serviceaccount() {
    log_info "Testing ServiceAccount permissions from host..."
    
    if ! kubectl get sa ${SERVICE_ACCOUNT_NAME} -n ${NAMESPACE} &>/dev/null; then
        log_error "ServiceAccount ${SERVICE_ACCOUNT_NAME} not found in namespace ${NAMESPACE}"
        exit 1
    fi
    
    log_info "ServiceAccount details:"
    kubectl get sa ${SERVICE_ACCOUNT_NAME} -n ${NAMESPACE} -o yaml
    echo ""
    
    log_info "Checking RBAC permissions:"
    kubectl describe role ${SERVICE_ACCOUNT_NAME}-read -n ${NAMESPACE}
    echo ""
    
    log_info "Checking RoleBinding:"
    kubectl describe rolebinding ${SERVICE_ACCOUNT_NAME}-read -n ${NAMESPACE}
    echo ""
    
    log_success "ServiceAccount is properly configured!"
}

# Function to update RBAC permissions
update_rbac() {
    log_info "Updating RBAC permissions for ${SERVICE_ACCOUNT_NAME}..."
    
    # Parse custom permissions if provided
    if [ -n "${CUSTOM_RESOURCES}" ] && [ -n "${CUSTOM_VERBS}" ]; then
        RESOURCES="${CUSTOM_RESOURCES}"
        VERBS="${CUSTOM_VERBS}"
        
        log_info "Applying custom RBAC permissions:"
        echo "  Resources: ${CUSTOM_RESOURCES}"
        echo "  Verbs: ${CUSTOM_VERBS}"
        echo ""
        
        cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${SERVICE_ACCOUNT_NAME}-read
  namespace: ${NAMESPACE}
rules:
- apiGroups: [""]
  resources: [${RESOURCES}]
  verbs: [${VERBS}]
EOF
        
        log_success "RBAC permissions updated with custom permissions"
        echo ""
        log_info "Updated Role details:"
        kubectl describe role ${SERVICE_ACCOUNT_NAME}-read -n ${NAMESPACE}
        echo ""
        
        log_success "To test these permissions inside the VM, run:"
        echo '  TOKEN="$(sudo cat /mnt/serviceaccount/token)"'
        echo ""
        
        # Generate test commands based on resources
        IFS=',' read -ra RES_ARRAY <<< "${CUSTOM_RESOURCES//\"/}"
        for resource in "${RES_ARRAY[@]}"; do
            resource=$(echo "$resource" | xargs) # trim whitespace
            echo "  # Test access to ${resource}:"
            echo '  sudo curl --cacert /mnt/serviceaccount/ca.crt \'
            echo '    -H "Authorization: Bearer ${TOKEN}" \'
            echo "    https://kubernetes.default.svc/api/v1/namespaces/${NAMESPACE}/${resource}"
            echo ""
        done
    else
        # Default: add more permissions
        log_info "Applying extended RBAC permissions:"
        echo "  Core API resources: pods, services, configmaps, secrets"
        echo "    Verbs: get, list, watch"
        echo "  Apps API resources: deployments, statefulsets"
        echo "    Verbs: get, list, watch"
        echo ""
        
        cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${SERVICE_ACCOUNT_NAME}-read
  namespace: ${NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "secrets"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets"]
  verbs: ["get", "list", "watch"]
EOF
        
        log_success "RBAC permissions updated with extended permissions"
        echo ""
        log_info "Updated Role details:"
        kubectl describe role ${SERVICE_ACCOUNT_NAME}-read -n ${NAMESPACE}
        echo ""
        
        log_success "To test these permissions inside the VM, run:"
        echo '  TOKEN="$(sudo cat /mnt/serviceaccount/token)"'
        echo ""
        echo "  # Test access to pods:"
        echo '  sudo curl --cacert /mnt/serviceaccount/ca.crt \'
        echo '    -H "Authorization: Bearer ${TOKEN}" \'
        echo "    https://kubernetes.default.svc/api/v1/namespaces/${NAMESPACE}/pods"
        echo ""
        echo "  # Test access to services:"
        echo '  sudo curl --cacert /mnt/serviceaccount/ca.crt \'
        echo '    -H "Authorization: Bearer ${TOKEN}" \'
        echo "    https://kubernetes.default.svc/api/v1/namespaces/${NAMESPACE}/services"
        echo ""
        echo "  # Test access to configmaps:"
        echo '  sudo curl --cacert /mnt/serviceaccount/ca.crt \'
        echo '    -H "Authorization: Bearer ${TOKEN}" \'
        echo "    https://kubernetes.default.svc/api/v1/namespaces/${NAMESPACE}/configmaps"
        echo ""
        echo "  # Test access to secrets:"
        echo '  sudo curl --cacert /mnt/serviceaccount/ca.crt \'
        echo '    -H "Authorization: Bearer ${TOKEN}" \'
        echo "    https://kubernetes.default.svc/api/v1/namespaces/${NAMESPACE}/secrets"
        echo ""
        echo "  # Test access to deployments:"
        echo '  sudo curl --cacert /mnt/serviceaccount/ca.crt \'
        echo '    -H "Authorization: Bearer ${TOKEN}" \'
        echo "    https://kubernetes.default.svc/apis/apps/v1/namespaces/${NAMESPACE}/deployments"
        echo ""
        echo "  # Test access to statefulsets:"
        echo '  sudo curl --cacert /mnt/serviceaccount/ca.crt \'
        echo '    -H "Authorization: Bearer ${TOKEN}" \'
        echo "    https://kubernetes.default.svc/apis/apps/v1/namespaces/${NAMESPACE}/statefulsets"
        echo ""
    fi
}

# Function to cleanup resources
cleanup() {
    log_warn "Cleaning up resources..."
    
    log_info "Deleting VM: ${VM_NAME}..."
    kubectl delete vm ${VM_NAME} -n ${NAMESPACE} --wait=true 2>/dev/null || log_warn "VM not found or already deleted"
    
    log_info "Deleting PVC: ${PVC_NAME}..."
    kubectl delete pvc ${PVC_NAME} -n ${NAMESPACE} --wait=true 2>/dev/null || log_warn "PVC not found or already deleted"
    
    log_info "Deleting ServiceAccount and RBAC..."
    kubectl delete sa ${SERVICE_ACCOUNT_NAME} -n ${NAMESPACE} 2>/dev/null || log_warn "ServiceAccount not found or already deleted"
    kubectl delete role ${SERVICE_ACCOUNT_NAME}-read -n ${NAMESPACE} 2>/dev/null || true
    kubectl delete rolebinding ${SERVICE_ACCOUNT_NAME}-read -n ${NAMESPACE} 2>/dev/null || true
    
    log_info "Cleaning up cloud-init secrets..."
    kubectl delete secret -n ${NAMESPACE} -l harvesterhci.io/cloud-init-template=harvester --field-selector metadata.ownerReferences[*].name=${VM_NAME} 2>/dev/null || true
    
    read -p "Delete namespace ${NAMESPACE}? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Deleting namespace: ${NAMESPACE}..."
        kubectl delete namespace ${NAMESPACE} --wait=true 2>/dev/null || log_warn "Namespace not found or already deleted"
    else
        log_info "Namespace ${NAMESPACE} preserved"
    fi
    
    log_success "Cleanup complete!"
}

# Function to display usage
usage() {
    cat <<EOF
Usage: $0 [COMMAND] [OPTIONS]

Commands:
  setup             Set up everything from scratch (feature gate, namespace, SA, RBAC, PVC, VM)
  create-vm         Create only the VM (assumes namespace, SA, and PVC exist)
  test-sa           Test ServiceAccount permissions from host
  update-rbac       Update RBAC permissions for the ServiceAccount
  cleanup           Delete all created resources (VM, PVC, ServiceAccount, RBAC)
  status            Check VM status and show access instructions
  help              Display this help message

Options for update-rbac:
  --resources VALUE   Comma-separated list of resources (quoted, e.g., "pods,services,configmaps")
  --verbs VALUE       Comma-separated list of verbs (quoted, e.g., "get,list,watch,create")

Examples:
  $0 setup                                    # Create everything from scratch
  $0 status                                   # Check VM status and show instructions
  $0 test-sa                                  # Test ServiceAccount from host
  $0 update-rbac                              # Update with extended permissions
  $0 update-rbac --resources "pods,services" --verbs "get,list,create,delete"
  $0 cleanup                                  # Delete all resources

Configuration (edit script to modify):
  NAMESPACE:            ${NAMESPACE}
  VM_NAME:              ${VM_NAME}
  PVC_NAME:             ${PVC_NAME}
  SERVICE_ACCOUNT_NAME: ${SERVICE_ACCOUNT_NAME}
  IMAGE_ID:             ${IMAGE_ID}
  STORAGE_CLASS:        ${STORAGE_CLASS}

Testing inside VM:
  After VM is created, connect via console and test:
  
  # Verify mount
  sudo mount | grep virtiofs
  sudo ls -al /mnt/serviceaccount
  
  # Check ServiceAccount files
  sudo cat /mnt/serviceaccount/namespace
  sudo cat /mnt/serviceaccount/token
  
  # Test Kubernetes API
  TOKEN="\$(sudo cat /mnt/serviceaccount/token)"
  sudo curl --cacert /mnt/serviceaccount/ca.crt \\
    -H "Authorization: Bearer \${TOKEN}" \\
    https://kubernetes.default.svc/api
  
  sudo curl --cacert /mnt/serviceaccount/ca.crt \\
    -H "Authorization: Bearer \${TOKEN}" \\
    https://kubernetes.default.svc/api/v1/namespaces/${NAMESPACE}/pods
EOF
}

# Main script logic
main() {
    # Parse options for update-rbac command
    if [ "${1:-}" = "update-rbac" ]; then
        shift
        while [ $# -gt 0 ]; do
            case "$1" in
                --resources)
                    CUSTOM_RESOURCES="$2"
                    shift 2
                    ;;
                --verbs)
                    CUSTOM_VERBS="$2"
                    shift 2
                    ;;
                *)
                    log_error "Unknown option for update-rbac: $1"
                    usage
                    exit 1
                    ;;
            esac
        done
        update_rbac
        exit 0
    fi
    
    case "${1:-}" in
        setup)
            log_info "Starting full setup..."
            enable_feature_gate
            create_namespace
            create_serviceaccount
            create_pvc
            create_vm
            echo ""
            check_vm_status
            ;;
        create-vm)
            log_info "Creating VM only..."
            create_vm
            echo ""
            check_vm_status
            ;;
        test-sa)
            test_serviceaccount
            ;;
        cleanup)
            cleanup
            ;;
        status)
            check_vm_status
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            log_error "Invalid command: ${1:-}"
            echo ""
            usage
            exit 1
            ;;
    esac
}

main "$@"
