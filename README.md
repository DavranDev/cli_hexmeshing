# Instructions on setting up the environment for EvoCube and Interactive-All-HexMesh
Authors: lyq@tamu.edu, xinli@tamu.edu

## NVIDIA-Docker

### 1 Install Docker
```
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
	sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
	sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
```
```
sed -i -e '/experimental/ s/^#//g' /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
```
Reference: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html

### 2 Configuration
```
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

### 3 Test Docker (Optional)
```
sudo docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi
```

## Build the environment
### 1 Clone the repository
```
git clone –recursive git@github.com:xmlyqing00/AutoHexMesh.git
```

### 2 Setup the host environment
```
sh setup.sh
```

CUDA container Reference: https://catalog.ngc.nvidia.com/orgs/nvidia/containers/cuda/tags 

### 3 Start the Docker container
```
sh run_docker.sh
```

### 4 Resume the container
```
sh attach [container id]
```
