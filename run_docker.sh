# enable GUI program
xhost +local:root

sudo docker run \
--runtime=nvidia \
--gpus all \
-it \
--env="DISPLAY=$DISPLAY" \
--env="NVIDIA_DRIVER_CAPABILITIES=all" \
--env="VULKAN_SDK_ROOT=/space/lib/vulkan-sdk" \
--env="VULKAN_SDK=/space/lib/vulkan-sdk/x86_64" \
--env="VK_LAYER_PATH=/space/lib/vulkan-sdk/x86_64/share/vulkan/explicit_layer.d" \
--env="VK_ADD_LAYER_PATH=/space/lib/vulkan-sdk/x86_64/share/vulkan/explicit_layer.d" \
--env="LD_LIBRARY_PATH=/space/lib/libtorch/lib:/space/lib/vulkan-sdk/x86_64/lib/VulkanLoader/lib:/space/lib/vulkan-sdk/x86_64/lib" \
-v /tmp/.X11-unix:/tmp/.X11-unix:rw \
-v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
-v $(pwd)/lib:/space/lib \
-v $(pwd)/evocube:/space/evocube \
-v $(pwd)/interactive-hex-meshing:/space/interactive-hex-meshing \
-v $(pwd)/compile.sh:/space/compile.sh \
-v $(pwd)/patches:/space/patches:ro \
-v $(pwd)/data:/space/data \
-v $(pwd)/output:/space/output \
docker-hexmesh
