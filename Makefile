CC = clang
ARCH = -arch arm64 -arch x86_64
VERSION ?= $(shell tr -d '[:space:]' < VERSION)
CFLAGS = -fobjc-arc -O2 -mmacosx-version-min=12.0 -DSL3_VERSION=\"$(VERSION)\"
# make plugin DEBUG=1 builds the driver with its streaming diagnostics and its debug commands
# (tools/latency/bin/sl3dbg: test hooks); make install DEBUG=1 also installs it
PLUGIN_DEFS = $(if $(DEBUG),-DSL3_DEBUG=1)

all: plugin api panel

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

# sl3apitest: checks Sl3Api as Serato DJ Pro 2.5.5 uses it (run the x86_64 slice with arch -x86_64)
apitest:
	$(CC) $(ARCH) -O2 tools/sl3apitest.c -o sl3apitest

# latency and glitch test tools (tools/latency/README.md), built into tools/latency/bin
LATENCY_TOOLS = rtlat sinetest chtone chrec devprobe setrate sl3dbg volctl meters
latency: $(addprefix tools/latency/bin/,$(LATENCY_TOOLS))

tools/latency/bin/%: tools/latency/%.c tools/latency/common.h
	@mkdir -p tools/latency/bin
	$(CC) -O2 -framework CoreAudio -framework CoreFoundation -framework AudioToolbox $< -o $@

clean:
	rm -f SL3Device Sl3Api sl3panel sl3apitest
	rm -rf tools/latency/bin

.PHONY: all plugin install api panel apitest latency clean
