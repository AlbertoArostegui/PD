//core/thread_context.sv
//
// Current simple module to store PC for each thread

module thread_context
  import ariane_pkg::*;
#(
  parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
  parameter int unsigned NUM_THREADS = CVA6Cfg.NUM_THREADS
) (
  input logic clk_i,
  input logic rst_ni,

  input logic [$clog2(NUM_THREADS)-1:0] pc_read_thread_id_i,
  output logic [CVA6Cfg.VLEN-1:0] pc_read_value_o,

  input logic pc_write_i,
  input logic [$clog2(NUM_THREADS)-1:0] pc_write_thread_id_i,
  input logic [CVA6Cfg.VLEN-1:0] pc_write_value_i,

  input logic thread_status_update_i,
  input logic [$clog2(NUM_THREADS)-1:0] thread_status_update_id_i,
  input thread_status_t thread_status_value_i,

  output thread_status_t [NUM_THREADS-1:0] all_threads_status,

  input logic [CVA6Cfg.VLEN-1:0] boot_addr_i
);

logic [(NUM_THREADS)-1:0][CVA6Cfg.VLEN-1:0] thread_pcs;
thread_status_t [(NUM_THREADS)-1:0] thread_statuses;

assign pc_read_value_o = thread_pcs[pc_read_thread_id_i];
assign all_threads_status = thread_statuses;

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (~rst_ni) begin
    for (int i = 0; i < NUM_THREADS; i++) begin
      thread_pcs[i] <= boot_addr_i;
      if (i != 0)
        thread_statuses[i] <= HALTED;
    end
    thread_statuses[0] <= READY;
  end
  else begin
    if (pc_write_i) begin
      thread_pcs[pc_write_thread_id_i] <= pc_write_value_i;
    end
    if (thread_status_update_i) begin
      thread_statuses[thread_status_update_id_i] <= thread_status_value_i;
    end
  end
end

endmodule : thread_context
