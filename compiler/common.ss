(export #t)

(import :gerbil/gambit/bytes
        <expander-runtime>
        (for-template :glow/compiler/syntax-context)
        :std/format
        :std/iter
        :clan/utils/base
        :clan/utils/files)

;; stx-atomic-literal? : Any -> Bool
(def (stx-atomic-literal? v)
  (def e (stx-e v))
  (or (integer? e) (string? e) (bytes? e) (boolean? e)))

;; stx-leaf? : Any -> Bool
(def (stx-leaf? v) (or (identifier? v) (stx-atomic-literal? v)))

;; head-id : Stx -> (U Id #f)
(def (head-id stx)
  (cond ((identifier? stx) stx)
        ((stx-pair? stx) (head-id (stx-car stx)))
        (else #f)))

;; restx1 : Stx Any -> Stx
;; restore the lexical-context and source-location from stx onto e
;; TODO: also preserve any "syntax properties" such as type, visibility, etc.
(def (restx1 stx e)
  (datum->syntax (head-id stx) e (stx-source stx)))

;; restx : Stx Any -> Stx
;; multiple levels for a nested list / tree
(def (restx stx e)
  (cond ((and (list? e) (stx-list? stx) (= (length e) (stx-length stx)))
         (restx1 stx (stx-map restx stx e)))
        ((and (pair? e) (stx-pair? stx))
         (let ((p (cons (restx (stx-car stx) (car e))
                        (restx (stx-cdr stx) (cdr e)))))
           (if (pair? stx) p (restx1 stx p))))
        (else
         (restx1 stx e))))

;; stx-sexpr=? : Stx Stx -> Bool
(def (stx-sexpr=? a b) (equal? (syntax->datum a) (syntax->datum b)))

;; stx-sexpr=?/recur : Stx Stx [Stx Stx -> Bool] -> Bool
;; The rec=? function is only called on sub-pieces of the syntax,
;; so it can be used for recursion based on decreasing size
(def (stx-sexpr=?/recur a b rec=?)
  (cond
    ((or (stx-list? a) (stx-list? b))
     (and (stx-list? a) (stx-list? b) (= (stx-length a) (stx-length b))
          (andmap rec=? (syntax->list a) (syntax->list b))))
    ((or (stx-pair? a) (stx-pair? b))
     (and (stx-pair? a) (stx-pair? b)
          (rec=? (stx-car a) (stx-car b))
          (let ((a2 (stx-cdr a)) (b2 (stx-cdr b)))
            (cond ((and (stx-pair? a2) (stx-pair? b2))
                   (stx-sexpr=?/recur a2 b2 rec=?))
                  (else
                   (rec=? a2 b2))))))
    ((or (stx-leaf? a) (stx-leaf? b))
     (stx-sexpr=? a b))
    (else (error 'stx-sexpr=?/recur "unknown syntax structure:" a b))))

;; stx-shallow-source=? : Stx Stx -> Bool
;; only cares about source locations at the very top
(def (stx-shallow-source=? a b) (equal? (stx-source a) (stx-source b)))

;; stx-deep-source=? : Stx Stx -> Bool
;; only cares about source locations and structure of lists/containers
;; does not care about leaves such as symbols or literals
(def (stx-deep-source=? a b)
  (and (stx-shallow-source=? a b)
       (cond
         ((or (stx-leaf? a) (stx-leaf? b))
          (and (stx-leaf? a) (stx-leaf? b)))
         (else
          (stx-sexpr=?/recur a b stx-deep-source=?)))))


;; TODO: do we need to properly parameterize the context (?)
(def (read-sexp-file file)
  (read-syntax-from-file file))

;; NB: this is lossy of source location and identifier resolution
(def (write-sexps statements (port (current-output-port)))
  (for ((stmt statements))
    (fprintf port "~y" (syntax->datum stmt))))