(in-package :mezzanine.runtime)

;; Hardcoded string accessor, the support stuff for arrays doesn't function at this point.
(defun char (string index)
  (assert (sys.int::character-array-p string) (string))
  (let ((data (sys.int::%array-like-ref-t string 0)))
    (assert (and (<= 0 index)
                 (< index (sys.int::%object-header-data data)))
            (string index))
    (code-char
     (case (sys.int::%object-tag data)
       (#.sys.int::+object-tag-array-unsigned-byte-8+
        (sys.int::%array-like-ref-unsigned-byte-8 data index))
       (#.sys.int::+object-tag-array-unsigned-byte-16+
        (sys.int::%array-like-ref-unsigned-byte-16 data index))
       (#.sys.int::+object-tag-array-unsigned-byte-32+
        (sys.int::%array-like-ref-unsigned-byte-32 data index))
       (t 0)))))

(defun code-char (code)
  (sys.int::%%assemble-value (ash code 4) sys.int::+tag-character+))

(defun char-code (character)
  (logand (ash (sys.int::lisp-object-address character) -4) #x1FFFFF))