# Harvester Study Notes and Records

## Overview
This repository serves as a collection of notes, records, and examples related to studying and working with Harvester. It includes various subfolders, each dedicated to a specific topic or feature of Harvester. Currently, it contains examples for volume online resizing and PVC annotation with CSI creation flow, but more topics may be added in the future.

## Table of Contents
- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Usage](#usage)
- [Contributing](#contributing)
- [License](#license)

## Prerequisites
- A running Harvester cluster.
- Access to the relevant Harvester commits or pull requests as needed for specific examples.
- Basic knowledge of Kubernetes and YAML configuration files.

## Project Structure
- `volume-online-resize/`: Contains examples and documentation for resizing volumes online in Harvester.
  - `README.md`: Documentation for the volume online resize process.
  - `lh-pvc-block.yaml`: YAML configuration for block mode PVC.
  - `lh-pvc-fs.yaml`: YAML configuration for filesystem mode PVC.
  - `lh-pvc-fs-rwx.yaml`: YAML configuration for filesystem mode PVC with ReadWriteMany access mode.
  - `lh-pvc-fs-rwx-pod.yaml`: YAML configuration for a pod using a filesystem mode PVC with ReadWriteMany access mode.
  - `lh-rwx-sc.yaml`: YAML configuration for a storage class with ReadWriteMany access mode.
- `pvc-ann-with-creation-flow/`: Contains documentation for PVC annotation with CSI creation flow.
  - `README.md`: Documentation for the PVC annotation and CSI creation flow process.
- `topolvm/`: Contains examples and documentation for TopoLVM configurations.
  - `README.md`: Documentation for TopoLVM usage.
  - `blk-pod.yaml`: YAML configuration for a pod using block mode PVC.
  - `blk-pvc.yaml`: YAML configuration for block mode PVC.
  - `fs-pod.yaml`: YAML configuration for a pod using filesystem mode PVC.
  - `fs-pvc.yaml`: YAML configuration for filesystem mode PVC.
  - `sc.yaml`: YAML configuration for a storage class.

## Usage
1. Navigate to the directory of the topic you want to explore. For example, to explore volume online resizing:
   ```bash
   cd volume-online-resize
   ```

   Or to explore PVC annotation with CSI creation flow:
   ```bash
   cd pvc-ann-with-creation-flow
   ```

2. Follow the instructions in the `README.md` file within the respective directory to apply configurations or test features.

## Contributing
Feel free to submit issues or pull requests to expand this repository with additional topics, examples, or improvements.

## License
This project is licensed under the [MIT License](LICENSE).