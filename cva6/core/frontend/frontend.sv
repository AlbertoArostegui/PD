// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 08.02.2018
// Description: Ariane Instruction Fetch Frontend
//
// This module interfaces with the instruction cache, handles control
// change request from the back-end and does branch prediction.

module frontend
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bp_resolve_t = logic,
    parameter type fetch_entry_t = logic,
    parameter type icache_dreq_t = logic,
    parameter type icache_drsp_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Next PC when reset - SUBSYSTEM
    input logic [CVA6Cfg.VLEN-1:0] boot_addr_i,
    // Flush branch prediction - zero
    input logic flush_bp_i,
    // Flush requested by FENCE, mis-predict and exception - CONTROLLER
    input logic flush_i,
    // Halt requested by WFI and Accelerate port - CONTROLLER
    input logic halt_i,
    // Set COMMIT PC as next PC requested by FENCE, CSR side-effect and Accelerate port - CONTROLLER
    input logic set_pc_commit_i,
    // COMMIT PC - COMMIT
    input logic [CVA6Cfg.VLEN-1:0] pc_commit_i,
    // Exception event - COMMIT
    input logic ex_valid_i,
    // Mispredict event and next PC - EXECUTE
    input bp_resolve_t resolved_branch_i,
    // Return from exception event - CSR
    input logic eret_i,
    // Next PC when returning from exception - CSR
    input logic [CVA6Cfg.VLEN-1:0] epc_i,
    // Next PC when jumping into exception - CSR
    input logic [CVA6Cfg.VLEN-1:0] trap_vector_base_i,
    // Debug event - CSR
    input logic set_debug_pc_i,
    // Debug mode state - CSR
    input logic debug_mode_i,
    // Handshake between CACHE and FRONTEND (fetch) - CACHES
    output icache_dreq_t icache_dreq_o,
    // Handshake between CACHE and FRONTEND (fetch) - CACHES
    input icache_drsp_t icache_dreq_i,
    // Handshake's data between fetch and decode - ID_STAGE
    output fetch_entry_t [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_o,
    // Handshake's valid between fetch and decode - ID_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_valid_o,
    // Handshake's ready between fetch and decode - ID_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_ready_i,

    //Thread logic
    input logic [CVA6Cfg.NUM_THREADS_LOG-1:0] eret_thread_id_i,
    input logic [CVA6Cfg.NUM_THREADS_LOG-1:0] ex_thread_id_i,
    input logic [CVA6Cfg.NUM_THREADS_LOG-1:0] pc_commit_thread_id_i,
    input logic [CVA6Cfg.NUM_THREADS_LOG-1:0] debug_thread_id_i
);

  localparam type bht_update_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] pc;     // update at PC
    logic                    taken;
  };

  localparam type btb_prediction_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] target_address;
  };

  localparam type btb_update_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] pc;              // update at PC
    logic [CVA6Cfg.VLEN-1:0] target_address;
  };

  localparam type ras_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] ra;
  };

  // Instruction Cache Registers, from I$
  logic                            [    CVA6Cfg.FETCH_WIDTH-1:0] icache_data_q;
  logic                                                          icache_valid_q;
  ariane_pkg::frontend_exception_t                               icache_ex_valid_q;
  logic                            [           CVA6Cfg.VLEN-1:0] icache_vaddr_q;
  logic                            [          CVA6Cfg.GPLEN-1:0] icache_gpaddr_q;
  logic                            [                       31:0] icache_tinst_q;
  logic                                                          icache_gva_q;
  logic                                                          instr_queue_ready;
  logic                            [CVA6Cfg.INSTR_PER_FETCH-1:0] instr_queue_consumed;
  // upper-most branch-prediction from last cycle
  btb_prediction_t                                               btb_q;
  bht_prediction_t                                               bht_q;
  // instruction fetch is ready
  logic                                                          if_ready;
  logic [CVA6Cfg.VLEN-1:0] npc_d, npc_q;  // next PC

  // indicates whether we come out of reset (then we need to load boot_addr_i)
  logic                                       npc_rst_load_q;

  logic                                       replay;
  logic [                   CVA6Cfg.VLEN-1:0] replay_addr;

  // shift amount
  logic [$clog2(CVA6Cfg.INSTR_PER_FETCH)-1:0] shamt;
  // address will always be 16 bit aligned, make this explicit here
  if (CVA6Cfg.RVC) begin : gen_shamt
    assign shamt = icache_dreq_i.vaddr[$clog2(CVA6Cfg.INSTR_PER_FETCH):1];
  end else begin
    assign shamt = 1'b0;
  end

  // -----------------------
  // Ctrl Flow Speculation
  // -----------------------
  // RVI ctrl flow prediction
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] rvi_return, rvi_call, rvi_branch, rvi_jalr, rvi_jump;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] rvi_imm;
  // RVC branching
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] rvc_branch, rvc_jump, rvc_jr, rvc_return, rvc_jalr, rvc_call;
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] rvc_imm;
  // re-aligned instruction and address (coming from cache - combinationally)
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0][            31:0] instr;
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] addr;
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0]                   instruction_valid;
  // BHT, BTB and RAS prediction
  bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   bht_prediction;
  btb_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   btb_prediction;
  bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   bht_prediction_shifted;
  btb_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   btb_prediction_shifted;
  ras_t                                                            ras_predict;
  ras_t            [    CVA6Cfg.NUM_THREADS-1:0]                   ras_predict_all;
  logic            [           CVA6Cfg.VLEN-1:0]                   vpc_btb;
  logic            [           CVA6Cfg.VLEN-1:0]                   vpc_bht;

  // branch-predict update
  logic                                                            is_mispredict;
  logic ras_push, ras_pop;
  logic [           CVA6Cfg.VLEN-1:0] ras_update;

  // Instruction FIFO
  logic [           CVA6Cfg.VLEN-1:0] predict_address;
  cf_t  [CVA6Cfg.INSTR_PER_FETCH-1:0] cf_type;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] taken_rvi_cf;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] taken_rvc_cf;

  logic                               serving_unaligned;
  // Re-align instructions
  instr_realign #(
      .CVA6Cfg(CVA6Cfg)
  ) i_instr_realign (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (icache_dreq_o.kill_s2),
      .valid_i            (icache_valid_q),
      .serving_unaligned_o(serving_unaligned),
      .address_i          (icache_vaddr_q),
      .data_i             (icache_data_q),
      .valid_o            (instruction_valid),
      .addr_o             (addr),
      .instr_o            (instr)
  );
  // --------------------
  // Branch Prediction
  // --------------------
  // select the right branch prediction result
  // in case we are serving an unaligned instruction in instr[0] we need to take
  // the prediction we saved from the previous fetch
  if (CVA6Cfg.RVC) begin : gen_btb_prediction_shifted
    assign bht_prediction_shifted[0] = (serving_unaligned) ? bht_q : bht_prediction[addr[0][$clog2(
        CVA6Cfg.INSTR_PER_FETCH
    ):1]];
    assign btb_prediction_shifted[0] = (serving_unaligned) ? btb_q : btb_prediction[addr[0][$clog2(
        CVA6Cfg.INSTR_PER_FETCH
    ):1]];

    // for all other predictions we can use the generated address to index
    // into the branch prediction data structures
    for (genvar i = 1; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_prediction_address
      assign bht_prediction_shifted[i] = bht_prediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
      assign btb_prediction_shifted[i] = btb_prediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
    end
  end else begin
    assign bht_prediction_shifted[0] = (serving_unaligned) ? bht_q : bht_prediction[addr[0][1]];
    assign btb_prediction_shifted[0] = (serving_unaligned) ? btb_q : btb_prediction[addr[0][1]];
  end
  ;

  // for the return address stack it doens't matter as we have the
  // address of the call/return already
  logic bp_valid;

  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_branch;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_call;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_jump;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_return;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_jalr;

  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
    // branch history table -> BHT
    assign is_branch[i] = instruction_valid[i] & (rvi_branch[i] | rvc_branch[i]);
    // function calls -> RAS
    assign is_call[i] = instruction_valid[i] & (rvi_call[i] | rvc_call[i]);
    // function return -> RAS
    assign is_return[i] = instruction_valid[i] & (rvi_return[i] | rvc_return[i]);
    // unconditional jumps with known target -> immediately resolved
    assign is_jump[i] = instruction_valid[i] & (rvi_jump[i] | rvc_jump[i]);
    // unconditional jumps with unknown target -> BTB
    assign is_jalr[i] = instruction_valid[i] & ~is_return[i] & (rvi_jalr[i] | rvc_jalr[i] | rvc_jr[i]);
  end

  // taken/not taken
  always_comb begin
    taken_rvi_cf = '0;
    taken_rvc_cf = '0;
    predict_address = '0;

    for (int i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) cf_type[i] = ariane_pkg::NoCF;

    ras_push = 1'b0;
    ras_pop = 1'b0;
    ras_update = '0;

    // lower most prediction gets precedence
    for (int i = CVA6Cfg.INSTR_PER_FETCH - 1; i >= 0; i--) begin
      unique case ({
        is_branch[i], is_return[i], is_jump[i], is_jalr[i]
      })
        4'b0000: ;  // regular instruction e.g.: no branch
        // unconditional jump to register, we need the BTB to resolve this
        4'b0001: begin
          ras_pop  = 1'b0;
          ras_push = 1'b0;
          if (CVA6Cfg.BTBEntries != 0 && btb_prediction_shifted[i].valid) begin
            predict_address = btb_prediction_shifted[i].target_address;
            cf_type[i] = ariane_pkg::JumpR;
          end
        end
        // its an unconditional jump to an immediate
        4'b0010: begin
          ras_pop = 1'b0;
          ras_push = 1'b0;
          taken_rvi_cf[i] = rvi_jump[i];
          taken_rvc_cf[i] = rvc_jump[i];
          cf_type[i] = ariane_pkg::Jump;
        end
        // return
        4'b0100: begin
          // make sure to only alter the RAS if we actually consumed the instruction
          ras_pop = ras_predict.valid & instr_queue_consumed[i];
          ras_push = 1'b0;
          predict_address = ras_predict.ra;
          cf_type[i] = ariane_pkg::Return;
        end
        // branch prediction
        4'b1000: begin
          ras_pop  = 1'b0;
          ras_push = 1'b0;
          // if we have a valid dynamic prediction use it
          if (bht_prediction_shifted[i].valid) begin
            taken_rvi_cf[i] = rvi_branch[i] & bht_prediction_shifted[i].taken;
            taken_rvc_cf[i] = rvc_branch[i] & bht_prediction_shifted[i].taken;
            // otherwise default to static prediction
          end else begin
            // set if immediate is negative - static prediction
            taken_rvi_cf[i] = rvi_branch[i] & rvi_imm[i][CVA6Cfg.VLEN-1];
            taken_rvc_cf[i] = rvc_branch[i] & rvc_imm[i][CVA6Cfg.VLEN-1];
          end
          if (taken_rvi_cf[i] || taken_rvc_cf[i]) begin
            cf_type[i] = ariane_pkg::Branch;
          end
        end
        default: ;
        // default: $error("Decoded more than one control flow");
      endcase
      // if this instruction, in addition, is a call, save the resulting address
      // but only if we actually consumed the address
      if (is_call[i]) begin
        ras_push   = instr_queue_consumed[i];
        ras_update = addr[i] + (rvc_call[i] ? 2 : 4);
      end
      // calculate the jump target address
      if (taken_rvc_cf[i] || taken_rvi_cf[i]) begin
        predict_address = addr[i] + (taken_rvc_cf[i] ? rvc_imm[i] : rvi_imm[i]);
      end
    end
  end
  // or reduce struct
  always_comb begin
    bp_valid = 1'b0;
    // BP cannot be valid if we have a return instruction and the RAS is not giving a valid address
    // Check that we encountered a control flow and that for a return the RAS
    // contains a valid prediction.
    for (int i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++)
    bp_valid |= ((cf_type[i] != NoCF & cf_type[i] != Return) | ((cf_type[i] == Return) & ras_predict.valid));
  end
  assign is_mispredict = resolved_branch_i.valid & resolved_branch_i.is_mispredict;



  // Cache interface
  assign icache_dreq_o.req = instr_queue_ready && !icache_stall_pending_q;
  assign if_ready = icache_dreq_i.ready & instr_queue_ready;
  // We need to flush the cache pipeline if:
  // 1. We mispredicted
  // 2. Want to flush the whole processor front-end
  // 3. Need to replay an instruction because the fetch-fifo was full
  assign icache_dreq_o.kill_s1 = is_mispredict | flush_i | replay;
  // if we have a valid branch-prediction we need to only kill the last cache request
  // also if we killed the first stage we also need to kill the second stage (inclusive flush)
  assign icache_dreq_o.kill_s2 = icache_dreq_o.kill_s1 | bp_valid;

  // Update Control Flow Predictions
  bht_update_t bht_update;
  btb_update_t btb_update;

  // assert on branch, deassert when resolved
  logic speculative_q, speculative_d;
  assign speculative_d = (speculative_q && !resolved_branch_i.valid || |is_branch || |is_return || |is_jalr) && !flush_i;
  assign icache_dreq_o.spec = speculative_d;

  assign bht_update.valid = resolved_branch_i.valid
                                & (resolved_branch_i.cf_type == ariane_pkg::Branch);
  assign bht_update.pc = resolved_branch_i.pc;
  assign bht_update.taken = resolved_branch_i.is_taken;
  // only update mispredicted branches e.g. no returns from the RAS
  assign btb_update.valid = resolved_branch_i.valid
                                & resolved_branch_i.is_mispredict
                                & (resolved_branch_i.cf_type == ariane_pkg::JumpR);
  assign btb_update.pc = resolved_branch_i.pc;
  assign btb_update.target_address = resolved_branch_i.target_address;

  // THREADING
  // thread scheduling
  logic [CVA6Cfg.VLEN-1:0] thread_pc;
  logic [CVA6Cfg.NUM_THREADS_LOG-1:0] current_thread_id_d, current_thread_id_q;
  logic [CVA6Cfg.NUM_THREADS-1:0] thread_ready;
  thread_status_t [CVA6Cfg.NUM_THREADS-1:0] all_threads_status;

  logic found_ready_comb;
  logic [CVA6Cfg.NUM_THREADS_LOG-1:0] candidate_thread_id_comb;

  logic pc_write_en_comb;
  logic [CVA6Cfg.VLEN-1:0] pc_write_val_comb;
  logic [CVA6Cfg.NUM_THREADS_LOG-1:0] pc_thread_id_comb;

  // thread stalling on icache miss
  // Track single outstanding icache miss
  logic icache_stall_pending_d, icache_stall_pending_q;
  logic [CVA6Cfg.NUM_THREADS_LOG-1:0] stalled_thread_id_d, stalled_thread_id_q;

  // drive thread_context status updates
  logic status_update_req_comb;
  logic [CVA6Cfg.NUM_THREADS_LOG-1:0] status_update_thread_id_comb;
  thread_status_t status_udpate_val_comb;

  // Next PC selection
  logic [CVA6Cfg.VLEN-1:0] current_thread_pc_comb;

  // Status update logic
  logic wants_to_fetch_for_current;
  logic cache_accepting_req;
  logic current_thread_is_ready;

  thread_status_t status_update_val_comb;

  thread_context #(
    .CVA6Cfg(CVA6Cfg),
    .NUM_THREADS(CVA6Cfg.NUM_THREADS)
  ) i_thread_context (
    .clk_i,
    .rst_ni,
    .pc_read_thread_id_i(current_thread_id_q),
    .pc_read_value_o(thread_pc),

    .pc_write_thread_id_i(pc_thread_id_comb),
    .pc_write_i(pc_write_en_comb),
    .pc_write_value_i(pc_write_val_comb),

    .thread_status_update_i(status_update_req_comb),
    .thread_status_update_id_i(status_update_thread_id_comb),
    .thread_status_value_i(status_update_val_comb),
    .all_threads_status(all_threads_status),
    .boot_addr_i(boot_addr_i)
  );

  always_comb begin : thread_schedule
    current_thread_id_d = current_thread_id_q;
    found_ready_comb = 1'b0;
    candidate_thread_id_comb = 'x;

    if (instr_queue_ready && !halt_i) begin
      for (int i = 1; i < CVA6Cfg.NUM_THREADS; i++) begin
        candidate_thread_id_comb = (current_thread_id_q + i) % CVA6Cfg.NUM_THREADS;

        if (all_threads_status[candidate_thread_id_comb] == READY) begin
          current_thread_id_d = candidate_thread_id_comb;
          found_ready_comb = 1'b1;
          break;
        end
      end
    end
  end

  for (genvar i = 0; i < CVA6Cfg.NUM_THREADS; i++) begin : gen_tid_fetch_entry
    assign fetch_entry_o[i].thread_id = current_thread_id_q;
  end
  assign icache_dreq_o.vaddr = thread_pc;

  // -------------------
  // Next PC
  // -------------------
  // next PC (NPC) can come from (in order of precedence):
  // 0. Default assignment/replay instruction
  // 1. Branch Predict taken
  // 2. Control flow change request (misprediction)
  // 3. Return from environment call
  // 4. Exception/Interrupt
  // 5. Pipeline Flush because of CSR side effects
  // Mis-predict handling is a little bit different
  // select PC a.k.a PC Gen
  //
  // TODO: Next PC control logic (i. e. the signals that points out if there has been
  // a branch, exception, ret and so on) must be associated with a thread id
  always_comb begin : npc_multithreaded
    // Default: no write
    pc_write_en_comb = 1'b0;
    pc_thread_id_comb = current_thread_id_q;
    pc_write_val_comb = 0;

    current_thread_pc_comb = thread_pc;
    if (bp_valid) begin
      pc_write_en_comb = 1'b1;
      pc_thread_id_comb = current_thread_id_q;
      // TODO: BP logic should take into account the thread ID. BP needs to be partitioned, or, at
      // least, address how are we going to to it.
      pc_write_val_comb = predict_address;
    end else if (if_ready) begin
      pc_write_en_comb = 1'b1;
      pc_write_val_comb = {
        current_thread_pc_comb[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] + 1, {CVA6Cfg.FETCH_ALIGN_BITS{1'b0}}
      };
      pc_thread_id_comb = current_thread_id_q;
    end else if (replay) begin
      pc_write_en_comb = 1'b1;
      pc_thread_id_comb = current_thread_id_q;
      pc_write_val_comb = replay_addr;
    end else if (resolved_branch_i.valid && resolved_branch_i.is_mispredict) begin
      pc_write_en_comb = 1'b1;
      pc_thread_id_comb = resolved_branch_i.thread_id;
      pc_write_val_comb = resolved_branch_i.target_address;
    end else if (eret_i) begin
      pc_write_en_comb = 1'b1;
      pc_thread_id_comb = eret_thread_id_i;
      pc_write_val_comb = epc_i;
    end else if (ex_valid_i) begin
      pc_write_en_comb = 1'b1;
      pc_thread_id_comb = ex_thread_id_i;
      pc_write_val_comb = trap_vector_base_i;
    end else if (set_pc_commit_i) begin
      pc_write_en_comb = 1'b1;
      pc_thread_id_comb = pc_commit_thread_id_i;
      pc_write_val_comb = pc_commit_i + (halt_i ? '0 : {{CVA6Cfg.VLEN - 3{1'b0}}, 3'b100});
    end
    if (CVA6Cfg.DebugEn && set_debug_pc_i) begin
      pc_write_en_comb  = 1'b1;
      pc_thread_id_comb = debug_thread_id_i;
      pc_write_val_comb = CVA6Cfg.DmBaseAddress[CVA6Cfg.VLEN-1:0] + CVA6Cfg.HaltAddress[CVA6Cfg.VLEN-1:0];
    end
  end : npc_multithreaded

  logic [CVA6Cfg.FETCH_WIDTH-1:0] icache_data;
  // re-align the cache line
  assign icache_data = icache_dreq_i.data >> {shamt, 4'b0};

  always_comb begin : status_update_logic
    status_update_req_comb = 1'b0;
    status_update_thread_id_comb = 'x;
    status_udpate_val_comb = READY;

    icache_stall_pending_d = icache_stall_pending_q;
    stalled_thread_id_d = stalled_thread_id_q;

    wants_to_fetch_for_current = instr_queue_ready;
    cache_accepting_req = icache_dreq_i.ready;
    current_thread_is_ready = (all_threads_status[current_thread_id_q] == READY);

    // stalling
    if (wants_to_fetch_for_current && !cache_accepting_req &&
      current_thread_is_ready && !icache_stall_pending_q) begin
      status_update_req_comb = 1'b1;
      status_update_thread_id_comb = current_thread_id_q;
      status_update_val_comb = STALLED_ICACHE;

      icache_stall_pending_d = 1'b1;
      stalled_thread_id_d = current_thread_id_q;
    end

    // un-stalling
    if (icache_stall_pending_q && icache_dreq_i.ready) begin
      if (all_threads_status[stalled_thread_id_q] == STALLED_ICACHE) begin
        if (icache_dreq_i.ex.valid) begin
          // If there is an exception, we do not set to ready
          status_update_req_comb = 1'b0;
        end else begin
          status_update_req_comb = 1'b1;
          status_update_thread_id_comb = stalled_thread_id_q;
          status_update_val_comb = READY;
        end
      end
      icache_stall_pending_d = 1'b0;
    end

    if (flush_i) begin
      icache_stall_pending_d = 1'b0;

    end

  end : status_update_logic

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      speculative_q     <= '0;
      icache_data_q     <= '0;
      icache_valid_q    <= 1'b0;
      icache_vaddr_q    <= 'b0;
      icache_gpaddr_q   <= 'b0;
      icache_tinst_q    <= 'b0;
      icache_gva_q      <= 1'b0;
      icache_ex_valid_q <= ariane_pkg::FE_NONE;
      btb_q             <= '0;
      bht_q             <= '0;
      current_thread_id_q  <= '0;
      icache_stall_pending_q <= '0;
      stalled_thread_id_q <= '0;

    end else begin
      speculative_q  <= speculative_d;
      icache_valid_q <= icache_dreq_i.valid;

      current_thread_id_q <= current_thread_id_d;
      icache_stall_pending_q <= icache_stall_pending_d;
      stalled_thread_id_q <= stalled_thread_id_d;

      if (icache_dreq_i.valid) begin
        icache_data_q  <= icache_data;
        icache_vaddr_q <= icache_dreq_i.vaddr;
        if (CVA6Cfg.RVH) begin
          icache_gpaddr_q <= icache_dreq_i.ex.tval2[CVA6Cfg.GPLEN-1:0];
          icache_tinst_q  <= icache_dreq_i.ex.tinst;
          icache_gva_q    <= icache_dreq_i.ex.gva;
        end else begin
          icache_gpaddr_q <= 'b0;
          icache_tinst_q  <= 'b0;
          icache_gva_q    <= 1'b0;
        end

        // Map the only three exceptions which can occur in the frontend to a two bit enum
        if (CVA6Cfg.MmuPresent && icache_dreq_i.ex.cause == riscv::INSTR_GUEST_PAGE_FAULT) begin
          icache_ex_valid_q <= ariane_pkg::FE_INSTR_GUEST_PAGE_FAULT;
        end else if (CVA6Cfg.MmuPresent && icache_dreq_i.ex.cause == riscv::INSTR_PAGE_FAULT) begin
          icache_ex_valid_q <= ariane_pkg::FE_INSTR_PAGE_FAULT;
        end else if (icache_dreq_i.ex.cause == riscv::INSTR_ACCESS_FAULT) begin
          icache_ex_valid_q <= ariane_pkg::FE_INSTR_ACCESS_FAULT;
        end else begin
          icache_ex_valid_q <= ariane_pkg::FE_NONE;
        end
        // save the uppermost prediction
        btb_q <= btb_prediction[CVA6Cfg.INSTR_PER_FETCH-1];
        bht_q <= bht_prediction[CVA6Cfg.INSTR_PER_FETCH-1];
      end
    end
  end

  if (CVA6Cfg.RASDepth == 0) begin : gen_no_ras
    assign ras_predict = '0;
  end else begin : gen_ras_array
    for (genvar thread_id = 0; thread_id < CVA6Cfg.NUM_THREADS; thread_id++) begin : gen_ras_instance
      ras #(
          .CVA6Cfg(CVA6Cfg),
          .ras_t  (ras_t),
          .DEPTH  (CVA6Cfg.RASDepth)
      ) i_ras (
          .clk_i,
          .rst_ni,
          .flush_bp_i(flush_bp_i),
          .push_i(ras_push && (current_thread_id_q == thread_id)),
          .pop_i(ras_pop && (current_thread_id_q == thread_id)),
          .data_i(ras_update),
          .data_o(ras_predict_all[thread_id])
      );
    end : gen_ras_instance
  end : gen_ras_array

  if (CVA6Cfg.RASDepth > 0)
    assign ras_predict = ras_predict_all[current_thread_id_q];

  //For FPGA, BTB is implemented in read synchronous BRAM
  //while for ASIC, BTB is implemented in D flip-flop
  //and can be read at the same cycle.
  //Same for BHT
  assign vpc_btb = (CVA6Cfg.FpgaEn) ? icache_dreq_i.vaddr : icache_vaddr_q;
  assign vpc_bht = (CVA6Cfg.FpgaEn && CVA6Cfg.FpgaAlteraEn && icache_dreq_i.valid) ? icache_dreq_i.vaddr : icache_vaddr_q;

  if (CVA6Cfg.BTBEntries == 0) begin
    assign btb_prediction = '0;
  end else begin : btb_gen
    btb #(
        .CVA6Cfg   (CVA6Cfg),
        .btb_update_t(btb_update_t),
        .btb_prediction_t(btb_prediction_t),
        .NR_ENTRIES(CVA6Cfg.BTBEntries)
    ) i_btb (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .debug_mode_i,
        .vpc_i           (vpc_btb),
        .btb_update_i    (btb_update),
        .btb_prediction_o(btb_prediction)
    );
  end

  if (CVA6Cfg.BHTEntries == 0) begin
    assign bht_prediction = '0;
  end else if (CVA6Cfg.BPType == config_pkg::BHT) begin : bht_gen
    bht #(
        .CVA6Cfg   (CVA6Cfg),
        .bht_update_t(bht_update_t),
        .NR_ENTRIES(CVA6Cfg.BHTEntries)
    ) i_bht (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .debug_mode_i,
        .vpc_i           (vpc_bht),
        .bht_update_i    (bht_update),
        .bht_prediction_o(bht_prediction)
    );
  end else if (CVA6Cfg.BPType == config_pkg::PH_BHT) begin : bht2lvl_gen
    bht2lvl #(
        .CVA6Cfg     (CVA6Cfg),
        .bht_update_t(bht_update_t)
    ) i_bht (
        .clk_i,
        .rst_ni,
        .flush_i         (flush_bp_i),
        .vpc_i           (icache_vaddr_q),
        .bht_update_i    (bht_update),
        .bht_prediction_o(bht_prediction)
    );
  end

  // we need to inspect up to CVA6Cfg.INSTR_PER_FETCH instructions for branches
  // and jumps
  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_instr_scan
    instr_scan #(
        .CVA6Cfg(CVA6Cfg)
    ) i_instr_scan (
        .instr_i     (instr[i]),
        .rvi_return_o(rvi_return[i]),
        .rvi_call_o  (rvi_call[i]),
        .rvi_branch_o(rvi_branch[i]),
        .rvi_jalr_o  (rvi_jalr[i]),
        .rvi_jump_o  (rvi_jump[i]),
        .rvi_imm_o   (rvi_imm[i]),
        .rvc_branch_o(rvc_branch[i]),
        .rvc_jump_o  (rvc_jump[i]),
        .rvc_jr_o    (rvc_jr[i]),
        .rvc_return_o(rvc_return[i]),
        .rvc_jalr_o  (rvc_jalr[i]),
        .rvc_call_o  (rvc_call[i]),
        .rvc_imm_o   (rvc_imm[i])
    );
  end

  instr_queue #(
      .CVA6Cfg(CVA6Cfg),
      .fetch_entry_t(fetch_entry_t)
  ) i_instr_queue (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (flush_i),
      .instr_i            (instr),                 // from re-aligner
      .addr_i             (addr),                  // from re-aligner
      .exception_i        (icache_ex_valid_q),     // from I$
      .exception_addr_i   (icache_vaddr_q),
      .exception_gpaddr_i (icache_gpaddr_q),
      .exception_tinst_i  (icache_tinst_q),
      .exception_gva_i    (icache_gva_q),
      .predict_address_i  (predict_address),
      .cf_type_i          (cf_type),
      .valid_i            (instruction_valid),     // from re-aligner
      .consumed_o         (instr_queue_consumed),
      .ready_o            (instr_queue_ready),
      .replay_o           (replay),
      .replay_addr_o      (replay_addr),
      .fetch_entry_o      (fetch_entry_o),         // to back-end
      .fetch_entry_valid_o(fetch_entry_valid_o),   // to back-end
      .fetch_entry_ready_i(fetch_entry_ready_i)    // to back-end
  );

endmodule
