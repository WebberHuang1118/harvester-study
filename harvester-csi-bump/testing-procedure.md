# Harvester CSI Driver Chart Bump Testing Guide

> **📖 Reference**: This guide is based on the official [Harvester CSI Driver Release How-To](https://github.com/harvester/harvester-csi-driver/blob/master/docs/ReleaseHowTo.md). Please refer to the official documentation for the most up-to-date release procedures.

## Table of Contents
- [Prerequisites](#prerequisites)
- [Phase 1: Chart Development](#phase-1-chart-development)
- [Phase 2: Rancher Charts Integration](#phase-2-rancher-charts-integration)  
- [Phase 3: Local Helm Testing](#phase-3-local-helm-testing)
- [Phase 4: Rancher UI Testing](#phase-4-rancher-ui-testing)
- [Troubleshooting](#troubleshooting)

## Prerequisites

Before starting, ensure you have:
- Access to fork `harvester/charts` and `rancher/rancher-charts` repositories
- Docker repository access (e.g., `webberhuang/harvester-csi-driver`)
- Helm CLI installed
- Access to a Kubernetes cluster with Rancher
- Required permissions to manage helm releases in `kube-system` namespace

## Phase 1: Chart Development

### 1.1 Create Initial PR
Create a pull request to the `harvester/charts` master branch with your chart changes.
- **Example**: https://github.com/WebberHuang1118/charts/tree/issue-3778

### 1.2 Prepare Testing Branch
Create a dedicated testing branch with version and appVersion bumps that points to your Docker repository.
- **Example**: https://github.com/WebberHuang1118/charts/tree/release-issue-3778

### 1.3 Package and Release Chart
1. **Clone and checkout** the testing branch:
   ```bash
   git clone https://github.com/WebberHuang1118/charts.git
   git checkout release-issue-3778
   ```

2. **Create the chart tarball**:
   ```bash
   helm package charts/harvester-csi-driver
   ```

3. **Upload to GitHub release**:
   - Create a new release in your forked charts repository
   - **Example**: https://github.com/WebberHuang1118/charts/releases/tag/harvester-csi-driver-0.1.25

## Phase 2: Rancher Charts Integration

### 2.1 Prepare Rancher Charts Repository
1. **Clone the rancher-charts repository**:
   ```bash
   git clone https://github.com/WebberHuang1118/rancher-charts.git
   cd rancher-charts
   ```

2. **Update configuration files** to point to the new version, appVersion, and chart release URL:
   - `packages/harvester/harvester-csi-driver/generated-changes/patch/Chart.yaml.patch`
   - `packages/harvester/harvester-csi-driver/package.yaml` 
   - `release.yaml`

   **Example branch**: https://github.com/WebberHuang1118/rancher-charts/tree/v2.10-bump-harvester-csi-driver-0.1.25-trial

### 2.2 Generate Rancher Chart Content
```bash
export PACKAGE=harvester/harvester-csi-driver
make prepare
make patch
make clean
PACKAGE=harvester/harvester-csi-driver make charts
make validate
```

## Phase 3: Local Helm Testing

### 3.1 Pre-upgrade Verification
```bash
# Check current helm installation
helm list -n kube-system | grep harvester

# Review current helm history
helm history harvester-csi-driver -n kube-system
```

### 3.2 Perform Upgrade Test
```bash
# Upgrade using the generated tarball
helm upgrade harvester-csi-driver assets/harvester-csi-driver/harvester-csi-driver-105.0.4+up0.1.25.tgz -n kube-system

# Verify the upgrade
helm history harvester-csi-driver -n kube-system
```

### 3.3 Validation and Rollback
1. **Verify component updates**:
   - Check that harvester-csi-driver DaemonSet is updated
   - Verify harvester-csi-driver Deployment is updated
   - Confirm pods are running with new image versions

2. **Test rollback procedure**:
   ```bash
   helm rollback harvester-csi-driver [previous-revision-number] -n kube-system
   ```

### 3.4 Commit Changes
Commit the following files to your rancher-charts repository:

**Generated assets**:
- `assets/harvester-csi-driver/harvester-csi-driver-105.0.4+up0.1.25.tgz`
- `index.yaml`

**Chart templates**:
- `charts/harvester-csi-driver/105.0.4+up0.1.25/.helmignore`
- `charts/harvester-csi-driver/105.0.4+up0.1.25/Chart.yaml`
- `charts/harvester-csi-driver/105.0.4+up0.1.25/questions.yml`
- `charts/harvester-csi-driver/105.0.4+up0.1.25/templates/*.yaml`
- `charts/harvester-csi-driver/105.0.4+up0.1.25/values.yaml`

**Package configuration**:
- `packages/harvester/harvester-csi-driver/generated-changes/patch/Chart.yaml.patch`
- `packages/harvester/harvester-csi-driver/package.yaml`
- `release.yaml`

## Phase 4: Rancher UI Testing

### 4.1 Add Custom Helm Repository
1. Navigate to **Apps** → **Repositories** → **Create**
2. Select **Target**: "Git repository containing Helm chart or cluster template definitions"
3. Configure repository:
   - **Git Repo URL**: `https://github.com/WebberHuang1118/rancher-charts.git`
   - **Git Branch**: `v2.10-bump-harvester-csi-driver-0.1.25-trial`

### 4.2 Update via Rancher UI
1. Go to **Apps** → **Charts**
2. Search for "Harvester"
3. Select the newly added "Harvester CSI Driver" chart
4. Update to version "105.0.4+up0.1.25"
5. Verify the installation completes successfully

## Troubleshooting

- **Chart packaging fails**: Verify Chart.yaml syntax and dependencies
- **Helm upgrade fails**: Check cluster permissions and resource constraints  
- **Rancher UI doesn't show updates**: Refresh repository cache or check branch name
- **Rollback issues**: Ensure previous revision exists in helm history