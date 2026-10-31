################################################################################
#
# rtl8733bu
#
################################################################################

# zlyme's pin: the next commit needs a 7.1-only API.
RTL8733BU_VERSION = c46aa25e237cb43f33390cf58eee5c69d9b32883
RTL8733BU_SITE = $(call github,Charliechen114514,rtl8733bu-linux-driver,$(RTL8733BU_VERSION))
RTL8733BU_LICENSE = GPL-2.0
RTL8733BU_MODULE_MAKE_OPTS = CONFIG_RTL8733BU=m

$(eval $(kernel-module))
$(eval $(generic-package))
