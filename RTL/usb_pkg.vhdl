
library ieee;
use ieee.std_logic_1164.all, ieee.numeric_std.all;

package usb_pkg is

    -- Initialization, handshake, reset.
    component usb_init is
        port (
            CLK :           in  std_logic;          -- 60 MHz UTMI clock
            RESET :         in  std_logic;          -- Synchronous reset
            I_USBRST :      out std_logic;          -- High when bus reset signal detected
            I_HIGHSPEED :   out std_logic;          -- High when attached at high speed
            I_SUSPEND :     out std_logic;          -- High when suspended
            P_CHIRPK :      out std_logic;
            PHY_RESET :     out std_logic;
            PHY_LINESTATE : in  std_logic_vector(1 downto 0);
            PHY_OPMODE :    out std_logic_vector(1 downto 0);
            PHY_XCVRSELECT : out std_logic;
            PHY_TERMSELECT : out std_logic );
    end component usb_init;

    -- Packet-level logic and CRC handling.
    component usb_packet is
        port (
            CLK :           in  std_logic;          -- 60 MHz UTMI clock
            RESET :         in  std_logic;          -- Synchronous reset of this entity
            P_CHIRPK :      in  std_logic;          -- High to force chirp K transmission
            P_RXACT :       out std_logic;          -- High while receiving a packet
            P_RXRDY :       out std_logic;          -- Indicates arrival of a byte
            P_RXFIN :       out std_logic;          -- Indicates successfull completion
            P_RXDAT :       out std_logic_vector(7 downto 0);   -- Received byte value
            P_TXACT :       in  std_logic;          -- High while transmitting a packet
            P_TXRDY :       out std_logic;          -- Request for next data byte
            P_TXDAT :       in  std_logic_vector(7 downto 0);   -- Data byte to transmit
            PHY_DATAIN :    in  std_logic_vector(7 downto 0);
            PHY_DATAOUT :   out std_logic_vector(7 downto 0);
            PHY_TXVALID :   out std_logic;
            PHY_TXREADY :   in  std_logic;
            PHY_RXACTIVE :  in  std_logic;
            PHY_RXVALID :   in  std_logic;
            PHY_RXERROR :   in  std_logic );
    end component usb_packet;

    -- Transaction-level logic.
    component usb_transact is
        port (
            CLK :       in  std_logic;              -- 60 MHz UTMI clock
            RESET :     in  std_logic;              -- Synchronous reset of this entity
            T_IN :      out std_logic;              -- High during IN transactions
            T_OUT :     out std_logic;              -- High during OUT transactions
            T_SETUP :   out std_logic;              -- High during SETUP transactions
            T_PING :    out std_logic;              -- High during PING transactions
            T_FIN :     out std_logic;              -- Indicates successfull completion
            T_ADDR :    in  std_logic_vector(6 downto 0);   -- Device address
            T_ENDPT :   out std_logic_vector(3 downto 0);   -- Endpoint number
            T_NAK :     in  std_logic;              -- Triggers a NAK response to IN/OUT
            T_STALL :   in  std_logic;              -- Triggers a STALL response to IN/OUT
            T_NYET :    in  std_logic;              -- Triggers a NYET response to OUT
            T_SEND :    in  std_logic;              -- High while application has data to send
            T_ISYNC :   in  std_logic;              -- Sync bit to use for IN transactions
            T_OSYNC :   out std_logic;              -- Sync bit used in the OUT transaction
            T_RXRDY :   out std_logic;              -- Indicates arrival of received byte
            T_RXDAT :   out std_logic_vector(7 downto 0);   -- Received data
            T_TXRDY :   out std_logic;              -- Requests next data byte to transmit
            T_TXDAT :   in  std_logic_vector(7 downto 0);   -- Data to transmit
            I_HIGHSPEED : in std_logic;
            P_RXACT :   in  std_logic;
            P_RXRDY :   in  std_logic;
            P_RXFIN :   in  std_logic;
            P_RXDAT :   in  std_logic_vector(7 downto 0);
            P_TXACT :   out std_logic;
            P_TXRDY :   in  std_logic;
            P_TXDAT :   out std_logic_vector(7 downto 0) );
    end component usb_transact;

    -- Default control endpoint.
    component usb_control is
        port (
            CLK :       in  std_logic;              -- 60 MHz UTMI clock
            RESET :     in  std_logic;              -- Synchronous reset of this entity
            C_ADDR :    out std_logic_vector(6 downto 0);   -- Current device address
            C_CONFD :   out std_logic;              -- High when in Configured state
            C_CLRIN :   out std_logic_vector(1 to 2);  -- Trigger clearing of sync bit for IN endpoint
            C_CLROUT :  out std_logic_vector(1 to 2);  -- Trigger clearing of sync bit for OUT endpoint
            C_HLTIN :   in  std_logic_vector(1 to 2);  -- Current status of halt bit for IN endpoint
            C_HLTOUT :  in  std_logic_vector(1 to 2);  -- Current status of halt bit for OUT endpoint
            C_SHLTIN :  out std_logic_vector(1 to 2);  -- Trigger setting of halt bit for IN endpoint
            C_SHLTOUT : out std_logic_vector(1 to 2);  -- Trigger setting of halt bit for OUT endpoint
            C_DSCBUSY : out std_logic;              -- High when accessing descriptor memory
            C_DSCRD :   out std_logic;              -- Descriptor read enable
            C_DSCTYP :  out std_logic_vector(2 downto 0);   -- Requested descriptor type
            C_DSCINX :  out std_logic_vector(7 downto 0);   -- Requested descriptor index
            C_DSCOFF :  out std_logic_vector(7 downto 0);   -- Offset within requested descriptor
            C_DSCLEN :  in  std_logic_vector(7 downto 0);   -- Length of selected descriptor
            C_SELFPOWERED : in std_logic;           -- High if the device is not drawing bus power
            T_IN :      in  std_logic;
            T_OUT :     in  std_logic;
            T_SETUP :   in  std_logic;
            T_PING :    in  std_logic;
            T_FIN :     in  std_logic;
            T_NAK :     out std_logic;
            T_STALL :   out std_logic;
            T_NYET :    out std_logic;
            T_SEND :    out std_logic;
            T_ISYNC :   out std_logic;
            T_OSYNC :   in  std_logic;
            T_RXRDY :   in  std_logic;
            T_RXDAT :   in  std_logic_vector(7 downto 0);
            T_TXRDY :   in  std_logic;
            T_TXDAT :   out std_logic_vector(7 downto 0) );
    end component usb_control;

    -- Serial data transfer core.
    component usb_cdc is
        generic (
            VENDORID :      std_logic_vector(15 downto 0);  -- Vendor ID
            PRODUCTID :     std_logic_vector(15 downto 0);  -- Product ID
            VERSIONBCD :    std_logic_vector(15 downto 0);  -- Product version
            VENDORSTR :     string := "";                   -- Manufacturer name
            PRODUCTSTR :    string := "";                   -- Product name
            SERIALSTR :     string := "";                   -- Serial number
            HSSUPPORT :     boolean := false;               -- Support high speed mode
            SELFPOWERED :   boolean := false;               -- Device does not use bus power
            RXBUFSIZE_BITS: integer range 7 to 12 := 11;    -- Size of receive buffer
            TXBUFSIZE_BITS: integer range 7 to 12 := 10 );  -- Size of transmit buffer
        port (
            CLK :           in  std_logic;          -- 60 MHz UTMI clock
            RESET :         in  std_logic;          -- Synchronous reset
            USBRST :        out std_logic;          -- Reset signal detected on bus
            HIGHSPEED :     out std_logic;          -- Device operating in high speed mode
            SUSPEND :       out std_logic;          -- Device is suspended
            ONLINE :        out std_logic;          -- Device is in Configured state
            RXVAL :         out std_logic;          -- Received byte available on RXDAT
            RXDAT :         out std_logic_vector(7 downto 0);
            RXRDY :         in  std_logic;          -- Application ready for next byte
            RXLEN :         out std_logic_vector(RXBUFSIZE_BITS-1 downto 0);
            TXVAL :         in  std_logic;          -- Application has data to send
            TXDAT :         in  std_logic_vector(7 downto 0);
            TXRDY :         out std_logic;          -- Entity ready to accept next byte
            TXROOM :        out std_logic_vector(TXBUFSIZE_BITS-1 downto 0);
            TXCORK :        in  std_logic;          -- Suppress data transmission
            PHY_DATAIN :    in  std_logic_vector(7 downto 0);
            PHY_DATAOUT :   out std_logic_vector(7 downto 0);
            PHY_TXVALID :   out std_logic;
            PHY_TXREADY :   in  std_logic;
            PHY_RXACTIVE :  in  std_logic;
            PHY_RXVALID :   in  std_logic;
            PHY_RXERROR :   in  std_logic;
            PHY_LINESTATE : in  std_logic_vector(1 downto 0);
            PHY_OPMODE :    out std_logic_vector(1 downto 0);
            PHY_XCVRSELECT: out std_logic;
            PHY_TERMSELECT: out std_logic;
            PHY_RESET :     out std_logic );
    end component usb_cdc;

end package usb_pkg;
