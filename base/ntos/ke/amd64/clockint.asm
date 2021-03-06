       title  "Interval Clock Interrupt"
;++
;
; Copyright (c) Microsoft Corporation. All rights reserved. 
;
; You may only use this code if you agree to the terms of the Windows Research Kernel Source Code License agreement (see License.txt).
; If you do not agree to the terms, do not use the code.
;
;
; Module Name:
;
;   clockint.asm
;
; Abstract:
;
;   This module implements the architecture dependent code necessary to
;   process the interval clock interrupt.
;
;--

include ksamd64.inc

        extern  ExpInterlockedPopEntrySListEnd:proc
        extern  ExpInterlockedPopEntrySListResume:proc
        extern  KeMaximumIncrement:dword
        extern  KeTimeAdjustment:dword
        extern  KeUpdateRunTime:proc
        extern  KiCheckForSListAddress:proc
        extern  KiDpcInterruptBypass:proc
        extern  KiIdleSummary:qword
        extern  KiInitiateUserApc:proc
        extern  KiRestoreDebugRegisterState:proc
        extern  KiSaveDebugRegisterState:proc
        extern  KiTimeIncrement:qword
        extern  KiTimerTableListHead:qword
        extern  __imp_HalRequestSoftwareInterrupt:qword

        subttl  "Update System Time"
;++
;
; VOID
; KeUpdateSystemTime (
;     IN PKTRAP_FRAME TrapFrame,
;     IN ULONG64 Increment
;     )
;
; Routine Description:
;
;   This routine is called as the result of an interrupt generated by the
;   interval timer. Its function is to update the interrupt time, update the
;   system time, and check to determine if a timer has expired.
;
;   N.B. This routine is executed on a single processor in a multiprocess
;        system. The remainder of the processors only execute the quantum end
;        and runtime update code.
;
; Arguments:
;
;   TrapFrame (rcx) - Supplies the address of a trap frame.
;
;   Increment (rdx) - Supplies the time increment value in 100 nanosecond
;       units.
;
; Return Value:
;
;   None.
;
;--

UsFrame struct
        P1Home  dq ?                    ; parameter home addresses
        P2Home  dq ?                    ;
        P3Home  dq ?                    ;
        P4Home  dq ?
        SavedRbp dq ?                   ; saved register RBP
UsFrame ends

        NESTED_ENTRY KeUpdateSystemTime, _TEXT$00

        alloc_stack (sizeof UsFrame)    ; allocate stack frame
        save_reg rbp, UsFrame.SavedRbp  ; save nonvolatile register

        END_PROLOGUE

        lea     rbp, 128[rcx]           ; set display pointer address
        mov     KiTimeIncrement, rdx    ; save time increment value

;
; Check if the current clock tick should be skipped.
;
; Skip tick is set when the kernel debugger is entered.
;

if DBG

        cmp     byte ptr gs:[PcSkipTick], 0 ; check if tick should be skipped
        jnz     KiUS50                  ; if nz, skip clock tick

endif

;
; Update interrupt time.
;
; N.B. Interrupt time is aligned 0 mod 8.
;

        mov     rcx, USER_SHARED_DATA   ; get user shared data address
        lea     r11, KiTimerTableListHead ; get timer table address
        mov     r8, UsInterruptTime[rcx] ; get interrupt time
        add     r8, rdx                 ; compute updated interrupt time
        ror     r8, 32                  ; swap upper and lower halves
        mov     UsInterruptTime + 8[rcx], r8d ; save 2nd upper half
        ror     r8, 32                  ; swap upper and lower halves
        mov     UsInterruptTime[rcx], r8 ; save updated interrupt time
        mov     r10, UsTickCount[rcx]   ; get tick count value

ifndef NT_UP

   lock sub     gs:[PcMasterOffset], edx ; subtract time increment

else

        sub     gs:[PcMasterOffset], edx ; subtract time increment

endif

        jg      short KiUS20            ; if greater, not complete tick
        mov     eax, KeMaximumIncrement ; get maximum time increment
        add     gs:[PcMasterOffset], eax ; add maximum time to residue

;
; Update system time.
;
; N.B. System time is aligned 4 mod 8, however, this data does not cross
;      a cache line and is, therefore, updated atomically,
;

        mov     eax, KeTimeAdjustment   ; get time adjustment value
        add     rax, UsSystemTime[rcx]  ; compute updated system time
        ror     rax, 32                 ; swap upper and lower halves
        mov     UsSystemTime + 8[rcx], eax ; save upper 2nd half
        ror     rax, 32                 ; swap upper and lower halves
        mov     UsSystemTime[rcx], rax  ; save updated system time

;
; Update tick count.
;
; N.B. Tick count is aligned 0 mod 8.
;
        
        mov     rax, UsTickCount[rcx]   ; get tick count
        inc     rax                     ; increment tick count
        ror     rax, 32                 ; swap upper and lower halves
        mov     UsTickCount + 8[rcx], eax ; save 2nd upper half
        ror     rax, 32                 ; swap upper and lower halves
        mov     UsTickCount[rcx], rax   ; save updated tick count

;
; Check to determine if a timer has expired.
;

        .errnz  (TIMER_ENTRY_SIZE - 24)

        mov     rcx, r10                ; copy tick count value
        and     ecx, TIMER_TABLE_SIZE - 1 ; isolate current hand value
        lea     rcx, [rcx + rcx * 2]    ; multiply by 3
        cmp     r8, TtTime[r11 + rcx * 8] ; compare due time
        jae     short KiUS30            ; if ae, timer has expired
        inc     r10                     ; advance tick count value

;
; Check to determine if a timer has expired.
;

KiUS20: mov     rcx, r10                ; copy tick count value
        and     ecx, TIMER_TABLE_SIZE - 1 ; isolate current hand value
        lea     rcx, [rcx + rcx * 2]    ; multiply by 3
        cmp     r8, TtTime[r11 + rcx * 8] ; compare due time
        jb      short KiUS40            ; if b, timer has not expired

;
; A timer has expired.
;
; Set the timer hand value in the current processor block if it is not already
; set.
;

KiUS30: mov     rdx, gs:[PcCurrentPrcb] ; get current processor block address
        cmp     qword ptr PbTimerRequest[rdx], 0 ; check if expiration active
        jne     short KiUS40            ; if ne, expiration already active
        mov     PbTimerHand[rdx], r10   ; set timer hand value
        mov     byte ptr PbInterruptRequest[rdx], TRUE ; set interrupt request

;
; Update runtime.
;

KiUS40: lea     rcx, (-128)[rbp]        ; set trap frame address
        mov     rdx, KiTimeIncrement    ; set time increment value
        call    KeUpdateRunTime         ; update runtime

if DBG

KiUS50: mov     byte ptr gs:[PcSkipTick], 0 ; clear skip tick indicator

endif

        mov     rbp, UsFrame.SavedRbp[rsp] ; restore nonvolatile register
        add     rsp, (sizeof UsFrame)   ; deallocate stack frame
        ret                             ; return

        NESTED_END KeUpdateSystemTime, _TEXT$00

        subttl  "Secondary Processor Clock Interrupt Service Routine"
;++
;
; VOID
; KiSecondaryClockInterrupt (
;     VOID
;     )
;
; Routine Description:
;
;   This routine is entered as the result of an interprocessor interrupt
;   at CLOCK_LEVEL. Its function is to provide clock interrupt service on
;   secondary processors.
;
; Arguments:
;
;   None.
;
; Return Value:
;
;   None.
;
;--

        NESTED_ENTRY KiSecondaryClockInterrupt, _TEXT$00

        .pushframe                      ; mark machine frame

        alloc_stack 8                   ; allocate dummy vector
        push_reg rbp                    ; save nonvolatile register

        GENERATE_INTERRUPT_FRAME <>, <Direct> ; generate interrupt frame

        mov     ecx, CLOCK_LEVEL        ; set new IRQL level

	ENTER_INTERRUPT <NoEoi>         ; raise IRQL and enable interrupts

;
; Update runtime.
;

        lea     rcx, (-128)[rbp]        ; set trap frame address
        mov     rdx, KiTimeIncrement    ; set time increment value
        call    KeUpdateRunTime         ; update runtime

        EXIT_INTERRUPT <>, <>, <Direct> ; do EOI, lower IRQL and restore state

        NESTED_END KiSecondaryClockInterrupt, _TEXT$00

        end

