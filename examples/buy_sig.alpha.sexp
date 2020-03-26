(@interaction
   ((@list Buyer Seller))
   (def payForSignature
     (λ ((digest0 : Digest) (price : Assets))
       (@ Buyer (deposit! price))
       (@ Seller (@verifiably (def signature (sign digest0))))
       (@ Seller (publish! signature))
       (verify! signature)
       (withdraw! Seller price))))