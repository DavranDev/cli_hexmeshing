# build evocube
cd /space/evocube
mkdir -p build
cd build
cmake ..
make -j8 all

# link vulkan sdk and libtorch
export Torch_DIR='/space/lib/libtorch/share/cmake/Torch/'
# enable libtorch first, then vulkan
source /space/lib/vulkan-sdk-1.3.268.0/setup-env.sh

# build interactive-hex-meshing
cd /space/interactive-hex-meshing
mkdir -p build/Release
cd build/Release
cmake ../.. -DCMAKE_BUILD_TYPE=Release -DTorch_DIR="$Torch_DIR"
make -j8 all

# the container
cd /space
