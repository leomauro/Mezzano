;;;; Copyright (c) 2011-2016 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

(in-package :mezzano.runtime)

(sys.int::defglobal *paranoid-allocation*)

(sys.int::defglobal sys.int::*wired-area-bump*)
(sys.int::defglobal sys.int::*wired-area-freelist*)
(sys.int::defglobal sys.int::*pinned-area-bump*)
(sys.int::defglobal sys.int::*pinned-area-freelist*)
(sys.int::defglobal sys.int::*general-area-bump*)
(sys.int::defglobal sys.int::*general-area-limit*)
(sys.int::defglobal sys.int::*cons-area-bump*)
(sys.int::defglobal sys.int::*cons-area-limit*)
(sys.int::defglobal sys.int::*stack-area-bump*)

(sys.int::defglobal *wired-allocator-lock*)
(sys.int::defglobal *allocator-lock*)
(sys.int::defglobal *general-area-expansion-granularity* (* 4 1024 1024))
(sys.int::defglobal *cons-area-expansion-granularity* (* 4 1024 1024))

(defvar *maximum-allocation-attempts* 5
  "GC this many times before giving up on an allocation.")

(defvar *enable-allocation-profiling* nil)
(defvar *allocation-profile*)

;; Use a seperate function here, as the compiler seems to want to
;; hoist allocation outside the *ENABLE-ALLOCATION-PROFILING* test.
;; This generates data in the same format as the statistical profiler.
(defun log-allocation-profile-entry-1 ()
  (let ((*enable-allocation-profiling* nil))
    (vector-push-extend :start *allocation-profile*)
    (vector-push-extend (mezzano.supervisor:current-thread) *allocation-profile*)
    (vector-push-extend :active *allocation-profile*)
    (vector-push-extend :allocation *allocation-profile*)
    (sys.int::map-backtrace
     (lambda (i fp)
       (let* ((return-address (sys.int::memref-signed-byte-64 fp 1))
              (fn (sys.int::return-address-to-function return-address))
              (fn-address (logand (sys.int::lisp-object-address fn) -16))
              (offset (- return-address fn-address)))
         (vector-push-extend fn *allocation-profile*)
         (vector-push-extend offset *allocation-profile*))))))

(defun log-allocation-profile-entry ()
  (when *enable-allocation-profiling*
    (log-allocation-profile-entry-1)))

(defun freelist-entry-next (entry)
  (sys.int::memref-t entry 1))

(defun (setf freelist-entry-next) (value entry)
  (setf (sys.int::memref-t entry 1) value))

(defun freelist-entry-size (entry)
  (ash (sys.int::memref-unsigned-byte-64 entry 0) (- sys.int::+object-data-shift+)))

(defun first-run-initialize-allocator ()
  (setf *wired-allocator-lock* :unlocked
        sys.int::*gc-in-progress* nil
        sys.int::*pinned-mark-bit* 0
        sys.int::*dynamic-mark-bit* 0
        sys.int::*general-area-limit* (logand (+ sys.int::*general-area-bump* #x1FFFFF) (lognot #x1FFFFF))
        sys.int::*cons-area-limit* (logand (+ sys.int::*cons-area-bump* #x1FFFFF) (lognot #x1FFFFF))
        *enable-allocation-profiling* nil
        *allocator-lock* (mezzano.supervisor:make-mutex "Allocator")))

(defun verify-freelist (start base end)
  (do ((freelist start (freelist-entry-next freelist))
       (prev nil freelist))
      ((null freelist))
    (unless (and
             ;; A freelist entry must fall within area limits.
             (<= base freelist)
             (< freelist end)
             (<= (+ freelist (* (freelist-entry-size freelist) 8)) end)
             ;; Must have a non-zero size.
             (not (zerop (freelist-entry-size freelist)))
             ;; Must have the correct object tag.
             (eql (ldb (byte sys.int::+object-type-size+ sys.int::+object-type-shift+)
                       (sys.int::memref-unsigned-byte-64 freelist 0))
                  sys.int::+object-tag-freelist-entry+)
             ;; Must have a fixnum link, or be the end of the list.
             (or (sys.int::fixnump (freelist-entry-next freelist))
                 (not (freelist-entry-next freelist)))
             ;; Must be after the end of the previous freelist entry.
             (or (not prev)
                 (> freelist (+ prev (* (freelist-entry-size prev) 8)))))
      (mezzano.supervisor:panic "Corrupt freelist."))))

(defun set-allocated-object-header (address tag data mark-bit)
  ;; Be careful to avoid bignum consing here. Some functions can have a
  ;; data value larger than a fixnum when shifted.
  (setf (sys.int::memref-unsigned-byte-32 address 0) (logior mark-bit
                                                             (ash tag sys.int::+object-type-shift+)
                                                             (ash (ldb (byte (- 32 sys.int::+object-data-shift+) 0) data) sys.int::+object-data-shift+))
        (sys.int::memref-unsigned-byte-32 address 1) (ldb (byte 32 (- 32 sys.int::+object-data-shift+)) data)))

;; Simple first-fit freelist allocator for pinned areas.
(defun %allocate-from-freelist-area (tag data words freelist-symbol)
  ;; Traverse the freelist.
  (do ((freelist (symbol-value freelist-symbol) (freelist-entry-next freelist))
       (prev nil freelist))
      ((null freelist)
       nil)
    (let ((size (freelist-entry-size freelist)))
      (when (>= size words)
        ;; This freelist entry is large enough, use it.
        (let ((next (cond ((eql size words)
                           ;; Entry is exactly the right size.
                           (freelist-entry-next freelist))
                          (t
                           ;; Entry is too large, split it.
                           ;; Always create new entries with the pinned mark bit
                           ;; set. A GC will flip it, making all the freelist
                           ;; entries unmarked. No object can ever point to a freelist entry, so
                           ;; they will never be marked during a gc.
                           (let ((next (+ freelist (* words 8))))
                             (setf (sys.int::memref-unsigned-byte-64 next 0) (logior sys.int::*pinned-mark-bit*
                                                                                     (ash sys.int::+object-tag-freelist-entry+ sys.int::+object-type-shift+)
                                                                                     (ash (- size words) sys.int::+object-data-shift+))
                                   (sys.int::memref-t next 1) (freelist-entry-next freelist))
                             next)))))
          ;; Update the prev's next pointer.
          (cond (prev
                 (setf (freelist-entry-next prev) next))
                (t
                 (setf (symbol-value freelist-symbol) next))))
        ;; Write object header.
        (set-allocated-object-header freelist tag data sys.int::*pinned-mark-bit*)
        ;; Clear data.
        (sys.int::%fill-words (+ freelist 8) 0 (1- words))
        ;; Return address.
        (return freelist)))))

(defun %allocate-from-pinned-area-1 (tag data words)
  (mezzano.supervisor:without-footholds
    (mezzano.supervisor:with-mutex (*allocator-lock*)
      (mezzano.supervisor:with-pseudo-atomic
        (when *paranoid-allocation*
          (verify-freelist sys.int::*pinned-area-freelist* (* 2 1024 1024 1024) sys.int::*pinned-area-bump*))
        (let ((address (%allocate-from-freelist-area tag data words 'sys.int::*pinned-area-freelist*)))
          (when address
            (sys.int::%%assemble-value address sys.int::+tag-object+)))))))

(defun %allocate-from-pinned-area (tag data words)
  (log-allocation-profile-entry)
  (loop
     for i from 0 do
       (let ((result (%allocate-from-pinned-area-1 tag data words)))
         (when result
           (return result)))
       (when (not (eql i 0))
         ;; The GC has been run at least once, try enlarging the pinned area.
         (let ((grow-by (* words 8)))
           (incf grow-by (1- (* 2 1024 1024)))
           (setf grow-by (logand (lognot (1- (* 2 1024 1024)))
                                 grow-by))
           (mezzano.supervisor:without-footholds
             (mezzano.supervisor:with-mutex (*allocator-lock*)
               (mezzano.supervisor:with-pseudo-atomic
                   (when (mezzano.supervisor:allocate-memory-range
                          sys.int::*pinned-area-bump*
                          grow-by
                          (logior sys.int::+block-map-present+
                                  sys.int::+block-map-writable+
                                  sys.int::+block-map-zero-fill+))
                     (when mezzano.supervisor::*pager-noisy*
                       (mezzano.supervisor:debug-print-line "Expanded pinned area by " grow-by))
                     ;; Success. Advance the pinned area limit and slap down a freelist header.
                     ;; Drop into the GC to rebuild the freelist properly.
                     (setf (sys.int::memref-unsigned-byte-64 sys.int::*pinned-area-bump* 0) (sys.int::make-freelist-header (truncate grow-by 8))
                           (sys.int::memref-t sys.int::*pinned-area-bump* 1) nil)
                     (incf sys.int::*pinned-area-bump* grow-by)))))))
       (when (> i *maximum-allocation-attempts*)
         (cerror "Retry allocation" 'storage-condition))
       (sys.int::gc)))

(defun %allocate-from-wired-area-1 (tag data words)
  (mezzano.supervisor::safe-without-interrupts (tag data words)
    (mezzano.supervisor:with-symbol-spinlock (*wired-allocator-lock*)
      (when *paranoid-allocation*
        (verify-freelist sys.int::*wired-area-freelist* (* 2 1024 1024) sys.int::*wired-area-bump*))
      (let ((address (%allocate-from-freelist-area tag data words 'sys.int::*wired-area-freelist*)))
        (when address
          (sys.int::%%assemble-value address sys.int::+tag-object+))))))

(defun %allocate-from-wired-area (tag data words)
  (log-allocation-profile-entry)
  (loop
     for i from 0 do
       (let ((result (%allocate-from-wired-area-1 tag data words)))
         (when result
           (return result)))
       (when (> i *maximum-allocation-attempts*)
         (error 'storage-condition))
       (sys.int::gc)))

(defun mangle-pinned/wired-cons (object)
  ;; Convert an object-tagged cons into a cons-tagged cons.
  (let ((addr (sys.int::lisp-object-address object)))
    (sys.int::%%assemble-value (+ (logand addr (lognot #b1111)) 16)
                               sys.int::+tag-cons+)))

(defun %cons-in-pinned-area (car cdr)
  (let ((object (mangle-pinned/wired-cons
                 (%allocate-from-pinned-area sys.int::+object-tag-cons+ 0 4))))
    (setf (car object) car
          (cdr object) cdr)
    object))

(defun %cons-in-wired-area (car cdr)
  (let ((object (mangle-pinned/wired-cons
                 (%allocate-from-wired-area sys.int::+object-tag-cons+ 0 4))))
    (setf (car object) car
          (cdr object) cdr)
    object))

(defun %allocate-from-general-area (tag data words)
  (log-allocation-profile-entry)
  (let ((gc-count 0))
    (tagbody
     OUTER-LOOP
       (mezzano.supervisor:without-footholds
         (mezzano.supervisor:with-mutex (*allocator-lock*)
           (mezzano.supervisor:with-pseudo-atomic
             (tagbody
              INNER-LOOP
                (when (> (+ sys.int::*general-area-bump* (* words 8)) sys.int::*general-area-limit*)
                  (go EXPAND-AREA))
                ;; Enough size, allocate here.
                (let ((addr (logior (ash sys.int::+address-tag-general+ sys.int::+address-tag-shift+)
                                    sys.int::*general-area-bump*
                                    sys.int::*dynamic-mark-bit*)))
                  (incf sys.int::*general-area-bump* (* words 8))
                  ;; Write array header.
                  (set-allocated-object-header addr tag data 0)
                  (return-from %allocate-from-general-area
                    (sys.int::%%assemble-value addr sys.int::+tag-object+)))
              EXPAND-AREA
                ;; No memory. If there's memory available, then expand the area, otherwise run the GC.
                ;; Cannot be done when pseudo-atomic.
                ;; Divide granularity by two because this is a semispace area. Need twice as much memory.
                (let ((expansion (logand (truncate *general-area-expansion-granularity* 2) (lognot #xFFF))))
                  (when mezzano.supervisor::*pager-noisy*
                    (mezzano.supervisor:debug-print-line "Expanding general area by " expansion))
                  ;; Do new & oldspace allocations seperately, this interacts better with the freelist.
                  (when (not (mezzano.supervisor:allocate-memory-range
                              (logior sys.int::*dynamic-mark-bit*
                                      (ash sys.int::+address-tag-general+
                                           sys.int::+address-tag-shift+)
                                      sys.int::*general-area-limit*)
                              expansion
                              (logior sys.int::+block-map-present+
                                      sys.int::+block-map-writable+
                                      sys.int::+block-map-zero-fill+)))
                    (when mezzano.supervisor::*pager-noisy*
                      (mezzano.supervisor:debug-print-line "A-M-R newspace failed, no memory. Doing GC."))
                    (go DO-GC))
                  (when (not (mezzano.supervisor:allocate-memory-range
                              (logior (logxor sys.int::*dynamic-mark-bit*
                                              (ash 1 sys.int::+address-newspace/oldspace-bit+))
                                      (ash sys.int::+address-tag-general+
                                           sys.int::+address-tag-shift+)
                                      sys.int::*general-area-limit*)
                              expansion
                              sys.int::+block-map-zero-fill+))
                    ;; Roll back newspace allocation.
                    (mezzano.supervisor:release-memory-range
                     (logior sys.int::*dynamic-mark-bit*
                             (ash sys.int::+address-tag-general+
                                  sys.int::+address-tag-shift+)
                             sys.int::*general-area-limit*)
                     expansion)
                    (go DO-GC))
                  (incf sys.int::*general-area-limit* expansion))
                (go INNER-LOOP)))))
     DO-GC
       ;; Must occur outside the locks.
       (when (> gc-count *maximum-allocation-attempts*)
         (cerror "Retry allocation" 'storage-condition))
       (incf gc-count)
       (sys.int::gc)
       (go OUTER-LOOP))))

(defun %allocate-object (tag data size area)
  (when sys.int::*gc-in-progress*
    (mezzano.supervisor:panic "Allocating during GC!"))
  (let ((words (1+ size)))
    (when (oddp words)
      (incf words))
    (ecase area
      ((nil)
       (%allocate-from-general-area tag data words))
      (:pinned
       (%allocate-from-pinned-area tag data words))
      (:wired
       (%allocate-from-wired-area tag data words)))))

(defun sys.int::cons-in-area (car cdr &optional area)
  (when sys.int::*gc-in-progress*
    (mezzano.supervisor:panic "Allocating during GC!"))
  (ecase area
    ((nil)
     (cons car cdr))
    (:pinned
     (%cons-in-pinned-area car cdr))
    (:wired
     (%cons-in-wired-area car cdr))))

(sys.int::define-lap-function cons ((car cdr))
  ;; Attempt to quickly allocate a cons. Will call SLOW-CONS if things get too hairy.
  ;; This is not even remotely SMP safe.
  ;; R8 = car; R9 = cdr
  ;; Big hammer, disable interrupts. Faster than taking locks & stuff.
  (sys.lap-x86:cli)
  ;; Check argument count.
  (sys.lap-x86:cmp64 :rcx #.(ash 2 #.sys.int::+n-fixnum-bits+))
  (sys.lap-x86:jne SLOW-PATH)
  ;; Check *ENABLE-ALLOCATION-PROFILING*
  ;; FIXME: This only tests the global value.
  #| Logging every cons tends to explode the profile buffer & exhaust memory.
  (sys.lap-x86:mov64 :rax (:constant *enable-allocation-profiling*))
  (sys.lap-x86:mov64 :rax (:object :rax #.sys.int::+symbol-value+))
  (sys.lap-x86:cmp64 (:object :rax #.sys.int::+symbol-value-cell-value+) nil)
  (sys.lap-x86:jne SLOW-PATH)
  |#
  ;; Check *GC-IN-PROGRESS*.
  (sys.lap-x86:mov64 :rax (:constant sys.int::*gc-in-progress*))
  (sys.lap-x86:mov64 :rax (:object :rax #.sys.int::+symbol-value+))
  (sys.lap-x86:cmp64 (:object :rax #.sys.int::+symbol-value-cell-value+) nil)
  (sys.lap-x86:jne SLOW-PATH)
  ;; Grovel directly in the allocator mutex to make sure that it isn't held.
  (sys.lap-x86:mov64 :rax (:constant *allocator-lock*))
  (sys.lap-x86:mov64 :rax (:object :rax #.sys.int::+symbol-value+))
  (sys.lap-x86:mov64 :rax (:object :rax #.sys.int::+symbol-value-cell-value+))
  (sys.lap-x86:mov64 :rbx (:constant :unlocked))
  (sys.lap-x86:cmp64 (:object :rax 6) :rbx) ; mutex-state
  (sys.lap-x86:jne SLOW-PATH)
  ;; Fetch current bump pointer.
  (sys.lap-x86:mov64 :rax (:constant sys.int::*cons-area-bump*))
  (sys.lap-x86:mov64 :rax (:object :rax #.sys.int::+symbol-value+))
  (sys.lap-x86:mov64 :rbx (:object :rax #.sys.int::+symbol-value-cell-value+))
  ;; + 16, size of cons.
  ;; Keep the old bump pointer, that's the address of the cons.
  (sys.lap-x86:lea64 :rsi (:rbx #.(ash 16 #.sys.int::+n-fixnum-bits+)))
  ;; Test against limit.
  (sys.lap-x86:mov64 :rdx (:constant sys.int::*cons-area-limit*))
  (sys.lap-x86:mov64 :rdx (:object :rdx #.sys.int::+symbol-value+))
  (sys.lap-x86:cmp64 :rsi (:object :rdx #.sys.int::+symbol-value-cell-value+))
  (sys.lap-x86:ja SLOW-PATH)
  ;; Enough space.
  ;; Update the bump pointer.
  (sys.lap-x86:mov64 (:object :rax #.sys.int::+symbol-value-cell-value+) :rsi)
  ;; Generate the cons object.
  ;; Unfixnumize address.
  (sys.lap-x86:shr64 :rbx #.sys.int::+n-fixnum-bits+)
  ;; Set address bits and the tag bits.
  (sys.lap-x86:mov64 :rax #.(logior (ash sys.int::+address-tag-cons+ sys.int::+address-tag-shift+)
                                    sys.int::+tag-cons+))
  (sys.lap-x86:or64 :rbx :rax)
  ;; Set mark bit.
  (sys.lap-x86:mov64 :rax (:constant sys.int::*dynamic-mark-bit*))
  (sys.lap-x86:mov64 :rax (:object :rax #.sys.int::+symbol-value+))
  (sys.lap-x86:mov64 :rax (:object :rax #.sys.int::+symbol-value-cell-value+))
  (sys.lap-x86:shr64 :rax #.sys.int::+n-fixnum-bits+)
  (sys.lap-x86:or64 :rbx :rax)
  ;; RBX now holds a valid cons, with the CAR and CDR set to zero.
  ;; It is safe to turn interrupts on again.
  (sys.lap-x86:sti)
  ;; Initialize the CAR & CDR with interrupts on because touching them may
  ;; trigger paging.
  (sys.lap-x86:mov64 (:car :rbx) :r8)
  (sys.lap-x86:mov64 (:cdr :rbx) :r9)
  ;; Done. Return everything.
  (sys.lap-x86:mov64 :r8 :rbx)
  (sys.lap-x86:mov32 :ecx #.(ash 1 #.sys.int::+n-fixnum-bits+))
  (sys.lap-x86:ret)
  SLOW-PATH
  (sys.lap-x86:sti)
  ;; Tail call into SLOW-CONS.
  (sys.lap-x86:mov64 :r13 (:function slow-cons))
  (sys.lap-x86:jmp (:object :r13 #.sys.int::+fref-entry-point+)))

(defun slow-cons (car cdr)
  (when sys.int::*gc-in-progress*
    (mezzano.supervisor:panic "Allocating during GC!"))
  (log-allocation-profile-entry)
  (let ((gc-count 0))
    (tagbody
     OUTER-LOOP
       (mezzano.supervisor:without-footholds
         (mezzano.supervisor:with-mutex (*allocator-lock*)
           (mezzano.supervisor:with-pseudo-atomic
             (tagbody
              INNER-LOOP
                (when (> (+ sys.int::*cons-area-bump* 16) sys.int::*cons-area-limit*)
                  (go EXPAND-AREA))
                ;; Enough size, allocate here.
                (let* ((addr (logior (ash sys.int::+address-tag-cons+ sys.int::+address-tag-shift+)
                                     sys.int::*cons-area-bump*
                                     sys.int::*dynamic-mark-bit*))
                       (val (sys.int::%%assemble-value addr sys.int::+tag-cons+)))
                  (incf sys.int::*cons-area-bump* 16)
                  (setf (car val) car
                        (cdr val) cdr)
                  (return-from slow-cons val))
              EXPAND-AREA
                ;; No memory. If there's memory available, then expand the area, otherwise run the GC.
                ;; Cannot be done when pseudo-atomic.
                ;; Divide granularity by two because this is a semispace area. Need twice as much memory.
                (let ((expansion (logand (truncate *cons-area-expansion-granularity* 2) (lognot #xFFF))))
                  (when mezzano.supervisor::*pager-noisy*
                    (mezzano.supervisor::debug-print-line "Expanding cons area by " expansion))
                  ;; Do new & oldspace allocations seperately, this interacts better with the freelist.
                  ;; Allocate newspace.
                  (when (not (mezzano.supervisor:allocate-memory-range
                              (logior sys.int::*dynamic-mark-bit*
                                      (ash sys.int::+address-tag-cons+
                                           sys.int::+address-tag-shift+)
                                      sys.int::*cons-area-limit*)
                              expansion
                              (logior sys.int::+block-map-present+
                                      sys.int::+block-map-writable+
                                      sys.int::+block-map-zero-fill+)))
                    (when mezzano.supervisor::*pager-noisy*
                      (mezzano.supervisor:debug-print-line "A-M-R newspace failed, no memory. Doing GC."))
                    (go DO-GC))
                  ;; Allocate oldspace.
                  (when (not (mezzano.supervisor:allocate-memory-range
                              (logior (logxor sys.int::*dynamic-mark-bit*
                                              (ash 1 sys.int::+address-newspace/oldspace-bit+))
                                      (ash sys.int::+address-tag-cons+
                                           sys.int::+address-tag-shift+)
                                      sys.int::*cons-area-limit*)
                              expansion
                              sys.int::+block-map-zero-fill+))
                    (when mezzano.supervisor::*pager-noisy*
                      (mezzano.supervisor:debug-print-line "A-M-R oldspace failed, no memory. Doing GC."))
                    ;; Roll back newspace allocation.
                    (mezzano.supervisor:release-memory-range
                     (logior sys.int::*dynamic-mark-bit*
                             (ash sys.int::+address-tag-cons+
                                  sys.int::+address-tag-shift+)
                             sys.int::*cons-area-limit*)
                     expansion)
                    (go DO-GC))
                  (incf sys.int::*cons-area-limit* expansion))
                (go INNER-LOOP)))))
     DO-GC
       ;; Must occur outside the locks.
       (when (> gc-count *maximum-allocation-attempts*)
         (cerror "Retry allocation" 'storage-condition))
       (incf gc-count)
       (sys.int::gc)
       (go OUTER-LOOP))))

(defun sys.int::make-simple-vector (size &optional area)
  (%allocate-object sys.int::+object-tag-array-t+ size size area))

(defun sys.int::%make-struct (size &optional area)
  (%allocate-object sys.int::+object-tag-structure-object+ size size area))

(defun sys.int::make-closure (function environment &optional area)
  "Allocate a closure object."
  (check-type function function)
  (let* ((closure (%allocate-object sys.int::+object-tag-closure+ #x2000100 3 area))
         (entry-point (sys.int::%object-ref-unsigned-byte-64
                       function
                       sys.int::+function-entry-point+)))
    (setf
     ;; Entry point
     (sys.int::%object-ref-unsigned-byte-64 closure sys.int::+function-entry-point+) entry-point
     ;; Initialize constant pool
     (sys.int::%object-ref-t closure sys.int::+closure-function+) function
     (sys.int::%object-ref-t closure 2) environment)
    closure))

(defun make-symbol (name)
  (check-type name string)
  ;; FIXME: Copy name into the wired area and unicode normalize it.
  (let* ((symbol (%allocate-object sys.int::+object-tag-symbol+ 0 5 :wired))
         (global-value (%allocate-object sys.int::+object-tag-array-t+ 3 3 :wired)))
    (setf (svref global-value sys.int::+symbol-value-cell-symbol+) symbol)
    (setf (svref global-value sys.int::+symbol-value-cell-value+) (sys.int::%unbound-value))
    (setf (sys.int::%object-ref-t symbol sys.int::+symbol-name+) name)
    (setf (sys.int::%object-ref-t symbol sys.int::+symbol-value+) global-value)
    (setf (sys.int::%object-ref-t symbol sys.int::+symbol-function+) nil
          (symbol-plist symbol) '()
          (symbol-package symbol) nil)
    symbol))

(defun copy-symbol (symbol &optional copy-properties)
  (check-type symbol symbol)
  (let ((new-sym (make-symbol (symbol-name symbol))))
    (when copy-properties
      (when (boundp symbol)
        (setf (symbol-value new-sym) (symbol-value symbol)))
      (when (fboundp symbol)
        (setf (symbol-function new-sym) (symbol-function symbol)))
      (setf (symbol-plist new-sym) (copy-list (symbol-plist symbol))))
    new-sym))

(sys.int::define-lap-function sys.int::%%make-bignum-128-rdx-rax ()
  (sys.lap-x86:push :rbp)
  (:gc :no-frame :layout #*0)
  (sys.lap-x86:mov64 :rbp :rsp)
  (:gc :frame)
  (sys.lap-x86:push :rdx)
  (sys.lap-x86:push :rax)
  (sys.lap-x86:mov64 :rcx #.(ash 1 sys.int::+n-fixnum-bits+)) ; fixnum 1
  (sys.lap-x86:mov64 :r8 #.(ash 2 sys.int::+n-fixnum-bits+)) ; fixnum 2
  (sys.lap-x86:mov64 :r13 (:function sys.int::%make-bignum-of-length))
  (sys.lap-x86:call (:r13 #.(+ (- sys.int::+tag-object+) 8 (* sys.int::+fref-entry-point+ 8))))
  (sys.lap-x86:pop (:r8 #.(+ (- sys.int::+tag-object+) 8)))
  (sys.lap-x86:pop (:r8 #.(+ (- sys.int::+tag-object+) 16)))
  (sys.lap-x86:mov32 :ecx #.(ash 1 sys.int::+n-fixnum-bits+)) ; fixnum 1
  (sys.lap-x86:leave)
  (:gc :no-frame)
  (sys.lap-x86:ret))

(sys.int::define-lap-function sys.int::%%make-bignum-64-rax ()
  (sys.lap-x86:push :rbp)
  (:gc :no-frame :layout #*0)
  (sys.lap-x86:mov64 :rbp :rsp)
  (:gc :frame)
  (sys.lap-x86:push 0)
  (sys.lap-x86:push :rax)
  (sys.lap-x86:mov64 :rcx #.(ash 1 sys.int::+n-fixnum-bits+)) ; fixnum 1
  (sys.lap-x86:mov64 :r8 #.(ash 1 sys.int::+n-fixnum-bits+)) ; fixnum 1
  (sys.lap-x86:mov64 :r13 (:function sys.int::%make-bignum-of-length))
  (sys.lap-x86:call (:r13 #.(+ (- sys.int::+tag-object+) 8 (* sys.int::+fref-entry-point+ 8))))
  (sys.lap-x86:pop (:r8 #.(+ (- sys.int::+tag-object+) 8)))
  (sys.lap-x86:mov32 :ecx #.(ash 1 sys.int::+n-fixnum-bits+)) ; fixnum 1
  (sys.lap-x86:leave)
  (:gc :no-frame)
  (sys.lap-x86:ret))

;;; This is used by the bignum code so that bignums and fixnums don't have
;;; to be directly compared.
(defun sys.int::%make-bignum-from-fixnum (n)
  (let ((bignum (sys.int::%make-bignum-of-length 1)))
    (setf (sys.int::%object-ref-signed-byte-64 bignum 0) n)
    bignum))

(defun sys.int::%make-bignum-of-length (words &optional area)
  (%allocate-object sys.int::+object-tag-bignum+ words words area))

(sys.int::define-lap-function sys.int::%%make-double-float-rax ()
  (sys.lap-x86:push :rbp)
  (:gc :no-frame :layout #*0)
  (sys.lap-x86:mov64 :rbp :rsp)
  (:gc :frame)
  (sys.lap-x86:push 0)
  (sys.lap-x86:push :rax)
  (sys.lap-x86:mov64 :rcx #.(ash 4 sys.int::+n-fixnum-bits+)) ; fixnum 4
  ;; Tag.
  (sys.lap-x86:mov64 :r8 #.(ash sys.int::+object-tag-double-float+
                                sys.int::+n-fixnum-bits+))
  ;; Header data.
  (sys.lap-x86:xor64 :r9 :r9)
  ;; Words.
  (sys.lap-x86:mov64 :r10 #.(ash 1 sys.int::+n-fixnum-bits+)) ; fixnum 1
  ;; Area
  (sys.lap-x86:mov64 :r11 nil) ; fixnum 1
  (sys.lap-x86:mov64 :r13 (:function %allocate-object))
  ;; Allocate object.
  (sys.lap-x86:call (:object :r13 #.sys.int::+fref-entry-point+))
  ;; Set data.
  (sys.lap-x86:pop (:object :r8 0))
  ;; Single-value return.
  (sys.lap-x86:mov32 :ecx #.(ash 1 sys.int::+n-fixnum-bits+)) ; fixnum 1
  (sys.lap-x86:leave)
  (:gc :no-frame)
  (sys.lap-x86:ret))

(defun sys.int::allocate-std-instance (class slots layout &optional area)
  (let ((value (%allocate-object sys.int::+object-tag-std-instance+ 3 3 area)))
    (setf (sys.int::std-instance-class value) class
          (sys.int::std-instance-slots value) slots
          (sys.int::std-instance-layout value) layout)
    value))

(defun sys.int::make-function-with-fixups (tag machine-code fixups constants gc-info &optional wired)
  (let* ((mc-size (ceiling (+ (length machine-code) 16) 16))
         (gc-info-size (ceiling (length gc-info) 8))
         (pool-size (length constants))
         (total (+ (* mc-size 2) pool-size gc-info-size)))
    (when (oddp total)
      (incf total))
    (let* ((object (%allocate-object tag
                                     (logior (ash mc-size 8)
                                             (ash pool-size 24)
                                             (ash (length gc-info) 40))
                                     (1- total) ; subtract header.
                                     (if wired :wired :pinned)))
           (address (ash (sys.int::%pointer-field object) 4)))
      ;; Initialize entry point.
      (setf (sys.int::%object-ref-unsigned-byte-64 object sys.int::+function-entry-point+) (+ address 16))
      ;; Initialize code.
      (dotimes (i (length machine-code))
        (setf (sys.int::memref-unsigned-byte-8 address (+ i 16)) (aref machine-code i)))
      ;; Apply fixups.
      (dolist (fixup fixups)
        (let ((value (case (car fixup)
                       ((nil t)
                        (sys.int::lisp-object-address (car fixup)))
                       (:undefined-function
                        (sys.int::lisp-object-address (sys.int::%undefined-function)))
                       (:closure-trampoline
                        (sys.int::lisp-object-address (sys.int::%closure-trampoline)))
                       (:unbound-value
                        (sys.int::lisp-object-address (sys.int::%unbound-value)))
                       (:funcallable-instance-trampoline
                        (sys.int::lisp-object-address (sys.int::%funcallable-instance-trampoline)))
                       (t (error "Unsupported fixup ~S." (car fixup))))))
          (dotimes (i 4)
            (setf (sys.int::memref-unsigned-byte-8 address (+ (cdr fixup) i))
                  (logand (ash value (* i -8)) #xFF)))))
      ;; Initialize constant pool.
      (dotimes (i (length constants))
        (setf (sys.int::memref-t (+ address (* mc-size 16)) i) (aref constants i)))
      ;; Initialize GC info.
      (let ((gc-info-offset (+ address (* mc-size 16) (* pool-size 8))))
        (dotimes (i (length gc-info))
          (setf (sys.int::memref-unsigned-byte-8 gc-info-offset i) (aref gc-info i))))
      object)))

(defun sys.int::make-function (machine-code constants gc-info &optional wired)
  (sys.int::make-function-with-fixups sys.int::+object-tag-function+ machine-code '() constants gc-info wired))

(defun sys.int::allocate-funcallable-std-instance (function class slots layout &optional area)
  "Allocate a funcallable instance."
  (check-type function function)
  (let* ((object (%allocate-object sys.int::+object-tag-funcallable-instance+
                                   ;; MC size (1 2-word units, header + entry-point)
                                   ;; constant pool size (4 entries)
                                   ;; GC info size (0 octets)
                                   #x00000004000100
                                   5
                                   area))
         (entry-point (sys.int::%object-ref-unsigned-byte-64
                       (sys.int::%funcallable-instance-trampoline)
                       sys.int::+function-entry-point+)))
    (setf
     ;; Entry point. F-I trampoline.
     ;; TODO: If FUNCTION is an +object-tag-function+, then the entry point could point directly at it.
     (sys.int::%object-ref-unsigned-byte-64 object sys.int::+function-entry-point+) entry-point
     ;; Function and other bits.
     (sys.int::%object-ref-t object sys.int::+funcallable-instance-function+) function
     (sys.int::%object-ref-t object sys.int::+funcallable-instance-class+) class
     (sys.int::%object-ref-t object sys.int::+funcallable-instance-slots+) slots
     (sys.int::%object-ref-t object sys.int::+funcallable-instance-layout+) layout)
    object))

(defun sys.int::make-weak-pointer (key &optional (value key) finalizer area)
  ;; Hold VALUE as long as KEY is live.
  ;; Call FINALIZER when the weak-pointer dies.
  ;; Disallow weak pointers to objects with dynamic-extent allocation.
  (check-type finalizer (or null function))
  (assert (or (sys.int::immediatep key)
              (not (eql (ldb (byte sys.int::+address-tag-size+ sys.int::+address-tag-shift+)
                             (sys.int::lisp-object-address key))
                        sys.int::+address-tag-stack+)))
          (key)
          "Weak pointers to object with dynamic-extent allocation not supported.")
  (let ((object (%allocate-object sys.int::+object-tag-weak-pointer+
                                  ;; Set the live bit in the header before setting the key cell.
                                  ;; If a GC occurs during initialization then the key will
                                  ;; remain live because MAKE-WEAK-POINTER has a strong reference
                                  ;; to it.
                                  ;; %ALLOCATE-OBJECT will initialize the key cell to some
                                  ;; safe object (probably 0).
                                  (ash 1 sys.int::+weak-pointer-header-livep+)
                                  5
                                  area)))
    (when finalizer
      ;; Atomically add to the finalizer list.
      (loop
         for prev-finalizer = sys.int::*known-finalizers*
         do
           (setf (sys.int::%object-ref-t object sys.int::+weak-pointer-finalizer-link+)
                 prev-finalizer)
           (when (eql (sys.int::cas (sys.int::symbol-global-value 'sys.int::*known-finalizers*)
                                    prev-finalizer
                                    object)
                      prev-finalizer)
             (return))))
    ;; Order carefully, KEY must be set last or the GC might finalize this
    ;; too soon.
    (setf (sys.int::%object-ref-t object sys.int::+weak-pointer-value+) value
          (sys.int::%object-ref-t object sys.int::+weak-pointer-finalizer+) finalizer
          (sys.int::%object-ref-t object sys.int::+weak-pointer-key+) key)
    object))

(defun sys.int::make-ratio (numerator denominator)
  (let ((value (%allocate-object sys.int::+object-tag-ratio+ 0 2 nil)))
    (setf (sys.int::%object-ref-t value sys.int::+ratio-numerator+) numerator
          (sys.int::%object-ref-t value sys.int::+ratio-denominator+) denominator)
    value))
