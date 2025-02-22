// ROMulator - RAM/ROM replacement and diagnostic for 8-bit CPUs
// Copyright (C) 2019  Michael Hill

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

module diagnostics(
     output reg halt,   // io line to halt the cpu

     // spi slave
     input      fpga_reset,
     input      fpga_clk,
     input      spi_select,
     input      spi_clk,
     output     spi_miso,
     input wire spi_mosi,

     // ram control
     output reg [15:0] address,
     input      [7:0] data,
     output reg [7:0] data_out,
     output reg we,
     output reg cs,

     input      [3:0] configuration,

     // video ram
     output reg [10:0] vram_address,
     input      [7:0] vram_data,
     output reg vram_read_clock,

     output reg [3:0] config_byte,
     input  wire [3:0] flash_addr,

     input      [10:0] vram_size
);

// module states
localparam RUNNING = 0;
localparam HALTED = 1;
localparam WRITE_MEMORY_BYTE = 2;
localparam WRITE_MEMORY_BYTE_WAIT = 3;
localparam WRITE_MEMORY_BYTE_NEXT = 4;
localparam WRITE_CONFIG_BYTE = 5;
localparam OUTPUT_MEMORY_BYTE = 6;
localparam OUTPUT_MEMORY_BYTE_WRITEDONE = 7;
localparam OUTPUT_MEMORY_BYTE_WAIT = 8;
localparam OUTPUT_MEMORY_BYTE_NEXT = 9;
localparam STARTUP = 10;
localparam WRITE_CRC32_BYTE = 11;
localparam WRITE_CRC32_BYTE_WAIT = 12;
localparam WRITE_CRC32_BYTE_NEXT = 13;
localparam WRITE_DUMMY_BYTE = 14;
localparam WRITE_DUMMY_BYTE_WAIT = 15;
localparam WRITE_DUMMY_BYTE_NEXT = 16;

localparam WRITE_MEMORY_BYTE_NEXT2 = 17;
localparam SEND_VRAM_BYTE = 18;
localparam NEXT_VRAM_BYTE = 19;
localparam END_VRAM_BYTE = 20;
localparam SEND_PARITY_BYTE = 21;
localparam DONE_SEND_PARITY_BYTE = 22;
localparam VERIFY_PARITY_BYTE = 23;
reg [7:0] state = RUNNING;

// spi slave setup
wire rx_dv;
wire [7:0] rx_byte;
reg tx_dv = 0;
reg [7:0] tx_byte = 8'h00;

reg write_started = 0;
//reg [3:0] config_byte;

reg [31:0] crc32;
reg [7:0] crc32_byte_index;

reg [31:0] crc32_table [0:255];
reg [7:0] parity_byte;
reg [2:0] parity_counter;
reg parity_sent;
reg send_parity;

localparam HALT_CPU = 8'haa;
localparam RESUME_CPU = 8'h55;
localparam READ_MEMORY = 8'h66;
localparam READ_CONFIG = 8'h77;
localparam READ_VRAM = 8'h88;
localparam WRITE_MEMORY = 8'h99;
localparam PARITY_ERROR = 8'h22;

SPI_Slave spiSlave(
  .i_Rst_L(fpga_reset),
  .i_Clk(fpga_clk),
  .o_RX_DV(rx_dv),
  .o_RX_Byte(rx_byte),
  .i_TX_DV(tx_dv),
  .i_TX_Byte(tx_byte),

  .i_SPI_Clk(spi_clk),
  .o_SPI_MISO(spi_miso),
  .i_SPI_MOSI(spi_mosi),
  .i_SPI_CS_n(spi_select)
  );

// main state machine for diagnostics
always @(posedge fpga_clk)
begin
    case(state)
    STARTUP:
    begin
      config_byte <= configuration;
      state <= RUNNING;
    end
    RUNNING:
    begin
        // check for halt command
        if (rx_dv == 1'b1) // byte received from spi
        begin
            if (rx_byte == HALT_CPU) // halt command
            begin
                halt <= 1;
                state <= HALTED;
            end
            else if (rx_byte == READ_CONFIG)
            begin
                tx_dv <= 1;
                //tx_byte <= config_byte;
                tx_byte <= flash_addr;
                state <= WRITE_CONFIG_BYTE;
            end
            else if (rx_byte == READ_VRAM) // start reading back from video ram
            begin
                parity_byte <= 0;
                parity_counter <= 0;
                parity_sent <= 0;
                send_parity <= 0;
                vram_read_clock <= 1;
                vram_address <= 0;
                state <= SEND_VRAM_BYTE;
            end
        end
    end
    SEND_VRAM_BYTE:
    begin
      // now transfer byte from vram and send
      tx_dv <= 1;
      tx_byte <= vram_data;
      parity_byte[parity_counter] = vram_data[0] + vram_data[1] + vram_data[2] + vram_data[3] + vram_data[4] + vram_data[5] + vram_data[6] + vram_data[7];
      vram_read_clock <= 0;
      vram_address <= vram_address + 1;
      if (parity_counter == 3'b111)
      begin
        send_parity <= 1;
      end
      parity_counter <= parity_counter + 1;
      state <= NEXT_VRAM_BYTE;
    end
    NEXT_VRAM_BYTE:
    begin
      tx_dv <= 0;
      if (rx_dv == 1'b1)
      begin
        if (send_parity == 1)
        begin
          state <= SEND_PARITY_BYTE;
        end
        else if (vram_address == vram_size)
        begin
          vram_address <= 0;
          state <= RUNNING;
        end
        else 
        begin
          parity_sent <= 0;
          vram_read_clock <= 1;
          state <= SEND_VRAM_BYTE;
        end
      end
      else
      begin
        state <= NEXT_VRAM_BYTE;
      end
    end
    SEND_PARITY_BYTE:
    begin
        tx_dv <= 1;
        tx_byte <= parity_byte;
        send_parity <= 0;
        state <= DONE_SEND_PARITY_BYTE;
    end
    DONE_SEND_PARITY_BYTE:
    begin
      tx_dv <= 0;
      if (rx_dv == 1'b1)
      begin
        state <= VERIFY_PARITY_BYTE;
      end
    end
    VERIFY_PARITY_BYTE:
    begin
      tx_dv <= 0;
      if (rx_dv <= 1'b1)
      begin
        if (rx_byte == PARITY_ERROR)
        begin
          vram_address <= vram_address - 8;
        end

        state <= NEXT_VRAM_BYTE;
      end
    end
    WRITE_CONFIG_BYTE:
    begin
        tx_dv <= 0;
        if (rx_dv == 1'b1)
        begin
          state <= RUNNING;
        end
    end
    HALTED:
    // in halt state, waiting for next command
    // from here, can resume or send contents of memory map.
    begin
        if (rx_dv == 1'b1)
        begin
          if (rx_byte == RESUME_CPU) // resume command
          begin
            halt <= 0;
            state <= RUNNING;
          end
          else if (rx_byte == READ_MEMORY) // read out a full memory map
          begin
            state <= WRITE_DUMMY_BYTE;
            cs <= 1;
            we <= 0;
            address <= 0;
            crc32 <= 32'h00000000;
            crc32_byte_index <= 0;
          end
          else if (rx_byte == WRITE_MEMORY) // write a memory map, retrieved from spi
          begin
            state <= OUTPUT_MEMORY_BYTE_NEXT;
            cs <= 1;
            we <= 0;
            write_started <= 0;
            address <= 0;
          end
        end
    end
    OUTPUT_MEMORY_BYTE:
    begin
      tx_dv <= 1;
      tx_byte <= data_out;

      // write the byte currently on the data out bus
      we <= 1;
      state <= OUTPUT_MEMORY_BYTE_WRITEDONE;
    end
    OUTPUT_MEMORY_BYTE_WRITEDONE:
    begin
      tx_dv <= 0;
      // disable write
      we <= 0;
      state <= OUTPUT_MEMORY_BYTE_WAIT;
    end
    OUTPUT_MEMORY_BYTE_WAIT:
    // now waiting for next byte to be receieved
    begin
      // increment write address
      address <= address + 1;
      state <= OUTPUT_MEMORY_BYTE_NEXT;
    end
    OUTPUT_MEMORY_BYTE_NEXT:
    // received a byte from spi. This is one byte in the memory map we are receiving.
    // put this byte on the data output
    begin
      if (rx_dv == 1'b1) // received a byte over spi
      begin
        if (write_started == 1 && address == 0)
        begin
          // done writing memory map
          // back to halt state
          address <= 0;
          cs <= 0;
          we <= 0;
          state <= HALTED;
        end
        else
        begin
          // place received byte onto data bus
          write_started <= 1;
          data_out <= rx_byte;
          state <= OUTPUT_MEMORY_BYTE;
        end
      end
    end
    WRITE_DUMMY_BYTE:
    begin
      // present memory byte
      tx_dv <= 1;
      tx_byte <= 0; // read from data bus
      state <= WRITE_DUMMY_BYTE_WAIT;
    end
    WRITE_DUMMY_BYTE_WAIT:
    begin
      tx_dv <= 0;
      state <= WRITE_DUMMY_BYTE_NEXT;
    end
    WRITE_DUMMY_BYTE_NEXT:
    begin
      if (rx_dv == 1'b1)
      begin
        state <= WRITE_MEMORY_BYTE;
      end
    end
    WRITE_MEMORY_BYTE:
    begin
      // present memory byte
      tx_dv <= 1;
      tx_byte <= data; // read from data bus
      
      // update crc32
      crc32 <= crc32_table[crc32[7:0] ^ data] ^ (crc32 >> 8);
      state <= WRITE_MEMORY_BYTE_WAIT;
    end
    WRITE_MEMORY_BYTE_WAIT:
    begin
      tx_dv <= 0;
      address <= address + 1; // increment address
      state <= WRITE_MEMORY_BYTE_NEXT2;
    end
    WRITE_MEMORY_BYTE_NEXT2: // wait for deassert of rx signal, current byte done
    begin
      if (rx_dv == 1'b0)
      begin
        state <= WRITE_MEMORY_BYTE_NEXT;
      end
    end
    WRITE_MEMORY_BYTE_NEXT:
    begin
      if (rx_dv == 1'b1)
      begin
        if (address == 0)
        begin
          // done reading
          address <= 0;
          cs <= 0;
          we <= 0;
          //state <= HALTED;
          state <= WRITE_CRC32_BYTE;
        end
        else 
        begin
          state <= WRITE_MEMORY_BYTE;
        end
      end
    end
    WRITE_CRC32_BYTE:
    begin
      tx_dv <= 1;
      tx_byte <= crc32[31 - crc32_byte_index:24 - crc32_byte_index];
      state <= WRITE_CRC32_BYTE_WAIT;
    end
    WRITE_CRC32_BYTE_WAIT:
    begin
      tx_dv <= 0;
      crc32_byte_index <= crc32_byte_index + 8;
      state <= WRITE_CRC32_BYTE_NEXT;
    end
    WRITE_CRC32_BYTE_NEXT:
    begin
      if (rx_dv == 1'b1)
      begin
        if (crc32_byte_index == 32)
        begin
          // done reading
          crc32_byte_index <= 0;
          state <= HALTED;
        end
        else 
        begin
          state <= WRITE_CRC32_BYTE;
        end
      end
    end
    endcase
end

initial
begin
    halt <= 0;
    address <= 0;
    vram_address <= 0;
    vram_read_clock <= 0;
    we <= 0;
    cs <= 0;

    $readmemh("../bin/crc32_table.txt", crc32_table);
end

endmodule