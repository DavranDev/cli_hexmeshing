
# build evocube
cd /space/evocube
mkdir build
cd build
cmake ..
make -j all

# link vulkan sdk and libtorch
echo "export Torch_DIR='/space/lib/libtorch/share/cmake/Torch/'" >> /root/.bashrc
source /root/.bashrc
# enable libtorch first, then vulkan
cd /space/lib/vulkan-sdk-1.3.268.0/
source ./setup-env.sh

# build interactive-hex-meshing
cd /space/interactive-hex-meshing
mkdir -p build/Release
cd build/Release
cmake ../.. -DCMAKE_BUILD_TYPE=Release
make -j all

# the container
cd /space