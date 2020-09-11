(@module (begin end)
(@label begin)
(def payForSignature
     (@make-interaction
      ((@list Buyer Seller))
      ((digest0 : Digest) (price : nat))
      ()
      (begin0 end0)
      ;; Entry point for the interaction -- from here on user must be Buyer
      (@label begin0)
      (deposit! Buyer price)

      ;; Switching to Seller
      (@label cp)
      (@ Seller (def signature (sign digest0)))
      (publish! Seller signature)
      ;; This part is consensual, but part of the Seller transaction
      (def tmp (@app isValidSignature Seller digest0 signature))
      (require! tmp) ; belongs to Seller
      (withdraw! Seller price)
      ;; In a standalone app, return kills the contract.
      ;; In a function called as part of a larger application,
      ;; it will actually set the state to the invoked continuation.
      (return (@tuple))
      (@label end0)))
;; Return from the application-defining interaction.
;; Instead of returning a unit, should it be returning a first-class environment
;; exporting all the variables defined?
(return (@tuple))
(@label end))
