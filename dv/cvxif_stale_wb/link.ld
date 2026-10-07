ENTRY(_start)
SECTIONS
{
  . = 0x80000000;                 /* CVA6 reset vector (boot_addr_i) */
  .text : ALIGN(4) { *(.text.main) }
  .data : ALIGN(8) { *(.data*) }
  .bss  : ALIGN(8) { *(.bss*) }
}
