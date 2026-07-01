FROM nvcr.io/nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04

WORKDIR /space

# install dependencies
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git cmake build-essential patch wget ca-certificates \
      python3 python3-pip \
      libblas-dev liblapack-dev libgl1-mesa-dev \
      libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev \
      libhdf5-serial-dev vulkan-tools \
 && rm -rf /var/lib/apt/lists/*

# install python dependencies
RUN pip install --no-cache-dir numpy meshio open3d h5py

CMD ["/bin/bash"]
