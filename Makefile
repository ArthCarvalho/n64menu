V=1
SOURCE_DIR=src
BUILD_DIR=build
include $(N64_INST)/include/n64.mk

sc64: m64menu.z64
	@cp $< sc64menu.n64
.PHONY: sc64

all: m64menu.z64 sc64
.PHONY: all
 
OBJS = $(BUILD_DIR)/main.o \
$(BUILD_DIR)/boot/cic.o \
$(BUILD_DIR)/boot/boot.o \
$(BUILD_DIR)/boot/reboot.o \
$(BUILD_DIR)/flashcart/64drive/64drive_ll.o \
$(BUILD_DIR)/flashcart/64drive/64drive.o \
$(BUILD_DIR)/flashcart/flashcart_utils.o \
$(BUILD_DIR)/flashcart/flashcart.o \
$(BUILD_DIR)/flashcart/sc64/sc64_ll.o \
$(BUILD_DIR)/flashcart/sc64/sc64.o \
$(BUILD_DIR)/utils/fs.o

m64menu.z64: N64_ROM_TITLE="M64 Menu"
m64menu.z64: $(BUILD_DIR)/spritemap.dfs

$(BUILD_DIR)/spritemap.dfs: $(wildcard filesystem/*)
$(BUILD_DIR)/m64menu.elf: $(OBJS)

clean:
	rm -f $(BUILD_DIR)/* *.z64
.PHONY: clean

-include $(wildcard $(BUILD_DIR)/*.d)