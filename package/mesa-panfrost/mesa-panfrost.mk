################################################################################
#
# mesa-panfrost
#
################################################################################

MESA_PANFROST_VERSION = $(MESA3D_VERSION)
MESA_PANFROST_SOURCE = $(MESA3D_SOURCE)
MESA_PANFROST_SITE = $(MESA3D_SITE)
MESA_PANFROST_DL_SUBDIR = mesa3d
MESA_PANFROST_LICENSE = $(MESA3D_LICENSE)
MESA_PANFROST_LICENSE_FILES = $(MESA3D_LICENSE_FILES)
MESA_PANFROST_DEPENDENCIES = \
	host-bison \
	host-flex \
	host-mesa3d \
	host-python-glslang \
	host-python-mako \
	host-python-pyyaml \
	expat \
	libdrm \
	zlib

# lib/mesa keeps its libEGL and friends apart from libmali's, and makes
# /usr/lib/mesa its GBM backend path. The shaders are precompiled on the host.
MESA_PANFROST_CONF_OPTS = \
	--libdir=lib/mesa \
	-Dplatforms= \
	-Dgallium-drivers=panfrost \
	-Dvulkan-drivers=panfrost \
	-Dvulkan-icd-dir=/usr/lib/mesa/vulkan/icd.d \
	-Dmesa-clc=system \
	-Dprecomp-compiler=system \
	-Dllvm=disabled \
	-Degl=enabled \
	-Dgbm=enabled \
	-Dgles1=enabled \
	-Dgles2=enabled \
	-Dglx=disabled \
	-Dglvnd=disabled \
	-Dgallium-va=disabled \
	-Dmicrosoft-clc=disabled \
	-Dvideo-codecs= \
	-Ddisplay-info=disabled \
	-Dzstd=disabled \
	-Dvalgrind=disabled \
	-Dlibunwind=disabled \
	-Dlmsensors=disabled
MESA_PANFROST_LDFLAGS = $(TARGET_LDFLAGS) -Wl,-rpath=/usr/lib/mesa

# Only usr/lib/mesa: its headers and pkg-config files would clash with
# libmali's. libmali.so.1 and libmali_hook.so.1 stand in for libmali's, so
# what links them resolves the same symbols from Mesa.
define MESA_PANFROST_INSTALL_TARGET_CMDS
	rm -rf $(@D)/stage $(TARGET_DIR)/usr/lib/mesa
	$(TARGET_MAKE_ENV) $(MESA_PANFROST_NINJA_ENV) DESTDIR=$(@D)/stage \
		$(NINJA) $(NINJA_OPTS) -C $(@D)/buildroot-build install
	cp -a $(@D)/stage/usr/lib/mesa $(TARGET_DIR)/usr/lib/
	rm -rf $(TARGET_DIR)/usr/lib/mesa/pkgconfig
	find $(TARGET_DIR)/usr/lib/mesa -name '*.so' -type l -delete
	echo 'int mali_injected;' | $(TARGET_CC) -shared -x c - \
		-Wl,-soname,libmali_hook.so.1 -o $(TARGET_DIR)/usr/lib/mesa/libmali_hook.so.1
	$(TARGET_CC) -shared -Wl,-soname,libmali.so.1 \
		-Wl,--no-as-needed -Wl,-rpath=/usr/lib/mesa \
		$(addprefix $(TARGET_DIR)/usr/lib/mesa/,libEGL.so.1 libGLESv2.so.2 libGLESv1_CM.so.1 libgbm.so.1) \
		-o $(TARGET_DIR)/usr/lib/mesa/libmali.so.1
endef

# host-mesa3d builds panfrost_compile only for mesa3d's own panfrost. Its
# gallium driver needs bison and flex, ordered by hand as mesa3d.mk is already
# evaluated here; cpp_rtti as in Buildroot master.
HOST_MESA3D_GALLIUM_DRIVERS-y += panfrost
HOST_MESA3D_TOOLS += panfrost
HOST_MESA3D_DEPENDENCIES += host-bison host-flex
$(HOST_MESA3D_TARGET_CONFIGURE): | host-bison host-flex
HOST_MESA3D_CONF_OPTS += -Dcpp_rtti=false
HOST_MESA3D_INSTALL_PANFROST_COMPILE = \
	$(INSTALL) -D -m 0755 $(@D)/buildroot-build/src/panfrost/clc/panfrost_compile \
		$(HOST_DIR)/bin/panfrost_compile

$(eval $(meson-package))
