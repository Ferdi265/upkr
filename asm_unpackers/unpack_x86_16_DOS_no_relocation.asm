; Contributions from pestis, TomCat and exoticorn
;
; This is the 16-bit DOS x86 decompression stub for upkr, which decompresses the
; code starting at address 0x3FFE (or whatever is defined by the entrypoint
; below). Thus, the packed code needs to be assembled with org 0x3FFE to work.
;
; How to use:
;   1) Put POPA as the first instruction of your compiled code and use org
;      0x3FFE
;   2) Pack your intro using upkr into data.bin with the --x86 command line
;      argument:
;
;           $ upkr --x86 intro.com data.bin
;
;   2) Compile this .asm file using nasm (or any compatible assembler) e.g.
;
;           $ nasm unpack_x86_16_DOS_no_relocation.asm -fbin -o intropck.com
;
; In specific cases, the unpacker stub can be further optimized to save a byte
; or two:
;   1) If your stub+compressed code is 2k or smaller, you can save 1 byte by
;      putting probs at 0x900 and initializing DI with SALC; XCHG AX, DI instead
;      of MOV DI, probs
;   2) If you remove the PUSHA (and POPA in the compressed code), then you can
;      assume the registers as follows: AX = 0x00XX, BX = probs + 0x1XX, CX = 0
;      DX = (trash), SI = DI = right after your program, SP = as it was when the
;      program started, flags = carry set
;
; Note that even with the PUSHA / POPA, carry will be set (!) unlike normal dos
; program.
entry       equ 0x3FFE
probs       equ entry - 0x1FE   ; must be aligned to 256

org 0x100


; This is will be loaded at 0x100, but relocates the code and data to prog_start
upkr_unpack:
    pusha
    xchg    ax, bp              ; position in bitstream = 0
    cwd                         ; upkr_state = 0;
    mov     di, probs
    mov     ax, 0x8080          ; for(int i = 0; i < sizeof(upkr_probs); ++i) upkr_probs[i] = 128;
    rep     stosw
    push    di
.mainloop:
    mov     bx, probs
    call    upkr_decode_bit
    jc      .else               ; if(upkr_decode_bit(0)) {
    mov     bh, (probs+256)/256
    jcxz    .skip_call          ; if(prev_was_match || upkr_decode_bit(257)) {
    call    upkr_decode_bit
    jc      .skipoffset
.skip_call:
    stc
    call    upkr_decode_number  ;  offset = upkr_decode_number(258) - 1;
    mov     si, di
    loop    .sub                ; if(offset == 0)
    ret
.sub:
    dec     si
    loop    .sub
.skipoffset:
    mov     bl, 128             ; int length = upkr_decode_number(384);
    call    upkr_decode_number
    rep     movsb               ; *write_ptr = write_ptr[-offset];
    jmp     .mainloop
.byteloop:
    call    upkr_decode_bit     ; int bit = upkr_decode_bit(byte);
.else:
    adc     bl, bl              ; byte = (byte << 1) + bit;
    jnc     .byteloop
    xchg    ax, bx
    stosb
    inc     si
    mov     cl, 1
    jmp     .mainloop           ;  prev_was_match = 0;


; upkr_decode_bit decodes one bit from the rANS entropy encoded bit stream.
; parameters:
;    bx = memory address of the context probability
;    dx = decoder state
;    bp = bit position in input stream
; returns:
;    dx = new decoder state
;    bp = new bit position in input stream
;    carry = bit
; trashes ax
upkr_load_bit:
    bt      [compressed_data], bp
    inc     bp
    adc     dx, dx
upkr_decode_bit:
    inc     dx
    dec     dx              ; inc dx, dec dx is used to test the top (sign) bit of dx
    jns     upkr_load_bit
    movzx   ax, byte [bx]   ; int prob = upkr_probs[context_index]
    push    ax              ; save prob
    cmp     dl, al          ; int bit = (upkr_state & 255) < prob ? 1 : 0; (carry = bit)
    pushf                   ; save bit flags
    jc      .bit            ; (skip if bit)
    neg     al              ;   tmp = 256 - tmp;
.bit:
    mov     [bx], al        ; tmp_new = tmp + (256 - tmp + 8) >> 4;
    neg     byte [bx]
    shr     byte [bx], 4
    adc     [bx], al
    mul     dh              ; upkr_state = tmp * (upkr_state >> 8) + (upkr_state & 255);
    mov     dh, 0
    add     dx, ax
    popf
    pop     ax
    jc      .bit2           ; (skip if bit)
    neg     byte [bx]       ;   tmp = 256 - tmp;
    sub     dx, ax          ;    upkr_state -= prob; note that this will also leave carry always unset, which is what we want
.bit2:
    ret                     ; flags = bit


; upkr_decode_number loads a variable length encoded number (up to 16 bits) from
; the compressed stream. Only numbers 1..65535 can be encoded. If the encoded
; number has 4 bits and is 1ABC, it is encoded using a kind of an "interleaved
; elias code": 0A0B0C1. The 1 in the end implies that no more bits are coming.
; parameters:
;   cx = must be 0
;   bx = memory address of the context probability
;   dx = decoder state
;   bp = bit position in input stream
;   carry = must be 1
; returns:
;   cx = length
;   dx = new decoder state
;   bp = new bit position in input stream
;   carry = 1
; trashes bl, ax
upkr_decode_number_loop:
    inc     bx
    call    upkr_decode_bit
upkr_decode_number:
    rcr     cx, 1
    inc     bx
    call    upkr_decode_bit
    jnc     upkr_decode_number_loop ; while(upkr_decode_bit(context_index)) {
.loop2:
    rcr     cx, 1
    jnc     .loop2
    ret


compressed_data:
    incbin  "data.bin"
