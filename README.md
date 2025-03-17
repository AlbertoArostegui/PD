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

5. Set the $RISCV variable

6. Install help2man and device-tree-compiler
```bash
export RISCV=/path/to/toolchain/installation/directory
```

7. Install the python requirements
```bash
pip3 install -r verif/sim/dv/requirements.txt
```

Now, we are supposed to be able to run the tests, but I required some more configuration to make it run.
Go to cva6/verif/sim and `source setup-env.sh`. 
Export the desired simulators. I have used verilator and spike: `export DV_SIMULATORS=veri-testharness,spike`.
Before running any test, read the following section.

## 3. Now comes the tricky part.
If you have executed get-toolchain.sh inside cva6/ folder, you will have verilator-v5.008/ and spike/ folder inside the build/ folder.
I have sourced the verilator and spike binaries from these folders and have been able to run the tests. For ease of use I have put them in the $PATH.
```bash
export PATH="$HOME/cva6/tools/verilator-v5.008/bin:$HOME/cva6/tools/spike/bin:$PATH"
```
With this, we can run both verilator and spike binaries.

```bash
python3 cva6.py --target cv32a60x --iss=$DV_SIMULATORS --iss_yaml=cva6.yaml \
--c_tests ../tests/custom/hello_world/hello_world.c \
--linker=../../config/gen_from_riscv_config/linker/link.ld \
--gcc_opts="-static -mcmodel=medany -fvisibility=hidden -nostdlib \
-nostartfiles -g ../tests/custom/common/syscalls.c \
../tests/custom/common/crt.S -lgcc \
-I../tests/custom/env -I../tests/custom/common"
```

We can even create another C source file and run it, e. g., fibonacci.c
You just have to subsittute ../tests/custom/hello_world/hello_world.c with the path to your C source file.
If you want the waves of the simulation, follow the next steps.

## 4. The even trickier part.
Running tests from cva6/verif/sim is straight forward.
According to the official repo, to run the simulation and output the vcd wave files, you have to set TRACE_FAST to 1.
Sometimes, after setting this environmental variable, the simulation will crash because the script will look in different verilator directories, both cva6/tools/build/verilator/... and cva6/tools/build/verilator-v5.008/...
What I have done has been just to copy the verilator-v5.008 into another folder named verilator. This way, when it looks in any directory, it will find the source files for the VCD output. There are obviously more clever ways to achieve this functionality, but this just works. I assume you can also link it, but I haven't tried.



