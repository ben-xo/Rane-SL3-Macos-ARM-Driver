CC = clang
ARCH = -arch arm64 -arch x86_64
VERSION ?= $(shell tr -d '[:space:]' < VERSION)
CFLAGS = -fobjc-arc -O2 -mmacosx-version-min=12.0 -DSL3_VERSION=\"$(VERSION)\"
# make plugin DEBUG=1 builds the driver with its streaming diagnostics and its debug commands
# (tools/latency/bin/sl3dbg: test hooks); make install DEBUG=1 also installs it
PLUGIN_DEFS = $(if $(DEBUG),-DSL3_DEBUG=1)

all: plugin api panel dump flash controlpanel

plugin:
	$(CC) $(ARCH) -bundle $(CFLAGS) $(PLUGIN_DEFS) -framework Foundation -framework CoreAudio -framework IOKit -framework IOUSBHost plugin/SL3Device.m -o SL3Device

# build the driver and install it into the installed driver bundle, then restart coreaudiod
# (tools/install-sl3.sh; asks for your password). The release package must be installed first.
# make install DEBUG=1 installs a debug build; make install puts a release build back.
install: plugin
	sudo tools/install-sl3.sh

api:
	$(CC) $(ARCH) -dynamiclib $(CFLAGS) -install_name /Library/Frameworks/Sl3Api.framework/Versions/A/Sl3Api -current_version $(VERSION) -compatibility_version 1.0.0 -framework Foundation -framework CoreAudio -framework IOKit tools/Sl3Api.m -o Sl3Api

panel:
	$(CC) $(ARCH) $(CFLAGS) -framework Foundation -framework CoreAudio -framework IOKit -Itools tools/sl3panel.m tools/SL3Passthrough.m -o sl3panel

dump:
	$(CC) $(ARCH) $(CFLAGS) -Itools -framework Foundation -framework CoreAudio tools/sl3dump.m tools/SL3Passthrough.m -o sl3dump

flash:
	$(CC) $(ARCH) $(CFLAGS) -Itools -framework Foundation -framework CoreAudio -framework IOKit -framework IOUSBHost tools/firmware/sl3flash.m tools/SL3Passthrough.m -o sl3flash

# SL 3 Control Panel.app (SwiftUI, universal), in the repository root
controlpanel:
	tools/controlpanel/build-app.sh

# the installer package and download zip, built into build/ (VERSION=x.y.z, default from VERSION)
package:
	Installer/build-pkg.sh $(VERSION)

# sl3apitest: checks Sl3Api as Serato DJ Pro 2.5.5 uses it (run the x86_64 slice with arch -x86_64)
apitest:
	$(CC) $(ARCH) -O2 tools/sl3apitest.c -o sl3apitest

# latency and glitch test tools (tools/latency/README.md), built into tools/latency/bin
LATENCY_TOOLS = rtlat sinetest chtone chrec devprobe setrate sl3dbg volctl meters
latency: $(addprefix tools/latency/bin/,$(LATENCY_TOOLS))

tools/latency/bin/%: tools/latency/%.c tools/latency/common.h
	@mkdir -p tools/latency/bin
	$(CC) -O2 -framework CoreAudio -framework CoreFoundation -framework AudioToolbox $< -o $@

# the hardware tests in one run (tools/hwtest.sh), on the installed driver with a box attached
# (install a debug build first, make install DEBUG=1, to also run the debug-only tests):
#   make hwtest ARGS="--loopback"   with the loopback cable in (Left Deck Out L to In L); add
#                                   --no-physical to skip the steps that need someone at the box
#                                   (each deck's LINE/PHONO switch, unplug and replug)
hwtest: panel apitest latency
	tools/hwtest.sh $(ARGS)

clean:
	rm -f SL3Device Sl3Api sl3panel sl3apitest sl3dump sl3flash
	rm -rf tools/latency/bin "SL 3 Control Panel.app" build

.PHONY: all plugin install api panel dump flash controlpanel package apitest latency hwtest clean
