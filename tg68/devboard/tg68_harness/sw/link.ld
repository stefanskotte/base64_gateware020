/* Test programs run from fast RAM: loaded by the ROM loader at $08000000. */
ENTRY(_start)
SECTIONS {
    . = 0x08000000;
    .text : { KEEP(*(.text.start)) *(.text*) *(.rodata*) }
    .data : { *(.data*) }
    . = ALIGN(4);
    __bss_start = .;
    .bss : { *(.bss*) *(COMMON) }
    . = ALIGN(4);
    __bss_end = .;
    __end = .;
}
