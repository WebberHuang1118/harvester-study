#!/bin/bash

set -e

# Configuration
NAMESPACE="default"
VM_NAME="vm-configmap"
PVC_NAME="os-vol-configmap"
CONFIGMAP_NAME="app-config"
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

# Function to create app configmap
create_app_configmap() {
    log_info "Creating app configmap: ${CONFIGMAP_NAME}..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CONFIGMAP_NAME}
  namespace: ${NAMESPACE}
data:
  api.conf: |
    # Application API Configuration
    server {
      listen 8080;
      server_name api.example.internal;
      
      location / {
        proxy_pass http://backend:3000;
      }
    }
  database.conf: |
    # Database Configuration
    host=db.example.internal
    port=5432
    database=myapp
    pool_size=20
    timeout=30
  features.json: |
    {
      "featureFlags": {
        "newUI": true,
        "betaFeatures": false,
        "analytics": true
      },
      "limits": {
        "maxConnections": 100,
        "requestTimeout": 5000
      }
    }
  app.properties: |
    app.name=MyApplication
    app.version=1.0.0
    app.environment=production
    log.level=info
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
          - name: appconfigfs
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
      - name: appconfigfs
        configMap:
          name: ${CONFIGMAP_NAME}
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
              - mkdir -p /mnt/app-config
              - mount -t virtiofs appconfigfs /mnt/app-config
              - ls -al /mnt/app-config || true
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
    echo "  ls -al /mnt/app-config"
    echo "  cat /mnt/app-config/api.conf"
    echo "  cat /mnt/app-config/database.conf"
    echo "  cat /mnt/app-config/features.json"
    echo "  cat /mnt/app-config/app.properties"
    echo ""
    
    log_info "To update configmap:"
    echo "  $0 update-config"
}

# Function to update configmap
update_configmap() {
    log_info "Updating configmap: ${CONFIGMAP_NAME}..."
    
    # Check if configmap exists
    if ! kubectl get configmap ${CONFIGMAP_NAME} -n ${NAMESPACE} &>/dev/null; then
        log_error "ConfigMap ${CONFIGMAP_NAME} not found in namespace ${NAMESPACE}"
        exit 1
    fi
    
    # Get current values
    log_info "Current configmap data keys:"
    kubectl get configmap ${CONFIGMAP_NAME} -n ${NAMESPACE} -o jsonpath='{.data}' | jq 'keys'
    echo ""
    
    # Generate new values or use provided ones
    if [ -n "${NEW_API_CONF}" ]; then
        API_CONF="${NEW_API_CONF}"
    else
        API_CONF="# Application API Configuration - Updated $(date)
server {
  listen 8080;
  server_name api-v2.example.internal;
  
  location / {
    proxy_pass http://backend-v2:3000;
  }
}"
    fi
    
    if [ -n "${NEW_DB_CONF}" ]; then
        DB_CONF="${NEW_DB_CONF}"
    else
        DB_CONF="# Database Configuration - Updated $(date)
host=db-v2.example.internal
port=5432
database=myapp_v2
pool_size=50
timeout=60"
    fi
    
    if [ -n "${NEW_FEATURES}" ]; then
        FEATURES="${NEW_FEATURES}"
    else
        FEATURES="{
  \"featureFlags\": {
    \"newUI\": true,
    \"betaFeatures\": true,
    \"analytics\": true,
    \"darkMode\": true
  },
  \"limits\": {
    \"maxConnections\": 200,
    \"requestTimeout\": 10000
  },
  \"updated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
}"
    fi
    
    if [ -n "${NEW_APP_PROPS}" ]; then
        APP_PROPS="${NEW_APP_PROPS}"
    else
        APP_PROPS="app.name=MyApplication
app.version=2.0.0
app.environment=production
log.level=debug
updated.timestamp=$(date +%s)"
    fi
    
    log_info "Updating configmap with new values..."
    
    # Create a temporary JSON file for the patch
    TEMP_JSON=$(mktemp)
    cat > "${TEMP_JSON}" <<EOF
{
  "data": {
    "api.conf": $(echo "${API_CONF}" | jq -Rs .),
    "database.conf": $(echo "${DB_CONF}" | jq -Rs .),
    "features.json": $(echo "${FEATURES}" | jq -Rs .),
    "app.properties": $(echo "${APP_PROPS}" | jq -Rs .)
  }
}
EOF
    
    # Apply the patch
    kubectl patch configmap ${CONFIGMAP_NAME} -n ${NAMESPACE} --type merge --patch-file "${TEMP_JSON}"
    
    # Clean up
    rm -f "${TEMP_JSON}"
    
    log_success "ConfigMap updated successfully!"
    echo ""
    
    # Verify inside VM if it's running
    if kubectl get vmi ${VM_NAME} -n ${NAMESPACE} &>/dev/null; then
        log_info "VM is running. Verifying the changes are visible inside VM..."
        echo ""
        echo "To verify the changes inside VM, run:"
        echo "  virtctl -n ${NAMESPACE} console ${VM_NAME}"
        echo ""
        echo "Then inside VM:"
        echo "  cat /mnt/app-config/api.conf"
        echo "  cat /mnt/app-config/database.conf"
        echo "  cat /mnt/app-config/features.json"
        echo "  cat /mnt/app-config/app.properties"
        echo ""
        log_success "Changes should be visible immediately (no VM restart required)!"
    else
        log_warn "VM is not running. Start the VM to see the new configmap values."
    fi
}

# Function to cleanup resources
cleanup() {
    log_warn "Cleaning up resources..."
    
    log_info "Deleting VM: ${VM_NAME}..."
    kubectl delete vm ${VM_NAME} -n ${NAMESPACE} --wait=true 2>/dev/null || log_warn "VM not found or already deleted"
    
    log_info "Deleting PVC: ${PVC_NAME}..."
    kubectl delete pvc ${PVC_NAME} -n ${NAMESPACE} --wait=true 2>/dev/null || log_warn "PVC not found or already deleted"
    
    log_info "Deleting ConfigMap: ${CONFIGMAP_NAME}..."
    kubectl delete configmap ${CONFIGMAP_NAME} -n ${NAMESPACE} 2>/dev/null || log_warn "ConfigMap not found or already deleted"
    
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
  setup             Set up everything from scratch (feature gate, PVC, configmap, VM)
  create-vm         Create only the VM (assumes PVC and configmap exist)
  update-config     Update the configmap with new values
  cleanup           Delete all created resources (VM, PVC, configmap)
  status            Check VM status
  help              Display this help message

Options for update-config:
  --api-conf VALUE    Set custom api.conf content
  --db-conf VALUE     Set custom database.conf content
  --features VALUE    Set custom features.json content
  --app-props VALUE   Set custom app.properties content

Examples:
  $0 setup                                    # Create everything from scratch
  $0 status                                   # Check VM status
  $0 update-config                            # Update with auto-generated values
  $0 update-config --app-props "app.version=3.0.0"
  $0 cleanup                                  # Delete all resources

Configuration (edit script to modify):
  NAMESPACE:       ${NAMESPACE}
  VM_NAME:         ${VM_NAME}
  PVC_NAME:        ${PVC_NAME}
  CONFIGMAP_NAME:  ${CONFIGMAP_NAME}
EOF
}

# Main script logic
main() {
    # Parse options for update-config command
    if [ "${1:-}" = "update-config" ]; then
        shift
        while [ $# -gt 0 ]; do
            case "$1" in
                --api-conf)
                    NEW_API_CONF="$2"
                    shift 2
                    ;;
                --db-conf)
                    NEW_DB_CONF="$2"
                    shift 2
                    ;;
                --features)
                    NEW_FEATURES="$2"
                    shift 2
                    ;;
                --app-props)
                    NEW_APP_PROPS="$2"
                    shift 2
                    ;;
                *)
                    log_error "Unknown option for update-config: $1"
                    usage
                    exit 1
                    ;;
            esac
        done
        update_configmap
        exit 0
    fi
    
    case "${1:-}" in
        setup)
            log_info "Starting full setup..."
            enable_feature_gate
            create_app_configmap
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
