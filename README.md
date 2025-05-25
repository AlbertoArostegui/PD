# PD Project

Fine grained multi-threading implementation of cva6

## Toolchain installation and testing

## 1. Clone the repo and initiate the submodules

```bash
git clone https://github.com/openhwgroup/cva6.git
cd cva6
git submodule update --init --recursive
```

## 2. Install GCC and the Toolchain.

### For the toolchain:

Prerequisites:
```bash
$ sudo apt-get install autoconf automake autotools-dev curl git libmpc-dev libmpfr-dev libgmp-dev gawk build-essential bison flex texinfo gperf libtool bc zlib1g-dev
```

1. Select an installation location for the toolchain. You may set this up and the toolchain not care. I set it up at /home/<user>/riscv but the toolchain ended up being installed in cva6/tools/ folder either way.
```bash
INSTALL_DIR=$RISCV
```

2. Get the toolchain itself, specify the version. I executed this from cva6/ folder, it creates the src/ and build/ folders. 
```bash
bash get-toolchain.sh gcc-13.1.0-baremetal
```

3. Build and install the toolchain specifying the version and the install directory.
```bash
bash build-toolchain.sh $INSTALL_DIR
```

4. Install cmake.

5. Set the $RISCV variable, this is where we will store the gcc binaries for Risc-V
It should be $INSTALL_DIR
```bash
export RISCV=$INSTALL_DIR
```

6. Install help2man and device-tree-compiler
```bash
export RISCV=/path/to/toolchain/installation/directory
```

7. Install the python requirements
```bash
pip3 install -r verif/sim/dv/requirements.txt
```

8. now, install the custom spike and verilator versions (set up NUM_JOBS for faster installation).
They should be installed under cva6/tools/spike and cva6/tools/verilator, respectively.
(from cva6/)
```bash
verif/regress/install-spike.sh
verif/regress/install-verilator.sh
```

We should set up some variables in order to be able to run the tests
```bash
export RISCV=$INSTALL_DIR
export RISCV_CC=$RISCV/bin/riscv-none-elf-gcc
export RISCV_OBJCOPY=$RISCV/bin/riscv-none-elf-objcopy
export SPIKE_INSTALL_DIR={cva6_dir}/tools/spike
export VERILATOR_INSTALL_DIR={cva6_dir}/tools/verilator
export DV_SIMULATORS=spike,veri-testharness
```

Now, we are supposed to be able to run the tests, but I required some more configuration to make it run.
Go to cva6/verif/sim and `source setup-env.sh`. 


And try to run the simulators:
```bash
python3 cva6.py --target cv32a60x --iss=$DV_SIMULATORS --iss_yaml=cva6.yaml --c_tests ../tests/custom/hello_world/hello_world.c --linker=../../config/gen_from_riscv_config/linker/link.ld --gcc_opts="-static -mcmodel=medany -fvisibility=hidden -nostdlib \
-nostartfiles -g ../tests/custom/common/syscalls.c \
../tests/custom/common/crt.S -lgcc \
-I../tests/custom/env -I../tests/custom/common"
```