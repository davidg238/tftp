// Copyright 2022, 2023 Ekorau LLC

import device show hardware-id
import gpio
import i2c


import gpio.adc show Adc
import esp32
import math show pow


// Specific for ezSBC Feather.  https://github.com/EzSBC/ESP32_Feather
BATTERY-VOLTAGE ::= 35
BATTERY-SENSE ::= 2
RED-LED ::= 13
RETRIES ::= 5

// Assignable.
WAKEUP-PIN ::= 32  // Use a pull-down resistor to pull pin 32 to ground.

class ESP32Feather:

  rled := gpio.Pin RED-LED --output
  battery-adc/Adc := Adc (gpio.Pin BATTERY-VOLTAGE)
  battery-sense-pin := gpio.Pin BATTERY-SENSE --output  
  bus/i2c.Bus? := null


  on:
    bus = i2c.Bus
      --sda=gpio.Pin 21
      --scl=gpio.Pin 22
    
    // init_wakeup_pin
    battery-sense-off
    print ".... ezSBC Feather $short-id started"

  off:

  add-i2c-device address/int -> i2c.Device:
    return bus.device address

  red-on -> none:
    rled.set 0
  red-off -> none:
    rled.set 1

  short-id -> string:
    return (hardware-id.stringify)[24..]

  battery-voltage -> float:
    battery-sense-on
    sleep --ms=100
    voltage := battery-adc.get  // battery_voltage_pin.get
    battery-sense-off
    return voltage*2.0

  battery-sense-on -> none:
    battery-sense-pin.set 1

  battery-sense-off -> none:
    battery-sense-pin.set 0

  blink --on=250 --off=1000 -> none:
    red-on
    sleep --ms=on
    red-off
    sleep --ms=off

init-wakeup-pin:
  pin := gpio.Pin WAKEUP-PIN
  mask := 0
  mask |= 1 << pin.num
  esp32.enable-external-wakeup mask true

//  https://github.com/EzSBC/ESP32_Feather/blob/main/ESP32_Feather_Vbat_Test.ino

/*
  raw_voltage -> float:
    battery_sense_pin.set 1
    sleep --ms=100
    voltage := voltage battery_adc  // battery_voltage_pin.get
    battery_sense_pin.set 0
    return voltage

  battery_voltage -> float:
    battery_sense_pin.set 1
    sleep --ms=10
    x := 7600.0
    10.repeat:
      x = x + 200* (voltage battery_adc)// (voltage battery_voltage_pin)
    x = 0.9*x + 200* (voltage battery_adc)// (voltage battery_voltage_pin)
    battery_sense_pin.set 0
    return x/2.0

    voltage adc/Adc -> float:
    reading := adc.get // Reference voltage is 3v3 so maximum reading is 3v3 = 4095 in range 0 to 4095
    if reading < 1 or reading > 4095:
      return 0.0
  // Return the voltage after fixin the ADC non-linearity
    return linearize reading

  linearize reading/float -> float:
    return -0.000000000000016*(pow reading 4) + 0.000000000118171*(pow reading 3 ) - 0.000000301211691*(pow reading 2) + 0.001109019271794*reading + 0.034143524634089

  */  



