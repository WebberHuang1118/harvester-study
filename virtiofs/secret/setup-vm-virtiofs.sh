#!/bin/bash

set -e

# Configuration
NAMESPACE="default"
VM_NAME="vm-secret"
PVC_NAME="os-vol-secret"
SECRET_NAME="app-secret"
IMAGE_ID="default/image-ccv5j"
STORAGE_CLASS="longhorn-image-ccv5j"
NETWORK_NAME="default/mgmt-vlan"
SSH_KEY_SECRET="default/webberhuang"

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

# Function to create app secret
create_app_secret() {
    log_info "Creating app secret: ${SECRET_NAME}..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: Opaque
data:
  endpoint: $(echo -n "https://example.internal" | base64 -w0)
  token: $(echo -n "abc-123" | base64 -w0)
EOF
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
    MAC_ADDRESS=$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
    
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
      annotations:
        harvesterhci.io/sshNames: '["${SSH_KEY_SECRET}"]'
      labels:
        harvesterhci.io/vmName: ${VM_NAME}
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: network.harvesterhci.io/mgmt
                operator: In
                values:
                - "true"
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
          - name: appsecretfs
            virtiofs: {}
          inputs:
          - bus: usb
            name: tablet
            type: tablet
          interfaces:
          - bridge: {}
            macAddress: ${MAC_ADDRESS}
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
      - multus:
          networkName: ${NETWORK_NAME}
        name: default
      terminationGracePeriodSeconds: 20
      volumes:
      - name: appsecretfs
        secret:
          secretName: ${SECRET_NAME}
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
              - mkdir -p /mnt/app-secret
              - mount -t virtiofs appsecretfs /mnt/app-secret
              - ls -al /mnt/app-secret || true
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
    
    log_info "To connect to VM console, run:"
    echo "  virtctl -n ${NAMESPACE} console ${VM_NAME}"
    echo ""
    
    log_info "To test virtiofs mount inside VM, run:"
    echo "  ls -al /mnt/app-secret"
    echo "  cat /mnt/app-secret/token"
    echo "  cat /mnt/app-secret/endpoint"
    echo ""
    
    log_info "To rotate secret:"
    echo "  $0 rotate-secret"
}

# Function to rotate secret
rotate_secret() {
    log_info "Rotating secret: ${SECRET_NAME}..."
    
    # Check if secret exists
    if ! kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} &>/dev/null; then
        log_error "Secret ${SECRET_NAME} not found in namespace ${NAMESPACE}"
        exit 1
    fi
    
    # Get current values
    log_info "Current secret values:"
    CURRENT_ENDPOINT=$(kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath='{.data.endpoint}' | base64 -d)
    CURRENT_TOKEN=$(kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath='{.data.token}' | base64 -d)
    echo "  endpoint: ${CURRENT_ENDPOINT}"
    echo "  token: ${CURRENT_TOKEN}"
    echo ""
    
    # Generate new values or use provided ones
    if [ -n "${NEW_ENDPOINT}" ]; then
        NEW_ENDPOINT_VALUE="${NEW_ENDPOINT}"
    else
        NEW_ENDPOINT_VALUE="https://api-$(date +%s).example.internal"
    fi
    
    if [ -n "${NEW_TOKEN}" ]; then
        NEW_TOKEN_VALUE="${NEW_TOKEN}"
    else
        NEW_TOKEN_VALUE="token-$(openssl rand -hex 8)"
    fi
    
    log_info "New secret values:"
    echo "  endpoint: ${NEW_ENDPOINT_VALUE}"
    echo "  token: ${NEW_TOKEN_VALUE}"
    echo ""
    
    # Update the secret
    kubectl patch secret ${SECRET_NAME} -n ${NAMESPACE} --type='json' -p="[
        {\"op\": \"replace\", \"path\": \"/data/endpoint\", \"value\": \"$(echo -n "${NEW_ENDPOINT_VALUE}" | base64 -w0)\"},
        {\"op\": \"replace\", \"path\": \"/data/token\", \"value\": \"$(echo -n "${NEW_TOKEN_VALUE}" | base64 -w0)\"}
    ]"
    
    log_success "Secret rotated successfully!"
    echo ""
    
    # Verify inside VM if it's running
    if kubectl get vmi ${VM_NAME} -n ${NAMESPACE} &>/dev/null; then
        log_info "VM is running. Verifying the changes are visible inside VM..."
        echo ""
        echo "To verify the changes inside VM, run:"
        echo "  virtctl -n ${NAMESPACE} console ${VM_NAME}"
        echo ""
        echo "Then inside VM:"
        echo "  cat /mnt/app-secret/endpoint  # Should show: ${NEW_ENDPOINT_VALUE}"
        echo "  cat /mnt/app-secret/token     # Should show: ${NEW_TOKEN_VALUE}"
        echo ""
        log_success "Changes should be visible immediately (no VM restart required)!"
    else
        log_warn "VM is not running. Start the VM to see the new secret values."
    fi
}

# Function to cleanup resources
cleanup() {
    log_warn "Cleaning up resources..."
    
    log_info "Deleting VM: ${VM_NAME}..."
    kubectl delete vm ${VM_NAME} -n ${NAMESPACE} --wait=true 2>/dev/null || log_warn "VM not found or already deleted"
    
    log_info "Deleting PVC: ${PVC_NAME}..."
    kubectl delete pvc ${PVC_NAME} -n ${NAMESPACE} --wait=true 2>/dev/null || log_warn "PVC not found or already deleted"
    
    log_info "Deleting Secret: ${SECRET_NAME}..."
    kubectl delete secret ${SECRET_NAME} -n ${NAMESPACE} 2>/dev/null || log_warn "Secret not found or already deleted"
    
    # Clean up cloud-init secrets (they have owner references but let's be thorough)
    log_info "Cleaning up cloud-init secrets..."
    kubectl delete secret -n ${NAMESPACE} -l harvesterhci.io/cloud-init-template=harvester --field-selector metadata.ownerReferences[*].name=${VM_NAME} 2>/dev/null || true
    
    log_info "Cleanup complete!"
}

# Function to display usage
usage() {
    cat <<EOF
Usage: $0 [COMMAND] [OPTIONS]

Commands:
  setup             Set up everything from scratch (feature gate, PVC, secrets, VM)
  create-vm         Create only the VM (assumes PVC and secrets exist)
  rotate-secret     Rotate the filesystem secret with new values
  cleanup           Delete all created resources (VM, PVC, secrets)
  status            Check VM status
  help              Display this help message

Options for rotate-secret:
  --endpoint VALUE  Set custom endpoint value (default: auto-generated with timestamp)
  --token VALUE     Set custom token value (default: auto-generated random token)

Examples:
  $0 setup                                    # Create everything from scratch
  $0 status                                   # Check VM status
  $0 rotate-secret                            # Rotate with auto-generated values
  $0 rotate-secret --token "new-token-456"    # Rotate with custom token
  $0 rotate-secret --endpoint "https://new-api.example.com" --token "secret-xyz"
  $0 cleanup                                  # Delete all resources

Configuration (edit script to modify):
  NAMESPACE:     ${NAMESPACE}
  VM_NAME:       ${VM_NAME}
  PVC_NAME:      ${PVC_NAME}
  SECRET_NAME:   ${SECRET_NAME}
EOF
}

# Main script logic
main() {
    # Parse options for rotate-secret command
    if [ "${1:-}" = "rotate-secret" ]; then
        shift
        while [ $# -gt 0 ]; do
            case "$1" in
                --endpoint)
                    NEW_ENDPOINT="$2"
                    shift 2
                    ;;
                --token)
                    NEW_TOKEN="$2"
                    shift 2
                    ;;
                *)
                    log_error "Unknown option for rotate-secret: $1"
                    usage
                    exit 1
                    ;;
            esac
        done
        rotate_secret
        exit 0
    fi
    
    case "${1:-}" in
        setup)
            log_info "Starting full setup..."
            enable_feature_gate
            create_app_secret
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
