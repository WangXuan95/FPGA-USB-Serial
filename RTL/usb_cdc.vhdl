library ieee;
use ieee.std_logic_1164.all, ieee.numeric_std.all;
use work.usb_pkg.all;

entity usb_cdc is

    generic (

        -- Vendor ID to report in device descriptor.
        VENDORID :      std_logic_vector(15 downto 0);

        -- Product ID to report in device descriptor.
        PRODUCTID :     std_logic_vector(15 downto 0);

        -- Product version to report in device descriptor.
        VERSIONBCD :    std_logic_vector(15 downto 0);

        -- Optional description of manufacturer (max 126 characters).
        VENDORSTR :     string := "";

        -- Optional description of product (max 126 characters).
        PRODUCTSTR :    string := "";

        -- Optional product serial number (max 126 characters).
        SERIALSTR :     string := "";

        -- Support high speed mode.
        HSSUPPORT :     boolean := false;

        -- Set to true if the device never draws power from the USB bus.
        SELFPOWERED :   boolean := false;

        -- Size of receive buffer as 2-logarithm of the number of bytes.
        -- Must be at least 10 (1024 bytes) for high speed support.
        RXBUFSIZE_BITS: integer range 7 to 12 := 11;

        -- Size of transmit buffer as 2-logarithm of the number of bytes.
        TXBUFSIZE_BITS: integer range 7 to 12 := 10 );

    port (

        -- 60 MHz UTMI clock.
        CLK :           in  std_logic;

        -- Synchronous reset; clear buffers and re-attach to the bus.
        RESET :         in  std_logic;

        -- High for one clock when a reset signal is detected on the USB bus.
        -- Note: do NOT wire this signal to RESET externally.
        USBRST :        out std_logic;

        -- High when the device is operating (or suspended) in high speed mode.
        HIGHSPEED :     out std_logic;

        -- High while the device is suspended.
        -- Note: This signal is not synchronized to CLK.
        -- It may be used to asynchronously drive the UTMI SuspendM pin.
        SUSPEND :       out std_logic;

        -- High when the device is in the Configured state.
        ONLINE :        out std_logic;

        -- High if a received byte is available on RXDAT.
        RXVAL :         out std_logic;

        -- Received data byte, valid if RXVAL is high.
        RXDAT :         out std_logic_vector(7 downto 0);

        -- High if the application is ready to receive the next byte.
        RXRDY :         in  std_logic;

        -- Number of bytes currently available in receive buffer.
        RXLEN :         out std_logic_vector((RXBUFSIZE_BITS-1) downto 0);

        -- High if the application has data to send.
        TXVAL :         in  std_logic;

        -- Data byte to send, must be valid if TXVAL is high.
        TXDAT :         in  std_logic_vector(7 downto 0);

        -- High if the entity is ready to accept the next byte.
        TXRDY :         out std_logic;

        -- Number of free byte positions currently available in transmit buffer.
        TXROOM :        out std_logic_vector((TXBUFSIZE_BITS-1) downto 0);

        -- Temporarily suppress transmissions at the outgoing endpoint.
        -- This gives the application an oppertunity to fill the transmit
        -- buffer in order to blast data efficiently in big chunks.
        TXCORK :        in  std_logic;

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
	
end entity usb_cdc;

architecture usb_cdc_arch of usb_cdc is

    -- Byte array type
    type t_byte_array is array(natural range <>) of std_logic_vector(7 downto 0);

    -- Conditional expression.
    function choose_int(z: boolean; a, b: integer)
        return integer is
    begin
        if z then return a; else return b; end if;
    end function;

    -- Conditional expression.
    function choose_byte(z: boolean; a, b: std_logic_vector)
        return std_logic_vector is
    begin
        if z then return a; else return b; end if;
    end function;

    -- Create USB string descriptor from VHDL string.
    function strdesc_from_string(s: in string)
        return t_byte_array is
        variable y: t_byte_array(0 to 2 + 2*s'length - 1);
    begin
        assert s'length <= 126;
        -- bLength = descriptor length in bytes
        y(0) := std_logic_vector(to_unsigned(2 + 2 * s'length, 8));
        -- bDescriptorType = string descriptor
        y(1) := X"03";
        -- String contents in UTF16-LE.
        if s'length > 0 then
            for i in s'range loop
                y(2*(i-s'low)+2) := std_logic_vector(
                    to_unsigned(character'pos(s(i)), 8));
                y(2*(i-s'low)+3) := (others => '0');
            end loop;
        end if;
        return y;
    end function;

    -- Maximum packet size according to protocol.
    constant MAX_FSPACKET_SIZE: integer := 64;
    constant MAX_HSPACKET_SIZE: integer := 512;

    -- Width required for a pointer that can cover either RX or TX buffer.
    constant BUFPTR_SIZE :  integer := choose_int(RXBUFSIZE_BITS > TXBUFSIZE_BITS, RXBUFSIZE_BITS, TXBUFSIZE_BITS);

    -- Data endpoint number.
    constant data_endpt :   std_logic_vector(3 downto 0) := "0001";
    constant notify_endpt : std_logic_vector(3 downto 0) := "0010";

    -- Descriptor ROM
    --   addr   0 ..  17 : device descriptor
    --   addr  20 ..  29 : device qualifier
    --   addr  32 ..  98 : full speed configuration descriptor 
    --   addr 112 .. 178 : high speed configuration descriptor
    --   addr 179 :        other_speed_configuration hack
    --   addr 192 .. 195 : string descriptor 0 = supported languages
    --   addr 196 ..     : 3 string descriptors: vendor, product, serial
    constant DESC_DEV_ADDR :        integer := 0;
    constant DESC_DEV_LEN  :        integer := 18;
    constant DESC_QUAL_ADDR :       integer := 20;
    constant DESC_QUAL_LEN :        integer := 10;
    constant DESC_FSCFG_ADDR :      integer := 32;
    constant DESC_FSCFG_LEN :       integer := 67;
    constant DESC_HSCFG_ADDR :      integer := 112;
    constant DESC_HSCFG_LEN :       integer := 67;
    constant DESC_OTHERSPEED_ADDR : integer := 179;
    constant DESC_STRLANG :         integer := 192;
    constant DESC_STRVENDOR :       integer := 196;
    constant DESC_STRPRODUCT :      integer := DESC_STRVENDOR + 2 + 2*VENDORSTR'length;
    constant DESC_STRSERIAL :       integer := DESC_STRPRODUCT + 2 + 2*PRODUCTSTR'length;
    constant DESC_END :             integer := DESC_STRSERIAL + 2 + 2*SERIALSTR'length;

    constant descrom_dev: t_byte_array(0 to 19) := (
        -- 18 bytes device descriptor
        X"12",                  -- bLength = 18 bytes
        X"01",                  -- bDescriptorType = device descriptor
        choose_byte(HSSUPPORT, X"00", X"10"),   -- bcdUSB = 1.10 or 2.00
        choose_byte(HSSUPPORT, X"02", X"01"),
        X"02",                  -- bDeviceClass = Communication Device Class
        X"00",                  -- bDeviceSubClass = none
        X"00",                  -- bDeviceProtocol = none
        X"40",                  -- bMaxPacketSize0 = 64 bytes
        VENDORID(7 downto 0),   -- idVendor
        VENDORID(15 downto 8),
        PRODUCTID(7 downto 0),  -- idProduct
        PRODUCTID(15 downto 8),
        VERSIONBCD(7 downto 0), -- bcdDevice
        VERSIONBCD(15 downto 8),
        choose_byte(VENDORSTR'length > 0,  X"01", X"00"),   -- iManufacturer
        choose_byte(PRODUCTSTR'length > 0, X"02", X"00"),   -- iProduct
        choose_byte(SERIALSTR'length > 0,  X"03", X"00"),   -- iSerialNumber
        X"01",                  -- bNumConfigurations = 1
        -- 2 bytes padding
        X"00", X"00" );

    constant descrom_qual: t_byte_array(0 to 11) := (
        -- 10 bytes device qualifier
        X"0a",                  -- bLength = 10 bytes
        X"06",                  -- bDescriptorType = device qualifier
        X"00", X"02",           -- bcdUSB = 2.0
        X"02",                  -- bDeviceClass = Communication Device Class
        X"00",                  -- bDeviceSubClass = none
        X"00",                  -- bDeviceProtocol = none
        X"40",                  -- bMaxPacketSize0 = 64 bytes
        X"01",                  -- bNumConfigurations = 1
        X"00",                  -- bReserved
        -- 2 bytes padding
        X"00", X"00" );

    constant descrom_fscfg: t_byte_array(0 to 79) := (
        -- 67 bytes full-speed configuration descriptor
        -- 9 bytes configuration header
        X"09",                  -- bLength = 9 bytes
        X"02",                  -- bDescriptorType = configuration descriptor
        X"43", X"00",           -- wTotalLength = 67 bytes
        X"02",                  -- bNumInterfaces = 2
        X"01",                  -- bConfigurationValue = 1
        X"00",                  -- iConfiguration = none
        choose_byte(SELFPOWERED, X"c0", X"80"), -- bmAttributes
        X"fa",                  -- bMaxPower = 500 mA
        -- 9 bytes interface descriptor (communication control class)
        X"09",                  -- bLength = 9 bytes
        X"04",                  -- bDescriptorType = interface descriptor
        X"00",                  -- bInterfaceNumber = 0
        X"00",                  -- bAlternateSetting = 0
        X"01",                  -- bNumEndpoints = 1
        X"02",                  -- bInterfaceClass = Communication Interface
        X"02",                  -- bInterfaceSubClass = Abstract Control Model
        X"01",                  -- bInterfaceProtocol = V.25ter (required for Linux CDC-ACM driver)
        X"00",                  -- iInterface = none
        -- 5 bytes functional descriptor (header)
        X"05",                  -- bLength = 5 bytes
        X"24",                  -- bDescriptorType = CS_INTERFACE
        X"00",                  -- bDescriptorSubtype = header
        X"10", X"01",           -- bcdCDC = 1.10
        -- 4 bytes functional descriptor (abstract control management)
        X"04",                  -- bLength = 4 bytes
        X"24",                  -- bDescriptorType = CS_INTERFACE
        X"02",                  -- bDescriptorSubtype = Abstract Control Mgmnt
        X"00",                  -- bmCapabilities = none
        -- 5 bytes functional descriptor (union)
        X"05",                  -- bLength = 5 bytes
        X"24",                  -- bDescriptorType = CS_INTERFACE
        X"06",                  -- bDescriptorSubtype = union
        X"00",                  -- bMasterInterface = 0
        X"01",                  -- bSlaveInterface0 = 1
        -- 5 bytes functional descriptor (call management)
        X"05",                  -- bLength = 5 bytes
        X"24",                  -- bDescriptorType = CS_INTERFACE
        X"01",                  -- bDescriptorSubType = Call Management
        X"00",                  -- bmCapabilities = no call mgmnt
        X"01",                  -- bDataInterface = 1
        -- 7 bytes endpoint descriptor (notify IN)
        X"07",                  -- bLength = 7 bytes
        X"05",                  -- bDescriptorType = endpoint descriptor
        X"82",                  -- bEndpointAddress = IN 2
        X"03",                  -- bmAttributes = interrupt data
        X"08", X"00",           -- wMaxPacketSize = 8 bytes
        X"ff",                  -- bInterval = 255 frames
        -- 9 bytes interface descriptor (data class)
        X"09",                  -- bLength = 9 bytes
        X"04",                  -- bDescriptorType = interface descriptor
        X"01",                  -- bInterfaceNumber = 1
        X"00",                  -- bAlternateSetting = 0
        X"02",                  -- bNumEndpoints = 2
        X"0a",                  -- bInterfaceClass = Data Interface
        X"00",                  -- bInterfaceSubClass = none
        X"00",                  -- bInterafceProtocol = none
        X"00",                  -- iInterface = none
	-- 7 bytes endpoint descriptor (data IN)
        X"07",                  -- bLength = 7 bytes
        X"05",                  -- bDescriptorType = endpoint descriptor
        X"81",                  -- bEndpointAddress = IN 1
        X"02",                  -- bmAttributes = bulk data
        X"40", X"00",           -- wMaxPacketSize = 64 bytes
        X"00",                  -- bInterval
        -- 7 bytes endpoint descriptor (data OUT)
        X"07",                  -- bLength = 7 bytes
        X"05",                  -- bDescriptorType = endpoint descriptor
        X"01",                  -- bEndpointAddress = OUT 1
        X"02",                  -- bmAttributes = bulk data
        X"40", X"00",           -- wMaxPacketSize = 64 bytes
        X"00",                  -- bInterval
        -- 13 bytes padding
        X"00", X"00", X"00", X"00", X"00", X"00", X"00", X"00",
        X"00", X"00", X"00", X"00", X"00" );

    constant descrom_hscfg: t_byte_array(0 to 79) := (
        -- 67 bytes high-speed configuration descriptor
        -- 9 bytes configuration header
        X"09",                  -- bLength = 9 bytes
        X"02",                  -- bDescriptorType = configuration descriptor
        X"43", X"00",           -- wTotalLength = 67 bytes
        X"02",                  -- bNumInterfaces = 2
        X"01",                  -- bConfigurationValue = 1
        X"00",                  -- iConfiguration = none
        choose_byte(SELFPOWERED, X"c0", X"80" ), -- bmAttributes = self-powered
        X"fa",                  -- bMaxPower = 500 mA
        -- 9 bytes interface descriptor (communication control class)
        X"09",                  -- bLength = 9 bytes
        X"04",                  -- bDescriptorType = interface descriptor
        X"00",                  -- bInterfaceNumber = 0
        X"00",                  -- bAlternateSetting = 0
        X"01",                  -- bNumEndpoints = 1
        X"02",                  -- bInterfaceClass = Communication Interface
        X"02",                  -- bInterfaceSubClass = Abstract Control Model
        X"01",                  -- bInterfaceProtocol = V.25ter (required for Linux CDC-ACM driver)
        X"00",                  -- iInterface = none
        -- 5 bytes functional descriptor (header)
        X"05",                  -- bLength = 5 bytes
        X"24",                  -- bDescriptorType = CS_INTERFACE
        X"00",                  -- bDescriptorSubtype = header
        X"10", X"01",           -- bcdCDC = 1.10
        -- 4 bytes functional descriptor (abstract control management)
        X"04",                  -- bLength = 4 bytes
        X"24",                  -- bDescriptorType = CS_INTERFACE
        X"02",                  -- bDescriptorSubtype = Abstract Control Mgmnt
        X"00",                  -- bmCapabilities = none
        -- 5 bytes functional descriptor (union)
        X"05",                  -- bLength = 5 bytes
        X"24",                  -- bDescriptorType = CS_INTERFACE
        X"06",                  -- bDescriptorSubtype = union
        X"00",                  -- bMasterInterface = 0
        X"01",                  -- bSlaveInterface0 = 1
        -- 5 bytes functional descriptor (call management)
        X"05",                  -- bLength = 5 bytes
        X"24",                  -- bDescriptorType = CS_INTERFACE
        X"01",                  -- bDescriptorSubType = Call Management
        X"00",                  -- bmCapabilities = no call mgmnt
        X"01",                  -- bDataInterface = 1
        -- 7 bytes endpoint descriptor (notify IN)
        X"07",                  -- bLength = 7 bytes
        X"05",                  -- bDescriptorType = endpoint descriptor
        X"82",                  -- bEndpointAddress = IN 2
        X"03",                  -- bmAttributes = interrupt data
        X"08", X"00",           -- wMaxPacketSize = 8 bytes
        X"0f",                  -- bInterval = 2**14 frames
        -- 9 bytes interface descriptor (data class)
        X"09",                  -- bLength = 9 bytes
        X"04",                  -- bDescriptorType = interface descriptor
        X"01",                  -- bInterfaceNumber = 1
        X"00",                  -- bAlternateSetting = 0
        X"02",                  -- bNumEndpoints = 2
        X"0a",                  -- bInterfaceClass = Data Interface
        X"00",                  -- bInterfaceSubClass = none
        X"00",                  -- bInterafceProtocol = none
        X"00",                  -- iInterface = none
	-- 7 bytes endpoint descriptor (data IN)
        X"07",                  -- bLength = 7 bytes
        X"05",                  -- bDescriptorType = endpoint descriptor
        X"81",                  -- bEndpointAddress = IN 1
        X"02",                  -- bmAttributes = bulk data
        X"00", X"02",           -- wMaxPacketSize = 512 bytes
        X"00",                  -- bInterval
        -- 7 bytes endpoint descriptor (data OUT)
        X"07",                  -- bLength = 7 bytes
        X"05",                  -- bDescriptorType = endpoint descriptor
        X"01",                  -- bEndpointAddress = OUT 1
        X"02",                  -- bmAttributes = bulk data
        X"00", X"02",           -- wMaxPacketSize = 512 bytes
        X"00",                  -- bInterval = never NAK
        -- other_speed_configuration hack
        X"07",
        -- 12 bytes padding
        X"00", X"00", X"00", X"00", X"00", X"00", X"00", X"00",
        X"00", X"00", X"00", X"00" );

    constant descrom_str0: t_byte_array(0 to 3) := (
        -- string descriptor 0 (supported languages)
        X"04",                  -- bLength = 4
        X"03",                  -- bDescriptorType = string descriptor
        X"09", X"04" );         -- wLangId[0] = 0x0409 = English U.S.

    -- Concatenate all descriptors.
    constant descrom_pre: t_byte_array(0 to DESC_END-1) :=
        descrom_dev & descrom_qual &
        descrom_fscfg & descrom_hscfg &
        descrom_str0 &
        strdesc_from_string(VENDORSTR) &
        strdesc_from_string(PRODUCTSTR) &
        strdesc_from_string(SERIALSTR) ;

    -- Truncate descriptor data to keep only the necessary pieces;
    -- either just the full-speed stuff, or full-speed plus high-speed,
    -- or full-speed plus high-speed plus string descriptors.
    constant descrom_have_strings : boolean :=
        (VENDORSTR'length > 0 or PRODUCTSTR'length > 0 or
         SERIALSTR'length > 0);
    constant descrom_len :          integer :=
        choose_int(HSSUPPORT or descrom_have_strings,
            choose_int(descrom_have_strings, DESC_END, 192), 112);

    constant descrom: t_byte_array(0 to descrom_len-1) :=
        descrom_pre(0 to descrom_len-1);

    signal descrom_start:   unsigned(9 downto 0);
    signal descrom_raddr:   unsigned(9 downto 0);
    signal descrom_rdat:    std_logic_vector(7 downto 0);

    -- RX buffer
    signal rxbuf:           t_byte_array(0 to (2**RXBUFSIZE_BITS-1));
    signal rxbuf_rdat:      std_logic_vector(7 downto 0);

    -- TX buffer
    signal txbuf:           t_byte_array(0 to (2**TXBUFSIZE_BITS-1));
    signal txbuf_rdat:      std_logic_vector(7 downto 0);

    -- Interface to usb_init
    signal usbi_usbrst :    std_logic;
    signal usbi_highspeed : std_logic;
    signal usbi_suspend :   std_logic;

    -- Interface to usb_packet
    signal usbp_chirpk :    std_logic;
    signal usbp_rxact :     std_logic;
    signal usbp_rxrdy :     std_logic;
    signal usbp_rxfin :     std_logic;
    signal usbp_rxdat :     std_logic_vector(7 downto 0);
    signal usbp_txact :     std_logic;
    signal usbp_txrdy :     std_logic;
    signal usbp_txdat :     std_logic_vector(7 downto 0);

    -- Interface to usb_transact
    signal usbt_in :        std_logic;
    signal usbt_out :       std_logic;
    signal usbt_setup :     std_logic;
    signal usbt_ping :      std_logic;
    signal usbt_fin :       std_logic;
    signal usbt_endpt :     std_logic_vector(3 downto 0);
    signal usbt_nak :       std_logic;
    signal usbt_stall :     std_logic;
    signal usbt_nyet :      std_logic;
    signal usbt_send :      std_logic;
    signal usbt_isync :     std_logic;
    signal usbt_osync :     std_logic;
    signal usbt_rxrdy :     std_logic;
    signal usbt_rxdat :     std_logic_vector(7 downto 0);
    signal usbt_txrdy :     std_logic;
    signal usbt_txdat :     std_logic_vector(7 downto 0);

    -- Interface to usb_control
    signal usbc_addr :      std_logic_vector(6 downto 0);
    signal usbc_confd :     std_logic;
    signal usbc_clr_in :    std_logic_vector(1 to 2);
    signal usbc_clr_out :   std_logic_vector(1 to 2);
    signal usbc_sethlt_in : std_logic_vector(1 to 2);
    signal usbc_sethlt_out: std_logic_vector(1 to 2);
    signal usbc_dscbusy :   std_logic;
    signal usbc_dscrd :     std_logic;
    signal usbc_dsctyp :    std_logic_vector(2 downto 0);
    signal usbc_dscinx :    std_logic_vector(7 downto 0);
    signal usbc_dscoff :    std_logic_vector(7 downto 0);
    signal usbc_dsclen :    std_logic_vector(7 downto 0);
    signal usbc_selfpowered : std_logic;
    signal usbc_in :        std_logic;
    signal usbc_out :       std_logic;
    signal usbc_setup :     std_logic;
    signal usbc_ping :      std_logic;
    signal usbc_nak :       std_logic;
    signal usbc_stall :     std_logic;
    signal usbc_nyet :      std_logic;
    signal usbc_send :      std_logic;
    signal usbc_isync :     std_logic;
    signal usbc_txdat :     std_logic_vector(7 downto 0);

    -- State machine
    type t_state is (
      ST_IDLE, ST_STALL, ST_NAK,
      ST_INSTART, ST_INSEND, ST_INDONE, ST_OUTRECV, ST_OUTNAK );
    signal s_state : t_state := ST_IDLE;

    -- Endpoint administration (PHY side).
    signal s_rxbuf_head :   unsigned(RXBUFSIZE_BITS-1 downto 0) := to_unsigned(0, RXBUFSIZE_BITS);
    signal s_rxbuf_tail :   unsigned(RXBUFSIZE_BITS-1 downto 0);
    signal s_txbuf_head :   unsigned(TXBUFSIZE_BITS-1 downto 0);
    signal s_txbuf_tail :   unsigned(TXBUFSIZE_BITS-1 downto 0) := to_unsigned(0, TXBUFSIZE_BITS);
    signal s_txbuf_stop :   unsigned(TXBUFSIZE_BITS-1 downto 0);
    signal s_bufptr :       unsigned(BUFPTR_SIZE-1 downto 0) := to_unsigned(0, BUFPTR_SIZE);
    signal s_txprev_full :  std_logic := '0';       -- Last transmitted packet was full-size
    signal s_txprev_acked : std_logic := '1';       -- Last trantsmitted packet was ack-ed.
    signal s_isync :        std_logic := '0';
    signal s_osync :        std_logic := '0';
    signal s_halt_in :      std_logic_vector(1 to 2) := "00";
    signal s_halt_out :     std_logic_vector(1 to 2) := "00";
    signal s_nyet :         std_logic := '0';

    -- Buffer state (application side).
    signal q_rxbuf_head :   unsigned(RXBUFSIZE_BITS-1 downto 0);
    signal q_rxbuf_tail :   unsigned(RXBUFSIZE_BITS-1 downto 0) := to_unsigned(0, RXBUFSIZE_BITS);
    signal q_txbuf_head :   unsigned(TXBUFSIZE_BITS-1 downto 0) := to_unsigned(0, TXBUFSIZE_BITS);
    signal q_txbuf_tail :   unsigned(TXBUFSIZE_BITS-1 downto 0);

    -- Control signals (PHY side).
    signal s_reset :        std_logic;
    signal s_txcork :       std_logic;

    -- Status signals (application side).
    signal q_usbrst :       std_logic;
    signal q_online :       std_logic;
    signal q_highspeed :    std_logic;

    -- Receive buffer logic (application side).
    signal q_rxval :        std_logic := '0';
    signal q_rxbuf_read :   std_logic;
    signal q_txbuf_rdy :    std_logic;

begin

    -- Check buffer size.
    assert ((not HSSUPPORT) or (RXBUFSIZE_BITS >= 10))
        report "High-speed device needs at least 1024 bytes RX buffer";

    -- Bus reset logic
    usb_init_inst : usb_init
        port map (
            CLK             => CLK,
            RESET           => s_reset,
            I_USBRST        => usbi_usbrst,
            I_HIGHSPEED     => usbi_highspeed,
            I_SUSPEND       => usbi_suspend,
            P_CHIRPK        => usbp_chirpk,
            PHY_RESET       => PHY_RESET,
            PHY_LINESTATE   => PHY_LINESTATE,
            PHY_OPMODE      => PHY_OPMODE,
            PHY_XCVRSELECT  => PHY_XCVRSELECT,
            PHY_TERMSELECT  => PHY_TERMSELECT );

    -- Packet level logic
    usb_packet_inst : usb_packet
        port map (
            CLK             => CLK,
            RESET           => usbi_usbrst,
            P_CHIRPK        => usbp_chirpk,
            P_RXACT         => usbp_rxact,
            P_RXRDY         => usbp_rxrdy,
            P_RXFIN         => usbp_rxfin,
            P_RXDAT         => usbp_rxdat,
            P_TXACT         => usbp_txact,
            P_TXRDY         => usbp_txrdy,
            P_TXDAT         => usbp_txdat,
            PHY_DATAIN      => PHY_DATAIN,
            PHY_DATAOUT     => PHY_DATAOUT,
            PHY_TXVALID     => PHY_TXVALID,
            PHY_TXREADY     => PHY_TXREADY,
            PHY_RXACTIVE    => PHY_RXACTIVE,
            PHY_RXVALID     => PHY_RXVALID,
            PHY_RXERROR     => PHY_RXERROR );

    -- Transaction level logic
    usb_transact_inst : usb_transact
        port map (
            CLK             => CLK,
            RESET           => usbi_usbrst,
            T_IN            => usbt_in,
            T_OUT           => usbt_out,
            T_SETUP         => usbt_setup,
            T_PING          => usbt_ping,
            T_FIN           => usbt_fin,
            T_ADDR          => usbc_addr,
            T_ENDPT         => usbt_endpt,
            T_NAK           => usbt_nak,
            T_STALL         => usbt_stall,
            T_NYET          => usbt_nyet,
            T_SEND          => usbt_send,
            T_ISYNC         => usbt_isync,
            T_OSYNC         => usbt_osync,
            T_RXRDY         => usbt_rxrdy,
            T_RXDAT         => usbt_rxdat,
            T_TXRDY         => usbt_txrdy,
            T_TXDAT         => usbt_txdat,
            I_HIGHSPEED     => usbi_highspeed,
            P_RXACT         => usbp_rxact,
            P_RXRDY         => usbp_rxrdy,
            P_RXFIN         => usbp_rxfin,
            P_RXDAT         => usbp_rxdat,
            P_TXACT         => usbp_txact,
            P_TXRDY         => usbp_txrdy,
            P_TXDAT         => usbp_txdat );

    -- Default control endpoint
    usb_control_inst : usb_control
        port map (
            CLK             => CLK,
            RESET           => usbi_usbrst,
            C_ADDR          => usbc_addr,
            C_CONFD         => usbc_confd,
            C_CLRIN         => usbc_clr_in,
            C_CLROUT        => usbc_clr_out,
            C_HLTIN         => s_halt_in,
            C_HLTOUT        => s_halt_out,
            C_SHLTIN        => usbc_sethlt_in,
            C_SHLTOUT       => usbc_sethlt_out,
            C_DSCBUSY       => usbc_dscbusy,
            C_DSCRD         => usbc_dscrd,
            C_DSCTYP        => usbc_dsctyp,
            C_DSCINX        => usbc_dscinx,
            C_DSCOFF        => usbc_dscoff,
            C_DSCLEN        => usbc_dsclen,
            C_SELFPOWERED   => usbc_selfpowered,
            T_IN            => usbc_in,
            T_OUT           => usbc_out,
            T_SETUP         => usbc_setup,
            T_PING          => usbc_ping,
            T_FIN           => usbt_fin,
            T_NAK           => usbc_nak,
            T_STALL         => usbc_stall,
            T_NYET          => usbc_nyet,
            T_SEND          => usbc_send,
            T_ISYNC         => usbc_isync,
            T_OSYNC         => usbt_osync,
            T_RXRDY         => usbt_rxrdy,
            T_RXDAT         => usbt_rxdat,
            T_TXRDY         => usbt_txrdy,
            T_TXDAT         => usbc_txdat );

    -- Assign usb_cdc output signals.
    USBRST      <= q_usbrst;
    HIGHSPEED   <= q_highspeed;
    SUSPEND     <= usbi_suspend;
    ONLINE      <= q_online;
    RXVAL       <= q_rxval;
    RXDAT       <= rxbuf_rdat;
    RXLEN       <= std_logic_vector(q_rxbuf_head - q_rxbuf_tail);
    TXRDY       <= q_txbuf_rdy;
    TXROOM      <= std_logic_vector(q_txbuf_tail - q_txbuf_head - 1);

    -- Assign usb_control input signals
    usbc_in     <= usbt_in    when (usbt_endpt = "0000") else '0';
    usbc_out    <= usbt_out   when (usbt_endpt = "0000") else '0';
    usbc_setup  <= usbt_setup when (usbt_endpt = "0000") else '0';
    usbc_ping   <= usbt_ping  when (usbt_endpt = "0000") else '0';
    usbc_selfpowered <= '1'   when SELFPOWERED else '0';

    -- Assign usb_transact input lines
    usbt_nak    <= usbc_nak   when (usbt_endpt = "0000") else
                   '1'        when (s_state = ST_NAK) else
                   '0';
    usbt_stall  <= usbc_stall when (usbt_endpt = "0000") else
                   '1'        when (s_state = ST_STALL) else
                   '0';
    usbt_nyet   <= usbc_nyet  when (usbt_endpt = "0000") else
                   s_nyet;
    usbt_send   <= usbc_send  when (usbt_endpt = "0000") else
                   '1'        when (s_state = ST_INSEND) else
		   '0';
    usbt_isync  <= usbc_isync when (usbt_endpt = "0000") else
                   s_isync;
    usbt_txdat  <= usbc_txdat when (usbt_endpt = "0000" and usbc_dscbusy = '0') else
                   descrom_rdat when (usbt_endpt = "0000") else
                   txbuf_rdat;

    -- Buffer logic.
    q_rxbuf_read <= (RXRDY or (not q_rxval)) when (q_rxbuf_tail /= q_rxbuf_head) else '0';
    q_txbuf_rdy <= '1' when (q_txbuf_head + 1 /= q_txbuf_tail) else '0';

    -- Connection between PHY-side and application-side signals.
    -- This could be a good place to insert clock domain crossing.
    q_rxbuf_head <= s_rxbuf_head;
    s_rxbuf_tail <= q_rxbuf_tail;
    s_txbuf_head <= q_txbuf_head;
    q_txbuf_tail <= s_txbuf_tail;
    s_txcork    <= TXCORK;
    s_reset     <= RESET;
    q_online    <= usbc_confd;
    q_usbrst    <= usbi_usbrst;
    q_highspeed <= usbi_highspeed;

    -- Lookup address/length of the selected descriptor (combinatorial).
    process (usbc_dsctyp, usbc_dscinx, usbi_highspeed)
        variable s: unsigned(9 downto 0);
        variable n: unsigned(7 downto 0);
    begin
        s := to_unsigned(0, s'length);
        n := to_unsigned(0, n'length);
        case usbc_dsctyp is
            when "001" =>   -- device descriptor
                s := to_unsigned(DESC_DEV_ADDR, s'length);
                n := to_unsigned(DESC_DEV_LEN, n'length);
            when "010" =>   -- configuration descriptor
                if usbc_dscinx = X"00" then
                    if HSSUPPORT and (usbi_highspeed = '1') then
                        s := to_unsigned(DESC_HSCFG_ADDR, s'length);
                        n := to_unsigned(DESC_HSCFG_LEN, n'length);
                    else
                        s := to_unsigned(DESC_FSCFG_ADDR, s'length);
                        n := to_unsigned(DESC_FSCFG_LEN, n'length);
                    end if;
                end if;
            when "011" =>   -- string descriptor
                if descrom_have_strings then
                    case usbc_dscinx is
                        when X"00" => -- supported languages
                            s := to_unsigned(DESC_STRLANG, s'length);
                            n := to_unsigned(4, n'length);
                        when X"01" => -- vendor name
                            s := to_unsigned(DESC_STRVENDOR, s'length);
                            n := to_unsigned(2 + 2*VENDORSTR'length, n'length);
                        when X"02" => -- product name
                            s := to_unsigned(DESC_STRPRODUCT, s'length);
                            n := to_unsigned(2 + 2*PRODUCTSTR'length, n'length);
                        when X"03" => -- serial number
                            s := to_unsigned(DESC_STRSERIAL, s'length);
                            n := to_unsigned(2 + 2*SERIALSTR'length, n'length);
                        when others =>
                            -- unsupported descriptor index
                    end case;
                end if;
            when "110" =>   -- device qualifier
                if HSSUPPORT then
                    s := to_unsigned(DESC_QUAL_ADDR, s'length);
                    n := to_unsigned(DESC_QUAL_LEN, n'length);
                end if;
            when "111" =>   -- other speed configuration
                if HSSUPPORT and (usbc_dscinx = X"00") then
                    if usbi_highspeed = '1' then
                        s := to_unsigned(DESC_FSCFG_ADDR, s'length);
                        n := to_unsigned(DESC_FSCFG_LEN, n'length);
                    else
                        s := to_unsigned(DESC_HSCFG_ADDR, s'length);
                        n := to_unsigned(DESC_HSCFG_LEN, n'length);
                    end if;
                end if;
            when others =>
                -- unsupported descriptor type
        end case;
        descrom_start <= s;
        usbc_dsclen   <= std_logic_vector(n);
    end process;

    -- Main application-side synchronous process.
    process is
    begin
        wait until rising_edge(CLK);

        if RESET = '1' then

            -- Reset this entity.
            q_rxbuf_tail <= to_unsigned(0, RXBUFSIZE_BITS);
            q_txbuf_head <= to_unsigned(0, TXBUFSIZE_BITS);
            q_rxval      <= '0'; 

        else

            -- Read data from the RX buffer.
            if q_rxbuf_read = '1' then
                -- The RAM buffer reads a byte in this cycle.
                q_rxbuf_tail    <= q_rxbuf_tail + 1;
                q_rxval         <= '1';
            elsif RXRDY = '1' then
                -- Byte consumed by application; no new data yet.
                q_rxval         <= '0';
            end if;

            -- Write data to the TX buffer.
            if (TXVAL = '1') and (q_txbuf_rdy = '1') then
                -- The RAM buffer writes a byte in this cycle.
                q_txbuf_head    <= q_txbuf_head + 1;
            end if;

        end if;

    end process;

    -- Main PHY-side synchronous process.
    process is
        variable v_max_txsize :     unsigned(TXBUFSIZE_BITS-1 downto 0);
        variable v_rxbuf_len_lim :  unsigned(RXBUFSIZE_BITS-1 downto 0);
        variable v_rxbuf_tmp_head : unsigned(RXBUFSIZE_BITS-1 downto 0);
        variable v_rxbuf_pktroom :  std_logic;
    begin
        wait until rising_edge(CLK);

        -- Determine the maximum packet size we can transmit.
        if HSSUPPORT and usbi_highspeed = '1' then
            v_max_txsize := to_unsigned(MAX_HSPACKET_SIZE, TXBUFSIZE_BITS);
        else
            v_max_txsize := to_unsigned(MAX_FSPACKET_SIZE, TXBUFSIZE_BITS);
        end if;

        -- Determine if there is room for another packet in the RX buffer.
        -- We need room for the largest possible incoming packet, plus
        -- two CRC bytes.
        if HSSUPPORT then
            v_rxbuf_len_lim := to_unsigned(2**RXBUFSIZE_BITS - MAX_HSPACKET_SIZE - 2, RXBUFSIZE_BITS);
        else
            v_rxbuf_len_lim := to_unsigned(2**RXBUFSIZE_BITS - MAX_FSPACKET_SIZE - 2, RXBUFSIZE_BITS);
        end if;
        if HSSUPPORT and s_state = ST_OUTRECV then
            -- Currently receiving a packet; compare against the temporary
            -- tail pointer to decide NYET vs ACK.
            v_rxbuf_tmp_head := resize(s_bufptr, RXBUFSIZE_BITS);
        else
            -- Not receiving a packet (or NYET not supported);
            -- compare against the tail pointer to decide NAK vs ACK.
            v_rxbuf_tmp_head := s_rxbuf_head;
        end if;
        if v_rxbuf_tmp_head - s_rxbuf_tail < v_rxbuf_len_lim then
            v_rxbuf_pktroom := '1';
        else
            v_rxbuf_pktroom := '0';
        end if;

        -- State machine
        if s_reset = '1' then

            -- Reset this entity.
            s_state         <= ST_IDLE;
            s_rxbuf_head    <= to_unsigned(0, RXBUFSIZE_BITS);
            s_txbuf_tail    <= to_unsigned(0, TXBUFSIZE_BITS);
            s_bufptr        <= to_unsigned(0, BUFPTR_SIZE);
            s_txprev_full   <= '0';
            s_txprev_acked  <= '1';
            s_isync         <= '0';
            s_osync         <= '0';
            s_halt_in       <= "00";
            s_halt_out      <= "00";

        elsif usbi_usbrst = '1' then

            -- Reset protocol state.
            s_state         <= ST_IDLE;
            s_txprev_full   <= '0';
            s_txprev_acked  <= '1';
            s_isync         <= '0';
            s_osync         <= '0';
            s_halt_in       <= "00";
            s_halt_out      <= "00";

        else

            case s_state is

                when ST_IDLE =>
                    -- Idle; wait for a transaction
                    s_nyet <= '0';
                    if (usbt_endpt = data_endpt) and (usbt_in = '1') then
                        -- Start of IN transaction
                        if s_halt_in(1) = '1' then
                            -- Endpoint halted
                            s_state  <= ST_STALL;
                        elsif (s_txbuf_tail /= s_txbuf_head and s_txcork = '0') or s_txprev_full = '1' then
                            -- Prepare to send data
                            s_bufptr <= resize(s_txbuf_tail, s_bufptr'length);
                            s_state  <= ST_INSTART;
                        else
                            -- We have no data to send
                            s_state  <= ST_NAK;
                        end if;
                    elsif (usbt_endpt = data_endpt) and (usbt_out = '1') then
                        -- Start of OUT transaction
                        if s_halt_out(1) = '1' then
                            -- Endpoint halted
                            s_state  <= ST_STALL;
                        elsif v_rxbuf_pktroom = '1' then
                            -- Prepare to receive data
                            s_bufptr <= resize(s_rxbuf_head, s_bufptr'length);
                            s_state  <= ST_OUTRECV; 
                        else
                            -- We have no room to store a new packet
                            s_state  <= ST_OUTNAK;
                        end if;
                    elsif HSSUPPORT and (usbt_endpt = data_endpt) and (usbt_ping = '1') then
                         -- Start of PING transaction
                        if v_rxbuf_pktroom = '1' then
                            -- There is room in the RX buffer for another packet; do nothing (ACK).
                            s_state  <= ST_IDLE;
                        else
                            -- There is no room in the RX buffer; respond with NAK.
                            s_state  <= ST_NAK;
                        end if;
                    elsif (usbt_endpt = notify_endpt) and (usbt_in = '1') then
                        -- The notify endpoint simply NAK's all IN transactions
                        if s_halt_in(2) = '1' then
                            -- Endpoint halted
                            s_state <= ST_STALL;
                        else
                            s_state <= ST_NAK;
                        end if;
                    end if;

                    -- Reset sync bits when the control endpoint tells us.
                    s_isync <= s_isync and (not usbc_clr_in(1));
                    s_osync <= s_osync and (not usbc_clr_out(1));

                    -- Set/reset halt bits when the control endpoint tells us.
                    s_halt_in(1)  <= (s_halt_in(1) or usbc_sethlt_in(1)) and (not usbc_clr_in(1));
                    s_halt_in(2)  <= (s_halt_in(2) or usbc_sethlt_in(2)) and (not usbc_clr_in(2));
                    s_halt_out(1) <= (s_halt_out(1) or usbc_sethlt_out(1)) and (not usbc_clr_out(1));

                when ST_STALL =>
                    -- Wait for end of transaction
                    if (usbt_in = '0') and (usbt_out = '0') and (usbt_ping = '0') then
                        s_state <= ST_IDLE;
                    end if;

                when ST_NAK =>
                    -- Wait for end of transaction
                    if (usbt_in = '0') and (usbt_out = '0') and (usbt_ping = '0') then
                        s_state <= ST_IDLE;
                    end if;

                when ST_INSTART =>
                    -- Prepare to send data; read first byte from memory.
                    if usbt_in = '0' then
                        -- Transaction canceled.
                        s_state <= ST_IDLE;
                    elsif (s_txbuf_tail = s_txbuf_head) or
                          (s_txprev_acked = '0' and resize(s_bufptr, TXBUFSIZE_BITS) = s_txbuf_stop) or
                          (s_txprev_acked = '1' and s_txcork = '1') then
                        -- The TX buffer is empty, or a previous empty packet
                        -- is unacknowledged, or the TX buffer is corked;
                        -- must send an empty packet.
                        s_state <= ST_INDONE;
                    else
                        -- Send a non-empty packet.
                        if s_txprev_acked = '1' then
                            -- Set up a size limit for this packet.
                            s_txbuf_stop <= s_txbuf_tail + v_max_txsize;
                        end if;
			s_bufptr <= s_bufptr + 1;
                        s_state <= ST_INSEND;
                    end if;

                when ST_INSEND =>
                    -- Sending data
                    if usbt_in = '0' then
                        -- Transaction canceled.
                        s_state <= ST_IDLE;
                    elsif usbt_txrdy = '1' then
                        -- Need to provide the next data byte;
                        -- stop when we reach the end of the TX buffer;
                        -- stop when we reach the packet size limit.
                        if (resize(s_bufptr, TXBUFSIZE_BITS) = s_txbuf_head) or
                           (resize(s_bufptr, TXBUFSIZE_BITS) = s_txbuf_stop) then
                            -- No more bytes
                            s_state <= ST_INDONE;
                        else
                            s_bufptr <= s_bufptr + 1;
                        end if;
                    end if;

                when ST_INDONE =>
                    -- Done sending packet; wait for ACK.
                    if usbt_in = '0' then
                        -- No acknowledgement
                        s_txprev_acked <= '0';
                        -- Set limit for next packet to the same point
			s_txbuf_stop <= resize(s_bufptr, TXBUFSIZE_BITS);
                        -- Done
                        s_state <= ST_IDLE;
                    elsif usbt_fin = '1' then
                        -- Got acknowledgement
                        s_txprev_acked <= '1';
                        -- Update buffer tail
                        s_txbuf_tail <= resize(s_bufptr, TXBUFSIZE_BITS);
                        -- Flip sync bit
                        s_isync <= not s_isync;
                        -- Remember if this was a full-sized packet.
                        if s_txbuf_tail + v_max_txsize = resize(s_bufptr, TXBUFSIZE_BITS) then
                            s_txprev_full <= '1';
                        else
                            s_txprev_full <= '0';
                        end if;
                        -- Done
                        s_state <= ST_IDLE;
                    end if;

                when ST_OUTRECV =>
                    -- Receiving data
                    if usbt_out = '0' then
                        -- Transaction ended.
                        -- If the transaction was succesful, usbt_fin has been
                        -- asserted in the previous cycle and has triggered
                        -- an update of s_rxbuf_head.
                        s_state <= ST_IDLE;
                    elsif (usbt_fin = '1') and (usbt_osync = s_osync) then
                        -- Good packet received; discard CRC bytes
                        s_rxbuf_head <= resize(s_bufptr, RXBUFSIZE_BITS) - 2;
                        s_osync <= not s_osync;
                    elsif usbt_rxrdy = '1' then
                        -- Got data byte
                        s_bufptr <= s_bufptr + 1;
                        if HSSUPPORT then
                            -- Set NYET if there is no room to receive
                            -- another packet after this one.
                            s_nyet <= not v_rxbuf_pktroom;
                        end if;
                    end if;

                when ST_OUTNAK =>
                    -- Receiving data while we don't have room to store it
                    if usbt_out = '0' then
                        -- End of transaction
                        s_state <= ST_IDLE;
                    elsif (usbt_rxrdy = '1') and (usbt_osync = s_osync) then
                        -- This is a new (non-duplicate) packet, but we can
                        -- not store it; so respond with NAK.
                        s_state <= ST_NAK;
                    end if;

            end case;

        end if;
    end process;

    -- It is always a fight to get the synthesizer to infer block RAM.
    -- The problem is we need dual port RAM with read-enable signals.
    -- The recommended coding style, with registered read addresses,
    -- does not work in this case.
    -- The code below generates three RAM blocks on the Xilinx Spartan-3,
    -- but it is doubtful whether it will work on other FPGA families.

    -- Write to RX buffer.
    process (CLK) is
    begin
        if rising_edge(CLK) then
            if s_state = ST_OUTRECV and usbt_rxrdy = '1' then
                rxbuf(to_integer(resize(s_bufptr, RXBUFSIZE_BITS))) <= usbt_rxdat;
            end if;
        end if;
    end process;

    -- Read from RX buffer.
    process (CLK) is
    begin
        if rising_edge(CLK) then
            if q_rxbuf_read = '1' then
                rxbuf_rdat <= rxbuf(to_integer(q_rxbuf_tail));
            end if;
        end if;
    end process;

    -- Write to TX buffer.
    process (CLK) is
    begin
        if rising_edge(CLK) then
            if TXVAL = '1' then
                txbuf(to_integer(q_txbuf_head)) <= TXDAT;
            end if;
        end if;
    end process;

    -- Read from TX buffer.
    process (CLK) is
    begin
        if rising_edge(CLK) then
            if (usbt_txrdy = '1') or (s_state = ST_INSTART) then
                txbuf_rdat <= txbuf(to_integer(resize(s_bufptr, TXBUFSIZE_BITS)));
            end if;
        end if;
    end process;

    -- Read from descriptor memory.
    process (CLK) is
    begin
        if rising_edge(CLK) then
            if usbc_dscrd = '1' then
                if HSSUPPORT and unsigned(usbc_dscoff) = 1 and usbc_dsctyp = "111" then
                    -- Disguise the configuration descriptor as an
                    -- other_speed_configuration descriptor.
                    descrom_raddr <= to_unsigned(DESC_OTHERSPEED_ADDR, descrom_raddr'length);
                else
                    descrom_raddr <= descrom_start + resize(unsigned(usbc_dscoff), descrom_raddr'length);
                end if;
            end if;
        end if;
    end process;
    
    assert to_integer(descrom_raddr) < descrom'length;
    descrom_rdat <= descrom(to_integer(descrom_raddr));

end architecture usb_cdc_arch;

