import 'package:arm7_tdmi/arm7_tdmi.dart';
import 'package:binary/binary.dart' as binary;
import 'package:test/test.dart';

import '../common/matchers.dart';
import '../common/rom.dart';

void main() {
  test('Addition overflow should occur', () {
    final rom = createRom([
      0xe3e01000, // mvn  r1, #0
      0xe3a02001, // mov  r2, #1
      0xe0910002, // adds r0, r1, r2
    ]);
    final cpu = new TracedCpu(
      read16: (a) => rom[a ~/ 4],
      read32: (a) => rom[a ~/ 4],
    )..step();
    expect(cpu.pc, resetLabel);
    for (var i = 0; i < 3; i++) {
      cpu.step();
    }
    final expected = new Psr.bits(cpu.cpsr.value)
      ..n = false
      ..z = true
      ..c = true
      ..v = false;
    expect(
      cpu.cpsr,
      new EqualsPsr(expected),
      reason: cpu.getTraces().join('\n'),
    );
    expect(
      cpu.gprs[1],
      binary.uint32.max,
      reason: ''
          'Should have stored uint32.max in r1\n'
          '${cpu.getTraces().join('\n')}',
    );
    expect(
      cpu.gprs[2],
      1,
      reason: ''
          'Should have stored #1 in r2\n'
          '${cpu.getTraces().join('\n')}',
    );
    expect(
      cpu.gprs[0],
      0,
      reason: ''
          'Should have stored #0 in r0\n'
          '${cpu.getTraces().join('\n')}',
    );
  });

  test('Undefined instruction trap should be triggered', () {
    final rom = createRom([0xFF000000 /* Undefined Instruction */]);
    final cpu = new Cpu.noExecution(read32: (a) => rom[a ~/ 4])
      ..step(); // Reset branch.
    expect(cpu.pc, resetLabel);
    cpu.step(); // Execute undefined instruction.
    expect(
      cpu.pc,
      0x00000004,
      reason: ''
          'Next read should fetch instruction from the undefined instruction '
          'interrupt (0x00000004)',
      skip: 'TO BE FIXED',
    );
    expect(cpu.mode, Mode.und, skip: 'TO BE FIXED');
  });

  test('Software interrupt should raise a SWI exception', () {
    final rom = createRom([0xEF00000F]);
    final cpu = new Cpu.noExecution(read32: (a) => rom[a ~/ 4])
      ..step(); // Reset branch.
    expect(cpu.pc, resetLabel);
    cpu.step();

    // Next read should fetch instruction from the software interrupt exception
    // vector (0x00000008).
    expect(cpu.pc, 0x00000008);

    // CPU mode should be supervisor.
    expect(cpu.mode, Mode.svc);

    // R14_svc - 4 should be address of the SWI instruction.
    final address = cpu.gprs[14] - 4;
    expect(rom[address ~/ 4], 0xEF00000F);
  });

  test('Data abort should take the trap when an address is unavailable', () {
    const abortInst = 0xE5901000;
    final rom = createRom([
      0xe51f0000, // ldr r0, [pc, #-0]
      abortInst, // ldr r1, [r0]
      0x12345678, // embedded constant for ldr r0 instruction
    ]);
    final cpu = new Cpu.noExecution(read32: (a) {
      assert(a % 4 == 0);
      if (a >= rom.length * 4) {
        throw MemoryException.badAddress;
      }
      return rom[a ~/ 4];
    })
      ..step(); // Reset branch.

    expect(cpu.pc, resetLabel);
    cpu.step();

    // R0 should contain 0x12345678 now.
    expect(cpu.gprs[0], 0x12345678);

    // Trying to read from memory address 0x12345678 should raise a data-abort.
    cpu.step();
    const dataAbortVector = 0x00000010;
    expect(cpu.pc, dataAbortVector);
    expect(cpu.mode, Mode.abt);

    // Instruction that caused the abort should be at R14_abt - 8.
    final address = cpu.gprs[14] - 8;
    expect(rom[address ~/ 4], abortInst);
  });

  test('taking nFIQ input HIGH should raise an FIQ Exception', () {
    final rom = createRom([
      0xe10f1000, // mrs r1, CPSR
      0xe3c11040, // bic r1, r1, #64
      0xe121f001, // msr CPSR_c, r1

      // Some random instructions
      0xe0a15003, // adc  r5, r1, r3
      0xe280001a, // add  r0, r0, #26
      0xe1510000, // cmp  r1, r0
    ]);

    final cpu = new Cpu.noExecution(read32: (a) {
      assert(a % 4 == 0);
      return rom[a ~/ 4];
    })
      ..step(); // Reset branch.

    expect(cpu.pc, resetLabel);
    // CPU mode should be 'supervisor' and FIQ interrupts disabled.
    expect(cpu.mode, Mode.svc);
    expect(cpu.isFiqDisabled, true);

    for (int i = 0; i < 3; i++) {
      cpu.step();
    }
    // FIQ interrupts should now be enabled.
    expect(cpu.isFiqDisabled, false);

    // Execute some instruction and then take nFIQ input LOW.
    cpu
      ..step()
      ..inputFIQ = false;

    // Next step should result in FIQ trap being taken.
    final fiqVector = 0x0000001C;

    cpu.step();
    expect(cpu.pc, fiqVector);
    expect(cpu.mode, Mode.fiq);

    // FIQ exception should have disabled FIQ interrupts.
    expect(cpu.cpsr.f, true);
    // IRQs should also be disabled.
    expect(cpu.cpsr.i, true);
  });

  test('IRQ exception should be raised when taking the nIRQ input HIGH', () {
    final rom = createRom([
      0xe10f1000, // mrs r1, CPSR
      0xe3c110c0, // bic r1, r1, #0xC0
      0xe121f001, // msr CPSR_c, r1

      // Some random instructions
      0xe0a15003, // adc  r5, r1, r3
      0xe280001a, // add  r0, r0, #26
      0xe1510000 // cmp  r1, r0
    ]);
    final cpu = new Cpu.noExecution(read32: (a) {
      assert(a % 4 == 0);
      return rom[a ~/ 4];
    })
      ..step(); // Reset branch.

    expect(cpu.pc, resetLabel);

    // CPU mode should be 'supervisor' and IRQ + FIQ interrupts disabled.
    expect(cpu.mode, Mode.svc);
    expect(cpu.cpsr.i, true);
    expect(cpu.cpsr.f, true);

    for (var i = 0; i < 3; i++) {
      cpu.step();
    }

    // IRQ + FIQ interrupts should now be enabled.
    expect(cpu.cpsr.i, false);
    expect(cpu.cpsr.f, false);

    // Execute some instruction and then take nIRQ input LOW.
    cpu
      ..step()
      ..inputIRQ = false;

    // Next step should result in IRQ trap being taken.
    final irqVector = 0x00000018;
    cpu.step();
    expect(cpu.pc, irqVector);
    expect(cpu.mode, Mode.irq);
    // IRQ exception should have disabled IRQ interrupts but FIQ interrupts
    // should still be enabled.
    expect(cpu.cpsr.i, true);
    expect(cpu.cpsr.f, false);
  });

  test('switching processor modes should work as expected.', () {
    final rom = createRom([
      // Switch to System mode
      0xe10f3000, // mrs r3, CPSR
      0xe383301f, // orr r3, r3, #31
      0xe129f003, // msr CPSR_fc, r3

      // Switch to User mode
      0xe10f3000, // mrs r3, CPSR
      0xe3c3301f, // bic r3, r3, #31
      0xe3833010, // orr r3, r3, #16
      0xe129f003, // msr CPSR_fc, r3

      // Switch to Supervisor mode
      0xe10f3000, // mrs r3, CPSR
      0xe3c3301f, // bic r3, r3, #31
      0xe3833013, // orr r3, r3, #19
      0xe129f003 // msr CPSR_fc, r3
    ]);

    final cpu = new Cpu.noExecution(read32: (a) {
      expect(a % 4, 0);
      return rom[a ~/ 4];
    })
      ..step(); // Reset branch.
    expect(cpu.pc, resetLabel);
    // Cpu starts up in 'supervisor' mode.
    expect(cpu.mode, Mode.svc);

    for (var i = 0; i < 3; i++) {
      cpu.step();
    }

    expect(cpu.mode, Mode.sys);
    for (var i = 0; i < 4; i++) {
      cpu.step();
    }

    expect(cpu.mode, Mode.usr);
    // Trying to switch from user mode to a privileged mode must not work,
    // of course.
    for (var i = 0; i < 4; i++) {
      cpu.step();
    }

    expect(cpu.mode, Mode.usr);
  });

  test(
      'Banked registers should be switched in when a processor mode switch '
      'occurs', () {
    // Stack pointer is banked.
    final sp_svc = 0x87654321;
    final sp_usr = 0x11112222;

    final rom = createRom([
      0xe59fd01c, // ldr sp, [pc, #28]	; 5c <ResetException + 0x24>
      // Switch to System mode
      0xe10f3000, // mrs r3, CPSR
      0xe383301f, // orr r3, r3, #31
      0xe129f003, // msr CPSR_fc, r3
      0xe59fd010, // ldr sp, [pc, #16]	; 60 <ResetException + 0x28>
      // Switch to User mode
      0xe10f3000, // mrs r3, CPSR
      0xe3c3301f, // bic r3, r3, #31
      0xe3833010, // orr r3, r3, #16
      0xe129f003, // msr CPSR_fc, r3
      0x87654321,
      0x11112222
    ]);

    final cpu = new Cpu.noExecution(read32: (a) {
      expect(a % 4, 0);
      return rom[a ~/ 4];
    })
      ..step(); // Reset branch.
    expect(cpu.pc, resetLabel);
    // Cpu starts in 'supervisor' mode.
    expect(cpu.mode, Mode.svc);
    cpu.step();
    expect(cpu.gprs[13], sp_svc);
    for (var i = 0; i < 3; i++) {
      cpu.step();
    }
    expect(cpu.mode, Mode.sys);
    expect(cpu.gprs[13], isNot(sp_svc));

    cpu.step();
    expect(cpu.gprs[13], sp_usr);
    for (var i = 0; i < 4; i++) {
      cpu.step();
    }
    expect(cpu.mode, Mode.usr);
    // User and System modes share register bank, so stack-pointer should still
    // have the same value as before.
    expect(cpu.gprs[13], sp_usr);
  });
}
