In this document will be laid out definitions and explanations about the FGMT implementation of cva6.

We will start with the thread. A thread will be an OS thread, with its own context, and it could belong to the same process. So they could share an ASID.

We will be adding the thread_id field to structs used across different structures.

###### CVA6.sv

- bt_resolve_t: we will want to know from which thread is the resolution of a branch in order to correctly update the PC of that thread.
- fetch_entry_t: we store the thread_id in the entry passed to decode from fetch in order to propagate it through the pipeline.
- scoreboard_entry_t: we will be adding the thread_id field in order to correctly propagate it through the pipeline.

###### ariane_pkg.sv
- We created an ENUM in order to store the threads current status:
```systemverilog
  typedef enum logic [2:0] {
    READY,
    RUNNING,
    STALLED_ICACHE,
    STALLED_DCACHE,
    HALTED
  } thread_status_t;
```

- 

# Changes

## Frontend

The frontend is going to receive several updates, because we need all the logic in order to select the next thread to run. Furthermore, all the different components that matter in this stage (BP, RAS, ICACHE) need to be addressed in order to adapt their behaviour with an implementation using several threads.

#### Thread_context module
From this module, we will get the next PC, which will be the one from the next thread which is in the READY state. We will also be updating the status of each thread and its PC within this module.

#### Thread_schedule block
In this combinational block, the next thread will be scheduled. We will cycle through all the available threads and select the first one that we find is ready.

#### New next PC block (Updated from old npc_select)
The new PC logic keeps most of the structure, the priorities are the same, but we update the PC of the current thread. In case of branch resolutions, we update the PC of the thread who scheduled the branch. For now, we are sharing the BP structure.

#### Thread status update block
We are going to calculate the status of the thread. We have to bear in mind if the ICache is stalled currently, and, for those threads that were stalled because of an ICache miss, we must update their status once we have the instructions ready. For the other types of stalls, we have not yet implemented anything.

#### Replication of the RAS
We have replicated the RAS based on thread in order to correctly predict the return addresses, per thread.

## Pipeline
Changes to the pipeline are needed to propagate the thread_id across the stages, so we will have to add the thread_id to the structures used as data transfer through the stages.

Once the PC of the current thread exists the frontend, the thread_id is propagated through decode, not much to change here. 
In the issue stage, precisely in the scoreboard, we have updated the struct to contain the thread_id and correctly propagate it once it enters execute. Furthermore, in order to correctly forward the values, we need to correctly use only the forwarding values which are from this thread's previous instructions.

In the execute stage, we will be making some changes to the writeback of the instructions:
- In the FLU (fixed latency units) its simple, we just return the same thread_id that entered in the scoreboard entry struct (the input).
- In the LSU, we have to first store the thread_id while the operations complete, regarding stalls, delays and so on. Once the instruction is marked as valid output, we take that same thread_id for the writeback.

##### EX stage
###### Multiplier
Pipelined the thread_id that comes in `fu_data_t` in both the multiplier (simple sequential 1 cycle multiplication) and in the serdiv (pipelining until it finished). From there, propagated into the output of the `mult.sv` module in order to assign it to the writeback port `thread_id_o` of the EX stage when `mult_valid` is asserted.
