# Ubuntu Environment Build Guide

This guide helps you set up a development environment on Ubuntu with Docker, Tailscale, kubectl, and k9s.

---

## 1. Update System Packages
```sh
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release
```

## 2. Install Docker Engine
1. Add Docker’s official GPG key:
   ```sh
   sudo mkdir -p /etc/apt/keyrings
   curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
     sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
   ```
2. Set up the Docker repository:
   ```sh
   echo \
     "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
     https://download.docker.com/linux/ubuntu \
     $(lsb_release -cs) stable" | \
     sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
   ```
3. Install Docker Engine and related components:
   ```sh
   sudo apt update
   sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
   ```
4. Test Docker installation:
   ```sh
   sudo docker run hello-world
   ```
5. (Optional) Run Docker as a non-root user:
   ```sh
   sudo usermod -aG docker $USER
   newgrp docker
   ```
   > **Note:** You may need to log out and log back in for group changes to take effect.

---

## 3. Install Tailscale
```sh
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

---

## 4. Install kubectl (Kubernetes CLI)
```sh
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

---

## 5. Install k9s (Kubernetes Terminal UI)
```sh
curl -s https://api.github.com/repos/derailed/k9s/releases/latest | \
  grep browser_download_url | \
  grep Linux_amd64.tar.gz | \
  cut -d '"' -f 4 | \
  xargs curl -LO

tar -xzf k9s_Linux_amd64.tar.gz
sudo mv k9s /usr/local/bin/
```

## 6. Install Helm
1. Download the Helm install script:
   ```sh
   curl -O https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
   ```
2. (Optional) Review the script for safety:
   ```sh
   less get-helm-3
   ```
3. Run the install script:
   ```sh
   bash get-helm-3
   ```
4. Verify Helm installation:
   ```sh
   helm version
   ```
> **Note:** If you encounter permission issues, you may need to run the script with `sudo` or move the binary manually.

---

## Notes
- Always review scripts from the internet before running them with `sudo` or piping to `sh`.
- For more details, refer to the official documentation of each tool.
- If you encounter permission issues with Docker, ensure your user is in the `docker` group and restart your session.

---

## References
- [Docker Documentation](https://docs.docker.com/engine/install/ubuntu/)
- [Tailscale Documentation](https://tailscale.com/kb/)
- [Kubernetes kubectl Install Guide](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)
- [k9s Releases](https://github.com/derailed/k9s/releases)


