----------------------------------------------------------------
-- RC522 RFID Reader for NodeMCU LUA
-- By Ben Jackson

-- This is a port of:
--   https://github.com/ondryaso/pi-rc522        -> Python
--   https://github.com/ljos/MFRC522             -> Arduino

-- to be used with MFRC522 RFID reader and s50 tag (but can work with other tags)

pin_ss = 8                  -- SS (marked as SDA) pin

mode_idle = 0x00
mode_auth = 0x0E
mode_receive = 0x08
mode_transmit = 0x04
mode_transrec = 0x0C
mode_reset = 0x0F
mode_crc = 0x03

auth_a = 0x60
auth_b = 0x61

act_read = 0x30
act_write = 0xA0
act_increment = 0xC1
act_decrement = 0xC0
act_restore = 0xC2
act_transfer = 0xB0

act_reqidl = 0x26
act_reqall = 0x52
act_anticl = 0x93
act_select = 0x93
act_end = 0x50

reg_tx_control = 0x14
length = 16
num_write = 0

authed = false

RC522 = {}
RC522.__index = RC522


--------------------------------------------------------
--  Converts a table of numbers into a HEX string
function appendHex(t)
  strT = ""
  for i,v in ipairs(t) do
    strT = strT.."0x"..string.format("%X", t[i]).." "
  end
  return strT
end

--------------------------------------------------------
--  Writes to a register
--    address    The address of the register
--    value      The value to write to the register
function RC522.dev_write(address, value)
    gpio.write(pin_ss, gpio.LOW)
    num_write = spi.send(1, bit.band(bit.lshift(address,1), 0x7E), value)
    gpio.write(pin_ss, gpio.HIGH)
end

--------------------------------------------------------
--  Reads a register
--    address    The address of the register
-- returns:
--    the byte at the register
function RC522.dev_read(address)
    local val = 0;
    gpio.write(pin_ss, gpio.LOW)
    spi.send(1,bit.bor(bit.band(bit.lshift(address,1), 0x7E), 0x80))
    val = spi.recv(1,1)
    gpio.write(pin_ss, gpio.HIGH)
    return string.byte(val)
end

--------------------------------------------------------
--  Adds a bitmask to a register
--    address    The address of the register
--    mask       The mask to update the register with
function RC522.set_bitmask(address, mask)
    local current = RC522.dev_read(address)
    RC522.dev_write(address, bit.bor(current, mask))
end

--------------------------------------------------------
--  Removes a bitmask from a register
--    address    The address of the register
--    mask       The mask to update the register with
function RC522.clear_bitmask(address, mask)
    local current = RC522.dev_read(address)
    RC522.dev_write(address, bit.band(current, bit.bnot(mask)))
end


--------------------------------------------------------
--  Reads the firmware version
function RC522.getFirmwareVersion()
  return RC522.dev_read(0x37)
end

--------------------------------------------------------
--  Checks to see if there is a TAG in the vacinity
--  Returns false if tag is present, otherwise returns true
function RC522.request()
    req_mode = { 0x26 }   -- find tag in the antenna area (does not enter hibernation)
    err = true
    back_bits = 0

    RC522.dev_write(0x0D, 0x07)         -- bitFramingReg
    err, back_data, back_bits = RC522.card_write(mode_transrec, req_mode)

    if err or (back_bits ~= 0x10) then
        return false, nil
     end

    return true, back_data
end

--------------------------------------------------------
--  Sends a command to a TAG
--    command       The command to the RC522 to send to the commandto the tag
--    data          The data needed to complete the command.  THIS MUST BE A TABLE
--  returns:
--    error          true/false
--    back_data      A table of the returned data (index starting at 1)
--    back_length    The number of bits in the returned data
function RC522.card_write(command, data)
    back_data = {}
    back_length = 0
    local err = false
    local irq = 0x00
    local irq_wait = 0x00
    local last_bits = 0
    n = 0

    if command == mode_auth then
        irq = 0x12
        irq_wait = 0x10
    end
    
    if command == mode_transrec then
        irq = 0x77
        irq_wait = 0x30
    end

    RC522.dev_write(0x02, bit.bor(irq, 0x80))       -- CommIEnReg
    RC522.clear_bitmask(0x04, 0x80)                 -- CommIrqReg
    RC522.set_bitmask(0x0A, 0x80)                   -- FIFOLevelReg
    RC522.dev_write(0x01, mode_idle)                -- CommandReg - no action, cancel the current action

    for i,v in ipairs(data) do
        RC522.dev_write(0x09, data[i])              -- FIFODataReg
    end

    RC522.dev_write(0x01, command)           -- execute the command
                                             -- command is "mode_transrec"  0x0C
    if command == mode_transrec then
        -- StartSend = 1, transmission of data starts
        RC522.set_bitmask(0x0D, 0x80)               -- BitFramingReg
    end

    --- Wait for the command to complete so we can receive data
    i = 25  --- WAS 20000
    while true do
        tmr.delay(1)
        n = RC522.dev_read(0x04)                    -- ComIrqReg
        i = i - 1
        if  not ((i ~= 0) and (bit.band(n, 0x01) == 0) and (bit.band(n, irq_wait) == 0)) then
            break
        end
    end
    
    RC522.clear_bitmask(0x0D, 0x80)                 -- StartSend = 0

    if (i ~= 0) then                                -- Request did not timeout
        if bit.band(RC522.dev_read(0x06), 0x1B) == 0x00 then        -- Read the error register and see if there was an error
            err = false

--            if bit.band(n,irq,0x01) then
--                err = false
--            end
            
            if (command == mode_transrec) then
                n = RC522.dev_read(0x0A)            -- find out how many bytes are stored in the FIFO buffer
                last_bits = bit.band(RC522.dev_read(0x0C),0x07)
                if last_bits ~= 0 then
                    back_length = (n - 1) * 8 + last_bits
                else
                    back_length = n * 8
                end

                if (n == 0) then
                    n = 1
                end 

                if (n > length) then   -- n can't be longer that 16
                    n = length
                end
                
                for i=1, n do
                    xx = RC522.dev_read(0x09)
                    back_data[i] = xx
                end
              end
        else
            err = true
        end
    end

    return  err, back_data, back_length 
end

--------------------------------------------------------
--  Reads the serial number of just one TAG so that it can be identified
--    returns:  
--               error      true/false
--               back_data  the serial number of the tag
function RC522.anticoll()
    back_data = {}
    serial_number = {}

    serial_number_check = 0
    
    RC522.dev_write(0x0D, 0x00)
    serial_number[1] = act_anticl
    serial_number[2] = 0x20

    err, back_data, back_bits = RC522.card_write(mode_transrec, serial_number)
    if not err then
        if table.maxn(back_data) == 5 then
            for i, v in ipairs(back_data) do
                serial_number_check = bit.bxor(serial_number_check, back_data[i])
            end 
            
            if serial_number_check ~= back_data[4] then
                err = true
            end
        else
            err = true
        end
    end
    
    return error, back_data
end

--------------------------------------------------------
--  Uses the RC522 to calculate the CRC of a tabel of bytes
--      Data          Table of bytes to calculate a CRC for
--  returns:  
--      ret_data      Tabel of the CRC values; 2 bytes
function RC522.calculate_crc(data)
    RC522.clear_bitmask(0x05, 0x04)
    RC522.set_bitmask(0x0A, 0x80)               -- clear the FIFO pointer

    for i,v in ipairs(data) do                  -- Write all the data in the table to the FIFO buffer
        RC522.dev_write(0x09, data[i])          -- FIFODataReg
    end
    
    RC522.dev_write(0x01, mode_crc)

    i = 255
    while true do
        n = RC522.dev_read(0x05)
        i = i - 1
        if not ((i ~= 0) and not bit.band(n,0x04)) then
            break
        end
    end

    -- read the CRC result
    ret_data = {}
    ret_data[1] = RC522.dev_read(0x22)
    ret_data[2] = RC522.dev_read(0x21)

    return ret_data
end
