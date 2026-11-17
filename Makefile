CC = clang
ARCH = -arch arm64 -arch x86_64
CFLAGS = -fobjc-arc -O2 -mmacosx-version-min=12.0

all: plugin api panel

plugin:
	$(CC) $(ARCH) -bundle $(CFLAGS) -framework Foundation -framework CoreFoundation -framework CoreAudio -framework IOKit -framework IOUSBHost plugin/SL3Device.m -o SL3Device

api:
	$(CC) $(ARCH) -dynamiclib $(CFLAGS) -install_name /Library/Frameworks/Sl3Api.framework/Versions/A/Sl3Api -framework Foundation -framework CoreAudio -framework IOKit tools/Sl3Api.m -o Sl3Api

panel:
	$(CC) $(ARCH) $(CFLAGS) -framework Foundation -framework IOKit -framework IOUSBHost tools/sl3panel.m -o sl3panel

clean:
	rm -f SL3Device Sl3Api sl3panel

.PHONY: all plugin api panel clean
