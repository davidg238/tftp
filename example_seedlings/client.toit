// Copyright 2023 Ekorau LLC

import i2c
import gpio
import bme280

import tftp show TFTPClient RingStore

import .ezsbc show ESP32Feather

SERVER ::= "192.168.0.179"


main:
  // set_timezone "MST7"
  board := ESP32Feather
  board.on
  board.red_on
  bme := bme280.Driver (board.add_i2c_device 0x77)

  temp_ring := RingStore "temp" 96
  hum_ring := RingStore "hum" 96
  press_ring := RingStore "press" 96

  temp := (bme.read_temperature) * 9/5 + 32
  temp_ring.append temp
  hum := bme.read_humidity
  hum_ring.append hum
  press := bme.read_pressure/100
  press_ring.append press
  voltage := board.battery_voltage

  tmin := temp_ring.minimum
  tmax := temp_ring.maximum
  hmin := hum_ring.minimum
  hmax := hum_ring.maximum
  pmin := press_ring.minimum
  pmax := press_ring.maximum

  print "Publishing via TFTP to $SERVER:8080.  Temperature: $(%.1f temp), Humidity: $(%.1f hum), Pressure: $(%.1f press), Voltage: $(%.3f voltage)"
  // temperature in C, humidity in %, pressure in hPa

//  print (html temp hum press voltage)

  client := TFTPClient --host=SERVER

  client.open
  result := client.write_string (html tmin temp tmax hmin hum hmax pmin press pmax voltage) --name="index.html"
  print "Write msg, result: $result"
  client.close
  board.red_off

html tmin/float temp/float tmax/float hmin/float hum/float hmax/float pmin/float press/float pmax/float voltage/float-> string:
  return """
    <!DOCTYPE html>
    <html>
      <head>
        <title>Seedling Hothouse</title>
        <script>
          setTimeout(function(){location.reload()}, 50000);
        </script>
        <style type="text/css" media="screen">
          p {font-size: 20px;}
          table{
          border-collapse:collapse;
          border:1px solid #FF0000;
          }
          table td{
          border:1px solid #FF0000;
          font-size: 36px;
          text-align:center;
          }
        </style>
      </head>
      <body>
        <h1>Temperature/Humidity/Pressure for Seedling</h1>
        <table>
          <thead>
            <tr>
              <th>       </th>
              <th>------ Min ------</th>
              <th>------ Now ------</th>
              <th>------ Max ------</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>Temperature</td>
              <td>$tmin.to_int</td>
              <td>$temp.to_int</td>
              <td>$tmax.to_int</td>
            </tr>
            <tr>
              <td>Humidity</td>
              <td>$hmin.to_int</td>
              <td>$hum.to_int</td>
              <td>$hmax.to_int</td>
            </tr>
            <tr>
              <td>Pressure</td>
              <td>$pmin.to_int</td>
              <td>$press.to_int</td>
              <td>$pmax.to_int</td>
            </tr>
          </tbody>
        </table>
        <p>(Measured every 7.5 minutes, min/max over last 12 hour period)</p>
        <h2>$(Time.now.plus --h=-7) Battery Voltage: $(%.3f voltage)</h2>
      </body>
    </html>
    """