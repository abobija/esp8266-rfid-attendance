--
-- ******************************************************
-- *
-- * Title: RFID Based Attendance System (WiFi ESP8266)
-- * Author: Alija Bobija
-- *
-- * https://github.com/abobija/esp8266-rfid-attendance
-- *
-- ******************************************************

require "RC522"

WorkTime = {
    LED_BLUE  = 4,
    LED_GREEN = 0,
    LED_RED   = 2,
	
	NodeJsServer = '192.168.0.163',  -- Location of deployed NodeJS server
	StationSsid  = 'MyWifi',         -- Name of your wifi network
	StationPwd   = '12345678'        -- Pasword of your wifi network
};

WorkTime.init = function()
    gpio.mode(WorkTime.LED_RED, gpio.OUTPUT)
    gpio.write(WorkTime.LED_RED, gpio.LOW)
    
    gpio.mode(WorkTime.LED_BLUE, gpio.OUTPUT)
    gpio.write(WorkTime.LED_BLUE, gpio.HIGH)
    
    gpio.mode(WorkTime.LED_GREEN, gpio.OUTPUT)
    gpio.write(WorkTime.LED_GREEN, gpio.LOW)

    WorkTime.blueLedBlink = tmr.create()

    WorkTime.blueLedBlink:register(125, tmr.ALARM_AUTO, function(t)
        local state = gpio.read(WorkTime.LED_BLUE)
    
        if state == 1 then
            gpio.write(WorkTime.LED_BLUE, gpio.LOW)
        else
            gpio.write(WorkTime.LED_BLUE, gpio.HIGH)
        end
    end)
end

isRC522Inited = false

WorkTime.init()
WorkTime.blueLedBlink:start()

-- PiezoBuzzer tone pwm
pwm.setup(1, 1000, 128)

beepTimer = tmr.create()

beepCount = 1

beepTimer:register(100, tmr.ALARM_SEMI, function(t)
    pwm.stop(1)

    beepCount = beepCount - 1

    if beepCount > 0 then
        pwm.start(1)
        beepTimer:start()
    end
end)

function makeSuccessBeep(times, interval)
    beepCount = times
    beepTimer:interval(interval)
    pwm.setclock(1, 1000)
    pwm.setduty(1, 400)
    pwm.start(1)
    beepTimer:start()
end

function makeErrorBeep()
    beepCount = 1
    beepTimer:interval(1000)
    pwm.setclock(1, 300)
    pwm.setduty(1, 400)
    pwm.start(1)
    beepTimer:start()
end

busyTimer = tmr.create()

-- Welcome beep
makeSuccessBeep(1, 250)

function initRC522()
    -- Initialise the RC522
    spi.setup(1, spi.MASTER, spi.CPOL_LOW, spi.CPHA_LOW, spi.DATABITS_8, 0)
    
    gpio.mode(pin_ss, gpio.OUTPUT)
    gpio.write(pin_ss, gpio.HIGH)       -- needs to go LOW during communications

    RC522.dev_write(0x01, mode_reset)   -- soft reset
    RC522.dev_write(0x2A, 0x8D)         -- Timer: auto; preScaler to 6.78MHz
    RC522.dev_write(0x2B, 0x3E)         -- Timer 
    RC522.dev_write(0x2D, 30)           -- Timer
    RC522.dev_write(0x2C, 0)            -- Timer
    RC522.dev_write(0x15, 0x40)         -- 100% ASK
    RC522.dev_write(0x11, 0x3D)         -- CRC initial value 0x6363
    
    -- turn on the antenna
    current = RC522.dev_read(reg_tx_control)
    
    if bit.bnot(bit.band(current, 0x03)) then
        RC522.set_bitmask(reg_tx_control, 0x03)
    end
    
    print("RC522 Firmware Version: 0x"..string.format("%X", RC522.getFirmwareVersion()))
    
    tmr.alarm(0, 250, tmr.ALARM_AUTO, function()
        -- Because after tag is sent successfully to server
        -- we was set interval a little bit longer to prevent multiple
        -- http requests in short time.
        -- Now we must revert prevoius timer period
        tmr.interval(0, 250)
        gpio.write(WorkTime.LED_GREEN, gpio.LOW)
        gpio.write(WorkTime.LED_RED, gpio.LOW)
        
        isTagNear, cardType = RC522.request()
        
        if isTagNear == true then
            tmr.stop(0)
            err, serialNo = RC522.anticoll()

            -- Valid Tag is 5 byte length
            if table.getn(serialNo) == 5 then
                print("Tag Found: "..appendHex(serialNo).."  of type: "..appendHex(cardType))

                print("Sending http request")

                gpio.write(WorkTime.LED_BLUE, gpio.LOW)
                
                http.post('http://' .. WorkTime.NodeJsServer,
                    'ChipId: ' .. node.chipid() .. '\r\n'
                    .. 'RfidTag: ' .. appendHex(serialNo) .. '\r\n'
                    ..'Content-Length: 0' .. '\r\n',
                    nil,
                    function(code, data)
                        gpio.write(WorkTime.LED_BLUE, gpio.HIGH)
                    
                        if(code < 0) then
                            print('Http request failed')
                        else
                            print(code, data)

                            if code == 200 then
                                gpio.write(WorkTime.LED_GREEN, gpio.HIGH)
                                makeSuccessBeep(2, 100)
                            else
                                gpio.write(WorkTime.LED_RED, gpio.HIGH)
                                makeErrorBeep()
                            end
                        end

                        -- Start scanning rfid tags again after http response was return
                        -- And some time is elapsed. This will prevent multiple
                        -- http request sending in short perion
                        tmr.interval(0, 2500)
                        tmr.start(0)
                    end
                )
            else
                tmr.start(0)
            end
            
            -- halt tag and get ready to read another.
            buf = {}
            buf[1] = 0x50  --MF1_HALT
            buf[2] = 0
            crc = RC522.calculate_crc(buf)
            table.insert(buf, crc[1])
            table.insert(buf, crc[2])
            err, back_data, back_length = RC522.card_write(mode_transrec, buf)
            RC522.clear_bitmask(0x08, 0x08)    -- Turn off encryption
        else 
         --print("NO TAG FOUND")
        end
    end)
end

wifi.setmode(wifi.STATION)

wifi.sta.sethostname("WorkTimeNode")

wifi.sta.config({
    ssid = WorkTime.StationSsid,
    pwd  = WorkTime.StationPwd,
    auto = false
})

wifi.eventmon.register(wifi.eventmon.STA_CONNECTED, function(t)
    print("STA connected to " .. t.SSID)
end)

wifi.eventmon.register(wifi.eventmon.STA_GOT_IP, function(t)
    WorkTime.blueLedBlink:stop()
    gpio.write(WorkTime.LED_BLUE, gpio.HIGH)
    print("Got ip " .. t.IP .. " " .. t.netmask .. " " .. t.gateway)
    
    if isRC522Inited == false then
        isRC522Inited = true
        initRC522()
    end
end)

wifi.eventmon.register(wifi.eventmon.STA_DISCONNECTED, function(t)
    WorkTime.blueLedBlink:start()
end)

wifi.sta.connect()
