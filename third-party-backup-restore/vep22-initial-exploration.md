# VEP#22 Analysis: Storage Agnostic Incremental Backup Using QEMU

## Overview

This document provides an initial exploration of VEP#22 (Storage agnostic incremental backup using QEMU) from KubeVirt and compares it with existing backup/restore solutions for Harvester. Since VEP#22 is still in the proposal phase, this analysis serves as a preliminary assessment of its potential integration as another backup/restore engine within Harvester's built-in solution.

## VEP#22 Reference

- **Design Details**: [VEP#22 Storage agnostic incremental backup using qemu](https://github.com/kubevirt/enhancements/blob/main/veps/sig-storage/incremental-backup.md)
- **Enhancement Proposal**: Storage agnostic incremental backup using QEMU
- **Target Versions**: Alpha → v1.7.0, Beta → v1.9.0, GA → v1.12.0 (still not determined)

## VEP#22 vs Harvester VM Backup/Restore

### Pros

- **VM-Centric Backup**: Focuses specifically on virtual machine backup operations
- **Incremental Backup Support**: 
  - Leverages QEMU Changed Block Tracking (CBT) and checkpoint functionality
  - Reduces backup time and storage requirements through incremental snapshots
- **Synchronization Handling**: Provides coordinated handling among:
  - VM backup operations
  - VM state interruption
  - VM crash scenarios  
  - VM migration events
- **Data Consistency**: FSFreeze command is issued to ensure file system consistency during backup operations

### Cons

- **VM Restart Requirement**: VM restart is required to enable CBT and checkpoint functionality
  - Necessary for adding QCOW2 overlay to existing disks
  - Impacts production availability during initial setup
- **No Offline Backup Support**: Does not support backing up stopped/offline VMs
- **No VM Restore API**: 
  - VM disks are backed up as QCOW2 files in incremental manner and stored in filesystem mode PVC
  - Requires manual use of qemu-img to merge incremental backups with base full image
  - Must flatten backup images to raw format and store in PVC for restored VM
  - Complex process to rebase incremental images

## Comparison Analysis

This section compares three backup/restore approaches:
1. **Existing Third-Party Solution**: Velero (as example) - [Reference](https://harvesterhci.io/kb/2025/05/26/velero-backup-restore)
2. **Proposed Built-in Solution**: Harvester native backup/restore - [Reference](https://github.com/WebberHuang1118/harvester-study/blob/master/third-party-backup-restore/third-party-backup-restore.md)
3. **VEP#22**: KubeVirt storage agnostic incremental backup

| Feature/Aspect | Existing Third-Party Solution (Velero) | Proposed Built-in Solution | VEP#22 (KubeVirt) |
|---|---|---|---|
| **Data Consistency Support** | ❌ No support or complex hook mechanism | ✅ Issues filesystem freeze to ensure application-consistent backups | ✅ Issues filesystem freeze to ensure application-consistent backups |
| **VM Restart Required** | ✅ No restart required | ✅ No restart required | ❌ Yes, required for adding QCOW2 overlay |
| **Offline VM Backup Support** | ✅ Supports offline VM backup | ✅ Supports offline VM backup | ❌ No offline backup support |
| **Granular Control** | ❌ Not optimized for per-VM operations | ✅ Per-VM backup and restore capabilities | ⚠️ Per-VM backup but no restore API (manual restore required) |
| **Storage Migration Support** | ❌ Typically requires same storage class for backup and restore | ✅ Cross-storage-class restore capabilities | ✅ Cross-storage-class restore capabilities |
| **Harvester Native Integration** | ❌ General-purpose design not optimized for Harvester<br>❌ Harder to customize for specific requirements | ✅ VM-related resources and manifest sanitization support<br>✅ Deep integration with Harvester ecosystem | ❌ General-purpose design not optimized for Harvester<br>❌ Harder to customize for specific requirements |
| **Maturity** | ✅ Mature codebase with proven stability<br>✅ Large user base and active development | ⚠️ New solution requiring development | ⚠️ New solution from KubeVirt<br>⚠️ Timeline: Alpha → v1.7.0, Beta → v1.9.0, GA → v1.12.0 |

### Legend
- ✅ **Supported/Advantage**: Feature is well-supported or provides clear benefits
- ❌ **Not Supported/Disadvantage**: Feature is not available or presents significant limitations  
- ⚠️ **Partial/Conditional**: Feature has limitations or conditional support

## Personal Perspective: VEP#22 as Additional Backup/Restore Engine

### Integration Approach

VEP#22 could be wrapped as another backup/restore engine within Harvester's built-in solution architecture:

#### Rationale
- **General-Purpose Design**: Since VEP#22 is designed as a general-purpose solution for KubeVirt VMs, additional control paths are still needed to handle:
  - Harvester-specific resources
  - Custom annotations and labels
  - Manifest sanitization requirements

#### Implementation Strategy
- **Common Abstraction Layer**: Extend the backup/restore abstraction layer to accommodate KubeVirt QEMU-based solutions
  - Example: Introduce "kubevirt-cbt" as a new backup/restore engine option
- **Proven Control Flow**: Maintain the same established control flow as Harvester's current VM backup implementation
- **Continuous Improvements**: Leverage ongoing resilience improvements since v0.3.0

### Implementation Roadmap

Given the current development timeline and VEP#22's proposal status, we can maintain flexibility in our backup/restore abstraction layer implementation:

- **Parallel Development Strategy**: We can proceed with the current plan for the backup/restore abstraction layer while keeping options open for multiple implementations
- **Implementation Choices**: Based on VEP#22's development progress, we can choose to implement:
  - A restic-based solution for immediate functionality
  - A KubeVirt CBT implementation following VEP#22's maturation
  - Both implementations in parallel during early/experimental stages to evaluate effectiveness
- **Timeline Flexibility**: This approach allows us to adapt our implementation strategy based on real-world feedback and VEP#22's actual delivery timeline
