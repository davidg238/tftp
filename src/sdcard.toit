// Copyright 2024 Ekorau LLC

import flash
import gpio 
import spi
import host.file

class SDCard:

  constructor --miso/gpio.Pin --mosi/gpio.Pin --clk/gpio.Pin --cs/gpio.Pin --mount_point/string="/sd":
    bus := spi.Bus
        --miso=miso
        --mosi=mosi
        --clock=clk

    sdcard := flash.Mount.sdcard
        --mount_point=mount_point
        --spi_bus=bus
        --cs=cs

  openw filename -> file.Stream:
    return file.Stream.for_write filename

  openr filename -> file.Stream: 
    return file.Stream.for_read filename