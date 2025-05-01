FROM nvcr.io/nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04

WORKDIR /space

# install dependencies
RUN apt update
RUN apt install -y git cmake build-essential python3 python3-pip
RUN apt install -y libblas-dev liblapack-dev libgl1-mesa-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev
RUN apt install -y libhdf5-serial-dev
RUN apt install -y vulkan-tools

# install python dependencies
RUN pip install numpy meshio open3d h5py

CMD ["/bin/bash"]