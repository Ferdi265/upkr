;; https://github.com/exoticorn/upkr/blob/z80/c_unpacker/unpack.c - original C implementation
;; C source in comments ahead of asm - the C macros are removed to keep only bitstream variant
;;
;; initial version by Peter "Ped" Helcmanovsky (C) 2022, licensed same as upkr project ("unlicensed")
;; to assemble use z00m's sjasmplus: https://github.com/z00m128/sjasmplus
;;
;; you can define UPKR_PROBS_ORIGIN to specific 256 byte aligned address for probs array (386 bytes),
;; otherwise it will be positioned after the unpacker code (256 aligned)
;;
;; public API:
;;
;;     upkr.unpack
;;         IN: IX = packed data, HL' (shadow HL) = destination
;;         OUT: IX = after packed data
;;         modifies: all registers except IY, requires 14 bytes of stack space
;;

    OPT push reset --syntax=abf
    MODULE upkr

/*
u8* upkr_data_ptr;
u8 upkr_probs[1 + 255 + 1 + 2*32 + 2*32];
u16 upkr_state;
u8 upkr_current_byte;
int upkr_bits_left;

int upkr_unpack(void* destination, void* compressed_data) {
    upkr_data_ptr = (u8*)compressed_data;
    upkr_state = 0;
    upkr_bits_left = 0;
    for(int i = 0; i < sizeof(upkr_probs); ++i)
        upkr_probs[i] = 128;

    u8* write_ptr = (u8*)destination;

    int prev_was_match = 0;
    int offset = 0;
    for(;;) {
        if(upkr_decode_bit(0)) {
            if(prev_was_match || upkr_decode_bit(256)) {
                offset = upkr_decode_length(257) - 1;
                if(offset == 0) {
                    break;
                }
            }
            int length = upkr_decode_length(257 + 64);
            while(length--) {
                *write_ptr = write_ptr[-offset];
                ++write_ptr;
            }
            prev_was_match = 1;
        } else {
            int byte = 1;
            while(byte < 256) {
                int bit = upkr_decode_bit(byte);
                byte = (byte << 1) + bit;
            }
            *write_ptr++ = byte;
            prev_was_match = 0;
        }
    }

    return write_ptr - (u8*)destination;
}
*/
; IN: IX = compressed_data, HL' = destination
unpack:
  ; ** reset probs to 0x80, also reset HL (state) to zero, and set BC to probs+context 0
    ld      hl,probs.c>>1
    ld      bc,probs.e
    ld      a,$80
.reset_probs:
    dec     bc
    ld      (bc),a              ; will overwrite one extra byte after the array because of odd length
    dec     bc
    ld      (bc),a
    dec     l
    jr      nz,.reset_probs
    exa
    ; BC = probs (context_index 0), state HL = 0, A' = 0x80 (no source bits left in upkr_current_byte)

  ; ** main loop to decompress data
.decompress_data_reset_match:
    ld      d,0                 ; prev_was_match = 0;
.decompress_data:
    ld      c,0
    call    decode_bit          ; if(upkr_decode_bit(0))
    jr      c,.copy_chunk

  ; * extract byte from compressed data (literal)
    ld      e,1                 ; E = byte = 1
.decode_byte:
    ld      c,e
    call    decode_bit          ; bit = upkr_decode_bit(byte);
    rl      e                   ; byte = (byte << 1) + bit;
    jr      nc,.decode_byte     ; while(byte < 256)
    ld      a,e
    exx
    ld      (hl),a              ; *write_ptr++ = byte;
    inc     hl
    exx
    jr      .decompress_data_reset_match

  ; * copy chunk of already decompressed data (match)
.copy_chunk:
    inc     b                   ; context_index = 256
        ;             if(prev_was_match || upkr_decode_bit(256)) {
        ;                 offset = upkr_decode_length(257) - 1;
        ;                 if (0 == offset) break;
        ;             }
    ld      a,d                 ; A = prev_was_match
    or      a
    jr      nz,.decode_offset   ; if(prev_was_match
    call    decode_bit          ; upkr_decode_bit(256)
    jr      nc,.keep_offset
.decode_offset:
    inc     c
    call    decode_length
    dec     de                  ; offset = upkr_decode_length(257) - 1;
    ld      a,d
    or      e
    ret     z                   ; if(offset == 0) break
    ld      (.offset),de
.keep_offset:
        ;             int length = upkr_decode_length(257 + 64);
        ;             while(length--) {
        ;                 *write_ptr = write_ptr[-offset];
        ;                 ++write_ptr;
        ;             }
        ;             prev_was_match = 1;
    ld      c,low(257+64)       ; context_index = 257+64
    call    decode_length       ; length = upkr_decode_length(257 + 64);
    push    de
    exx
    push    hl
.offset+*:  ld      de,0
    or      a
    sbc     hl,de
    pop     de
    pop     bc
    ldir
    ex      de,hl
    exx
    ld      d,b                 ; prev_was_match = non-zero
    djnz    .decompress_data    ; adjust context_index back to 0..255 range, go to main loop

/*
int upkr_decode_bit(int context_index) {
    while(upkr_state < 32768) {
        if(upkr_bits_left == 0) {
            upkr_current_byte = *upkr_data_ptr++;
            upkr_bits_left = 8;
        }
        upkr_state = (upkr_state << 1) + (upkr_current_byte >> 7);
        upkr_current_byte <<= 1;
        --upkr_bits_left;
    }

    int prob = upkr_probs[context_index];
    int bit = (upkr_state & 255) >= prob ? 1 : 0;

    int prob_offset = 16;
    int state_offset = 0;
    int state_scale = prob;
    if(bit) {
        state_offset = -prob;
        state_scale = 256 - prob;
        prob_offset = 0;
    }
    upkr_state = state_offset + state_scale * (upkr_state >> 8) + (upkr_state & 255);
    upkr_probs[context_index] = prob_offset + prob - ((prob + 8) >> 4);

    return bit;
}
*/
decode_bit:
  ; HL = upkr_state
  ; IX = upkr_data_ptr
  ; BC = probs+context_index
  ; A' = upkr_current_byte (!!! init to 0x80 at start, not 0x00)
  ; preserves DE
  ; ** while (state < 32768) - initial check
    push    de
    bit     7,h
    jr      nz,.state_b15_set
    exa
  ; ** while body
.state_b15_zero:
  ; HL = upkr_state
  ; IX = upkr_data_ptr
  ; A = upkr_current_byte (init to 0x80 at start, not 0x00)
    add     a,a                     ; upkr_current_byte <<= 1; // and testing if(upkr_bits_left == 0)
    jr      nz,.has_bit             ; CF=data, ZF=0 -> some bits + stop bit still available
  ; CF=1 (by stop bit)
    ld      a,(ix)
    inc     ix                      ; upkr_current_byte = *upkr_data_ptr++;
    adc     a,a                     ; CF=data, b0=1 as new stop bit
.has_bit:
    adc     hl,hl                   ; upkr_state = (upkr_state << 1) + (upkr_current_byte >> 7);
    jp      p,.state_b15_zero       ; while (state < 32768)
    exa
  ; ** set "bit"
.state_b15_set:
    ld      a,(bc)                  ; A = upkr_probs[context_index]
    dec     a                       ; prob is in ~7..249 range, never zero, safe to -1
    cp      l                       ; CF = bit = prob-1 < (upkr_state & 255) <=> prob <= (upkr_state & 255)
    inc     a
  ; ** adjust state
    push    af
    push    af
    push    hl
    push    af
    jr      nc,.bit_is_0
    neg                             ; A = -prob == (256-prob), CF=1 preserved
.bit_is_0:
    ld      d,0
    ld      e,a                     ; DE = state_scale ; prob || (256-prob)
    ld      l,d                     ; H:L = (upkr_state>>8) : 0
    ld      a,8                     ; counter
.mulLoop:
    add     hl,hl
    jr      nc,.mul0
    add     hl,de
.mul0:
    dec     a
    jr      nz,.mulLoop             ; until HL = state_scale * (upkr_state>>8)
    pop     af
    jr      nc,.bit_is_0_2
    dec     d                       ; D = 0xFF (DE = -prob)
    add     hl,de                   ; HL += -prob
.bit_is_0_2:                        ; HL = state_offset + state_scale * (upkr_state >> 8)
    pop     de
    ld      d,0                     ; DE = (upkr_state & 255)
    add     hl,de                   ; HL = state_offset + state_scale * (upkr_state >> 8) + (upkr_state & 255) ; new upkr_state
 ; *** adjust probs[context_index]
    pop     af                      ; restore prob and bit
    ld      e,a
    jr      c,.bit_is_1
    ld      d,-16                   ; 0xF0
.bit_is_1:                          ; D:E = -prob_offset:prob, A = prob
    ;FIXME and + 4x rra will be probably shorter!
    srl     a
    srl     a
    srl     a
    srl     a
    adc     a,d                     ; A = -prob_offset + ((prob + 8) >> 4)
    neg
    add     a,e                     ; A = prob_offset + prob - ((prob + 8) >> 4)
    ld      (bc),a                  ; update probs[context_index]
    pop     af                      ; restore resulting CF = bit
        ; TODO: check if it's possible to `cpl` instead of neg, have +1 on original prob,
        ; and get correct CF=bit from `add a,e` then (without extra push+pop AF)
        ; !!! I think this will **NOT** work, because clamping of prob ends with +-0 at both ends (cpl 0 -> 255 -> CF=1)
    pop     de
    ret

/*
int upkr_decode_length(int context_index) {
    int length = 0;
    int bit_pos = 0;
    while(upkr_decode_bit(context_index)) {
        length |= upkr_decode_bit(context_index + 1) << bit_pos++;
        context_index += 2;
    }
    return length | (1 << bit_pos);
}
*/
decode_length:
  ; HL = upkr_state
  ; IX = upkr_data_ptr
  ; BC = probs+context_index
  ; A' = upkr_current_byte (!!! init to 0x80 at start, not 0x00)
  ; return length in DE
    ld      de,$8000            ; length = 0 with positional-stop-bit
    jr      .loop_entry
.loop:
    inc     bc                  ; context_index + 1 ; TODO can be just `inc c` for 257.. and 257+64.. contexts
    call    decode_bit
    rr      d
    rr      e                   ; DE = length = (length >> 1) | (bit << 15);
    inc     bc                  ; context_index += 2 ; TODO can be just `inc c` for 257.. and 257+64.. contexts
.loop_entry:
    call    decode_bit
    jr      c,.loop
    scf                         ; will become this final `| (1 << bit_pos)` bit
.fix_bit_pos:
    rr      d
    rr      e
    jr      nc,.fix_bit_pos     ; until stop bit is reached (all bits did land to correct position)
    ret

    DISPLAY "upkr.unpack total size: ",/D,$-unpack

    ; reserve space for probs array without emitting any machine code (using only EQU)

    IFDEF UPKR_PROBS_ORIGIN     ; if specific address is defined by user, move probs array there
    ORG UPKR_PROBS_ORIGIN
    ENDIF

probs:      EQU ($+255) & -$100                 ; probs array aligned to 256
.real_c:    EQU 1 + 255 + 1 + 2*32 + 2*32       ; real size of probs array
.c:         EQU (.real_c + 1) & -2              ; padding to even size (required by init code)
.e:         EQU probs + .c

    DISPLAY "upkr.unpack probs array placed at: ",/A,probs,",\tsize: ",/A,probs.c

    ENDMODULE
    OPT pop
