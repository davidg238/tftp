# Copyright (C) 2023 Kasper Lund.

CHIP   = esp32
JAGUAR = $(HOME)/.cache/jaguar

.PHONY: firmware
firmware: build/firmware.envelope

.PHONY: clean
clean:
	rm -rf build

#############################################################################

build/firmware.envelope: build/app.snapshot
build/firmware.envelope: $(JAGUAR)/assets/firmware-$(CHIP).envelope
	mkdir -p $(dir $@)
	cp $< $@
	$(JAGUAR)/sdk/tools/firmware -e $@ container install app build/app.snapshot

.PHONY: build/app.snapshot
build/app.snapshot: client.toit
	mkdir -p $(dir $@)
	$(JAGUAR)/sdk/bin/toit.compile -w $@ $<


#  artemis device update -d 5acabd50-fa5f-8fc3-5179-39b1e13da06d --specification device.json
#  artemis device update --device-id 5acabd50-fa5f-8fc3-5179-39b1e13da06d --specification device.json