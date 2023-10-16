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
  board.red-on
  bme := bme280.Driver (board.add-i2c-device 0x77)

  temp-ring := RingStore "temp" 96
  hum-ring := RingStore "hum" 96
  press-ring := RingStore "press" 96

  temp := (bme.read-temperature) * 9/5 + 32
  temp-ring.append temp
  hum := bme.read-humidity
  hum-ring.append hum
  press := bme.read-pressure/100
  press-ring.append press
  voltage := board.battery-voltage

  tmin := temp-ring.minimum
  tmax := temp-ring.maximum
  hmin := hum-ring.minimum
  hmax := hum-ring.maximum
  pmin := press-ring.minimum
  pmax := press-ring.maximum

  print "Publishing via TFTP to $SERVER:8080.  Temperature: $(%.1f temp), Humidity: $(%.1f hum), Pressure: $(%.1f press), Voltage: $(%.3f voltage)"
  // temperature in C, humidity in %, pressure in hPa

//  print (html temp hum press voltage)

  client := TFTPClient --host=SERVER

  client.open
  result := client.write-string (html tmin temp tmax hmin hum hmax pmin press pmax voltage) --filename="index.html"
  print "Write msg, result: $result"
  client.close
  board.red-off

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
              <td>$tmin.to-int</td>
              <td>$temp.to-int</td>
              <td>$tmax.to-int</td>
            </tr>
            <tr>
              <td>Humidity</td>
              <td>$hmin.to-int</td>
              <td>$hum.to-int</td>
              <td>$hmax.to-int</td>
            </tr>
            <tr>
              <td>Pressure</td>
              <td>$pmin.to-int</td>
              <td>$press.to-int</td>
              <td>$pmax.to-int</td>
            </tr>
          </tbody>
        </table>
        <p>(Measured every 7.5 minutes, min/max over last 12 hour period)</p>
        <h2>$(Time.now.plus --h=-7) Battery Voltage: $(%.3f voltage)</h2>
      </body>
    </html>
    """