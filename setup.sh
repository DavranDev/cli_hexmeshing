sudo apt install zip tar

# download the libraries
wget https://download.pytorch.org/libtorch/cu124/libtorch-cxx11-abi-shared-with-deps-2.6.0%2Bcu124.zip
unzip libtorch-cxx11-abi-shared-with-deps-2.6.0+cu124.zip
mv libtorch lib/libtorch

wget https://sdk.lunarg.com/sdk/download/1.3.268.0/linux/vulkansdk-linux-x86_64-1.3.268.0.tar.xz
tar -xvf vulkansdk-linux-x86_64-1.3.268.0.tar.xz
mv 1.3.268.0 lib/vulkan-sdk-1.3.268.0

# clone the code
git clone --recursive https://github.com/LIHPC-Computational-Geometry/evocube.git
git clone --recursive https://github.com/lingxiaoli94/interactive-hex-meshing.git

# build the docker image
sudo docker build -t docker-hexmesh .

# host install vulkan support 
sudo apt install vulkan-tools

# enable GUI program
xhost +local:root
